// BUG-225 (qa/BUGS.md): signing out while a drain round is pushing journal
// entries. Those go back out through the sync service (`pushDocument`), which
// a sign-out swaps for the no-op repository, whose writes all "succeed" — so
// the worker cleared rows it never sent.

import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseException;
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_write_gate.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class _Auth implements AuthRepository {
  final _changes = StreamController<bool>.broadcast();
  String? _uid;

  @override
  String? get currentUserId => _uid;

  @override
  Stream<bool> get authStateChanges => _changes.stream;

  void signIn(String uid) {
    _uid = uid;
    _changes.add(true);
  }

  @override
  Future<void> signOut() async {
    _uid = null;
    _changes.add(false);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Signs the account out once the first write it admits has gone through;
/// every later write is refused the way Firestore refuses one without a
/// sign-in.
class _SignOutAfterFirstWriteGate extends FirestoreWriteGate {
  _SignOutAfterFirstWriteGate(this.signOut)
    : super(waitForPendingWrites: () async {});

  final void Function() signOut;
  var _writes = 0;

  @override
  Future<T> run<T>(
    Future<T> Function() write, {
    int weight = 1,
    int? generation,
  }) async {
    if (_writes++ > 0) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
    }
    final result = await write();
    signOut();
    return result;
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test(
    'signing out mid-round leaves the unsent journal entries queued',
    () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      // The dev OpenWeather client is the one weather client that needs no
      // Firebase app, which lets the real sync service be built here.
      final settingsRepo = DriftSettingsRepository(db);
      await settingsRepo.saveSettings(
        (await settingsRepo.getSettings()).copyWith(
          devUseDirectOpenWeather: true,
          devOpenWeatherApiKey: 'test-key',
        ),
      );
      final firestore = FakeFirebaseFirestore();
      final auth = _Auth();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          authRepositoryProvider.overrideWithValue(auth),
          firestoreProvider.overrideWithValue(firestore),
          firestoreWriteGateProvider.overrideWithValue(
            FirestoreWriteGate(waitForPendingWrites: () async {}),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(syncRepositoryProvider, (_, _) {});
      await container.read(settingsProvider.future);

      auth.signIn('accountA');
      await Future<void>.delayed(Duration.zero);

      final at = DateTime.utc(2026, 5, 1);
      final journals = DriftJournalRepository(db);
      for (final id in ['entry-1', 'entry-2']) {
        await journals.upsertEntry(
          JournalEntry(
            id: id,
            journalId: '__legacy__',
            title: 'title $id',
            body: 'offline edit to $id',
            entryDate: at,
            createdAt: at,
            updatedAt: at,
          ),
          recordLocalActivity: false,
        );
      }

      // Wired as `main.dart` wires it: the service is looked up per push, so a
      // sign-in change during the round swaps the one the next push gets.
      var pushes = 0;
      final worker = OutboxSyncWorker(
        db,
        firestore,
        () => container.read(authNotifierProvider).userId,
        yieldDelay: Duration.zero,
        pushDocument:
            (collection, documentId, {forceCrdtOverwrite = false}) async {
              if (pushes++ == 0) {
                // A signs out after the round has read its rows.
                await auth.signOut();
                await Future<void>.delayed(Duration.zero);
              }
              await container
                  .read(remoteSyncServiceProvider)
                  .pushOutboxDocument(
                    collection,
                    documentId,
                    forceCrdtOverwrite: forceCrdtOverwrite,
                  );
            },
      );
      for (final id in ['entry-1', 'entry-2']) {
        await worker.enqueue(
          collection: FirestoreCollections.journalEntries,
          documentId: id,
        );
      }

      await worker.startDraining();

      final uploaded = await firestore
          .collection('users/accountA/${FirestoreCollections.journalEntries}')
          .get();
      final queued = await db.select(db.pendingUploadsTable).get();
      // Each entry must be either in A's cloud copy or still queued for A's
      // next sign-in; anything else is an edit lost.
      final lost = {'entry-1', 'entry-2'}.difference({
        ...uploaded.docs.map((d) => d.id),
        ...queued.map((r) => r.documentId),
      });
      expect(
        lost,
        isEmpty,
        reason:
            'uploaded: ${uploaded.docs.map((d) => d.id)}, '
            'queued: ${queued.map((r) => r.documentId)}',
      );
    },
  );

  test('signing out between chunk commits leaves the rest queued, '
      'not parked', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final firestore = FakeFirebaseFirestore();
    String? uid = 'accountA';
    final worker = OutboxSyncWorker(
      db,
      firestore,
      () => uid,
      yieldDelay: Duration.zero,
      writeGate: _SignOutAfterFirstWriteGate(() => uid = null),
    );
    final tasks = DriftTodoRepository(db);
    final at = DateTime.utc(2026, 5, 1);
    // More than one chunk (40) of rows written straight to the mirror.
    for (var i = 0; i < 50; i++) {
      final id = 'task-$i';
      await tasks.upsertTask(
        TodoTask(
          id: id,
          listId: 'list-1',
          title: 'offline task $i',
          createdAt: at,
          updatedAt: at,
        ),
        recordLocalActivity: false,
      );
      await worker.enqueue(
        collection: FirestoreCollections.todoTasks,
        documentId: id,
      );
    }

    await worker.startDraining();

    final rows = await db.select(db.pendingUploadsTable).get();
    expect(rows, hasLength(10), reason: 'the first chunk of 40 went up');
    expect(
      rows.where((r) => r.failureReason != null).map((r) => r.documentId),
      isEmpty,
      reason: 'a sign-out refusal must not park the rows',
    );
  });
}
