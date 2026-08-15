import 'package:drift/drift.dart' show Value;
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class _StubAuthRepository implements AuthRepository {
  @override
  String? get currentUserId => 'user-1';

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FirebaseException firestoreError(String code) =>
    FirebaseException(plugin: 'cloud_firestore', code: code);

void main() {
  late AppDatabase db;
  late OutboxSyncWorker worker;

  setUp(() {
    db = AppDatabase.inMemory();
    worker = OutboxSyncWorker(
      db,
      FakeFirebaseFirestore(),
      _StubAuthRepository(),
    );
  });

  tearDown(() async => db.close());

  Future<List<PendingUploadData>> allRows() =>
      db.select(db.pendingUploadsTable).get();

  test('a queued upload carries no failure reason', () async {
    await worker.enqueue(
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
    );

    final rows = await allRows();
    expect(rows, hasLength(1));
    expect(rows.single.failureReason, isNull);
    expect(await worker.listParked(), isEmpty);
  });

  test('a parked upload is recorded and kept out of the retry queue', () async {
    await worker.park(
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
      reason: 'too large',
    );

    final parked = await worker.listParked();
    expect(parked, hasLength(1));
    expect(parked.single.failureReason, 'too large');
  });

  test('re-queueing keeps the original queue time', () async {
    // The age cap is the only thing bounding a failure this code cannot
    // recognise as permanent. Refreshing `addedAt` on every re-queue reset it
    // faster than it could ever expire, so the row retried on every launch
    // forever — and, since the drain works in `addedAt` order, kept jumping
    // the queue as well.
    final queuedAt = DateTime.utc(2026, 1, 1);
    await db
        .into(db.pendingUploadsTable)
        .insert(
          PendingUploadsTableCompanion.insert(
            documentId: 'entry-1',
            collectionName: FirestoreCollections.journalEntries,
            addedAt: Value(queuedAt),
          ),
        );

    await worker.enqueue(
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
    );

    final rows = await allRows();
    expect(rows.single.addedAt, queuedAt);
    expect(rows.single.failureReason, isNull);
  });

  test('re-queueing a parked document clears its failure reason', () async {
    await worker.park(
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
      reason: 'too large',
    );
    await worker.enqueue(
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
    );

    expect(await worker.listParked(), isEmpty);
    expect(await allRows(), hasLength(1));
  });

  test('a successful upload clears the row', () async {
    await worker.park(
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
      reason: 'too large',
    );

    await worker.clearFor(
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
    );

    expect(await allRows(), isEmpty);
  });

  test('clearing a document that never failed touches nothing', () async {
    await worker.enqueue(
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
    );

    await worker.clearFor(
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-2',
    );

    expect(await allRows(), hasLength(1));
  });

  test('rows for the same id in different collections are independent', () async {
    await worker.enqueue(
      collection: FirestoreCollections.journalEntries,
      documentId: 'shared-id',
    );
    await worker.enqueue(
      collection: FirestoreCollections.todoTasks,
      documentId: 'shared-id',
    );

    await worker.clearFor(
      collection: FirestoreCollections.journalEntries,
      documentId: 'shared-id',
    );

    final rows = await allRows();
    expect(rows, hasLength(1));
    expect(rows.single.collectionName, FirestoreCollections.todoTasks);
  });

  test('a queued transaction actually drains', () async {
    // Finance, calendars, trackers and the rest upload through
    // `SyncedWriteNotifier`, and the drain could not rebuild a write for any
    // of them: a transaction added on a flaky connection was parked on the
    // spot, and since the local row then outranks every later merge, Firestore
    // stayed permanently missing it.
    final firestore = FakeFirebaseFirestore();
    final worker = OutboxSyncWorker(
      db,
      firestore,
      _StubAuthRepository(),
      yieldDelay: Duration.zero,
    );

    final at = DateTime.utc(2026, 5, 1);
    await DriftFinanceRepository(db).upsertTransaction(
      FinancialTransaction(
        id: 'txn-1',
        type: TransactionType.expense,
        amountCents: 1250,
        occurredAt: at,
        note: 'Coffee',
        createdAt: at,
        updatedAt: at,
      ),
      recordLocalActivity: false,
    );
    await worker.enqueue(
      collection: FirestoreCollections.transactions,
      documentId: 'txn-1',
    );

    await worker.startDraining();

    final snap = await firestore
        .doc('users/user-1/${FirestoreCollections.transactions}/txn-1')
        .get();
    expect(snap.exists, isTrue);
    expect(snap.data()?['note'], 'Coffee');
    expect(await allRows(), isEmpty);
  });

  test('a queued row whose entity is gone is just cleared', () async {
    final firestore = FakeFirebaseFirestore();
    final worker = OutboxSyncWorker(
      db,
      firestore,
      _StubAuthRepository(),
      yieldDelay: Duration.zero,
    );

    await worker.enqueue(
      collection: FirestoreCollections.transactions,
      documentId: 'never-existed',
    );

    await worker.startDraining();

    expect(await allRows(), isEmpty);
  });

  test('every synced collection is retryable', () {
    // The drain can rebuild a write for all of them now. While it could only
    // rebuild four, everything else — every finance table, calendars,
    // trackers, tag colours, the settings document — was parked on the first
    // flaky-network failure and never re-sent by anything.
    for (final collection in FirestoreCollections.records) {
      expect(
        OutboxSyncWorker.drainableCollections,
        contains(collection),
        reason: '$collection has no retry path',
      );
    }
    expect(
      OutboxSyncWorker.drainableCollections,
      contains(FirestoreCollections.settings),
    );
  });
}
