// Follow-ups to DATA_INTEGRITY_AUDIT_REPORT.md beyond its prototype: the
// fixes it only recommended. Each pins an invariant rather than an
// interleaving — an edit is on the server or owed on the outbox, a deletion
// survives until it has uploaded, a batch never lands over a newer copy.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_write_gate.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class _StubAuthRepository implements AuthRepository {
  @override
  String? get currentUserId => 'user-1';

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Holds the first batch write until released.
class _HoldFirstBatchSyncRepository extends InMemorySyncRepository {
  final release = Completer<void>();
  var _batches = 0;

  @override
  Future<void> upsertDocumentsBatch(
    String collection,
    Map<String, Map<String, dynamic>> documentsById,
  ) async {
    if (++_batches == 1) await release.future;
    return super.upsertDocumentsBatch(collection, documentsById);
  }
}

/// Counts what goes through the gate.
class _CountingGate extends FirestoreWriteGate {
  _CountingGate() : super(waitForPendingWrites: () async {});

  final weights = <int>[];

  @override
  Future<T> run<T>(Future<T> Function() write, {int weight = 1}) {
    weights.add(weight);
    return super.run(write, weight: weight);
  }
}

RemoteSyncService _buildService(
  AppDatabase db,
  SyncRepository syncRepo, {
  Duration uploadDebounceDelay = Duration.zero,
}) {
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
    syncEngine: SyncEngine(
      syncRepository: syncRepo,
      deviceId: 'device-a',
      debouncer: Debouncer(delay: Duration.zero),
      retryPolicy: const SyncRetryPolicy(maxAttempts: 1),
    ),
    deviceId: 'device-a',
    uploadDebounceDelay: uploadDebounceDelay,
  );
}

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.inMemory());
  tearDown(() async => db.close());

  group('uploads', () {
    test(
      'an older batch still in flight is not overwritten out of order',
      () async {
        final syncRepo = _HoldFirstBatchSyncRepository();
        final service = _buildService(db, syncRepo);
        final at = DateTime.utc(2026, 9, 1);
        final older = Calendar(
          id: 'cal-1',
          name: 'Old name',
          createdAt: at,
          updatedAt: at,
          version: 1,
        );
        final newer = Calendar(
          id: 'cal-1',
          name: 'New name',
          createdAt: at,
          updatedAt: at.add(const Duration(minutes: 1)),
          version: 2,
        );

        final first = service.pushRecords(FirestoreCollections.calendars, [
          older,
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final second = service.pushRecords(FirestoreCollections.calendars, [
          newer,
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        syncRepo.release.complete();
        await Future.wait([first, second]);

        final remote = await syncRepo.getDocument(
          FirestoreCollections.calendars,
          'cal-1',
        );
        expect(remote?['name'], 'New name');
      },
    );

    test(
      'a debounced upload pending at dispose is owed on the outbox',
      () async {
        OutboxSyncWorker.initialize(
          db,
          FakeFirebaseFirestore(),
          _StubAuthRepository(),
          yieldDelay: Duration.zero,
        );
        final service = _buildService(
          db,
          InMemorySyncRepository(),
          uploadDebounceDelay: const Duration(hours: 1),
        );
        final at = DateTime.utc(2026, 9, 1);
        service.pushTodoTaskTitleDebounced(
          TodoTask(
            id: 'task-1',
            listId: 'list-1',
            title: 'Buy milk',
            createdAt: at,
            updatedAt: at,
          ),
        );

        service.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final owed = await db.select(db.pendingUploadsTable).get();
        expect(owed.map((row) => '${row.collectionName}/${row.documentId}'), [
          '${FirestoreCollections.todoTasks}/task-1',
        ]);
      },
    );

    test('a to-do upload keeps the row\'s own updatedAt', () async {
      final syncRepo = InMemorySyncRepository();
      final service = _buildService(db, syncRepo);
      final at = DateTime.utc(2026, 9, 1, 12);

      await service.pushTodoTaskNow(
        TodoTask(
          id: 'task-1',
          listId: 'list-1',
          title: 'Buy milk',
          createdAt: at,
          updatedAt: at,
          version: 3,
        ),
      );

      final remote = await syncRepo.getDocument(
        FirestoreCollections.todoTasks,
        'task-1',
      );
      expect(remote?['updatedAt'], at.toIso8601String());
      expect(remote?['version'], 3);
    });
  });

  group('outbox', () {
    test('a row queued again while its round was sending it is kept', () async {
      late OutboxSyncWorker worker;
      var pushes = 0;
      worker = OutboxSyncWorker(
        db,
        FakeFirebaseFirestore(),
        _StubAuthRepository(),
        yieldDelay: Duration.zero,
        pushDocument:
            (collection, documentId, {forceCrdtOverwrite = false}) async {
              // The first push is overtaken by a newer refused edit.
              if (++pushes == 1) {
                await worker.enqueue(
                  collection: collection,
                  documentId: documentId,
                );
              }
            },
      );
      await worker.enqueue(
        collection: FirestoreCollections.journalEntries,
        documentId: 'entry-1',
      );

      await worker.startDraining();

      expect(pushes, 2, reason: 'the newer edit was re-sent, not cleared');
      expect(await db.select(db.pendingUploadsTable).get(), isEmpty);
    });

    test('purging keeps a tombstone that has not uploaded yet', () async {
      final repo = DriftJournalRepository(db);
      final longAgo = DateTime.now().toUtc().subtract(const Duration(days: 90));
      for (final id in ['owed', 'sent']) {
        await repo.upsertEntry(
          JournalEntry(
            id: id,
            journalId: 'journal-1',
            title: id,
            body: '',
            entryDate: longAgo,
            createdAt: longAgo,
            updatedAt: longAgo,
            deletedAt: longAgo,
          ),
          recordLocalActivity: false,
        );
      }
      await OutboxSyncWorker(
        db,
        FakeFirebaseFirestore(),
        _StubAuthRepository(),
      ).enqueue(
        collection: FirestoreCollections.journalEntries,
        documentId: 'owed',
      );

      await repo.purgeExpiredDeleted(DateTime.now().toUtc());

      expect(await repo.getEntry('owed'), isNotNull);
      expect(await repo.getEntry('sent'), isNull);
    });
  });

  group('write gate', () {
    test('a batch counts as the writes it carries', () async {
      final gate = FirestoreWriteGate(waitForPendingWrites: () async {});
      await Future<void>.delayed(Duration.zero);
      final held = Completer<void>();
      unawaited(gate.run(() => held.future, weight: 45));

      await expectLater(
        gate.run(() async {}, weight: 10),
        throwsA(isA<SyncBackpressureException>()),
      );
      expect(await gate.run(() async => 'fits', weight: 5), 'fits');
      held.complete();
    });

    test('a batch over the startup allowance still goes out alone', () async {
      final gate = FirestoreWriteGate(
        waitForPendingWrites: () => Completer<void>().future,
      );
      await Future<void>.delayed(Duration.zero);
      expect(gate.hasStartupBacklog, isTrue);

      expect(
        await gate.run(() async => 'sent', weight: firestoreWriteChunkSize),
        'sent',
      );
    });

    test('a rejected probe is asked again rather than read as drained', () {
      fakeAsync((async) {
        var calls = 0;
        final gate = FirestoreWriteGate(
          waitForPendingWrites: () {
            calls++;
            // Rejected once — the user changed — then a queue still holding.
            if (calls == 1)
              return Future<void>.error(StateError('user changed'));
            return Completer<void>().future;
          },
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));

        expect(calls, 2);
        expect(gate.hasStartupBacklog, isTrue);
      });
    });
  });

  test('an operation group too large for one request is split', () async {
    final gate = _CountingGate();
    final repo = FirestoreSyncRepository(
      FakeFirebaseFirestore(),
      'user-1',
      writeGate: gate,
    );
    final payload = 'x' * (3 * 1024 * 1024);
    await repo.appendOperationGroup([
      for (var i = 0; i < 4; i++)
        SyncOperation(
          id: 'op-$i',
          documentId: 'entry-1',
          sequence: i,
          payload: payload,
          deviceId: 'device-a',
          timestamp: DateTime.utc(2026, 9, 1),
        ),
    ]);

    expect(gate.weights.length, greaterThan(1));
    expect(gate.weights.fold<int>(0, (a, b) => a + b), 4);
  });

  test('writes buffered before sync registers are never dropped', () {
    final notifier = SyncedWriteNotifier();
    for (var i = 0; i < 600; i++) {
      notifier.notifyOne(FirestoreCollections.calendars, i);
    }
    final received = <Object>[];
    notifier.onWrite = (_, records) => received.addAll(records);
    expect(received, hasLength(600));
    expect(received.first, 0);
  });

  test('deleting a journal bumps its version', () async {
    final repo = DriftJournalRepository(db);
    final at = DateTime.utc(2026, 9, 1);
    await repo.upsertJournal(
      Journal(
        id: 'journal-1',
        name: 'J',
        createdAt: at,
        updatedAt: at,
        version: 4,
      ),
      recordLocalActivity: false,
    );

    await repo.softDeleteJournal('journal-1');

    final deleted = await repo.getJournal('journal-1');
    expect(deleted?.deletedAt, isNotNull);
    expect(deleted?.version, 5);
  });
}
