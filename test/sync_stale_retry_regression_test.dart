// An upload that fails transiently is retried with the payload it was built
// with. These pin that such a retry cannot land a stale snapshot over a newer
// one the same device pushed in the meantime.

import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Refuses the first write of each document once, the way a full
/// FirestoreWriteGate or a dropped connection does.
class _RefuseOnceSyncRepository extends InMemorySyncRepository {
  final _refused = <String>{};

  @override
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    if (_refused.add('$collection/$id')) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    return super.upsertDocument(collection, id, data);
  }
}

class _StubAuthRepository implements AuthRepository {
  @override
  String? get currentUserId => 'user-1';

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Holds the first write of each document until released, and refuses the
/// second — a slow acknowledgement followed by a full write gate.
class _HoldThenRefuseSyncRepository extends InMemorySyncRepository {
  final held = Completer<void>();
  final _seen = <String, int>{};

  @override
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    final n = _seen.update('$collection/$id', (v) => v + 1, ifAbsent: () => 1);
    if (n == 1) await held.future;
    if (n >= 2 && !held.isCompleted) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    return super.upsertDocument(collection, id, data);
  }
}

RemoteSyncService _buildService(
  AppDatabase db,
  SyncRepository syncRepo, {
  SyncRetryPolicy retryPolicy = const SyncRetryPolicy(),
}) {
  final engine = SyncEngine(
    syncRepository: syncRepo,
    deviceId: 'device-a',
    debouncer: Debouncer(delay: Duration.zero),
    retryPolicy: retryPolicy,
  );
  return RemoteSyncService(
    syncRepository: syncRepo,
    journalRepository: DriftJournalRepository(db),
    dreamRepository: DriftDreamRepository(db),
    todoRepository: DriftTodoRepository(db),
    leetCodeRepository: DriftLeetCodeRepository(db),
    studyRepository: DriftStudyRepository(db),
    workoutRepository: DriftWorkoutRepository(db),
    jobRepository: DriftJobRepository(db),
    rankingRepository: DriftRankingRepository(db),
    calendarRepository: DriftCalendarRepository(db),
    trackerRepository: DriftTrackerRepository(db),
    financeRepository: DriftFinanceRepository(db),
    notificationRepository: DriftNotificationRepository(db),
    reminderRepository: DriftReminderRepository(db),
    bucketListRepository: DriftBucketListRepository(db),
    mediaRepository: DriftMediaRepository(db),
    settingsRepository: DriftSettingsRepository(db),
    syncEngine: engine,
    deviceId: 'device-a',
    uploadDebounceDelay: Duration.zero,
  );
}

void main() {
  test('a retried older upload does not overwrite a newer one', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final syncRepo = _RefuseOnceSyncRepository();
    final service = _buildService(db, syncRepo);

    final at = DateTime.utc(2026, 9, 1);
    final v1 = Journal(
      id: 'journal-1',
      name: 'Old name',
      createdAt: at,
      updatedAt: at,
      version: 1,
    );
    final v2 = v1.copyWith(name: 'New name');

    service.pushJournal(v1); // refused, retried after the policy's backoff
    await Future<void>.delayed(const Duration(milliseconds: 50));
    service.pushJournal(v2); // lands
    await Future<void>.delayed(const Duration(seconds: 2));

    final remote = await syncRepo.getDocument(
      FirestoreCollections.journals,
      'journal-1',
    );
    expect(remote?['name'], 'New name');
    expect(remote?['version'], 2);
  });

  test('an older upload landing late keeps the outbox row a newer failure '
      'queued', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    OutboxSyncWorker.initialize(
      db,
      FakeFirebaseFirestore(),
      _StubAuthRepository(),
      yieldDelay: Duration.zero,
    );
    final syncRepo = _HoldThenRefuseSyncRepository();
    final service = _buildService(
      db,
      syncRepo,
      retryPolicy: const SyncRetryPolicy(maxAttempts: 1),
    );

    final at = DateTime.utc(2026, 9, 1);
    final v1 = Journal(
      id: 'journal-1',
      name: 'Old name',
      createdAt: at,
      updatedAt: at,
      version: 1,
    );
    service.pushJournal(v1); // in flight, unacknowledged
    await Future<void>.delayed(const Duration(milliseconds: 20));
    service.pushJournal(v1.copyWith(name: 'New name')); // refused -> outbox
    await Future<void>.delayed(const Duration(milliseconds: 50));

    syncRepo.held.complete(); // the old write is acknowledged
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 'New name' is either on the server or still owed by the outbox — never
    // neither.
    final remote = await syncRepo.getDocument(
      FirestoreCollections.journals,
      'journal-1',
    );
    final owed = await db.select(db.pendingUploadsTable).get();
    expect(
      remote?['name'] == 'New name' || owed.length == 1,
      isTrue,
      reason: 'remote=${remote?['name']} owed=${owed.length}',
    );
  });
}
