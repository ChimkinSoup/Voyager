import 'package:drift/drift.dart';
import 'package:voyager/data/database/app_database.dart';

/// How far one collection's pull has got.
class SyncWatermark {
  const SyncWatermark({
    required this.changedSince,
    required this.lastFullPullAt,
  });

  /// The next pull asks only for documents the server wrote after this.
  final DateTime changedSince;

  /// When the collection was last pulled whole.
  final DateTime lastFullPullAt;
}

/// Where [RemoteSyncService] keeps its per-collection [SyncWatermark]s.
abstract class SyncWatermarkStore {
  Future<SyncWatermark?> read(String collection);

  Future<void> write(String collection, SyncWatermark watermark);
}

/// One account's watermarks, in the database they describe.
class DriftSyncWatermarkStore implements SyncWatermarkStore {
  DriftSyncWatermarkStore(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  @override
  Future<SyncWatermark?> read(String collection) async {
    final row =
        await (_db.select(_db.syncWatermarksTable)..where(
              (t) => t.userId.equals(_userId) & t.collection.equals(collection),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    return SyncWatermark(
      changedSince: row.changedSince.toUtc(),
      lastFullPullAt: row.lastFullPullAt.toUtc(),
    );
  }

  @override
  Future<void> write(String collection, SyncWatermark watermark) async {
    await _db
        .into(_db.syncWatermarksTable)
        .insertOnConflictUpdate(
          SyncWatermarksTableCompanion.insert(
            userId: _userId,
            collection: collection,
            changedSince: watermark.changedSince,
            lastFullPullAt: watermark.lastFullPullAt,
          ),
        );
  }
}

/// Watermarks that last as long as the process, for tests and signed-out
/// sessions.
class MemorySyncWatermarkStore implements SyncWatermarkStore {
  final watermarks = <String, SyncWatermark>{};

  @override
  Future<SyncWatermark?> read(String collection) async =>
      watermarks[collection];

  @override
  Future<void> write(String collection, SyncWatermark watermark) async =>
      watermarks[collection] = watermark;
}
