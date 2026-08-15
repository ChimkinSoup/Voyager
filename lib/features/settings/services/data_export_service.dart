import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';

/// Name of the archive member describing the backup itself.
const backupManifestFileName = 'manifest.json';

/// Archive layout version. Bumped when the shape of the files inside the zip
/// changes; [DataImportService] refuses anything it does not recognise rather
/// than half-restoring an archive it cannot read.
const backupFormatVersion = 2;

class DataExportService {
  DataExportService({
    required List<BackupCollection> collections,
    required SettingsRepository settingsRepository,
  }) : _collections = collections,
       _settingsRepository = settingsRepository;

  final List<BackupCollection> _collections;
  final SettingsRepository _settingsRepository;

  Future<File> exportDataToZip() async {
    final files = await buildArchiveContents();

    // Serializing and zipping is CPU-bound, so it runs off the UI isolate.
    final zipBytes = await compute(generateBackupZipIsolate, files);

    final outputDir = await getApplicationDocumentsDirectory();
    final exportFile = File(
      '${outputDir.path}/voyager_backup_${DateTime.now().millisecondsSinceEpoch}.zip',
    );
    return await exportFile.writeAsBytes(zipBytes);
  }

  /// Every file the archive will hold, keyed by name, as JSON-encodable
  /// structures. Split out from [exportDataToZip] so tests can read a backup's
  /// contents without touching the filesystem.
  Future<Map<String, Object>> buildArchiveContents() async {
    final files = <String, Object>{};
    final counts = <String, int>{};

    // One collection at a time rather than all at once: a full history of set
    // logs or review entries is large, and holding every collection's models
    // and payloads live simultaneously is what spikes memory.
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

    files[backupManifestFileName] = {
      'formatVersion': backupFormatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'collections': counts,
    };
    return files;
  }
}

/// Background isolate entry point — must be top-level.
List<int> generateBackupZipIsolate(Map<String, Object> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(jsonEncode(entry.value));
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive)!;
}
