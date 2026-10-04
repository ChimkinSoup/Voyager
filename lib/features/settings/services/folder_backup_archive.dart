/// The folder-backup archive: walking a folder, writing and verifying its
/// ZIP, and extracting one — FOLDER_BACKUP_HLD.md §6 and §7.
///
/// Everything here is synchronous and runs on a background isolate, through
/// [Isolate.run], so a multi-gigabyte vault never touches the UI isolate.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/features/settings/services/streaming_zip.dart';

/// The manifest entry at the archive's root (§6.3).
const folderBackupManifestName = '.voyager-folder-backup.json';
const folderBackupFormatVersion = 1;

const _chunkSize = 1 << 20;

/// A run or an extract that failed for a reason the user can act on. The
/// message is shown as is.
class FolderBackupFailure implements Exception {
  FolderBackupFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The archive does not hold what its manifest says.
class FolderBackupDamaged implements Exception {
  FolderBackupDamaged(this.message);

  final String message;

  @override
  String toString() => 'Damaged: $message';
}

/// Written in a manifest format this build does not read.
class FolderBackupUnsupported implements Exception {
  FolderBackupUnsupported(this.version);

  final Object? version;

  @override
  String toString() => 'Unsupported backup format $version';
}

class WalkedFile {
  const WalkedFile({
    required this.relative,
    required this.size,
    required this.modified,
  });

  /// Relative to the source folder, with forward slashes.
  final String relative;
  final int size;
  final DateTime modified;
}

class FolderWalk {
  const FolderWalk({
    required this.files,
    required this.totalBytes,
    required this.fingerprint,
  });

  /// Sorted by [WalkedFile.relative].
  final List<WalkedFile> files;
  final int totalBytes;
  final String fingerprint;

  int get fileCount => files.length;
}

/// The manifest's top-level fields, without its per-file list.
class FolderBackupSummary {
  const FolderBackupSummary({
    required this.capturedAt,
    required this.fileCount,
    required this.totalBytes,
    required this.fingerprint,
  });

  final DateTime? capturedAt;
  final int fileCount;
  final int totalBytes;
  final String? fingerprint;

