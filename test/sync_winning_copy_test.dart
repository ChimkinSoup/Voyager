// BUG-241 / BUG-245: Firestore keeps whichever upload lands last, not the
// later save. A device whose copy beats the one a pull brings has to put it
// back on the server, or the devices and the cloud disagree for good.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

RemoteSyncService _buildService(
  AppDatabase db,
  SyncRepository syncRepo,
  String deviceId,
) {
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
    photoSeriesRepository: DriftPhotoSeriesRepository(db),
    gaiaRepository: DriftGaiaRepository(db),
    settingsRepository: DriftSettingsRepository(db),
    syncEngine: SyncEngine(
      syncRepository: syncRepo,
      deviceId: deviceId,
      debouncer: Debouncer(delay: Duration.zero),
      retryPolicy: const SyncRetryPolicy(maxAttempts: 1),
    ),
    deviceId: deviceId,
    uploadDebounceDelay: Duration.zero,
  );
}

final _created = DateTime.utc(2026, 9, 1);

/// A server whose operation log can't be read once a purge has deleted it,
/// until [failReads] is cleared: a device offline right after the purge.
class _ReadsFailAfterPurge extends InMemorySyncRepository {
  bool failReads = false;

  @override
  Future<int> deleteOperationsForDocument(String documentId) async {
    final deleted = await super.deleteOperationsForDocument(documentId);
    failReads = true;
    return deleted;
  }

