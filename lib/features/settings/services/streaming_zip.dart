/// A ZIP writer and reader that never hold a whole entry in memory —
/// FOLDER_BACKUP_HLD.md §10.3.
///
/// `archive` 3.6 deflates and inflates each entry as one buffer, so a vault
/// holding a 1 GB video would need gigabytes of RAM to back up. This streams
/// through dart:io's zlib instead, a megabyte at a time, and writes Zip64
/// wherever a size, an offset or the entry count outgrows the classic fields.
///
/// Synchronous: it runs on background isolates only.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

const _chunkSize = 1 << 20;
const _max16 = 0xFFFF;
const _max32 = 0xFFFFFFFF;

/// An entry whose size hint is at least this gets a Zip64 field in its local
/// header. Well under 4 GiB, so deflate's worst-case growth on incompressible
/// data still fits the classic fields when the hint is below it.
const _zip64Threshold = 0xF0000000;

const _localSignature = 0x04034b50;
const _centralSignature = 0x02014b50;
const _endSignature = 0x06054b50;
const _zip64EndSignature = 0x06064b50;
const _zip64LocatorSignature = 0x07064b50;

/// General-purpose flag bit 11: the name is UTF-8.
const _utf8Flag = 0x0800;
const _methodStored = 0;
const _methodDeflate = 8;

/// The archive's framing or an entry's bytes are not what they claim to be.
class ZipFormatException implements Exception {
  ZipFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One entry as the central directory records it.
class ZipEntry {
  ZipEntry({
    required this.name,
    required this.method,
    required this.crc32,
    required this.compressedSize,
    required this.size,
    required this.localHeaderOffset,
    this.dosTime = 0,
    this.dosDate = 0,
    this.localZip64 = false,
  });

  final String name;
  final int method;
  int crc32;
  int compressedSize;
  int size;
  final int localHeaderOffset;
  final int dosTime;
  final int dosDate;

  /// Written with a Zip64 field in its local header.
  final bool localZip64;
}

class StreamingZipWriter {
  StreamingZipWriter(String path)
    : _out = File(path).openSync(mode: FileMode.write);

  final RandomAccessFile _out;
  final _entries = <ZipEntry>[];
  int _position = 0;

  int get entryCount => _entries.length;

  /// Writes the entry [name], whose bytes [produce] hands to the callback it
  /// is given, chunk by chunk. [sizeHint] is the expected uncompressed size.
  void addEntry(
    String name,
    DateTime modified,
    int sizeHint,
    void Function(void Function(List<int> chunk) add) produce,
  ) {
    final nameBytes = utf8.encode(name);
    final zip64 = sizeHint >= _zip64Threshold;
    final (dosTime, dosDate) = _dosDateTime(modified);
    final entry = ZipEntry(
      name: name,
      method: _methodDeflate,
      crc32: 0,
      compressedSize: 0,
      size: 0,
      localHeaderOffset: _position,
      dosTime: dosTime,
      dosDate: dosDate,
      localZip64: zip64,
    );

    final header = BytesBuilder()
      ..add(_u32(_localSignature))
      ..add(_u16(zip64 ? 45 : 20))
      ..add(_u16(_utf8Flag))
      ..add(_u16(_methodDeflate))
      ..add(_u16(dosTime))
      ..add(_u16(dosDate))
      // CRC and sizes are patched in once the data is written.
      ..add(_u32(0))
      ..add(_u32(zip64 ? _max32 : 0))
      ..add(_u32(zip64 ? _max32 : 0))
      ..add(_u16(nameBytes.length))
      ..add(_u16(zip64 ? 20 : 0))
      ..add(nameBytes);
    if (zip64) {
      header
        ..add(_u16(0x0001))
        ..add(_u16(16))
        ..add(_u64(0))
        ..add(_u64(0));
    }
    _write(header.takeBytes());
    final dataStart = _position;

    var crc = 0;
    var size = 0;
    final buffer = BytesBuilder(copy: false);
    void flush() {
      if (buffer.isEmpty) return;
      _write(buffer.takeBytes());
    }

    final deflater = ZLibEncoder(raw: true, level: 6).startChunkedConversion(
      _CallbackSink((compressed) {
        buffer.add(compressed);
        if (buffer.length >= _chunkSize) flush();
      }),
    );
    try {
      produce((chunk) {
        crc = getCrc32(chunk, crc);
        size += chunk.length;
        deflater.add(chunk);
      });
      deflater.close();
      flush();
    } catch (_) {
      _truncate(entry.localHeaderOffset);
      rethrow;
    }

    final compressedSize = _position - dataStart;
    if (!zip64 && (size >= _max32 || compressedSize >= _max32)) {
      _truncate(entry.localHeaderOffset);
      throw ZipFormatException('$name grew past 4 GB while it was read');
    }
    entry
      ..crc32 = crc
      ..size = size
      ..compressedSize = compressedSize;

    _out.setPositionSync(entry.localHeaderOffset + 14);
    _out.writeFromSync(_u32(crc));
    if (zip64) {
      _out.setPositionSync(entry.localHeaderOffset + 30 + nameBytes.length + 4);
      _out.writeFromSync(_u64(size));
      _out.writeFromSync(_u64(compressedSize));
    } else {
      _out.writeFromSync(_u32(compressedSize));
      _out.writeFromSync(_u32(size));
    }
    _out.setPositionSync(_position);
    _entries.add(entry);
  }