  static FolderBackupSummary fromManifest(Map<String, dynamic> manifest) =>
      FolderBackupSummary(
        capturedAt: DateTime.tryParse(manifest['capturedAt'] as String? ?? ''),
        fileCount: (manifest['fileCount'] as num?)?.toInt() ?? 0,
        totalBytes: (manifest['totalBytes'] as num?)?.toInt() ?? 0,
        fingerprint: manifest['fingerprint'] as String?,
      );
}

/// Files never backed up (§4): Obsidian's per-device window layout, its
/// trash, and a Git plugin's repository.
bool isExcludedFromFolderBackup(String relative) {
  if (relative == '.obsidian/workspace.json' ||
      relative == '.obsidian/workspace-mobile.json') {
    return true;
  }
  final top = relative.split('/').first;
  return top == '.trash' || top == '.git';
}

/// [path] in the `\\?\` form, which lifts Windows' 260-character limit for
/// listing and opening. Elsewhere, [path] as it is.
String longPath(String path) {
  if (!Platform.isWindows) return path;
  final absolute = p.normalize(p.absolute(path));
  if (absolute.startsWith(r'\\?\')) return absolute;
  if (absolute.startsWith(r'\\')) return '\\\\?\\UNC\\${absolute.substring(2)}';
  return '\\\\?\\$absolute';
}

/// SHA-256 over the sorted `(path, size, modified)` of every file (§6.1):
/// metadata only, so an idle check never reads a file's contents.
String folderFingerprint(List<WalkedFile> sorted) {
  final lines = StringBuffer();
  for (final file in sorted) {
    lines
      ..write(file.relative)
      ..write('\u0000')
      ..write(file.size)
      ..write('\u0000')
      ..write(file.modified.toUtc().microsecondsSinceEpoch)
      ..write('\n');
  }
  return sha256.convert(utf8.encode(lines.toString())).toString();
}

/// Lists every included file under [root] without following links (§6.2
/// step 2). A folder that can't be listed fails the walk and is named.
FolderWalk walkFolder(String root) {
  final base = longPath(root);
  final files = <WalkedFile>[];
  var totalBytes = 0;

  void visit(String dir) {
    final List<FileSystemEntity> children;
    try {
      children = Directory(dir).listSync(followLinks: false);
    } on FileSystemException catch (e) {
      final relative = _relative(base, dir);
      throw FolderBackupFailure(
        "Couldn't read ${relative.isEmpty ? 'the folder' : '$relative/'}: "
        '${_osReason(e)}',
      );
    }
    for (final entity in children) {
      // Symlinks and junctions both list as links, and are not followed.
      if (entity is Link) continue;
      final relative = _relative(base, entity.path);
      if (isExcludedFromFolderBackup(relative)) continue;
      if (entity is Directory) {
        visit(entity.path);
      } else if (entity is File) {
        final stat = entity.statSync();
        if (stat.type == FileSystemEntityType.notFound) continue;
        files.add(
          WalkedFile(
            relative: relative,
            size: stat.size,
            modified: stat.modified,
          ),
        );
        totalBytes += stat.size;
      }
    }
  }

  visit(base);
  files.sort((a, b) => a.relative.compareTo(b.relative));
  return FolderWalk(
    files: files,
    totalBytes: totalBytes,
    fingerprint: folderFingerprint(files),
  );
}

/// Listing builds every child path from its parent's, so [base] is always
/// the literal prefix — no need to ask `package:path`, which does not know
/// the `\\?\` form.
String _relative(String base, String path) {
  if (path.length <= base.length) return '';
  // A drive root keeps its separator: `D:\`.
  final cut = base.endsWith(r'\') ? base.length : base.length + 1;
  return path.substring(cut).replaceAll(r'\', '/');
}

/// What went wrong, in the words a run's failure shows (§6.2 step 6).
String _osReason(FileSystemException e) => switch (e.osError?.errorCode) {
  2 || 3 => 'not found',
  5 => 'access denied',
  32 || 33 => 'in use',
  206 => 'path too long',
  _ => e.osError?.message.trim() ?? e.message,
};

/// Writes [walk]'s files from [sourcePath] into a new archive at [zipPath],
/// hashing each file's bytes as they are read, then the manifest (§6.2 step
/// 6, §6.3). Returns the manifest's summary.
///
/// A file whose size or modified time moved since the walk, or while it was
/// read, is read once more; one still moving, or one that can't be opened,
/// fails the whole run and is named.
FolderBackupSummary writeFolderArchive({
  required String sourcePath,
  required FolderWalk walk,
  required String zipPath,
  required Map<String, Object?> header,
  required DateTime capturedAt,
}) {
  for (final file in walk.files) {
    if (file.relative == folderBackupManifestName) {
      throw FolderBackupFailure(
        'The folder holds a file named $folderBackupManifestName, which '
        'Voyager uses for its own manifest',
      );
    }
  }
  final base = longPath(sourcePath);
  final writer = StreamingZipWriter(zipPath);
  try {
    final captured = <WalkedFile>[];
    final entries = <String, Map<String, Object>>{};
    var totalBytes = 0;
    for (final walked in walk.files) {
      final file = File(p.join(base, walked.relative.replaceAll('/', r'\')));
      var expected = walked;
      for (var attempt = 0; ; attempt++) {
        final before = file.statSync();
        if (before.type == FileSystemEntityType.notFound) {
          throw FolderBackupFailure(
            "Couldn't read ${walked.relative}: deleted",
          );
        }
        late Digest digest;
        var read = 0;
        try {
          writer.addEntry(walked.relative, before.modified, before.size, (add) {
            final hash = _DigestSink();
            final hasher = sha256.startChunkedConversion(hash);
            final input = file.openSync();
            try {
              while (true) {
                final chunk = input.readSync(_chunkSize);
                if (chunk.isEmpty) break;
                read += chunk.length;
                hasher.add(chunk);
                add(chunk);
              }
            } finally {
              input.closeSync();
            }
            hasher.close();
            digest = hash.value!;
          });
        } on FileSystemException catch (e) {
          throw FolderBackupFailure(
            "Couldn't read ${walked.relative}: ${_osReason(e)}",
          );
        }
        final after = file.statSync();
        final steady =
            after.size == before.size &&
            after.modified == before.modified &&
            read == before.size;
        final asWalked =
            before.size == expected.size &&
            before.modified == expected.modified;
        if (steady && (asWalked || attempt > 0)) {
          final record = WalkedFile(
            relative: walked.relative,
            size: read,
            modified: before.modified,
          );
          captured.add(record);
          totalBytes += read;
          entries[walked.relative] = {
            'size': read,
            'modified': before.modified.toUtc().toIso8601String(),
            'sha256': digest.toString(),
          };
          break;
        }
        writer.removeLast();
        if (attempt > 0) {
          throw FolderBackupFailure(
            "Couldn't read ${walked.relative}: it kept changing",
          );
        }
        expected = WalkedFile(
          relative: walked.relative,
          size: after.size,
          modified: after.modified,
        );
      }
    }

    final summary = FolderBackupSummary(
      capturedAt: capturedAt,
      fileCount: captured.length,
      totalBytes: totalBytes,
      fingerprint: folderFingerprint(captured),
    );
    final manifest = utf8.encode(
      jsonEncode({
        'formatVersion': folderBackupFormatVersion,
        ...header,
        'capturedAt': capturedAt.toUtc().toIso8601String(),
        'fileCount': summary.fileCount,
        'totalBytes': summary.totalBytes,
        'fingerprint': summary.fingerprint,
        'files': entries,
      }),
    );
    writer.addEntry(
      folderBackupManifestName,
      capturedAt,
      manifest.length,
      (add) => add(manifest),
    );
    writer.close();
    return summary;
  } catch (_) {
    writer.abandon();
    rethrow;
  }
}

/// Reads the archive's manifest alone, through its central directory.
Map<String, dynamic> _readManifest(StreamingZipReader reader) {
  final entry = reader.entries
      .where((e) => e.name == folderBackupManifestName)
      .firstOrNull;
  if (entry == null) throw FolderBackupDamaged('manifest missing');
  try {
    return Map<String, dynamic>.from(
      jsonDecode(utf8.decode(reader.readEntryBytes(entry))) as Map,
    );
  } on FormatException catch (e) {
    throw FolderBackupDamaged('manifest unreadable: ${e.message}');
  } on ZipFormatException catch (e) {
    throw FolderBackupDamaged(e.message);
  }
}

StreamingZipReader _open(String path) {
  try {
    return StreamingZipReader(path);
  } on ZipFormatException catch (e) {
    throw FolderBackupDamaged(e.message);
  }
}

/// The manifest summary of the archive at [path], for the list and the size
/// check. Does not verify — [verifyFolderArchive] does that.
FolderBackupSummary readFolderArchiveSummary(String path) {
  final reader = _open(path);
  try {
    return FolderBackupSummary.fromManifest(_readManifest(reader));
  } finally {
    reader.close();
  }
}

/// Decodes every entry and checks its SHA-256, size and the entry count
/// against the manifest (§6.2 step 7), streaming, so memory stays flat
/// whatever the archive's size.
///
/// Throws [FolderBackupDamaged] or [FolderBackupUnsupported] for what is
/// wrong with the file, and a [FileSystemException] when it can't be read
/// right now — which says nothing about the file.
FolderBackupSummary verifyFolderArchive(String path) {
  final reader = _open(path);
  try {
    final manifest = _readManifest(reader);
    if (manifest['formatVersion'] != folderBackupFormatVersion) {
      throw FolderBackupUnsupported(manifest['formatVersion']);
    }
    final files = Map<String, dynamic>.from(manifest['files'] as Map? ?? {});
    final members = [
      for (final e in reader.entries)
        if (e.name != folderBackupManifestName) e,
    ];
    if (members.length != files.length ||
        members.map((e) => e.name).toSet().length != members.length ||
        manifest['fileCount'] != files.length) {
      throw FolderBackupDamaged(
        'holds ${members.length} files, manifest lists ${files.length}',
      );
    }
    for (final entry in members) {
      final expected = files[entry.name];
      if (expected is! Map) {
        throw FolderBackupDamaged('${entry.name} is not in the manifest');
      }
      final hash = _DigestSink();
      final hasher = sha256.startChunkedConversion(hash);
      try {
        reader.readEntry(entry, hasher.add);
      } on ZipFormatException catch (e) {
        throw FolderBackupDamaged(e.message);
      }
      hasher.close();
      if (entry.size != expected['size'] ||
          hash.value.toString() != expected['sha256']) {
        throw FolderBackupDamaged('${entry.name} does not match its checksum');
      }
    }
    return FolderBackupSummary.fromManifest(manifest);
  } finally {
    reader.close();
  }
}

/// Whether [name] is safe to extract under a target folder: relative, with
/// no drive, no root and no `..` (zip-slip, §7 step 3).
bool isSafeArchiveMemberName(String name) {
  if (name.isEmpty || name.contains(r'\') || name.contains(':')) return false;
  if (name.startsWith('/')) return false;
  for (final part in name.split('/')) {
    if (part.isEmpty || part == '.' || part == '..') return false;
  }
  return true;
}

/// Verifies the archive at [zipPath], then extracts every file into
/// [targetPath], checking each one's hash as it is written (§7). Nothing is
/// written if the archive fails verification or holds an unsafe name.
void extractFolderArchive(String zipPath, String targetPath) {
  verifyFolderArchive(zipPath);
  final reader = _open(zipPath);
  try {
    final files = Map<String, dynamic>.from(
      _readManifest(reader)['files'] as Map,
    );
    final members = [
      for (final e in reader.entries)
        if (e.name != folderBackupManifestName) e,
    ];
    for (final entry in members) {
      if (!isSafeArchiveMemberName(entry.name)) {
        throw FolderBackupFailure('Refused an unsafe file name: ${entry.name}');
      }
    }
    final base = longPath(targetPath);
    for (final entry in members) {
      final expected = files[entry.name] as Map;
      final file = File(p.join(base, entry.name.replaceAll('/', r'\')));
      file.parent.createSync(recursive: true);
      final out = file.openSync(mode: FileMode.writeOnly);
      final hash = _DigestSink();
      final hasher = sha256.startChunkedConversion(hash);
      try {
        reader.readEntry(entry, (chunk) {
          hasher.add(chunk);
          out.writeFromSync(chunk);
        });
      } on ZipFormatException catch (e) {
        throw FolderBackupDamaged(e.message);
      } finally {
        out.closeSync();
      }
      hasher.close();
      if (hash.value.toString() != expected['sha256']) {
        throw FolderBackupDamaged('${entry.name} does not match its checksum');
      }
      final modified = DateTime.tryParse(expected['modified'] as String? ?? '');
      if (modified != null) file.setLastModifiedSync(modified);
    }
  } finally {
    reader.close();
  }
}

/// Copies [from] to [to] and proves the copy's size and SHA-256 match the
/// original (§9.5 step 3).
void copyVerified(String from, String to) {
  File(from).copySync(to);
  final a = File(from);
  final b = File(to);
  if (a.lengthSync() != b.lengthSync() || _hashFile(a) != _hashFile(b)) {
    throw FolderBackupFailure(
      "The copy of ${p.basename(from)} doesn't match the original",
    );
  }
}

String _hashFile(File file) {
  final hash = _DigestSink();
  final hasher = sha256.startChunkedConversion(hash);
  final input = file.openSync();
  try {
    while (true) {
      final chunk = input.readSync(_chunkSize);
      if (chunk.isEmpty) break;
      hasher.add(chunk);
    }
  } finally {
    input.closeSync();
  }
  hasher.close();
  return hash.value.toString();
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