  @override
  Future<List<SyncOperation>> listOperations(String documentId) {
    if (failReads) throw StateError('offline');
    return super.listOperations(documentId);
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  late AppDatabase db;
  late InMemorySyncRepository remote;
  late RemoteSyncService service;
  late FakeFirebaseFirestore outboxFirestore;

  setUp(() {
    db = AppDatabase.inMemory();
    remote = InMemorySyncRepository();
    service = _buildService(db, remote, 'device-a');
    outboxFirestore = FakeFirebaseFirestore();
    OutboxSyncWorker.initialize(
      db,
      outboxFirestore,
      () => 'user-1',
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

  group('a record saved on two devices (BUG-241)', () {
    final saved = DateTime.utc(2026, 10, 12, 16, 45);
    CalendarEvent event(String title, DateTime at) => CalendarEvent(
      id: 'ev',
      calendarId: 'cal',
      title: title,
      start: _created,
      end: _created,
      createdAt: _created,
      updatedAt: at,
      version: 2,
    );

    Future<Map<String, dynamic>?> uploaded() async => (await outboxFirestore
            .doc('users/user-1/${FirestoreCollections.calendarEvents}/ev')
            .get())
        .data();

    test('the later save goes back up over the earlier one that landed last',
        () async {
      final calendars = DriftCalendarRepository(db);
      await calendars.upsertEvent(
        event('by A', saved.add(const Duration(seconds: 3))),
      );
      // B saved 3 s earlier but reconnected last, so its copy is the cloud's.
      await remote.upsertDocument(
        FirestoreCollections.calendarEvents,
        'ev',
        calendarEventToFirestore(event('by B', saved)),
      );

      await service.pullCalendarEvents(documentIds: {'ev'});
      await _settle();

      expect((await calendars.getEvent('ev'))!.title, 'by A');
      expect((await uploaded())?['title'], 'by A');
    });

    test('a later copy from the server is taken, and nothing is sent',
        () async {
      final calendars = DriftCalendarRepository(db);
      await calendars.upsertEvent(event('by A', saved));
      await remote.upsertDocument(
        FirestoreCollections.calendarEvents,
        'ev',
        calendarEventToFirestore(
          event('by B', saved.add(const Duration(seconds: 3))),
        ),
      );

      await service.pullCalendarEvents(documentIds: {'ev'});
      await _settle();

      expect((await calendars.getEvent('ev'))!.title, 'by B');
      expect(await uploaded(), isNull);
      expect(await db.select(db.pendingUploadsTable).get(), isEmpty);
    });

    test('a tombstone saved later than the server copy of the same deletion goes back '
        'up', () async {
      final calendars = DriftCalendarRepository(db);
      final deletedAt = saved.subtract(const Duration(seconds: 1));
      await calendars.upsertEvent(
        CalendarEvent(
          id: 'ev',
          calendarId: 'cal',
          title: 'by A',
          start: _created,
          end: _created,
          createdAt: _created,
          updatedAt: saved.add(const Duration(seconds: 1)),
          version: 2,
          deletedAt: deletedAt,
        ),
      );
      await remote.upsertDocument(
        FirestoreCollections.calendarEvents,
        'ev',
        calendarEventToFirestore(
          CalendarEvent(
            id: 'ev',
            calendarId: 'cal',
            title: 'by A',
            start: _created,
            end: _created,
            createdAt: _created,
            updatedAt: saved,
            version: 2,
            deletedAt: deletedAt,
          ),
        ),
      );

      await service.pullCalendarEvents(documentIds: {'ev'});
      await _settle();

      expect(await uploaded(), isNotNull);
    });

    test('an exact tie sends nothing back', () async {
      // The pull takes the remote copy on a tie; sending ours as well would
      // have two devices trade copies forever.
      final calendars = DriftCalendarRepository(db);
      await calendars.upsertEvent(event('by A', saved));
      await remote.upsertDocument(
        FirestoreCollections.calendarEvents,
        'ev',
        calendarEventToFirestore(event('by B', saved)),
      );

      await service.pullCalendarEvents(documentIds: {'ev'});
      await _settle();

      expect(await uploaded(), isNull);
      expect(await db.select(db.pendingUploadsTable).get(), isEmpty);
    });
  });

  test('a task ticked here goes back up over an earlier un-ticked copy that '
      'landed last', () async {
    final saved = DateTime.utc(2026, 10, 12, 16, 45);
    TodoTask task({required bool completed, required DateTime at}) => TodoTask(
      id: 't',
      listId: 'list',
      title: 'Pay rent',
      sortOrder: 0,
      completed: completed,
      createdAt: _created,
      updatedAt: at,
      version: 2,
    );
    final todos = DriftTodoRepository(db);
    await todos.upsertTask(
      task(completed: true, at: saved.add(const Duration(seconds: 3))),
    );
    // The other device saved its copy 3 s earlier, offline, and reconnected
    // last, so its copy is the cloud's.
    await remote.upsertDocument(
      FirestoreCollections.todoTasks,
      't',
      todoTaskToFirestore(task(completed: false, at: saved)),
    );

    await service.pullTodoTasks(documentIds: {'t'});
    await _settle();

    expect((await todos.getTask('t'))!.completed, isTrue);
    expect(
      (await remote.getDocument(FirestoreCollections.todoTasks, 't'))?[
          'completed'],
      isTrue,
    );
  });

  // BUG-256: an edit made offline once, after another device edited the same
  // record ten times. The version used to decide first, so the device that
  // saved more often won over the one that saved last.
  group('an offline edit after another device\'s many edits (BUG-256)', () {
    final saved = DateTime.utc(2026, 10, 13, 18);
    CalendarEvent event(
      String title,
      DateTime at,
      int version, {
      DateTime? deletedAt,
    }) => CalendarEvent(
      id: 'ev',
      calendarId: 'cal',
      title: title,
      start: _created,
      end: _created,
      createdAt: _created,
      updatedAt: at,
      version: version,
      deletedAt: deletedAt,
    );

    Future<Map<String, dynamic>?> uploaded() async =>
        (await outboxFirestore
                .doc('users/user-1/${FirestoreCollections.calendarEvents}/ev')
                .get())
            .data();

    test(
      'the reconnect pull keeps it and puts it back on the server',
      () async {
        final calendars = DriftCalendarRepository(db);
        await calendars.upsertEvent(
          event('A offline', saved.add(const Duration(seconds: 50)), 3),
        );
        await remote.upsertDocument(
          FirestoreCollections.calendarEvents,
          'ev',
          calendarEventToFirestore(event('B round 10', saved, 12)),
        );

        await service.pullCalendarEvents(documentIds: {'ev'});
        await _settle();

        expect((await calendars.getEvent('ev'))!.title, 'A offline');
        expect((await uploaded())?['title'], 'A offline');
      },
    );

    test('the device with the many edits takes it once it lands', () async {
      final calendars = DriftCalendarRepository(db);
      await calendars.upsertEvent(event('B round 10', saved, 12));
      await remote.upsertDocument(
        FirestoreCollections.calendarEvents,
        'ev',
        calendarEventToFirestore(
          event('A offline', saved.add(const Duration(seconds: 50)), 3),
        ),
      );

      await service.pullCalendarEvents(documentIds: {'ev'});
      await _settle();

      expect((await calendars.getEvent('ev'))!.title, 'A offline');
      expect(await uploaded(), isNull);
    });

    test('an erase still beats an edit saved after it', () async {
      final calendars = DriftCalendarRepository(db);
      await calendars.upsertEvent(
        event('', saved, 3 + kEraseVersionStep, deletedAt: kErasedAt),
      );
      await remote.upsertDocument(
        FirestoreCollections.calendarEvents,
        'ev',
        calendarEventToFirestore(
          event('edited late', saved.add(const Duration(minutes: 5)), 4),
        ),
      );

      await service.pullCalendarEvents(documentIds: {'ev'});
      await _settle();

      expect(isErasedAt((await calendars.getEvent('ev'))!.deletedAt), isTrue);
      expect(isErasedPayload((await uploaded())!), isTrue);
    });
  });

  // BUG-254: an acknowledge and a snooze of one occurrence, pressed within a
  // second on two devices, both write the next version. The cloud keeps the
  // upload that lands last; the later press has to win everywhere
  // (SCHEDULED_REMINDERS_HLD §8: "Ack beats older snooze if both land").
  group('an acknowledge racing a snooze (BUG-254)', () {
    final pressed = DateTime.utc(2026, 10, 13, 17, 1, 30);
    ReminderDeliveryState state(ReminderDeliveryStatus status, DateTime at) =>
        ReminderDeliveryState(
          id: 'rule:r1',
          sourceKind: ReminderSourceKind.scheduledRule,
          sourceId: 'r1',
          occurrenceKey: '2026-10-13T17:00',
          status: status,
          snoozeUntil: status == ReminderDeliveryStatus.snoozed
              ? at.add(const Duration(minutes: 10))
              : null,
          ackedAt: status == ReminderDeliveryStatus.acked ? at : null,
          createdAt: _created,
          updatedAt: at,
          version: 1,
        );

    Future<Map<String, dynamic>?> uploaded() async =>
        (await outboxFirestore
                .doc(
                  'users/user-1/${FirestoreCollections.reminderDeliveryStates}/'
                  'rule:r1',
                )
                .get())
            .data();

    test(
      'a later ack here goes back up over the snooze that landed last',
      () async {
        final reminders = DriftReminderRepository(db);
        await reminders.upsertDeliveryState(
          state(
            ReminderDeliveryStatus.acked,
            pressed.add(const Duration(milliseconds: 2)),
          ),
        );
        await remote.upsertDocument(
          FirestoreCollections.reminderDeliveryStates,
          'rule:r1',
          reminderDeliveryStateToFirestore(
            state(ReminderDeliveryStatus.snoozed, pressed),
          ),
        );

        await service.pullReminderDeliveryStates(documentIds: {'rule:r1'});
        await _settle();

        expect(
          (await reminders.getDeliveryState('rule:r1'))!.status,
          ReminderDeliveryStatus.acked,
        );
        expect((await uploaded())?['status'], 'acked');
      },
    );

    test('a later ack from elsewhere replaces the snooze here', () async {
      final reminders = DriftReminderRepository(db);
      await reminders.upsertDeliveryState(
        state(ReminderDeliveryStatus.snoozed, pressed),
      );
      await remote.upsertDocument(
        FirestoreCollections.reminderDeliveryStates,
        'rule:r1',
        reminderDeliveryStateToFirestore(
          state(
            ReminderDeliveryStatus.acked,
            pressed.add(const Duration(milliseconds: 2)),
          ),
        ),
      );

      await service.pullReminderDeliveryStates(documentIds: {'rule:r1'});
      await _settle();

      expect(
        (await reminders.getDeliveryState('rule:r1'))!.status,
        ReminderDeliveryStatus.acked,
      );
      expect(await uploaded(), isNull);
    });
  });

  test('a task deleted here goes back up over another device\'s notes '
      'uploads (BUG-245)', () async {
    final dbB = AppDatabase.inMemory();
    addTearDown(dbB.close);
    final serviceB = _buildService(dbB, remote, 'device-b');
    addTearDown(serviceB.dispose);

    final task = TodoTask(
      id: 't',
      listId: 'list',
      title: 'MD5 task b1',
      sortOrder: 0,
      createdAt: _created,
      updatedAt: _created,
      version: 3,
    );
    await DriftTodoRepository(db).upsertTask(task);
    await DriftTodoRepository(dbB).upsertTask(task);

    // B types the first words; both devices have them.
    serviceB.recordTodoNotesChange(
      taskId: 't',
      before: '',
      after: 'one two three',
    );
    await serviceB.saveTodoTaskThenScheduleUpload(
      task.copyWith(notes: 'one two three', bumpVersion: false),
    );
    await _settle();
    await service.pullTodoTasks(documentIds: {'t'});
    expect((await DriftTodoRepository(db).getTask('t'))!.notes, 'one two three');

    // A deletes the task; B, typing on in its Notes, never hears of it and
    // keeps uploading its live copy at the version it had.
    await DriftTodoRepository(db).softDeleteTask('t');
    serviceB.recordTodoNotesChange(
      taskId: 't',
      before: 'one two three',
      after: 'one two three four five six',
    );
    await serviceB.saveTodoTaskThenScheduleUpload(
      (await DriftTodoRepository(dbB).getTask('t'))!.copyWith(
        notes: 'one two three four five six',
        bumpVersion: false,
      ),
    );
    await _settle();
    expect(
      (await remote.getDocument(FirestoreCollections.todoTasks, 't'))?[
          'deletedAt'],
      isNull,
    );

    await service.pullTodoTasks(documentIds: {'t'});
    await _settle();

    final cloud = await remote.getDocument(FirestoreCollections.todoTasks, 't');
    expect(cloud?['deletedAt'], isNotNull);
    expect(parseVersion(cloud!), 4);

    // And B, hearing of it now, ends deleted too.
    await serviceB.pullTodoTasks(documentIds: {'t'});
    expect((await DriftTodoRepository(dbB).getTask('t'))!.deletedAt, isNotNull);

    // One text in the trash everywhere: the one the operation log spells,
    // not whatever each device happened to hold when the deletion met it.
    final notesA = (await DriftTodoRepository(db).getTask('t'))!.notes;
    final notesB = (await DriftTodoRepository(dbB).getTask('t'))!.notes;
    expect(notesB, 'one two three four five six');
    expect(notesA, notesB);
    expect(
      (await remote.getDocument(FirestoreCollections.todoTasks, 't'))?['notes'],
      notesB,
    );
  });

  test('typing after "Delete from Firestore" keeps every device on one '
      'whole text (BUG-247)', () async {
    final dbB = AppDatabase.inMemory();
    addTearDown(dbB.close);
    final serviceB = _buildService(dbB, remote, 'device-b');
    addTearDown(serviceB.dispose);
    final journalsA = DriftJournalRepository(db);
    final journalsB = DriftJournalRepository(dbB);
    final entry = JournalEntry(
      id: 'e',
      journalId: 'j',
      title: 'MD5 entry a1',
      body: '',
      entryDate: _created,
      createdAt: _created,
      updatedAt: _created,
    );
    await journalsA.upsertEntry(entry);
    await journalsB.upsertEntry(entry);

    Future<void> type(
      RemoteSyncService service,
      DriftJournalRepository journals,
      String added,
    ) async {
      final before = (await journals.getEntry('e'))!.body;
      service.recordJournalTextChange(
        entryId: 'e',
        before: before,
        after: '$before$added',
      );
      await JournalWriteCoordinator(
        journalRepository: journals,
        remoteSync: service,
      ).saveEntry(
        entryId: 'e',
        applyDelta: (baseline) => baseline.copyWith(body: '$before$added'),
      );
      await _settle();
    }

    // Both devices have the entry open on "quokkaa one".
    await service.prepareEditingSession(
      collection: FirestoreCollections.journalEntries,
      documentId: 'e',
      initialText: '',
    );
    await type(service, journalsA, 'quokkaa one');
    await serviceB.pullJournalEntries(documentIds: {'e'});
    await serviceB.prepareEditingSession(
      collection: FirestoreCollections.journalEntries,
      documentId: 'e',
      initialText: (await journalsB.getEntry('e'))!.body,
    );
    expect((await journalsB.getEntry('e'))!.body, 'quokkaa one');

    // A deletes it from Firestore; B hears of it through live sync.
    await service.permanentlyDeleteFromRemote(
      collection: FirestoreCollections.journalEntries,
      documentId: 'e',
    );
    await serviceB.forgetRemovedDocument(
      FirestoreCollections.journalEntries,
      'e',
    );

    await type(serviceB, journalsB, ' B typed after purge');
    await service.pullJournalEntries(documentIds: {'e'});
    expect(
      (await journalsA.getEntry('e'))!.body,
      'quokkaa one B typed after purge',
    );

    await type(service, journalsA, ' A types next');
    await serviceB.pullJournalEntries(documentIds: {'e'});
    const whole = 'quokkaa one B typed after purge A types next';
    expect((await journalsA.getEntry('e'))!.body, whole);
    expect((await journalsB.getEntry('e'))!.body, whole);
    expect(
      (await remote.getDocument(FirestoreCollections.journalEntries, 'e'))?[
          'body'],
      whole,
    );
  });

  test('a purge whose log can no longer be read still re-seeds the open '
      'session (BUG-247)', () async {
    final server = _ReadsFailAfterPurge();
    final serviceA = _buildService(db, server, 'device-a');
    addTearDown(serviceA.dispose);
    final dbB = AppDatabase.inMemory();
    addTearDown(dbB.close);
    final serviceB = _buildService(dbB, server, 'device-b');
    addTearDown(serviceB.dispose);
    final journalsA = DriftJournalRepository(db);
    final journalsB = DriftJournalRepository(dbB);
    final entry = JournalEntry(
      id: 'e',
      journalId: 'j',
      title: 'entry',
      body: '',
      entryDate: _created,
      createdAt: _created,
      updatedAt: _created,
    );
    await journalsA.upsertEntry(entry);
    await journalsB.upsertEntry(entry);

    Future<void> type(
      RemoteSyncService service,
      DriftJournalRepository journals,
      String added,
    ) async {
      final before = (await journals.getEntry('e'))!.body;
      service.recordJournalTextChange(
        entryId: 'e',
        before: before,
        after: '$before$added',
      );
      await JournalWriteCoordinator(
        journalRepository: journals,
        remoteSync: service,
      ).saveEntry(
        entryId: 'e',
        applyDelta: (baseline) => baseline.copyWith(body: '$before$added'),
      );
      await _settle();
    }

    await serviceA.prepareEditingSession(
      collection: FirestoreCollections.journalEntries,
      documentId: 'e',
      initialText: '',
    );
    await type(serviceA, journalsA, 'quokkaa one');
    await serviceB.pullJournalEntries(documentIds: {'e'});
    await serviceB.prepareEditingSession(
      collection: FirestoreCollections.journalEntries,
      documentId: 'e',
      initialText: (await journalsB.getEntry('e'))!.body,
    );

    // The purge went through: a failed re-read after it is not its failure.
    await serviceA.permanentlyDeleteFromRemote(
      collection: FirestoreCollections.journalEntries,
      documentId: 'e',
    );
    await serviceB.forgetRemovedDocument(
      FirestoreCollections.journalEntries,
      'e',
    );
    server.failReads = false;

    await type(serviceB, journalsB, ' B typed after purge');
    await serviceA.pullJournalEntries(documentIds: {'e'});
    await type(serviceA, journalsA, ' A types next');
    await serviceB.pullJournalEntries(documentIds: {'e'});
    const whole = 'quokkaa one B typed after purge A types next';
    expect((await journalsA.getEntry('e'))!.body, whole);
    expect((await journalsB.getEntry('e'))!.body, whole);
  });
}
