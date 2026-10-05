// A restore spent most of its time resolving operation logs one Firestore
// query per document (~800 on a real account, 16 at a time, on Windows'
// single worker). A collection's first pull inside pullAll now reads every
// log in a few paged queries shared across journal, dream and todo, and
// fetches on its own only a log that moved after that read.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/sync_watermark_store.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/services/character_operation.dart';

/// Records how logs are read, can fail the read of every log, and can run
/// [afterReadingAll] once that read has answered.
class _RecordingSyncRepository extends InMemorySyncRepository {
  final logsRead = <String>[];
  var allLogReads = 0;
  bool failReadingAll = false;
  Future<void> Function()? afterReadingAll;
  Map<String, List<SyncOperation>>? lastAllLogs;

  @override
  Future<List<SyncOperation>> listOperations(String documentId) {
    logsRead.add(documentId);
    return super.listOperations(documentId);
  }

  @override
  Future<
    ({Map<String, List<SyncOperation>> logs, DateTime? newestWriteAtStart})
  >
  listAllOperations() async {
    allLogReads++;
    if (failReadingAll) throw StateError('unavailable');
    final all = await super.listAllOperations();
    lastAllLogs = all.logs;
    final after = afterReadingAll;
    afterReadingAll = null;
    await after?.call();
    return all;
  }
}

class _Device {
  _Device(this.server) : db = AppDatabase.inMemory() {
    journals = DriftJournalRepository(db);
    todos = DriftTodoRepository(db);
    sync = RemoteSyncService(
      syncRepository: server,
      journalRepository: journals,
      dreamRepository: DriftDreamRepository(db),
      todoRepository: todos,
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
        syncRepository: server,
        deviceId: 'device-b',
        debouncer: Debouncer(delay: Duration.zero),
      ),
      watermarkStore: watermarks,
      deviceId: 'device-b',
      uploadDebounceDelay: Duration.zero,
    );
  }

  final _RecordingSyncRepository server;
  final AppDatabase db;
  final watermarks = MemorySyncWatermarkStore();
  late final DriftJournalRepository journals;
  late final DriftTodoRepository todos;
  late final RemoteSyncService sync;

  Future<Map<String, String>> taskTitles() async => {
    for (final task in await todos.listTasks('list-1')) task.id: task.title,
  };
}

/// Enough tasks for their first pull to start the read of every log.
const _tasks = RemoteSyncService.allOperationsMinDocuments;
const _lastTask = 'task-${_tasks - 1}';

