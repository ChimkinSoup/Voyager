import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/settings/services/data_export_service.dart';

/// Thrown when an archive isn't a backup this version can read. Restoring
/// nothing and saying why beats restoring half of something misread.
class BackupFormatException implements Exception {
  BackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Uploads restored records — `RemoteSyncService.pushRestoredRecords` in the
/// app, which also clears the character-operation log for the collections that
/// keep one so the restored text is not resolved away on the next pull.
typedef BackupRecordUploader =
    Future<void> Function(String collection, List<Object> records);

/// Uploads restored settings — [RemoteSyncService.pushSettings] in the app.
typedef BackupSettingsUploader = Future<void> Function(AppSettings settings);

/// What a restore actually did, so the caller can report it.
class BackupImportSummary {
  const BackupImportSummary({
    required this.restoredByCollection,
    required this.skipped,
    required this.settingsRestored,
    this.mediaFilesRestored = 0,
  });

  /// Records written, per collection. Collections that needed no work are
  /// absent rather than present with a zero.
  final Map<String, int> restoredByCollection;

  /// Records the backup held that the database already matched.
  final int skipped;

  final bool settingsRestored;

  /// Image files copied out of the archive into the local cache.
  final int mediaFilesRestored;

  int get restoredTotal =>
      restoredByCollection.values.fold(0, (sum, count) => sum + count);
}

class DataImportService {
  DataImportService({
    required AppDatabase db,
    required List<BackupCollection> collections,
    required SettingsRepository settingsRepository,
    required BackupRecordUploader pushRecords,
    required BackupSettingsUploader pushSettings,
    MediaRepository? mediaRepository,
    MediaFileStore? mediaFileStore,
  }) : _db = db,
       _collections = collections,
       _settingsRepository = settingsRepository,
       _pushRecords = pushRecords,
       _pushSettings = pushSettings,
       _mediaRepository = mediaRepository,
       _mediaFileStore = mediaFileStore;

  final AppDatabase _db;
  final List<BackupCollection> _collections;
  final SettingsRepository _settingsRepository;
  final BackupRecordUploader _pushRecords;
  final BackupSettingsUploader _pushSettings;

  /// Null in tests that restore only the JSON half. Without them an archive's
  /// image bytes are ignored and the restored assets stay `missing`, which is
  /// recoverable (they download) rather than wrong.
  final MediaRepository? _mediaRepository;
  final MediaFileStore? _mediaFileStore;

  Future<BackupImportSummary> importFromZip(File zipFile) async {
    final zipBytes = await zipFile.readAsBytes();
    final parsed = await compute(extractBackupIsolate, zipBytes);

    final backupCollections =
        parsed['collections'] as Map<String, List<Map<String, dynamic>>>;
    final backupSettings = parsed['settings'] as Map<String, dynamic>?;
    final backupBlobs = parsed['media'] as Map<String, Uint8List>? ?? const {};

    // Read the current state of every collection up front. Comparing the
    // backup against it is what keeps the restore — and the upload that
    // follows — down to the records that actually differ.
    final localByCollection = <String, Map<String, Map<String, dynamic>>>{};
    for (final collection in _collections) {
      localByCollection[collection.name] = {
        for (final record in await collection.read()) record.id: record.data,
      };
    }
    final localSettings = await _settingsRepository.getSettings();

    final restored = <String, List<Object>>{};
    // What a collection's `afterRestore` wrote on top of its restored records.
    // Uploaded with them but not counted as restored — nothing in the backup
    // asked for these.
    final followUps = <String, List<Object>>{};
    var skipped = 0;
    AppSettings? restoredSettings;

    // One transaction for the whole restore: a backup half-applied because
    // the process died partway through would be worse than one not applied.
    await _db.transaction(() async {
      for (final collection in _collections) {
        final local = localByCollection[collection.name]!;
        final records = [
          for (final json in backupCollections[collection.name] ?? const [])
            BackupRecord.fromJson(json),
        ];
        collection.prepare?.call(records);
        for (final record in records) {
          final localData = local[record.id];
          if (localData != null && backupContentEquals(localData, record.data)) {
            skipped++;
            continue;
          }
          final model = await collection.restore(
            record.id,
            _withRestoredVersion(record.data, localData),
          );
          (restored[collection.name] ??= []).add(model);
        }
        if (restored.containsKey(collection.name)) {
          final extra = await collection.afterRestore?.call() ?? const [];
          if (extra.isNotEmpty) followUps[collection.name] = extra;
        }
      }

      if (backupSettings != null &&
          !backupContentEquals(
            settingsToFirestore(localSettings),
            backupSettings,
          )) {
        final merged = mergeSettingsFromRemote(
          _withRestoredSettingsClock(backupSettings, localSettings),
          localSettings,
        );
        await _settingsRepository.saveSettings(
          merged,
          recordLocalActivity: false,
        );
        restoredSettings = merged;
      }
    });

    // Blobs are written after the transaction and before the uploads: the
    // asset rows they belong to are committed by now, so a file landing on
    // disk always has a row to describe it, and writing megabytes of images
    // inside a write transaction would block every other write in the app.
    final mediaFilesRestored = await _restoreMediaBlobs(backupBlobs);

    // Uploads run after the transaction commits — they are network calls, and
    // holding a write transaction open across them would block every other
    // write in the app for the duration.
    //
    // They take the same route as any other write, so a failed one lands on
    // the outbox exactly as it would have otherwise. What is *not* covered is
    // the process dying between the commit and the loop below: those records
    // are restored locally but never announced, and stay that way until they
    // are edited again or the backup is imported a second time.
    for (final entry in restored.entries) {
      // Follow-ups last: one that rewrote a restored record uploads over it.
      await _pushRecords(entry.key, [
        ...entry.value,
        ...?followUps[entry.key],
      ]);
    }
    final settings = restoredSettings;
    if (settings != null) await _pushSettings(settings);

    return BackupImportSummary(
      restoredByCollection: {
        for (final entry in restored.entries) entry.key: entry.value.length,
      },
      skipped: skipped,
      settingsRestored: settings != null,
      mediaFilesRestored: mediaFilesRestored,
    );
  }

