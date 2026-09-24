import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voyager/domain/models/media_models.dart';

/// Fraction of the volume below which the user is warned about disk space.
const double lowDiskFreeFraction = 0.05;

/// The on-disk half of the media cache: one file per unique blob, named by
/// content hash.
///
/// Content-addressed rather than id-addressed for the same reason the Storage
/// path is: two assets that deduped to identical bytes are one file, and a
/// file's name is enough to verify it holds what it claims to. Nothing here
/// knows about references or sync — it stores and returns bytes.
class MediaFileStore {
  MediaFileStore({Directory? root}) : _explicitRoot = root;

  /// Set by tests to a temp directory; null in the app, which resolves the
  /// documents directory once and caches it.
  final Directory? _explicitRoot;
  Directory? _resolvedRoot;

  /// `<documents>/media`, created on first use.
  Future<Directory> root() async {
    final cached = _resolvedRoot ?? _explicitRoot;
    if (cached != null) {
      if (!await cached.exists()) await cached.create(recursive: true);
      return cached;
    }
    final documents = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(documents.path, 'media'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _resolvedRoot = dir;
  }

  /// Where the blob for [contentHash] lives, whether or not it exists yet.
  ///
  /// The extension is carried so that a file dragged out of the cache, or
  /// handed to a "Save as…", opens in whatever the OS associates with it.
  ///
  /// [contentHash] arrives from synced and restored records, so it is refused
  /// unless it is a bare name: `../x` would otherwise point outside the cache.
  Future<File> fileFor(String contentHash, MediaImageFormat format) async {
    if (!_isBareName(contentHash)) {
      throw ArgumentError.value(contentHash, 'contentHash', 'not a bare name');
    }
    final dir = await root();
    return File(p.join(dir.path, '$contentHash.${format.extension}'));
  }

  Future<File?> fileForAsset(MediaAsset asset) async {
    final format = MediaImageFormat.fromMimeType(asset.mimeType);
    if (format == null || !_isBareName(asset.contentHash)) return null;
    final file = await fileFor(asset.contentHash, format);
    return await file.exists() ? file : null;
  }

  Future<bool> hasBytes(MediaAsset asset) async {
    return await fileForAsset(asset) != null;
  }

  Future<Uint8List?> readBytes(MediaAsset asset) async {
    final file = await fileForAsset(asset);
    if (file == null) return null;
    return file.readAsBytes();
  }

  /// Writes [bytes] for [contentHash], and returns the file.
  ///
  /// A blob that is already there is left alone rather than rewritten: the
  /// name *is* the hash of the content, so an existing file with this name
  /// already holds exactly these bytes, and skipping the write is what makes
  /// re-pasting the same screenshot cost nothing.
  Future<File> writeBytes(
    String contentHash,
    MediaImageFormat format,
    Uint8List bytes,
  ) async {
    final file = await fileFor(contentHash, format);
    if (await file.exists() && await file.length() == bytes.length) {
      return file;
    }
    return file.writeAsBytes(bytes, flush: true);
  }

  /// Removes a blob from disk. Missing is success — purge runs on every
  /// device, and only one of them has to have had the bytes.
  Future<void> deleteBytes(String contentHash, MediaImageFormat format) async {
    // No file can have been written under a name [fileFor] refuses.
    if (!_isBareName(contentHash)) return;
    final file = await fileFor(contentHash, format);
    if (await file.exists()) await file.delete();
  }

  Future<void> deleteBytesForAsset(MediaAsset asset) async {
    final format = MediaImageFormat.fromMimeType(asset.mimeType);
    if (format == null) return;
    await deleteBytes(asset.contentHash, format);
  }

  /// Total size of the cache directory, for the settings readout.
  ///
  /// Measured from the files rather than summed from `byteSize` in the
  /// database so that the number answers "how much disk is this costing me",
  /// including any blob whose row has already gone.
  Future<int> cacheSizeBytes() async {
    final dir = await root();
    var total = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// Files in the cache with no live asset row pointing at them.
  ///
  /// The purge deletes blobs it knows about; this catches the ones it cannot
  /// — a row lost to a failed migration, a half-finished download — so the
  /// cache cannot grow without bound in ways nothing is tracking.
  Future<List<File>> orphanedFiles(Set<String> liveContentHashes) async {
    final dir = await root();
    final orphans = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final hash = p.basenameWithoutExtension(entity.path);
      if (!liveContentHashes.contains(hash)) orphans.add(entity);
    }
    return orphans;
  }

  /// Free space on the media volume as a fraction of its total size, or null
  /// when the platform will not say.
  ///
  /// Returned as a fraction rather than a byte count because the threshold
  /// that matters is relative: 2 GB free is comfortable on a phone and nearly
  /// empty on a 2 TB desktop drive.
  Future<double?> freeSpaceFraction() async {
    try {
      final dir = await root();
      final stat = await _volumeStats(dir.path);
      if (stat == null || stat.total <= 0) return null;
      return stat.free / stat.total;
    } catch (_) {
      return null;
    }
  }

  /// Free bytes on the volume holding [path], or null when the platform will
  /// not say.
  Future<int?> freeBytesAt(String path) async {
    try {
      return (await _volumeStats(path))?.free;
    } catch (_) {
      return null;
    }
  }

  Future<bool> isDiskLow() async {
    final fraction = await freeSpaceFraction();
    return fraction != null && fraction < lowDiskFreeFraction;
  }

  /// Total and free bytes on the volume holding [path].
  ///
  /// Shelling out rather than binding an FFI call per platform: this runs
  /// once when the settings page opens and once before a prefetch, so the
  /// process cost is irrelevant next to carrying two native bindings.
  Future<({int total, int free})?> _volumeStats(String path) async {
    if (Platform.isWindows) {
      final drive = p.rootPrefix(path).replaceAll(RegExp(r'[\\/]'), '');
      if (drive.isEmpty) return null;
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "(Get-PSDrive -Name ${drive.replaceAll(':', '')} | "
            'Select-Object -First 1 | '
            'ForEach-Object { "\$(\$_.Used + \$_.Free) \$(\$_.Free)" })',
      ]);
      if (result.exitCode != 0) return null;
      final parts = result.stdout.toString().trim().split(RegExp(r'\s+'));
      if (parts.length < 2) return null;
      final total = int.tryParse(parts[0]);
      final free = int.tryParse(parts[1]);
      if (total == null || free == null) return null;
      return (total: total, free: free);
    }

    // df reports in 1K blocks: "Filesystem 1K-blocks Used Available …".
    final result = await Process.run('df', ['-k', path]);
    if (result.exitCode != 0) return null;
    final lines = result.stdout.toString().trim().split('\n');
    if (lines.length < 2) return null;
    final parts = lines[1].trim().split(RegExp(r'\s+'));
    if (parts.length < 4) return null;
    final total = int.tryParse(parts[1]);
    final free = int.tryParse(parts[3]);
    if (total == null || free == null) return null;
    return (total: total * 1024, free: free * 1024);
  }
}

final _bareName = RegExp(r'^[A-Za-z0-9_-]+$');

bool _isBareName(String contentHash) => _bareName.hasMatch(contentHash);