  /// Takes the entry added last back out, as if it had never been written.
  void removeLast() {
    final entry = _entries.removeLast();
    _truncate(entry.localHeaderOffset);
  }

  /// Writes the central directory, flushes and closes the file.
  void close() {
    final directoryStart = _position;
    for (final entry in _entries) {
      final nameBytes = utf8.encode(entry.name);
      final extra = BytesBuilder();
      if (entry.size >= _max32) extra.add(_u64(entry.size));
      if (entry.compressedSize >= _max32) extra.add(_u64(entry.compressedSize));
      if (entry.localHeaderOffset >= _max32) {
        extra.add(_u64(entry.localHeaderOffset));
      }
      final zip64Extra = extra.takeBytes();
      final needs64 = zip64Extra.isNotEmpty || entry.localZip64;
      _write(
        (BytesBuilder()
              ..add(_u32(_centralSignature))
              ..add(_u16(45))
              ..add(_u16(needs64 ? 45 : 20))
              ..add(_u16(_utf8Flag))
              ..add(_u16(entry.method))
              ..add(_u16(entry.dosTime))
              ..add(_u16(entry.dosDate))
              ..add(_u32(entry.crc32))
              ..add(_u32(_clamp32(entry.compressedSize)))
              ..add(_u32(_clamp32(entry.size)))
              ..add(_u16(nameBytes.length))
              ..add(_u16(zip64Extra.isEmpty ? 0 : zip64Extra.length + 4))
              ..add(_u16(0))
              ..add(_u16(0))
              ..add(_u16(0))
              ..add(_u32(0))
              ..add(_u32(_clamp32(entry.localHeaderOffset)))
              ..add(nameBytes)
              ..add(
                zip64Extra.isEmpty
                    ? const <int>[]
                    : [
                        ..._u16(0x0001),
                        ..._u16(zip64Extra.length),
                        ...zip64Extra,
                      ],
              ))
            .takeBytes(),
      );
    }
    final directorySize = _position - directoryStart;
    final count = _entries.length;
    if (count >= _max16 ||
        directoryStart >= _max32 ||
        directorySize >= _max32) {
      final zip64End = _position;
      _write(
        (BytesBuilder()
              ..add(_u32(_zip64EndSignature))
              ..add(_u64(44))
              ..add(_u16(45))
              ..add(_u16(45))
              ..add(_u32(0))
              ..add(_u32(0))
              ..add(_u64(count))
              ..add(_u64(count))
              ..add(_u64(directorySize))
              ..add(_u64(directoryStart))
              ..add(_u32(_zip64LocatorSignature))
              ..add(_u32(0))
              ..add(_u64(zip64End))
              ..add(_u32(1)))
            .takeBytes(),
      );
    }
    _write(
      (BytesBuilder()
            ..add(_u32(_endSignature))
            ..add(_u16(0))
            ..add(_u16(0))
            ..add(_u16(count >= _max16 ? _max16 : count))
            ..add(_u16(count >= _max16 ? _max16 : count))
            ..add(_u32(_clamp32(directorySize)))
            ..add(_u32(_clamp32(directoryStart)))
            ..add(_u16(0)))
          .takeBytes(),
    );
    _out.flushSync();
    _out.closeSync();
  }

  /// Closes the file without finishing it, after a failure.
  void abandon() {
    try {
      _out.closeSync();
    } catch (_) {}
  }

  void _write(List<int> bytes) {
    _out.writeFromSync(bytes);
    _position += bytes.length;
  }

