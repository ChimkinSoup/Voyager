// BUG-241 / BUG-245: Firestore keeps whichever upload lands last, not the
// later save. A device whose copy beats the one a pull brings has to put it
// back on the server, or the devices and the cloud disagree for good.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
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
