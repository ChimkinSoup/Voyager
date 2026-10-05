import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/media_models.dart';

/// Which account this device's local data belongs to, and the wipe that hands
/// the device to another one (BUG-005).
///
/// Nothing in the local store is keyed by account: the tables, the outbox and
/// the drafts all belong to whoever was signed in last. Signing out leaves
/// them in place, so the same account signing back in loses nothing it had not
/// uploaded yet. A *different* account must never see them or sync them, so
/// it gets an empty store instead, filled by its own pull.
class LocalAccountStore {
  LocalAccountStore(
    this._db, {
    required Future<Directory> Function() dataDirectory,
    required Future<Directory> Function() backupsRoot,
  }) : _dataDirectory = dataDirectory,
       _backupsRoot = backupsRoot;

  final AppDatabase _db;
  final Future<Directory> Function() _dataDirectory;
  final Future<Directory> Function() _backupsRoot;

  /// Account content kept beside the database in the app-data directory.
  /// Device chrome (`finance_ui_prefs.json`, `settings_tab.txt`) is not
  /// listed: it says nothing about whose data this is. The notification
  /// history is cleared by the app, which holds it in memory too.
  static const _accountEntries = [
    'media',
    'session_checkpoints',
    'quick_journal_entry.json',
    'todo_subtask_drafts.json',
    'jobs_track_draft.json',
    'leetcode_track_draft.json',
  ];

