// Regressions for the save/sync defects catalogued in SAVING.md.
//
// Each group names the finding it covers and asserts the behaviour that was
// wrong, not the shape of the fix — so a future refactor is free to move the
// code as long as saves keep landing.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/soft_delete_policy.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/weather_service.dart';

import 'fakes/fake_weather_api_client.dart';

/// Counts the reads a pull actually spends, so "the snapshot already carried
/// this document" is an assertion rather than a hope.
class _CountingSyncRepository extends InMemorySyncRepository {
  int documentReads = 0;
  int operationQueries = 0;

  /// When set, the next matching call throws instead of answering.
  String? failGetDocumentFor;

  @override
  Future<Map<String, dynamic>?> getDocument(String collection, String id) {
    documentReads++;
    if (failGetDocumentFor == id) {
      failGetDocumentFor = null;
      throw StateError('read failed');
    }
    return super.getDocument(collection, id);
  }

  @override
  Future<List<SyncOperation>> listOperations(String documentId) {
    operationQueries++;
    return super.listOperations(documentId);
  }
}

/// One device: its own database, wired to the shared server.
class _Device {
  _Device(this.server, this.deviceId) {
    db = AppDatabase.inMemory();
    syncedWrites = SyncedWriteNotifier();
    journals = DriftJournalRepository(db);
    calendars = DriftCalendarRepository(db, syncedWrites: syncedWrites);
    settings = DriftSettingsRepository(db, syncedWrites: syncedWrites);

    sync = RemoteSyncService(
      syncRepository: server,
      journalRepository: journals,
      dreamRepository: DriftDreamRepository(db),
      todoRepository: DriftTodoRepository(db),
      leetCodeRepository: DriftLeetCodeRepository(db),
      studyRepository: DriftStudyRepository(db),
      workoutRepository: DriftWorkoutRepository(db),
      calendarRepository: calendars,
      trackerRepository: DriftTrackerRepository(db),
      financeRepository: DriftFinanceRepository(db),
      notificationRepository: DriftNotificationRepository(db),
      bucketListRepository: DriftBucketListRepository(db),
      settingsRepository: settings,
      weatherService: WeatherService(
        settingsRepository: settings,
        syncRepository: server,
        weatherApiClient: FakeWeatherApiClient(),
        deviceId: deviceId,
      ),
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

  final InMemorySyncRepository server;
  final String deviceId;
  late final AppDatabase db;
  late final SyncedWriteNotifier syncedWrites;
  late final DriftJournalRepository journals;
  late final DriftCalendarRepository calendars;
  late final DriftSettingsRepository settings;
  late final RemoteSyncService sync;

  final _uploads = <Future<void>>[];

  Future<void> settle() async {
    while (_uploads.isNotEmpty) {
      final pending = List.of(_uploads);
      _uploads.clear();
      await Future.wait(pending);
    }
  }

  Future<void> close() => db.close();
}

void main() {
  final now = DateTime.utc(2026, 8, 14, 12);

  JournalEntry entry({String id = 'entry-1', String body = 'hello'}) =>
      JournalEntry(
        id: id,
        journalId: 'journal-1',
        title: 'Title',
        body: body,
        entryDate: now,
        createdAt: now,
        updatedAt: now,
      );

  group('self-echo suppression (findings #10, #11)', () {
    late _CountingSyncRepository server;
    late _Device device;

    setUp(() {
      server = _CountingSyncRepository();
      device = _Device(server, 'device-a');
    });

    tearDown(() => device.close());

    /// Writes a calendar and waits for the upload that mark accompanies.
    Future<Map<String, dynamic>> pushCalendar(String name) async {
      await device.calendars.upsertCalendar(
        Calendar(id: 'cal-1', name: name, createdAt: now, updatedAt: now),
      );
      await device.settle();
      return (await server.getDocument(
        FirestoreCollections.calendars,
        'cal-1',
      ))!;
    }

    test('our own write coming back is not applied again', () async {
      final stored = await pushCalendar('Work');
      final readsBefore = server.documentReads;

      // What the snapshot listener delivers: the document we just wrote.
      final applied = await device.sync.pullForCollection(
        FirestoreCollections.calendars,
        documentIds: {'cal-1'},
        documentData: {'cal-1': stored},
      );

      expect(
        applied,
        isFalse,
        reason: 'the echo of our own write should not count as a change',
      );
      expect(
        server.documentReads,
        readsBefore,
        reason: 'a suppressed echo must not spend a read either',
      );
    });

    test(
      'another device changing the same document inside the window still lands',
      () async {
        final stored = await pushCalendar('Work');

        // Device B renames it immediately afterwards — inside the old
        // fifteen-second blanket window, which swallowed this entirely and
        // left the two devices diverged with nothing to redeliver it.
        final applied = await device.sync.pullForCollection(
          FirestoreCollections.calendars,
          documentIds: {'cal-1'},
          documentData: {
            'cal-1': {...stored, 'name': 'Home', 'version': 99},
          },
        );

        expect(applied, isTrue);
        expect((await device.calendars.getCalendar('cal-1'))?.name, 'Home');
      },
    );

    test('a journal save suppresses its own echo too', () async {
      // The path finding #11 called the largest source of avoidable reads:
      // every journal, dream, todo, study, workout and LeetCode save marked
      // itself only *after* awaiting the write, by which time the snapshot
      // listener had already been and gone.
      await device.journals.upsertEntry(entry());
      device.sync.pushJournalEntryNow(entry());
      await pumpEventQueue();

      final stored = (await server.getDocument(
        FirestoreCollections.journalEntries,
        'entry-1',
      ))!;
      final opsBefore = server.operationQueries;

      final applied = await device.sync.pullForCollection(
        FirestoreCollections.journalEntries,
        documentIds: {'entry-1'},
        documentData: {'entry-1': stored},
      );

      expect(applied, isFalse);
      expect(
        server.operationQueries,
        opsBefore,
        reason: 'a suppressed echo must not spend the CRDT query either',
      );
    });

    test('a mark is consumed once, not left to eat the next change', () async {
      final stored = await pushCalendar('Work');

      await device.sync.pullForCollection(
        FirestoreCollections.calendars,
        documentIds: {'cal-1'},
        documentData: {'cal-1': stored},
      );

      // A second delivery of the identical document is no longer ours to skip.
      final applied = await device.sync.pullForCollection(
        FirestoreCollections.calendars,
        documentIds: {'cal-1'},
        documentData: {
          'cal-1': {...stored, 'name': 'Home', 'version': 99},
        },
      );

      expect(applied, isTrue);
      expect((await device.calendars.getCalendar('cal-1'))?.name, 'Home');
    });
  });

  group('live sync reuses the snapshot payload (finding #12)', () {
    test('a pull given the document spends no extra read', () async {
      final server = _CountingSyncRepository();
      final device = _Device(server, 'device-a');
      addTearDown(device.close);

      await device.calendars.upsertCalendar(
        Calendar(id: 'cal-1', name: 'Work', createdAt: now, updatedAt: now),
      );
      await device.settle();

      final stored = await server.getDocument(
        FirestoreCollections.calendars,
        'cal-1',
      );
      final readsBefore = server.documentReads;

      // A different device's edit, delivered with its payload.
      await device.sync.pullForCollection(
        FirestoreCollections.calendars,
        documentIds: {'cal-1'},
        documentData: {
          'cal-1': {...stored!, 'name': 'Home', 'version': 9},
        },
      );

      expect(server.documentReads, readsBefore);
      final local = await device.calendars.getCalendar('cal-1');
      expect(local?.name, 'Home');
    });
  });

  group('operation log is only kept where it is read (finding #13)', () {
    test('a journal entry still writes one', () async {
      final server = _CountingSyncRepository();
      final device = _Device(server, 'device-a');
      addTearDown(device.close);

      await device.journals.upsertEntry(entry());
      device.sync.pushJournalEntryNow(entry());
      await pumpEventQueue();

      expect(await server.listOperations('entry-1'), isNotEmpty);
    });

    test('a plain record writes none', () async {
      final server = _CountingSyncRepository();
      final device = _Device(server, 'device-a');
      addTearDown(device.close);

      await device.journals.upsertJournal(
        Journal(id: 'journal-1', name: 'Diary', createdAt: now, updatedAt: now),
      );
      device.sync.pushJournal(
        Journal(id: 'journal-1', name: 'Diary', createdAt: now, updatedAt: now),
      );
      await pumpEventQueue();

      expect(
        await server.listOperations('journal-1'),
        isEmpty,
        reason: 'journals carry no collaborative text',
      );
    });

    test('every collection is classified one way or the other', () {
      expect(
        FirestoreCollections.snapshotOnly.intersection(
          FirestoreCollections.crdtBacked,
        ),
        isEmpty,
      );
      expect(
        {
          ...FirestoreCollections.snapshotOnly,
          ...FirestoreCollections.crdtBacked,
        },
        FirestoreCollections.records,
      );
    });
  });

  group('pending character operations survive a failed upload (finding #3)', () {
    test('they are still pending after the write throws', () {
      final session = CharacterOpSession(clientId: 'device-a');
      session.recordTextChange('', 'hi');

      final taken = session.takePendingOps();
      expect(taken, isNotEmpty);
      expect(session.takePendingOps(), isEmpty);

      session.restorePendingOps(taken);
      expect(
        session.takePendingOps().map((op) => op.id),
        taken.map((op) => op.id),
      );
    });

    test('operations recorded during the failed upload still follow', () {
      final session = CharacterOpSession(clientId: 'device-a');
      session.recordTextChange('', 'ab');
      final inFlight = session.takePendingOps();

      // The user kept typing while the upload was in the air.
      session.recordTextChange('ab', 'abc');

      session.restorePendingOps(inFlight);
      final pending = session.takePendingOps();

      expect(pending.length, 3);
      expect(
        pending.take(2).map((op) => op.id),
        inFlight.map((op) => op.id),
        reason: 'the restored operations must come first',
      );
    });
  });

  group('startup purge runs after the pull (finding #8)', () {
    test('an expired tombstone pulled in is removed in the same pass', () async {
      final server = InMemorySyncRepository();
      final device = _Device(server, 'device-a');
      addTearDown(device.close);

      final policy = const SoftDeletePolicy();
      final longGone = policy.purgeCutoff(
        DateTime.now().toUtc(),
      ).subtract(const Duration(days: 5));

      // Another device deleted this months ago; the tombstone is still on the
      // server and the pull will faithfully bring it back.
      await server.upsertDocument(
        FirestoreCollections.journalEntries,
        'entry-old',
        journalEntryToFirestore(
          entry(id: 'entry-old').copyWith(deletedAt: longGone),
        ),
      );

      var purgeRan = false;
      await SyncEngine(
        syncRepository: server,
        deviceId: 'device-a',
        debouncer: Debouncer(delay: Duration.zero),
      ).pullOnStartup(
        pullFromRemote: () => device.sync.pullJournalEntries(),
        purgeExpiredDeleted: () async {
          purgeRan = true;
          await device.journals.purgeExpiredDeleted(DateTime.now().toUtc());
        },
        localRefresh: () async {},
      );

      expect(purgeRan, isTrue);
      expect(
        await device.journals.getEntry('entry-old'),
        isNull,
        reason:
            'purging before the pull left the row to be re-inserted and sit '
            'there until the next launch',
      );
    });
  });

  group('a restore outranks the old operation log (finding #7)', () {
    test('pushing restored records clears the document log', () async {
      final server = InMemorySyncRepository();
      final device = _Device(server, 'device-a');
      addTearDown(device.close);

      // The text as it was before the accident, with a log describing it.
      await device.journals.upsertEntry(entry(body: 'the original body'));
      device.sync.recordJournalTextChange(
        entryId: 'entry-1',
        before: '',
        after: 'the original body',
      );
      device.sync.pushJournalEntryNow(entry(body: 'the original body'));
      await pumpEventQueue();
      expect(await server.listOperations('entry-1'), isNotEmpty);

      // The restore writes the recovered row and uploads it.
      final restored = entry(body: 'recovered from backup');
      await device.journals.upsertEntry(restored, recordLocalActivity: false);
      await device.sync.pushRestoredRecords(
        FirestoreCollections.journalEntries,
        [restored],
      );

      expect(
        await server.listOperations('entry-1'),
        isEmpty,
        reason: 'the log still described the body the restore replaced',
      );

      // The pull that used to undo the recovery.
      await device.sync.pullJournalEntries();
      expect(
        (await device.journals.getEntry('entry-1'))?.body,
        'recovered from backup',
      );
    });
  });

  group('permanent delete clears the right operations (finding #16)', () {
    test('a legacy-id journal deletes its own log', () async {
      final server = InMemorySyncRepository();
      final device = _Device(server, 'device-a');
      addTearDown(device.close);

      // Operations are filed under the Firestore id, which for this collection
      // is not the local id.
      const localId = 'journal-1';
      final firestoreId = firestoreDocumentIdForLocal(
        FirestoreCollections.journals,
        localId,
      );
      await server.appendOperation(
        SyncOperation(
          id: 'op-1',
          documentId: firestoreId,
          sequence: 1,
          payload: '{}',
          deviceId: 'device-a',
          timestamp: now,
        ),
      );

      final deleted = await device.sync.permanentlyDeleteFromRemote(
        collection: FirestoreCollections.journals,
        documentId: localId,
      );

      expect(deleted, 1);
      expect(await server.listOperations(firestoreId), isEmpty);
    });
  });
}