  void _truncate(int position) {
    _out.truncateSync(position);
    _out.setPositionSync(position);
    _position = position;
  }
}

class StreamingZipReader {
  StreamingZipReader(String path) : _in = File(path).openSync() {
    try {
      entries = _readCentralDirectory();
    } catch (_) {
      _in.closeSync();
      rethrow;
    }
  }

  final RandomAccessFile _in;
  late final List<ZipEntry> entries;

  void close() => _in.closeSync();

  /// Hands [entry]'s uncompressed bytes to [onData] chunk by chunk, then
  /// checks them against its CRC and size. Exceptions [onData] throws pass
  /// through untouched; anything wrong with the archive is a
  /// [ZipFormatException].
  void readEntry(ZipEntry entry, void Function(List<int> chunk) onData) {
    final header = _readAt(entry.localHeaderOffset, 30);
    final view = ByteData.sublistView(header);
    if (view.getUint32(0, Endian.little) != _localSignature) {
      throw ZipFormatException('${entry.name}: bad local header');
    }
    final nameLength = view.getUint16(26, Endian.little);
    // Extracting tools read the name from here, so damage to it is damage.
    final localName = utf8.decode(
      _readAt(entry.localHeaderOffset + 30, nameLength),
      allowMalformed: true,
    );
    if (localName != entry.name) {
      throw ZipFormatException('${entry.name}: local header names $localName');
    }
    // Without a data descriptor (flag bit 3) the local header repeats the
    // method, CRC and sizes, and a tool may trust either copy. A size of
    // 0xFFFFFFFF defers to the Zip64 field.
    bool agrees(int offset, int value) {
      final local = view.getUint32(offset, Endian.little);
      return local == _max32 || local == value;
    }

    final descriptor = view.getUint16(6, Endian.little) & 0x0008 != 0;
    if (view.getUint16(8, Endian.little) != entry.method ||
        !descriptor &&
            (view.getUint32(14, Endian.little) != entry.crc32 ||
                !agrees(18, entry.compressedSize) ||
                !agrees(22, entry.size))) {
      throw ZipFormatException('${entry.name}: local header disagrees');
    }
    final dataStart =
        entry.localHeaderOffset +
        30 +
        nameLength +
        view.getUint16(28, Endian.little);

    var crc = 0;
    var size = 0;
    final pending = <List<int>>[];
    void deliver() {
      for (final chunk in pending) {
        crc = getCrc32(chunk, crc);
        size += chunk.length;
        onData(chunk);
      }
      pending.clear();
    }

    final ByteConversionSink? inflater = switch (entry.method) {
      _methodStored => null,
      _methodDeflate => ZLibDecoder(
        raw: true,
      ).startChunkedConversion(_CallbackSink(pending.add)),
      _ => throw ZipFormatException(
        '${entry.name}: unsupported compression method ${entry.method}',
      ),
    };

    var remaining = entry.compressedSize;
    var position = dataStart;
    while (remaining > 0) {
      final chunk = _readAt(
        position,
        remaining < _chunkSize ? remaining : _chunkSize,
      );
      position += chunk.length;
      remaining -= chunk.length;
      if (inflater == null) {
        pending.add(chunk);
      } else {
        try {
          inflater.add(chunk);
        } on Exception catch (e) {
          throw ZipFormatException('${entry.name}: $e');
        }
      }
      deliver();
    }
    if (inflater != null) {
      try {
        inflater.close();
      } on Exception catch (e) {
        throw ZipFormatException('${entry.name}: $e');
      }
      deliver();
    }
    if (size != entry.size) {
      throw ZipFormatException('${entry.name}: wrong size');
    }
    if (crc != entry.crc32) {
      throw ZipFormatException('${entry.name}: CRC mismatch');
    }
  }

  /// [entry] whole, for small entries such as a manifest.
  Uint8List readEntryBytes(ZipEntry entry) {
    final out = BytesBuilder(copy: false);
    readEntry(entry, out.add);
    return out.takeBytes();
  }

  /// Exactly [length] bytes at [position], or a [ZipFormatException] if the
  /// file ends first.
  Uint8List _readAt(int position, int length) {
    _in.setPositionSync(position);
    final bytes = _in.readSync(length);
    if (bytes.length != length) {
      throw ZipFormatException('Archive is truncated');
    }
    return bytes;
  }

