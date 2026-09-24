import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';

/// Name of the archive member describing the backup itself.
const backupManifestFileName = 'manifest.json';

/// Prefix for archive members that hold image bytes rather than JSON.
///
/// The prefix is what tells the zip writer and reader which members to leave
/// alone: everything else in the archive is a JSON document, and running
/// `jsonEncode` over a JPEG would produce a file nothing could restore.
/// Members are named `media/<contentHash>.<ext>`, the same name the on-disk
/// cache uses, so a restore is a straight copy.
const backupMediaDirectory = 'media/';

/// Archive layout version. Bumped when the shape of the files inside the zip
/// changes; [DataImportService] refuses anything it does not recognise rather
/// than half-restoring an archive it cannot read.
const backupFormatVersion = 2;

class DataExportService {
  DataExportService({
    required AppDatabase db,
    required List<BackupCollection> collections,
    required SettingsRepository settingsRepository,
    MediaRepository? mediaRepository,
    MediaFileStore? mediaFileStore,
  }) : _db = db,
       _collections = collections,
       _settingsRepository = settingsRepository,
       _mediaRepository = mediaRepository,
       _mediaFileStore = mediaFileStore;

  final AppDatabase _db;
  final List<BackupCollection> _collections;
  final SettingsRepository _settingsRepository;

  /// Both null in tests that only care about the JSON half of a backup. When
  /// either is missing the archive simply carries no image bytes — the asset
  /// rows and references still round-trip, so a restore rebuilds the
  /// structure and the blobs come back from Storage if they are there.
  final MediaRepository? _mediaRepository;
  final MediaFileStore? _mediaFileStore;

  /// Writes the whole backup archive to [destination], which the caller has
  /// already picked. Written straight to its final home rather than staged in
  /// the documents directory and copied: the copy left a stray archive behind
  /// whenever the copy or the delete failed.
  Future<File> exportDataToZip(File destination) async {
    final files = await buildArchiveContents();

    // Serializing and zipping is CPU-bound, so it runs off the UI isolate.
    final zipBytes = await compute(generateBackupZipIsolate, files);

    return await destination.writeAsBytes(zipBytes, flush: true);
  }

  /// Every file the archive will hold, keyed by name, as JSON-encodable
  /// structures. Split out from [exportDataToZip] so tests can read a backup's
  /// contents without touching the filesystem.
  Future<Map<String, Object>> buildArchiveContents() async {
    final files = <String, Object>{};
    final counts = <String, int>{};

    // One transaction, so the archive is a single point in time: a sync pull
    // landing between two collection reads would otherwise leave, say, an
    // entry without its journal. Writes wait for the few hundred ms it takes.
    await _db.transaction(() async {
      // One collection at a time rather than all at once: a full history of
      // set logs or review entries is large, and holding every collection's
      // models and payloads live simultaneously is what spikes memory.
      for (final collection in _collections) {
        final records = await collection.read();
        files['${collection.name}.json'] = [
          for (final record in records) record.toJson(),
        ];
        counts[collection.name] = records.length;
      }

      files['${FirestoreCollections.settings}.json'] = settingsToFirestore(
        await _settingsRepository.getSettings(),
      );
    });

    // Outside the transaction: blobs are content-addressed and never
    // rewritten, so reading them later cannot disagree with the rows above.
    final blobs = await _readMediaBlobs();
    files.addAll(blobs);

    files[backupManifestFileName] = {
      'formatVersion': backupFormatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'collections': counts,
      'mediaFiles': blobs.length,
    };
    return files;
  }

  /// Every image blob the cache still holds, keyed by archive member name.
  ///
  /// Read one at a time rather than gathered concurrently: a media library is
  /// the largest thing in a backup by far, and holding every image in memory
  /// at once is what would make exporting fail on the devices most likely to
  /// have a lot of them.
  ///
  /// An asset whose bytes are not on this device is skipped rather than
  /// treated as an error — it is an image another device holds, and the
  /// backup still carries its row.
  Future<Map<String, Object>> _readMediaBlobs() async {
    final repository = _mediaRepository;
    final store = _mediaFileStore;
    if (repository == null || store == null) return const {};

    final blobs = <String, Object>{};
    for (final asset in await repository.getAllAssets()) {
      final format = MediaImageFormat.fromMimeType(asset.mimeType);
      if (format == null) continue;
      final bytes = await store.readBytes(asset);
      if (bytes == null) continue;
      blobs['$backupMediaDirectory${asset.contentHash}.${format.extension}'] =
          bytes;
    }
    return blobs;
  }
}

/// Background isolate entry point — must be top-level.
///
/// The manifest, when present, is written last with a `checksums` map of
/// every other member's SHA-256, so a restore can tell a damaged archive from
/// a good one before writing anything. Additive: readers that predate it
/// ignore the field, which is why [backupFormatVersion] did not change.
List<int> generateBackupZipIsolate(Map<String, Object> files) {
  final archive = Archive();
  final checksums = <String, String>{};
  for (final entry in files.entries) {
    if (entry.key == backupManifestFileName) continue;
    // Members under `media/` are already bytes. Everything else is a
    // structure to serialise — see [backupMediaDirectory].
    final bytes = entry.key.startsWith(backupMediaDirectory)
        ? entry.value as List<int>
        : utf8.encode(jsonEncode(entry.value));
    checksums[entry.key] = sha256.convert(bytes).toString();
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  final manifest = files[backupManifestFileName];
  if (manifest != null) {
    final bytes = utf8.encode(
      jsonEncode({...manifest as Map, 'checksums': checksums}),
    );
    archive.addFile(ArchiveFile(backupManifestFileName, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive)!;
}
