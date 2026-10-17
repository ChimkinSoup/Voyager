// Conflict detection for Pinned Notes (SECURE_NOTES_HLD.md, Phase 1).
//
// Two devices share one InMemorySyncRepository (the server) while writing to
// their own databases, as in secondary_collections_sync_test.dart. The outbox
// path runs against fake_cloud_firestore, the way the app drains it.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/secure_vault/secure_vault.dart';
import 'package:voyager/core/secure_vault/secure_vault_service.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/note_sync.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/notification_models.dart';

class _Device {
  _Device(InMemorySyncRepository server, String deviceId) {
    db = AppDatabase.inMemory();
    final syncedWrites = SyncedWriteNotifier();
    notes = DriftNotificationRepository(db, syncedWrites: syncedWrites);
    sync = RemoteSyncService(
      syncRepository: server,
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
      notificationRepository: notes,
      reminderRepository: DriftReminderRepository(db),
      bucketListRepository: DriftBucketListRepository(db),
      mediaRepository: DriftMediaRepository(db),
      settingsRepository: DriftSettingsRepository(db),
      syncEngine: SyncEngine(
        syncRepository: server,
        deviceId: deviceId,
        debouncer: Debouncer(delay: Duration.zero),
      ),
      deviceId: deviceId,
      uploadDebounceDelay: Duration.zero,
    );
    syncedWrites.onWrite = (collection, records) =>
        _uploads.add(sync.pushRecords(collection, records));
  }

  late final AppDatabase db;
  late final DriftNotificationRepository notes;
  late final RemoteSyncService sync;
  final _uploads = <Future<void>>[];

  /// Uploads are started but not awaited by the repository, as in the app;
  /// a fork made while applying one starts another.
  Future<void> settle() async {
    while (_uploads.isNotEmpty) {
      final pending = List.of(_uploads);
      _uploads.clear();
      await Future.wait(pending);
    }
  }

  /// Saves [text] into the note as an edit made here.
  Future<void> edit(String id, String text) async {
    final note = (await notes.getPinnedNote(id))!;
    await notes.upsertPinnedNote(
      note.copyWith(
        text: text,
        updatedAt: note.updatedAt.add(const Duration(seconds: 1)),
        version: note.version + 1,
      ),
    );
  }

  Future<List<String>> texts() async => [
    for (final note in await notes.listPinnedNotes()) note.text,
  ];
}

