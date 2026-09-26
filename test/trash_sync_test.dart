// The sync half of the trash (TRASH_HLD.md §6.5): an erase has to take the
// text off every device, and a device that is still writing — an open editor,
// a save made before it heard of a delete — must not bring it back.

import 'dart:async';
import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/sync_watermark_store.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class _StubAuthRepository implements AuthRepository {
  @override
  String? get currentUserId => 'user-1';

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A server that can be taken out of reach for the one call that insists on
/// it — the operation-log wipe.
class _SyncRepository extends InMemorySyncRepository {
  var offline = false;

  /// While set, pulls wait on it — a catch-up held open.
  Completer<void>? pullGate;

  /// Collection writes, in the order they reached the server.
  final writes = <String>[];

  @override
  Future<
    ({
      List<({String id, Map<String, dynamic> data})> documents,
      DateTime? newestWrite,
      bool fromServer,
    })
  >
  listChangedDocuments(String collection, {DateTime? since}) async {
    await pullGate?.future;
    return super.listChangedDocuments(collection, since: since);
  }

  @override
  Future<void> upsertDocumentsBatch(
    String collection,
    Map<String, Map<String, dynamic>> documentsById,
  ) {
    writes.add(collection);
    return super.upsertDocumentsBatch(collection, documentsById);
  }

  @override
  Future<int> deleteOperationsForDocument(String documentId) {
    if (offline) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    return super.deleteOperationsForDocument(documentId);
  }
}

RemoteSyncService _buildService(
  AppDatabase db,
  SyncRepository syncRepo, {
  SyncWatermarkStore? watermarkStore,
}) {
  return RemoteSyncService(
    syncRepository: syncRepo,
    watermarkStore: watermarkStore,
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
    uploadDebounceDelay: Duration.zero,
  );
}

final _created = DateTime.utc(2026, 9, 1);

JournalEntry _entry({
  int version = 3,
  String body = 'Dear diary',
  DateTime? deletedAt,
}) => JournalEntry(
  id: 'e',
  journalId: 'j',
  title: 'Private',
  body: body,
  entryDate: _created,
  createdAt: _created,
  updatedAt: _created,
  version: version,
  deletedAt: deletedAt,
);

/// [_entry] as the trash leaves it after "Delete forever".
JournalEntry _erased() => JournalEntry(
  id: 'e',
  journalId: 'j',
  title: '',
  body: '',
  entryDate: _created,
  createdAt: _created,
  updatedAt: DateTime.now().toUtc(),
  version: 3 + kEraseVersionStep,
  deletedAt: kErasedAt,
);

SyncOperation _snapshotOp(JournalEntry entry) => SyncOperation(
  id: 'op-${entry.version}',
  documentId: entry.id,
  sequence: 1,
  payload: jsonEncode(journalEntryToFirestore(entry)),
  deviceId: 'device-b',
  timestamp: _created,
);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  late AppDatabase db;
  late _SyncRepository remote;
  late RemoteSyncService service;
  late DriftJournalRepository journals;
  late FakeFirebaseFirestore outboxFirestore;

  setUp(() {
    db = AppDatabase.inMemory();
    remote = _SyncRepository();
    service = _buildService(db, remote);
    journals = DriftJournalRepository(db);
    outboxFirestore = FakeFirebaseFirestore();
    OutboxSyncWorker.initialize(
      db,
      outboxFirestore,
      _StubAuthRepository(),
      yieldDelay: Duration.zero,
      pushDocument: (collection, documentId, {forceCrdtOverwrite = false}) =>
          service.pushOutboxDocument(
            collection,
            documentId,
            forceCrdtOverwrite: forceCrdtOverwrite,
          ),
    );
  });

  tearDown(() async {
    service.dispose();
    await db.close();
  });

  group('publishing an erase', () {
    test('clears the operation log and uploads the emptied entry', () async {
      await remote.appendOperation(_snapshotOp(_entry()));
      final erased = _erased();
      await journals.upsertEntry(erased);

      await service.pushTrashRecords(FirestoreCollections.journalEntries, [
        erased,
      ]);

      // A pull takes its text from the log whenever the log has any, so the
      // log is what actually held the text on every other device.
      expect(await remote.listOperations('e'), isEmpty);
      final doc = await remote.getDocument(
        FirestoreCollections.journalEntries,
        'e',
      );
      expect(doc?['body'], '');
      expect(isErasedPayload(doc!), isTrue);
    });

    test(
      'offline, it is owed on the outbox and the replay finishes it',
      () async {
        await remote.appendOperation(_snapshotOp(_entry()));
        final erased = _erased();
        await journals.upsertEntry(erased);
        remote.offline = true;

        await service.pushTrashRecords(FirestoreCollections.journalEntries, [
          erased,
        ]);

        expect(await remote.listOperations('e'), isNotEmpty);
        final owed = await db.select(db.pendingUploadsTable).get();
        expect(owed.map((row) => row.documentId), ['e']);

        remote.offline = false;
        await service.pushOutboxDocument(
          FirestoreCollections.journalEntries,
          'e',
        );

        expect(await remote.listOperations('e'), isEmpty);
        expect(
          isErasedPayload(
            (await remote.getDocument(
              FirestoreCollections.journalEntries,
              'e',
            ))!,
          ),
          isTrue,
        );
      },
    );
  });

  group('pulling around an erase', () {
    test('an erase from another device is adopted outright, and takes the '
        'open editor\'s session with it', () async {
      await journals.upsertEntry(_entry());
      await service.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: 'e',
        initialText: 'Dear diary',
      );
      await remote.upsertDocument(
        FirestoreCollections.journalEntries,
        'e',
        journalEntryToFirestore(_erased()),
      );

      await service.pullJournalEntries(documentIds: {'e'});

      final local = (await journals.getEntry('e'))!;
      expect(isErasedAt(local.deletedAt), isTrue);
      expect(local.body, isEmpty);
      expect(await service.listConflicts(), isEmpty);
      expect(
        service.charOpRegistry.session(
          FirestoreCollections.journalEntries,
          'e',
        ),
        isNull,
      );
    });

    test('a stale copy of an erased entry is not applied, and the erase is '
        'put back on the server', () async {
      await journals.upsertEntry(_erased());
      // A device that never heard of the erase saved over it.
      await remote.upsertDocument(
        FirestoreCollections.journalEntries,
        'e',
        journalEntryToFirestore(_entry()),
      );
      await remote.appendOperation(_snapshotOp(_entry()));

      await service.pullJournalEntries(documentIds: {'e'});
      await _settle();

      final local = (await journals.getEntry('e'))!;
      expect(isErasedAt(local.deletedAt), isTrue);
      expect(local.body, isEmpty);
      expect(await remote.listOperations('e'), isEmpty);
      final doc = await remote.getDocument(
        FirestoreCollections.journalEntries,
        'e',
      );
      expect(isErasedPayload(doc!), isTrue);
      expect(doc['body'], '');
    });

    test('an ordinary tombstone that beat a stale live copy is put back on '
        'the server', () async {
      final calendars = DriftCalendarRepository(db);
      final live = CalendarEvent(
        id: 'ev',
        calendarId: 'cal',
        title: 'Dentist',
        start: _created,
        end: _created,
        createdAt: _created,
        updatedAt: _created,
        version: 1,
      );
      await calendars.upsertEvent(live.copyWith(deletedAt: DateTime.now()));
      await remote.upsertDocument(
        FirestoreCollections.calendarEvents,
        'ev',
        calendarEventToFirestore(live),
      );

      await service.pullCalendarEvents(documentIds: {'ev'});
      await _settle();

      expect((await calendars.getEvent('ev'))!.deletedAt, isNotNull);
      final uploaded = await outboxFirestore
          .doc('users/user-1/${FirestoreCollections.calendarEvents}/ev')
          .get();
      expect(uploaded.data()?['deletedAt'], isNotNull);
    });

    test(
      'a copy that is newer than the local tombstone is left alone',
      () async {
        final calendars = DriftCalendarRepository(db);
        final base = CalendarEvent(
          id: 'ev',
          calendarId: 'cal',
          title: 'Dentist',
          start: _created,
          end: _created,
          createdAt: _created,
          updatedAt: _created,
          version: 1,
        );
        await calendars.upsertEvent(base.copyWith(deletedAt: DateTime.now()));
        await remote.upsertDocument(
          FirestoreCollections.calendarEvents,
          'ev',
          calendarEventToFirestore(base.copyWith().copyWith().copyWith()),
        );

        await service.pullCalendarEvents(documentIds: {'ev'});
        await _settle();

        expect(await db.select(db.pendingUploadsTable).get(), isEmpty);
        expect((await calendars.getEvent('ev'))!.deletedAt, isNull);
      },
    );
  });

  group('coming back after longer than tombstones are kept', () {
    /// A device whose last full pull is [ago] old, holding an offline edit to
    /// an event another device has since deleted.
    Future<(RemoteSyncService, DriftCalendarRepository)> away(
      Duration ago,
    ) async {
      final marks = MemorySyncWatermarkStore();
      final then = DateTime.now().toUtc().subtract(ago);
      for (final collection in FirestoreCollections.records) {
        await marks.write(
          collection,
          SyncWatermark(changedSince: then, lastFullPullAt: then),
        );
      }
      final device = _buildService(db, remote, watermarkStore: marks);
      final calendars = DriftCalendarRepository(db);
      final event = CalendarEvent(
        id: 'ev',
        calendarId: 'cal',
        title: 'Edited offline',
        start: _created,
        end: _created,
        createdAt: _created,
        updatedAt: _created,
        version: 4,
      );
      await calendars.upsertEvent(event);
      await OutboxSyncWorker.instance.enqueue(
        collection: FirestoreCollections.calendarEvents,
        documentId: 'ev',
      );
      await remote.upsertDocument(
        FirestoreCollections.calendarEvents,
        'ev',
        calendarEventToFirestore(
          event.copyWith(title: 'Dentist', deletedAt: DateTime.now()),
        ),
      );
      OutboxSyncWorker.initialize(
        db,
        outboxFirestore,
        _StubAuthRepository(),
        yieldDelay: Duration.zero,
        beforeDrain: device.catchUpIfAway,
      );
      return (device, calendars);
    }

    Future<Map<String, dynamic>?> uploaded() async =>
        (await outboxFirestore
                .doc('users/user-1/${FirestoreCollections.calendarEvents}/ev')
                .get())
            .data();

    test('pulls before sending, so the deletion meets the offline edit '
        'first', () async {
      final (device, calendars) = await away(const Duration(days: 45));

      await OutboxSyncWorker.instance.startDraining();

      expect((await calendars.getEvent('ev'))!.deletedAt, isNotNull);
      final server = await remote.getDocument(
        FirestoreCollections.calendarEvents,
        'ev',
      );
      expect(server?['deletedAt'], isNotNull);
      final sent = await uploaded();
      expect(
        sent == null || sent['deletedAt'] != null,
        isTrue,
        reason: 'the offline edit must not go out as a live copy',
      );
      device.dispose();
    });

    test('an upload made while it pulls waits for the pull', () async {
      final (device, calendars) = await away(const Duration(days: 45));
      final gate = remote.pullGate = Completer<void>();
      final catchUp = device.catchUpIfAway();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // An edit saved in the first moments back online.
      final edited = (await calendars.getEvent(
        'ev',
      ))!.copyWith(title: 'Typed just now');
      final push = device.pushRecords(FirestoreCollections.calendarEvents, [
        edited,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        remote.writes,
        isNot(contains(FirestoreCollections.calendarEvents)),
      );
      expect(
        (await remote.getDocument(
          FirestoreCollections.calendarEvents,
          'ev',
        ))?['deletedAt'],
        isNotNull,
      );

      gate.complete();
      await catchUp;
      await push;
      // The pull landed first: this device now holds the deletion, so its
      // next pull puts it back over the copy that was already in flight.
      expect((await calendars.getEvent('ev'))!.deletedAt, isNotNull);
      device.dispose();
    });

    test(
      'a device that synced recently sends its queue as it stands',
      () async {
        final (device, calendars) = await away(const Duration(days: 2));

        await OutboxSyncWorker.instance.startDraining();

        expect((await calendars.getEvent('ev'))!.deletedAt, isNull);
        expect((await uploaded())?['title'], 'Edited offline');
        device.dispose();
      },
    );
  });

  test('a field edited offline after an erase does not come back through a '
      'field-by-field merge', () {
    final erasedAt = DateTime.utc(2026, 9, 10);
    final editedAt = erasedAt.add(const Duration(hours: 1));
    final local = RankingParent(
      id: 'p',
      categoryId: 'c',
      title: '',
      createdAt: _created,
      updatedAt: erasedAt,
      version: 5 + kEraseVersionStep,
      deletedAt: kErasedAt,
    );
    // Another device, offline since before the erase, retitled the entry.
    final stale = rankingParentToFirestore(
      RankingParent(
        id: 'p',
        categoryId: 'c',
        title: 'Severance',
        createdAt: _created,
        updatedAt: editedAt,
        version: 6,
        fieldUpdatedAt: {'title': editedAt},
      ),
    );

    final merged = resolveRankingParentFromRemote(
      stale,
      'p',
      local: local,
    ).merged;

    expect(merged.title, isEmpty);
    expect(isErasedAt(merged.deletedAt), isTrue);
  });

  test('an erase arriving over a field edited offline takes the text with '
      'it', () {
    final editedAt = DateTime.utc(2026, 9, 5);
    // This device retitled the entry offline, before the erase was made.
    final local = RankingParent(
      id: 'p',
      categoryId: 'c',
      title: 'Severance',
      createdAt: _created,
      updatedAt: editedAt,
      version: 6,
      fieldUpdatedAt: {'title': editedAt},
    );
    final erase = rankingParentToFirestore(
      RankingParent(
        id: 'p',
        categoryId: 'c',
        title: '',
        createdAt: _created,
        updatedAt: DateTime.utc(2026, 9, 10),
        version: 5 + kEraseVersionStep,
        deletedAt: kErasedAt,
        fieldUpdatedAt: {'title': _created},
      ),
    );

    final resolved = resolveRankingParentFromRemote(erase, 'p', local: local);

    expect(resolved.merged.title, isEmpty);
    expect(isErasedAt(resolved.merged.deletedAt), isTrue);
    expect(resolved.localWon, isFalse);
  });

  test('an editor save onto an erased entry writes nothing', () async {
    await journals.upsertEntry(_erased());
    final coordinator = JournalWriteCoordinator(
      journalRepository: journals,
      remoteSync: service,
    );

    await coordinator.saveEntry(
      entryId: 'e',
      applyDelta: (baseline) => baseline.copyWith(body: 'Dear diary'),
    );
    await _settle();

    expect((await journals.getEntry('e'))!.body, isEmpty);
    expect(
      await remote.getDocument(FirestoreCollections.journalEntries, 'e'),
      isNull,
    );
  });
}