  /// The account that owns the local data, or null when none has claimed it:
  /// a fresh install, or a store from before owners were recorded.
  Future<String?> owner() async {
    final row = await (_db.select(
      _db.settingsTable,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    return row?.localOwnerUid;
  }

  /// Where the automatic backups of [owner]'s data live. Unowned data backs up
  /// into the root, which [claim] then hands to the first account to sign in.
  Future<Directory> backupsDirectory() async {
    final root = await _backupsRoot();
    final uid = await owner();
    return uid == null ? root : Directory(p.join(root.path, uid));
  }

  /// The accounts this store has pulled for, by the sync watermarks — which
  /// are kept per account. For a store from before owners were recorded, the
  /// one hint of whose data it holds.
  Future<Set<String>> pulledFor() async {
    final rows = await (_db.selectOnly(
      _db.syncWatermarksTable,
      distinct: true,
    )..addColumns([_db.syncWatermarksTable.userId])).get();
    return {for (final row in rows) row.read(_db.syncWatermarksTable.userId)!};
  }

  /// Records [uid] as the owner of unowned local data that is its own — see
  /// `admitAccount` for how that is decided.
  Future<void> claim(String uid) async {
    await moveUnownedBackupsTo(uid);
    await _setOwner(uid);
  }

  /// Uploads the current owner has queued and not delivered, which a wipe
  /// would lose: outbox rows, queued or parked, and images whose bytes have
  /// not reached Storage.
  Future<int> unsyncedChanges() async {
    final outbox = _db.pendingUploadsTable.documentId.count();
    final queued = await (_db.selectOnly(
      _db.pendingUploadsTable,
    )..addColumns([outbox])).map((row) => row.read(outbox)!).getSingle();
    final media = _db.mediaAssetsTable.id.count();
    final images =
        await (_db.selectOnly(_db.mediaAssetsTable)
              ..addColumns([media])
              ..where(
                _db.mediaAssetsTable.deletedAt.isNull() &
                    _db.mediaAssetsTable.uploadState.isIn([
                      MediaUploadState.localOnly.name,
                      MediaUploadState.pending.name,
                      MediaUploadState.uploading.name,
                      MediaUploadState.failed.name,
                    ]),
              ))
            .map((row) => row.read(media)!)
            .getSingle();
    return queued + images;
  }

  /// Empties every account table and the account files, and records [uid] as
  /// the new owner.
  ///
  /// The settings row is reset rather than emptied: the synced preferences
  /// are the old account's and its pull brings the new one's, but the device
  /// id, the debugging flags, the pane widths sized for this screen and the
  /// device's own location belong to the device.
  ///
  /// The files go first and the owner last, in one transaction with the
  /// tables: if anything fails, the old account still owns what is left, and
  /// the next sign-in of another account wipes it again rather than taking
  /// it over.
  Future<void> wipeFor(String uid) async {
    final data = await _dataDirectory();
    for (final name in _accountEntries) {
      final path = p.join(data.path, name);
      switch (FileSystemEntity.typeSync(path)) {
        case FileSystemEntityType.directory:
          await Directory(path).delete(recursive: true);
        case FileSystemEntityType.file:
          await File(path).delete();
        default:
      }
    }
    await _db.transaction(() async {
      final settings = await (_db.select(
        _db.settingsTable,
      )..where((t) => t.id.equals(1))).getSingleOrNull();
      for (final table in _db.allTables) {
        await _db.delete(table).go();
      }
      await _db
          .into(_db.settingsTable)
          .insert(
            SettingsTableCompanion(
              id: const Value(1),
              localOwnerUid: Value(uid),
              deviceId: Value(settings?.deviceId),
              syncBackfillVersion: Value(
                settings?.syncBackfillVersion ?? _newStoreBackfillVersion,
              ),
              journalEntryListWidth: Value(settings?.journalEntryListWidth),
              editSidePanelWidth: Value(settings?.editSidePanelWidth),
              dreamSplitWidth: Value(settings?.dreamSplitWidth),
              workoutLibraryWidth: Value(settings?.workoutLibraryWidth),
              rankingsDeviceLatitude: Value(settings?.rankingsDeviceLatitude),
              rankingsDeviceLongitude: Value(
                settings?.rankingsDeviceLongitude,
              ),
              devUseDirectOpenWeather: _kept(settings?.devUseDirectOpenWeather),
              devOpenWeatherApiKey: Value(settings?.devOpenWeatherApiKey),
              devShowSyncLocalSaves: _kept(settings?.devShowSyncLocalSaves),
              devShowSyncUploads: _kept(settings?.devShowSyncUploads),
              devShowSyncDownloads: _kept(settings?.devShowSyncDownloads),
              devShowCacheStatus: _kept(settings?.devShowCacheStatus),
              devShowCalendarZoomPrewarm: _kept(
                settings?.devShowCalendarZoomPrewarm,
              ),
              devShowCalendarInstantViewSwitch: _kept(
                settings?.devShowCalendarInstantViewSwitch,
              ),
              devSlowCalendarAnimations: _kept(
                settings?.devSlowCalendarAnimations,
              ),
              devTodoSortDebugLog: _kept(settings?.devTodoSortDebugLog),
              devJournalDebugLog: _kept(settings?.devJournalDebugLog),
              devForceConflictUi: _kept(settings?.devForceConflictUi),
              devShowConflictDocumentIds: _kept(
                settings?.devShowConflictDocumentIds,
              ),
              devShowJournalRemotePullButton: _kept(
                settings?.devShowJournalRemotePullButton,
              ),
              devShowFpsCounter: _kept(settings?.devShowFpsCounter),
              devDisableCache: _kept(settings?.devDisableCache),
            ),
          );
    });
  }

  /// What `DriftSettingsRepository.getSettings` writes into the row of a new
  /// database, which holds nothing for the one-time backfill to carry up.
  static const _newStoreBackfillVersion =
      FirestoreCollections.syncBackfillVersion;

  static Value<bool> _kept(bool? value) =>
      value == null ? const Value.absent() : Value(value);

  Future<void> _setOwner(String uid) async {
    await _db
        .into(_db.settingsTable)
        .insert(
          SettingsTableCompanion(
            id: const Value(1),
            localOwnerUid: Value(uid),
            syncBackfillVersion: const Value(_newStoreBackfillVersion),
          ),
          onConflict: DoUpdate(
            (_) => SettingsTableCompanion(localOwnerUid: Value(uid)),
          ),
        );
  }

  /// Backups taken before owners were recorded sit in the root, and they are
  /// of the unowned data, so they go to whichever account it turns out to
  /// be. Moved, not copied, so they are listed only under that account and
  /// its retention keeps counting them.
  Future<void> moveUnownedBackupsTo(String uid) async {
    final root = await _backupsRoot();
    if (!await root.exists()) return;
    final files = [
      await for (final entity in root.list())
        if (entity is File) entity,
    ];
    if (files.isEmpty) return;
    final target = Directory(p.join(root.path, uid));
    await target.create(recursive: true);
    for (final file in files) {
      final destination = p.join(target.path, p.basename(file.path));
      if (await File(destination).exists()) continue;
      await file.rename(destination);
    }
  }
}