void main() {
  final now = DateTime.utc(2026, 9, 20, 12);
  late _RecordingSyncRepository server;
  final devices = <_Device>[];

  _Device newDevice() {
    final device = _Device(server);
    devices.add(device);
    return device;
  }

  Future<void> appendTitle(
    TodoTask task,
    String title, {
    required int sequence,
  }) => server.appendOperation(
    SyncOperation(
      id: 'device-a_${task.id}_$sequence',
      documentId: task.id,
      sequence: sequence,
      payload: jsonEncode(todoTaskToFirestore(task.copyWith(title: title))),
      deviceId: 'device-a',
      timestamp: now.add(Duration(seconds: sequence)),
    ),
  );

  /// A task whose document is stale and whose log carries the real title.
  Future<void> writeTask(int i) async {
    final stale = TodoTask(
      id: 'task-$i',
      listId: 'list-1',
      title: 'Stale $i',
      createdAt: now,
      updatedAt: now,
    );
    await server.upsertDocument(
      FirestoreCollections.todoTasks,
      stale.id,
      todoTaskToFirestore(stale),
    );
    await appendTitle(stale, 'CRDT $i', sequence: 1);
  }

  /// An entry whose document body is empty and whose text lives in its log.
  Future<void> writeEntry() async {
    await server.upsertDocument(
      FirestoreCollections.journalEntries,
      'entry-1',
      journalEntryToFirestore(
        JournalEntry(
          id: 'entry-1',
          journalId: 'journal-1',
          title: '',
          body: '',
          entryDate: now,
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
    await server.appendOperation(
      SyncOperation(
        id: 'device-a_entry-1_0',
        documentId: 'entry-1',
        sequence: 0,
        payload: CharOpsPayload(
          charOps: const [
            CharacterOperation(
              id: 'a-1',
              clientId: 'device-a',
              logicalClock: 1,
              position: 'a0',
              character: 'h',
            ),
            CharacterOperation(
              id: 'a-2',
              clientId: 'device-a',
              logicalClock: 2,
              position: 'a1',
              character: 'i',
            ),
          ],
        ).encode(),
        deviceId: 'device-a',
        timestamp: now,
      ),
    );
  }

  setUp(() async {
    server = _RecordingSyncRepository();
    await server.upsertDocument(
      FirestoreCollections.todoLists,
      'list-1',
      todoListToFirestore(
        TodoListModel(
          id: 'list-1',
          name: 'Inbox',
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
    for (var i = 0; i < _tasks; i++) {
      await writeTask(i);
    }
    await writeEntry();
  });

  tearDown(() async {
    for (final device in devices) {
      await device.db.close();
    }
    devices.clear();
  });

  test('a first pull reads every log once, shared across collections, '
      'not one query per document', () async {
    final device = newDevice();

    await device.sync.pullAll();

    expect(server.allLogReads, 1);
    // Only the log holding the newest operation: nothing written after the
    // read can be told apart from it by write time alone.
    expect(server.logsRead.length, lessThanOrEqualTo(1));
    final titles = await device.taskTitles();
    expect(titles, hasLength(_tasks));
    expect(titles['task-0'], 'CRDT 0');
    expect(titles[_lastTask], 'CRDT ${_tasks - 1}');
  });

  test('resolves exactly what one query per document does', () async {
    final batched = newDevice();
    await batched.sync.pullAll();

    server.failReadingAll = true;
    server.logsRead.clear();
    final oneByOne = newDevice();
    await oneByOne.sync.pullAll();

    expect(
      server.logsRead.toSet(),
      containsAll(['task-0', _lastTask, 'entry-1']),
      reason: 'a failed read falls back to one query per document',
    );
    expect(await batched.taskTitles(), await oneByOne.taskTitles());
    final batchedEntry = await batched.journals.getEntry('entry-1');
    final oneByOneEntry = await oneByOne.journals.getEntry('entry-1');
    expect(batchedEntry?.body, 'hi');
    expect(batchedEntry?.body, oneByOneEntry?.body);
  });

  test('an operation that lands after the read is still resolved', () async {
    server.afterReadingAll = () => appendTitle(
      TodoTask(
        id: 'task-3',
        listId: 'list-1',
        title: '',
        createdAt: now,
        updatedAt: now,
      ),
      'Late',
      sequence: 2,
    );
    final device = newDevice();

    await device.sync.pullAll();

    expect(server.logsRead, contains('task-3'));
    expect((await device.taskTitles())['task-3'], 'Late');
  });

  test('a later pull goes back to one query per changed document', () async {
    final device = newDevice();
    await device.sync.pullAll();
    await writeTask(_tasks);
    server.logsRead.clear();

    await device.sync.pullAll();

    expect(server.allLogReads, 1, reason: 'no second read of every log');
    expect(server.logsRead, contains('task-$_tasks'));
    expect((await device.taskTitles())['task-$_tasks'], 'CRDT $_tasks');
  });
  test(
    'a weekly full pull with as many logs to resolve shares one read too',
    () async {
      final device = newDevice();
      await device.sync.pullAll();
      // Every task edited since that pull, so the weekly one can skip none.
      for (var i = 0; i < _tasks; i++) {
        await appendTitle(
          TodoTask(
            id: 'task-$i',
            listId: 'list-1',
            title: '',
            createdAt: now,
            updatedAt: now,
          ),
          'Week $i',
          sequence: 2,
        );
      }
      final mark =
          device.watermarks.watermarks[FirestoreCollections.todoTasks]!;
      device.watermarks.watermarks[FirestoreCollections.todoTasks] =
          SyncWatermark(
            changedSince: mark.changedSince,
            lastFullPullAt: DateTime.now().toUtc().subtract(
              const Duration(days: 8),
            ),
          );
      server.logsRead.clear();

      await device.sync.pullAll();

      expect(server.allLogReads, 2);
      expect(server.logsRead.length, lessThanOrEqualTo(1));
      final titles = await device.taskTitles();
      expect(titles['task-0'], 'Week 0');
      expect(titles[_lastTask], 'Week ${_tasks - 1}');
    },
  );

  test('a first pull of fewer documents asks for each log on its own, '
      'without reading every log in the account', () async {
    final few = _RecordingSyncRepository();
    for (final doc in await server.listCollectionDocuments(
      FirestoreCollections.todoLists,
    )) {
      await few.upsertDocument(
        FirestoreCollections.todoLists,
        doc.id,
        doc.data,
      );
    }
    server = few;
    for (var i = 0; i < 3; i++) {
      await writeTask(i);
    }
    final device = newDevice();

    await device.sync.pullAll();

    expect(server.allLogReads, 0);
    expect(server.logsRead.toSet(), {'task-0', 'task-1', 'task-2'});
    expect((await device.taskTitles())['task-2'], 'CRDT 2');
  });

  test('each collection takes its logs out of the read', () async {
    final device = newDevice();

    await device.sync.pullAll();

    expect(server.lastAllLogs, isNot(contains('task-0')));
    expect(server.lastAllLogs, isNot(contains(_lastTask)));
  });

  group('page size of the read of every log', () {
    test('starts small before any size is known', () {
      expect(
        FirestoreSyncRepository.nextOperationPageSize(count: 0, bytes: 0),
        250,
      );
    });

    test('fits about 16 MB of the operations seen so far', () {
      // ~12 KB each, as measured: ~1,300 would fit, capped at 1,000.
      expect(
        FirestoreSyncRepository.nextOperationPageSize(
          count: 250,
          bytes: 250 * 12 * 1024,
        ),
        1000,
      );
      // ~100 KB each.
      expect(
        FirestoreSyncRepository.nextOperationPageSize(
          count: 250,
          bytes: 250 * 100 * 1024,
        ),
        163,
      );
      // Near-megabyte chunks never shrink a page below 50.
      expect(
        FirestoreSyncRepository.nextOperationPageSize(
          count: 10,
          bytes: 10 * 900 * 1024,
        ),
        50,
      );
    });
  });
}