  /// Writes an archive's image bytes into the local cache and marks the
  /// assets they belong to as present.
  ///
  /// The download state is corrected from what is actually on disk rather
  /// than trusted from the backup: an asset row restored from an archive says
  /// nothing about whether *this* device has the bytes, and it is exactly the
  /// devices that have just been restored onto that would otherwise sit
  /// waiting for a download of a file already sitting next to them.
  Future<int> _restoreMediaBlobs(Map<String, Uint8List> blobs) async {
    final store = _mediaFileStore;
    final repository = _mediaRepository;
    if (store == null || repository == null || blobs.isEmpty) return 0;

    final byContentHash = <String, Uint8List>{};
    for (final entry in blobs.entries) {
      final name = entry.key.substring(backupMediaDirectory.length);
      final dot = name.lastIndexOf('.');
      byContentHash[dot == -1 ? name : name.substring(0, dot)] = entry.value;
    }

    var written = 0;
    for (final asset in await repository.getAllAssets()) {
      final bytes = byContentHash[asset.contentHash];
      if (bytes == null) continue;
      final format = MediaImageFormat.fromMimeType(asset.mimeType);
      if (format == null) continue;
      await store.writeBytes(asset.contentHash, format, bytes);
      written++;
      if (asset.downloadState == MediaDownloadState.present) continue;
      await repository.upsertAsset(
        asset.copyWith(
          downloadState: MediaDownloadState.present,
          clearFailureReason: true,
        ),
        recordLocalActivity: false,
      );
    }
    return written;
  }

  /// The backup payload with a version high enough for the restore to stick.
  ///
  /// One past both the local row and the backup's own version: the local part
  /// makes the write win here, and because the local row is itself at least as
  /// high as whatever this device last synced, it also beats the copy sitting
  /// in Firestore. Without that, restoring something deleted on another device
  /// would be undone by the next pull, which would see a higher remote version
  /// and put the tombstone back.
  ///
  /// Collections with no `version` field are append-only and never merged, so
  /// they are left alone rather than given a field they don't use.
  Map<String, dynamic> _withRestoredVersion(
    Map<String, dynamic> backup,
    Map<String, dynamic>? local,
  ) {
    if (!backup.containsKey('version')) return backup;
    final backupVersion = (backup['version'] as num?)?.toInt() ?? 0;
    final localVersion = (local?['version'] as num?)?.toInt() ?? 0;
    return {
      ...backup,
      'version': (localVersion > backupVersion ? localVersion : backupVersion) + 1,
    };
  }

  /// Settings resolve by clock rather than by version, so the restored
  /// document needs a timestamp strictly newer than the stored one to be
  /// applied at all.
  Map<String, dynamic> _withRestoredSettingsClock(
    Map<String, dynamic> backup,
    AppSettings local,
  ) {
    final now = DateTime.now().toUtc();
    final localClock = local.updatedAt;
    final clock = localClock == null || now.isAfter(localClock)
        ? now
        : localClock.add(const Duration(milliseconds: 1));
    return {...backup, 'settingsUpdatedAt': clock.toIso8601String()};
  }
}

/// Background isolate entry point — must be top-level.
///
/// Returns
/// `{'collections': {name: [record json]}, 'settings': payload?, 'media':
/// {member name: bytes}}`.
Map<String, Object?> extractBackupIsolate(List<int> zipBytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zipBytes);
  } catch (error) {
    throw BackupFormatException('That file could not be read as a ZIP.');
  }

  Object? readJson(String fileName) {
    final file = archive.findFile(fileName);
    if (file == null) return null;
    return jsonDecode(utf8.decode(file.content as List<int>));
  }

  // The manifest is also what tells a current backup apart from one made
  // before the archive held every collection. Those older archives named a
  // file `journals.json` too, but filled it with journal *entries* in a
  // different shape, so reading one without checking would quietly restore
  // nonsense.
  final manifest = readJson(backupManifestFileName);
  if (manifest is! Map) {
    throw BackupFormatException(
      'This ZIP has no $backupManifestFileName, so it is not a Voyager backup '
      '(backups taken before this version are not supported).',
    );
  }
  final formatVersion = (manifest['formatVersion'] as num?)?.toInt();
  if (formatVersion != backupFormatVersion) {
    throw BackupFormatException(
      'This backup is format version $formatVersion; this version of Voyager '
      'reads version $backupFormatVersion.',
    );
  }

  final media = <String, Uint8List>{};
  for (final file in archive.files) {
    if (!file.isFile) continue;
    if (!file.name.startsWith(backupMediaDirectory)) continue;
    media[file.name] = Uint8List.fromList(file.content as List<int>);
  }

  final collections = <String, List<Map<String, dynamic>>>{};
  for (final entry in (manifest['collections'] as Map? ?? {}).entries) {
    final name = entry.key as String;
    final content = readJson('$name.json');
    if (content is! List) continue;
    collections[name] = [
      for (final record in content) Map<String, dynamic>.from(record as Map),
    ];
  }

  final settings = readJson('${FirestoreCollections.settings}.json');
  return {
    'collections': collections,
    'settings': settings is Map ? Map<String, dynamic>.from(settings) : null,
    'media': media,
  };
}