void main() {
  late InMemorySyncRepository server;
  late _Device a;
  late _Device b;

  final created = DateTime.utc(2026, 10, 1, 9);

  setUp(() async {
    server = InMemorySyncRepository();
    a = _Device(server, 'device-a');
    b = _Device(server, 'device-b');
    // Both devices start in step on one note.
    await a.notes.upsertPinnedNote(
      PinnedNote(
        id: 'n1',
        text: 'buy milk',
        createdAt: created,
        updatedAt: created,
        version: 1,
      ),
    );
    await a.settle();
    await b.sync.pullPinnedNotes();
  });

  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });

  test('a note pulled or uploaded is in step at its version', () async {
    expect((await a.notes.getPinnedNote('n1'))!.syncedVersion, 1);
    expect((await b.notes.getPinnedNote('n1'))!.syncedVersion, 1);
  });

  test('both devices editing from the same base keep both texts', () async {
    await a.edit('n1', 'buy oat milk');
    await a.settle();
    await b.edit('n1', 'buy milk and eggs');
    await b.settle();
    await a.sync.pullPinnedNotes();

    for (final device in [a, b]) {
      // The original takes the server's text; B's follows it as a new note.
      expect(await device.texts(), ['buy oat milk', 'buy milk and eggs']);
    }
    final bNotes = await b.notes.listPinnedNotes();
    expect(
      bNotes.last.createdAt,
      bNotes.first.createdAt.add(const Duration(milliseconds: 1)),
    );
  });

  test('a conflict met on download forks too', () async {
    await a.edit('n1', 'buy oat milk');
    await a.settle();
    // B's edit never reached the server: as if it were made offline.
    final note = (await b.notes.getPinnedNote('n1'))!;
    await b.notes.upsertPinnedNote(
      note.copyWith(text: 'buy milk and eggs', version: 2),
      recordLocalActivity: false,
    );

    await b.sync.pullPinnedNotes();
    await b.settle();

    expect(await b.texts(), ['buy oat milk', 'buy milk and eggs']);
  });

  test('an edit meeting a delete survives, in either order', () async {
    // Edit first, delete second: the delete gives way to the edit.
    await a.edit('n1', 'buy oat milk');
    await a.settle();
    await b.notes.deletePinnedNote('n1');
    await b.settle();
    await a.sync.pullPinnedNotes();
    expect(await a.texts(), ['buy oat milk']);
    expect(await b.texts(), ['buy oat milk']);

    // Delete first, edit second: the edit is kept as a new note.
    await a.notes.deletePinnedNote('n1');
    await a.settle();
    await b.edit('n1', 'buy oat milk and bread');
    await b.settle();
    await a.sync.pullPinnedNotes();
    for (final device in [a, b]) {
      expect(await device.texts(), ['buy oat milk and bread']);
      expect((await device.notes.getPinnedNote('n1'))!.deletedAt, isNotNull);
    }
  });

  test('both devices deleting is no conflict', () async {
    await a.notes.deletePinnedNote('n1');
    await a.settle();
    await b.notes.deletePinnedNote('n1');
    await b.settle();

    expect(await a.notes.listPinnedNotes(includeDeleted: true), hasLength(1));
    expect(await b.notes.listPinnedNotes(includeDeleted: true), hasLength(1));
    expect(await b.texts(), isEmpty);
  });

  test('the same text on both sides is no conflict', () async {
    await a.edit('n1', 'buy oat milk');
    await a.settle();
    await b.edit('n1', 'buy oat milk');
    await b.settle();

    expect(await b.texts(), ['buy oat milk']);
  });

  test('edits taking turns never fork', () async {
    await a.edit('n1', 'one');
    await a.settle();
    await b.sync.pullPinnedNotes();
    await b.edit('n1', 'two');
    await b.settle();
    await a.sync.pullPinnedNotes();
    await a.edit('n1', 'three');
    await a.settle();
    await b.sync.pullPinnedNotes();

    expect(await a.texts(), ['three']);
    expect(await b.texts(), ['three']);
  });

  test('a row with no known base is not mistaken for a conflict', () async {
    // As the migration leaves a row still owed an upload: B's earlier save
    // reached the server, this one hasn't, and nothing records the base.
    await b.edit('n1', 'buy oat milk');
    await b.settle();
    final note = (await b.notes.getPinnedNote('n1'))!;
    await b.db
        .update(b.db.pinnedNotesTable)
        .write(const PinnedNotesTableCompanion(syncedVersion: Value(null)));
    await b.notes.upsertPinnedNote(
      PinnedNote(
        id: note.id,
        text: 'buy oat milk and bread',
        createdAt: note.createdAt,
        updatedAt: note.updatedAt.add(const Duration(seconds: 1)),
        version: note.version + 1,
      ),
    );
    await b.settle();
    await a.sync.pullPinnedNotes();

    expect(await b.texts(), ['buy oat milk and bread']);
    expect(await a.texts(), ['buy oat milk and bread']);
  });

  test('an edit made during an upload stays marked as not uploaded', () async {
    // The upload of version 1 lands after the row has moved on to 2.
    final original = (await b.notes.getPinnedNote('n1'))!;
    await b.notes.upsertPinnedNote(
      original.copyWith(text: 'buy oat milk', version: 2),
      recordLocalActivity: false,
    );
    await b.db
        .update(b.db.pinnedNotesTable)
        .write(const PinnedNotesTableCompanion(syncedVersion: Value(0)));
    await b.notes.markPinnedNoteSynced('n1', 1);
    final note = (await b.notes.getPinnedNote('n1'))!;
    expect(note.version, 2);
    expect(note.syncedVersion, 1, reason: 'version 2 is still owed');

    // And the base moves no further than the row itself has.
    await b.notes.markPinnedNoteSynced('n1', 3);
    expect((await b.notes.getPinnedNote('n1'))!.syncedVersion, 1);
    // Nor backwards.
    await b.notes.markPinnedNoteSynced('n1', 0);
    expect((await b.notes.getPinnedNote('n1'))!.syncedVersion, 1);

    // Its own upload then goes through as an ordinary one.
    await b.sync.pushRecords(FirestoreCollections.pinnedNotes, [note]);
    expect(await b.texts(), ['buy oat milk']);
    expect((await b.notes.getPinnedNote('n1'))!.syncedVersion, 2);
  });

  test('an edit from a snapshot read before its upload landed does not '
      'fork', () async {
    await a.edit('n1', 'buy oat milk');
    await a.settle();
    // What the inbox still holds: version 2, read before the upload marked it.
    final disk = (await a.notes.getPinnedNote('n1'))!;
    final snapshot = PinnedNote(
      id: disk.id,
      text: disk.text,
      createdAt: disk.createdAt,
      updatedAt: disk.updatedAt,
      version: disk.version,
      syncedVersion: 1,
    );
    await a.notes.upsertPinnedNote(
      snapshot.copyWith(
        text: 'buy oat milk and bread',
        updatedAt: disk.updatedAt.add(const Duration(seconds: 1)),
        version: snapshot.version + 1,
      ),
    );
    await a.settle();
    await b.sync.pullPinnedNotes();

    expect(await a.texts(), ['buy oat milk and bread']);
    expect(await b.texts(), ['buy oat milk and bread']);
  });

  test('an older server copy does not roll an in-step note back', () async {
    final stale = pinnedNoteToFirestore((await b.notes.getPinnedNote('n1'))!);
    await a.edit('n1', 'buy oat milk');
    await a.settle();
    await b.sync.pullPinnedNotes();

    await applyRemoteNote(pinnedNoteSyncStore(b.notes), 'n1', stale);

    expect(await b.texts(), ['buy oat milk']);
    expect((await b.notes.getPinnedNote('n1'))!.syncedVersion, 2);
  });

  group('secure notes', () {
    late SecureVaultService vaultA;
    late SecureVaultService vaultB;

    setUp(() {
      vaultA = SecureVaultService(repository: a.notes, sync: server);
      vaultB = SecureVaultService(repository: b.notes, sync: server);
    });

    Future<SecureNote> seal(
      SecretKey key,
      String vaultId,
      String id,
      String text, {
      SecureNote? from,
    }) async {
      final box = await SecureVault.encrypt(key, vaultId, text);
      return SecureNote(
        id: id,
        ciphertext: base64Encode(box.ciphertext),
        nonce: base64Encode(box.nonce),
        vaultId: vaultId,
        createdAt: from?.createdAt ?? created,
        updatedAt: (from?.updatedAt ?? created).add(const Duration(seconds: 1)),
        version: (from?.version ?? 0) + 1,
        syncedVersion: from?.syncedVersion,
      );
    }

    Future<String> open(SecretKey key, SecureNote note) => SecureVault.decrypt(
      key,
      note.vaultId,
      SecureBox(
        ciphertext: base64Decode(note.ciphertext),
        nonce: base64Decode(note.nonce),
      ),
    );

    test('a second device cannot make a vault of its own', () async {
      await vaultA.create('password-a');
      await expectLater(
        vaultB.create('password-b'),
        throwsA(isA<SecureVaultException>()),
      );
      // B took A's header instead, and unlocks with A's password.
      expect(await vaultB.unlock('password-a'), isNotNull);
      expect(await vaultB.unlock('password-b'), isNull);
    });

    test('a password change from a stale header is refused', () async {
      await vaultA.create('password-a');
      await b.sync.pullSecureVaultHeader();
      expect(await vaultA.changePassword('password-a', 'password-a2'), isTrue);

      await expectLater(
        vaultB.changePassword('password-a', 'password-b2'),
        throwsA(isA<SecureVaultException>()),
      );
      // B now holds A's change, and unlocks offline with the new password.
      expect(await vaultB.unlock('password-a2'), isNotNull);
    });

    test('both devices editing while locked keep both notes', () async {
      final key = await vaultA.create('password-a');
      final vaultId = (await vaultA.localHeader())!.vaultId;
      await a.notes.upsertSecureNote(await seal(key, vaultId, 's1', 'pin 1'));
      await a.settle();
      await b.sync.pullSecureNotes();

      final onA = (await a.notes.getSecureNote('s1'))!;
      final onB = (await b.notes.getSecureNote('s1'))!;
      await a.notes.upsertSecureNote(
        await seal(key, vaultId, 's1', 'pin 2', from: onA),
      );
      await a.settle();
      await b.notes.upsertSecureNote(
        await seal(key, vaultId, 's1', 'pin 3', from: onB),
      );
      await b.settle();

      final notes = await b.notes.listSecureNotes();
      expect(notes, hasLength(2));
      expect(
        [for (final note in notes) await open(key, note)],
        ['pin 2', 'pin 3'],
      );
    });

    test('a reset reaches a device already running live sync', () async {
      await vaultA.create('password-a');
      await b.sync.pullSecureVaultHeader();
      final changed = <String>[];
      final live = LiveSyncController(
        remoteSync: b.sync,
        syncRepository: server,
        onChanged: changed.add,
      )..start();
      addTearDown(live.dispose);

      await vaultA.reset('password-new');
      await a.settle();
      final newId = (await vaultA.localHeader())!.vaultId;
      for (var i = 0; i < 50; i++) {
        if ((await vaultB.localHeader())!.vaultId == newId) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect((await vaultB.localHeader())!.vaultId, newId);
      expect(changed, contains(FirestoreCollections.secureVault));
    });

    test('a reset deletes every note and starts a new vault', () async {
      final key = await vaultA.create('password-a');
      final oldId = (await vaultA.localHeader())!.vaultId;
      await a.notes.upsertSecureNote(await seal(key, oldId, 's1', 'pin 1'));
      await a.settle();

      await vaultA.reset('password-new');
      await a.settle();
      final header = (await vaultA.localHeader())!;
      expect(header.vaultId, isNot(oldId));
      expect(header.headerVersion, 2);
      expect(await a.notes.listSecureNotes(), isEmpty);

      await b.sync.pullSecureVaultHeader();
      await b.sync.pullSecureNotes();
      expect(await b.notes.listSecureNotes(), isEmpty);
      expect(await vaultB.unlock('password-new'), isNotNull);
    });

    test('each reset retires the vault it replaces', () async {
      await vaultA.create('password-a');
      final first = (await vaultA.localHeader())!.vaultId;
      await vaultA.reset('password-b');
      final second = (await vaultA.localHeader())!.vaultId;
      await vaultA.changePassword('password-b', 'password-c');
      await vaultA.reset('password-d');

      expect((await vaultA.localHeader())!.retiredVaultIds, [first, second]);
      await b.sync.pullSecureVaultHeader();
      expect((await vaultB.localHeader())!.retiredVaultIds, [first, second]);
    });

    test('notes made without a reset in view are held back, deleted and '
        'counted', () async {
      final key = await vaultA.create('password-a');
      final oldId = (await vaultA.localHeader())!.vaultId;
      await a.notes.upsertSecureNote(await seal(key, oldId, 's1', 'pin 1'));
      await a.settle();
      await b.sync.pullSecureVaultHeader();
      await b.sync.pullSecureNotes();

      await vaultA.reset('password-new');
      await a.settle();
      // B hasn't heard of the reset: it edits one note and adds another.
      final onB = (await b.notes.getSecureNote('s1'))!;
      await b.notes.upsertSecureNote(
        await seal(key, oldId, 's1', 'pin 2', from: onB),
      );
      await b.notes.upsertSecureNote(await seal(key, oldId, 's2', 'pin 3'));
      await b.settle();

      expect((await vaultB.localHeader())!.vaultId, isNot(oldId));
      expect(await b.notes.listSecureNotes(), isEmpty);
      expect(await b.notes.lostSecureNoteCount(), 2);
      for (final id in ['s1', 's2']) {
        final doc = await server.getDocument(
          FirestoreCollections.secureNotes,
          id,
        );
        expect(doc!['deletedAt'], isNotNull, reason: id);
      }
      await a.sync.pullSecureNotes();
      expect(await a.notes.listSecureNotes(), isEmpty);
      expect(await a.notes.lostSecureNoteCount(), 0);
    });

    test('a note another device left in a retired vault is deleted, not '
        'counted', () async {
      final key = await vaultA.create('password-a');
      final oldId = (await vaultA.localHeader())!.vaultId;
      await vaultA.reset('password-new');
      await a.settle();
      // As a device that uploaded before it heard of the reset leaves it.
      await server.upsertDocument(
        FirestoreCollections.secureNotes,
        's9',
        secureNoteToFirestore(await seal(key, oldId, 's9', 'pin 9')),
      );

      await b.sync.pullSecureVaultHeader();
      await b.sync.pullSecureNotes();
      await b.settle();

      expect(await b.notes.listSecureNotes(), isEmpty);
      expect(await b.notes.lostSecureNoteCount(), 0);
      final doc = await server.getDocument(
        FirestoreCollections.secureNotes,
        's9',
      );
      expect(doc!['deletedAt'], isNotNull);
    });

    test('a note from a vault this device has not heard of is kept', () async {
      await vaultA.create('password-a');
      await b.sync.pullSecureVaultHeader();
      final key = await vaultA.reset('password-new');
      final newId = (await vaultA.localHeader())!.vaultId;
      await a.notes.upsertSecureNote(await seal(key, newId, 's1', 'pin 1'));
      await a.settle();

      // Notes before the header, as live sync may deliver them.
      await b.sync.pullSecureNotes();
      expect([for (final n in await b.notes.listSecureNotes()) n.id], ['s1']);
      await b.sync.pullSecureVaultHeader();
      expect([for (final n in await b.notes.listSecureNotes()) n.id], ['s1']);
    });
  });

  group('outbox drain', () {
    late AppDatabase db;
    late FakeFirebaseFirestore firestore;

    setUp(() {
      db = AppDatabase.inMemory();
      firestore = FakeFirebaseFirestore();
      OutboxSyncWorker.initialize(
        db,
        firestore,
        () => 'user-1',
        yieldDelay: Duration.zero,
      );
    });

    tearDown(() async => db.close());

    test('forks a queued edit the server has moved past', () async {
      final notes = DriftNotificationRepository(db);
      final base = PinnedNote(
        id: 'n1',
        text: 'buy milk',
        createdAt: created,
        updatedAt: created,
        version: 1,
      );
      await firestore
          .doc('users/user-1/${FirestoreCollections.pinnedNotes}/n1')
          .set(
            pinnedNoteToFirestore(
              base.copyWith(
                text: 'buy oat milk',
                updatedAt: created.add(const Duration(minutes: 1)),
                version: 2,
              ),
            ),
          );
      await notes.upsertPinnedNote(
        PinnedNote(
          id: 'n1',
          text: 'buy milk and eggs',
          createdAt: created,
          updatedAt: created.add(const Duration(minutes: 2)),
          version: 2,
          syncedVersion: 1,
        ),
      );
      await OutboxSyncWorker.instance.enqueue(
        collection: FirestoreCollections.pinnedNotes,
        documentId: 'n1',
      );

      await OutboxSyncWorker.instance.startDraining();

      expect(
        [for (final note in await notes.listPinnedNotes()) note.text],
        ['buy oat milk', 'buy milk and eggs'],
      );
      final server = await firestore
          .collection('users/user-1/${FirestoreCollections.pinnedNotes}')
          .get();
      expect(
        {for (final doc in server.docs) doc.data()['text']},
        {'buy oat milk', 'buy milk and eggs'},
        reason: 'the fork is queued and uploaded; the original is not',
      );
      expect(await db.select(db.pendingUploadsTable).get(), isEmpty);
    });

    test('uploads a queued edit the server has not moved past', () async {
      final notes = DriftNotificationRepository(db);
      await notes.upsertPinnedNote(
        PinnedNote(
          id: 'n1',
          text: 'buy milk and eggs',
          createdAt: created,
          updatedAt: created,
          version: 2,
          syncedVersion: 1,
        ),
      );
      await OutboxSyncWorker.instance.enqueue(
        collection: FirestoreCollections.pinnedNotes,
        documentId: 'n1',
      );

      await OutboxSyncWorker.instance.startDraining();

      final doc = await firestore
          .doc('users/user-1/${FirestoreCollections.pinnedNotes}/n1')
          .get();
      expect(doc.data()!['text'], 'buy milk and eggs');
      expect((await notes.getPinnedNote('n1'))!.syncedVersion, 2);
    });

    test('holds back a queued note sealed under a retired vault', () async {
      final notes = DriftNotificationRepository(db);
      final made = await SecureVault.create(
        'password-new',
        vaultId: 'vault-2',
        now: created,
        headerVersion: 2,
        retiredVaultIds: ['vault-1'],
      );
      await firestore
          .doc(
            'users/user-1/${FirestoreCollections.secureVault}/'
            '${FirestoreCollections.secureVaultHeaderId}',
          )
          .set(made.header.toJson());
      await notes.upsertSecureNote(
        SecureNote(
          id: 's1',
          ciphertext: 'AAAA',
          nonce: 'AAAA',
          vaultId: 'vault-1',
          createdAt: created,
          updatedAt: created,
        ),
      );
      await OutboxSyncWorker.instance.enqueue(
        collection: FirestoreCollections.secureNotes,
        documentId: 's1',
      );

      await OutboxSyncWorker.instance.startDraining();

      expect(await notes.listSecureNotes(), isEmpty);
      expect(await notes.lostSecureNoteCount(), 1);
      expect((await notes.getSecureVaultHeader())!['vaultId'], 'vault-2');
      final doc = await firestore
          .doc('users/user-1/${FirestoreCollections.secureNotes}/s1')
          .get();
      expect(
        doc.data()?['deletedAt'],
        isNotNull,
        reason: 'only its tombstone reaches the server',
      );
      expect(await db.select(db.pendingUploadsTable).get(), isEmpty);
    });
  });
}