  List<ZipEntry> _readCentralDirectory() {
    final length = _in.lengthSync();
    if (length < 22) throw ZipFormatException('Not a ZIP file');
    final tailLength = length < 22 + _max16 ? length : 22 + _max16;
    final tailStart = length - tailLength;
    final tail = _readAt(tailStart, tailLength);
    final tailView = ByteData.sublistView(tail);
    var end = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tailView.getUint32(i, Endian.little) == _endSignature) {
        end = i;
        break;
      }
    }
    if (end < 0) throw ZipFormatException('Not a ZIP file');

    var count = tailView.getUint16(end + 10, Endian.little);
    var directorySize = tailView.getUint32(end + 12, Endian.little);
    var directoryStart = tailView.getUint32(end + 16, Endian.little);
    if (count == _max16 ||
        directorySize == _max32 ||
        directoryStart == _max32) {
      final locator = tailStart + end - 20;
      if (locator < 0) throw ZipFormatException('Zip64 locator missing');
      final locatorView = ByteData.sublistView(_readAt(locator, 20));
      if (locatorView.getUint32(0, Endian.little) != _zip64LocatorSignature) {
        throw ZipFormatException('Zip64 locator missing');
      }
      final record = ByteData.sublistView(
        _readAt(locatorView.getUint64(8, Endian.little), 56),
      );
      if (record.getUint32(0, Endian.little) != _zip64EndSignature) {
        throw ZipFormatException('Zip64 end record missing');
      }
      count = record.getUint64(32, Endian.little);
      directorySize = record.getUint64(40, Endian.little);
      directoryStart = record.getUint64(48, Endian.little);
    }
    if (directoryStart + directorySize > length) {
      throw ZipFormatException('Archive is truncated');
    }

    final directory = _readAt(directoryStart, directorySize);
    final view = ByteData.sublistView(directory);
    final entries = <ZipEntry>[];
    var i = 0;
    for (var n = 0; n < count; n++) {
      if (i + 46 > directory.length ||
          view.getUint32(i, Endian.little) != _centralSignature) {
        throw ZipFormatException('Central directory is damaged');
      }
      final method = view.getUint16(i + 10, Endian.little);
      final crc = view.getUint32(i + 16, Endian.little);
      var compressedSize = view.getUint32(i + 20, Endian.little);
      var size = view.getUint32(i + 24, Endian.little);
      final nameLength = view.getUint16(i + 28, Endian.little);
      final extraLength = view.getUint16(i + 30, Endian.little);
      final commentLength = view.getUint16(i + 32, Endian.little);
      var offset = view.getUint32(i + 42, Endian.little);
      final nameStart = i + 46;
      final extraStart = nameStart + nameLength;
      final next = extraStart + extraLength + commentLength;
      if (next > directory.length) {
        throw ZipFormatException('Central directory is damaged');
      }
      final name = utf8.decode(
        directory.sublist(nameStart, extraStart),
        allowMalformed: true,
      );

      // The Zip64 field holds only the values whose classic field is maxed
      // out, in this order.
      var e = extraStart;
      while (e + 4 <= extraStart + extraLength) {
        final id = view.getUint16(e, Endian.little);
        final fieldLength = view.getUint16(e + 2, Endian.little);
        if (id == 0x0001) {
          var f = e + 4;
          int take() {
            if (f + 8 > e + 4 + fieldLength) {
              throw ZipFormatException('Zip64 field is damaged');
            }
            final value = view.getUint64(f, Endian.little);
            f += 8;
            return value;
          }

          if (size == _max32) size = take();
          if (compressedSize == _max32) compressedSize = take();
          if (offset == _max32) offset = take();
        }
        e += 4 + fieldLength;
      }

      entries.add(
        ZipEntry(
          name: name,
          method: method,
          crc32: crc,
          compressedSize: compressedSize,
          size: size,
          localHeaderOffset: offset,
        ),
      );
      i = next;
    }
    return entries;
  }
}

class _CallbackSink implements Sink<List<int>> {
  _CallbackSink(this._onData);

  final void Function(List<int>) _onData;

  @override
  void add(List<int> data) => _onData(data);

  @override
  void close() {}
}

int _clamp32(int value) => value >= _max32 ? _max32 : value;

Uint8List _u16(int value) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little);

Uint8List _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

Uint8List _u64(int value) =>
    Uint8List(8)..buffer.asByteData().setUint64(0, value, Endian.little);

/// MS-DOS time and date fields, in local time, as ZIP tools show them.
/// Clamped to the format's 1980–2107 range.
(int, int) _dosDateTime(DateTime time) {
  final t = time.toLocal();
  final year = t.year.clamp(1980, 2107);
  return (
    (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2),
    ((year - 1980) << 9) | (t.month << 5) | t.day,
  );
}
