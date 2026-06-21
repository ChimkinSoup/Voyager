import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/services/weather_service.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  late AppDatabase db;
  late DriftJournalRepository journalRepo;
  late DriftTodoRepository todoRepo;
  late InMemorySyncRepository syncRepo;
  late RemoteSyncService deviceA;
  late RemoteSyncService deviceB;
  late SyncEngine engineA;

  setUp(() {
    db = AppDatabase.inMemory();
    journalRepo = DriftJournalRepository(db);
    todoRepo = DriftTodoRepository(db);
    syncRepo = InMemorySyncRepository();

    engineA = SyncEngine(
      syncRepository: syncRepo,
      deviceId: 'device-a',
      debouncer: Debouncer(delay: Duration.zero),
    );

    final weatherService = WeatherService(
      settingsRepository: DriftSettingsRepository(db),
      syncRepository: syncRepo,
      weatherApiClient: FakeWeatherApiClient(),
      deviceId: 'device-a',
    );

    deviceA = RemoteSyncService(
      syncRepository: syncRepo,
      journalRepository: journalRepo,
      todoRepository: todoRepo,
      weatherService: weatherService,
      syncEngine: engineA,
    );
    deviceB = RemoteSyncService(
      syncRepository: syncRepo,
      journalRepository: journalRepo,
      todoRepository: todoRepo,
      weatherService: weatherService,
      syncEngine: SyncEngine(
        syncRepository: syncRepo,
        deviceId: 'device-b',
        debouncer: Debouncer(delay: Duration.zero),
      ),
    );
  });

  tearDown(() async {
    engineA.dispose();
    await db.close();
  });

  test('pull applies remote journals lists and tasks in order', () async {
    final now = utcNow();
    await syncRepo.upsertDocument(
      FirestoreCollections.journals,
      'journal-1',
      journalToFirestore(
        Journal(
          id: 'journal-1',
          name: 'Travel',
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
    await syncRepo.upsertDocument(
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
    await syncRepo.upsertDocument(
      FirestoreCollections.todoTasks,
      'task-1',
      todoTaskToFirestore(
        TodoTask(
          id: 'task-1',
          listId: 'list-1',
          title: 'Pack bags',
          starred: true,
          sortOrder: 2,
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );

    await deviceB.pullJournalAndTodoData();

    final journals = await journalRepo.listJournals();
    final lists = await todoRepo.listLists();
    final tasks = await todoRepo.listTasks('list-1');

    expect(journals.single.name, 'Travel');
    expect(lists.single.name, 'Inbox');
    expect(tasks.single.title, 'Pack bags');
    expect(tasks.single.starred, isTrue);
  });

  test('pull prefers CRDT operations over stale document snapshots', () async {
    final now = utcNow();
    await todoRepo.upsertList(
      TodoListModel(
        id: 'list-1',
        name: 'Inbox',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final staleTask = TodoTask(
      id: 'task-1',
      listId: 'list-1',
      title: 'Stale title',
      createdAt: now,
      updatedAt: now,
    );
    final latestTask = staleTask.copyWith(title: 'CRDT title');

    await syncRepo.upsertDocument(
      FirestoreCollections.todoTasks,
      'task-1',
      todoTaskToFirestore(staleTask),
    );
    await syncRepo.appendOperation(
      SyncOperation(
        id: 'device-a_task-1_1',
        documentId: 'task-1',
        sequence: 1,
        payload: jsonEncode(todoTaskToFirestore(staleTask)),
        deviceId: 'device-a',
        timestamp: now,
      ),
    );
    await syncRepo.appendOperation(
      SyncOperation(
        id: 'device-a_task-1_2',
        documentId: 'task-1',
        sequence: 2,
        payload: jsonEncode(todoTaskToFirestore(latestTask)),
        deviceId: 'device-a',
        timestamp: now.add(const Duration(seconds: 1)),
      ),
    );

    await deviceB.pullTodoTasks();

    final tasks = await todoRepo.listTasks('list-1');
    expect(tasks.single.title, 'CRDT title');
  });

  test('push then pull propagates journal entry updates and deletes', () async {
    final now = utcNow();
    final journal = Journal(
      id: 'journal-1',
      name: 'Daily',
      createdAt: now,
      updatedAt: now,
    );
    await journalRepo.upsertJournal(journal);
    deviceA.pushJournal(journal);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final entry = JournalEntry(
      id: 'entry-1',
      journalId: journal.id,
      title: 'Morning',
      body: 'Coffee',
      entryDate: now,
      tags: const ['coffee'],
      createdAt: now,
      updatedAt: now,
    );
    await journalRepo.upsertEntry(entry);
    deviceA.pushJournalEntry(entry);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await deviceB.pullJournalAndTodoData();
    var pulled = await journalRepo.getEntry('entry-1');
    expect(pulled?.body, 'Coffee');

    final deleted = entry.copyWith(
      body: 'Updated',
      deletedAt: utcNow(),
    );
    await journalRepo.upsertEntry(deleted);
    deviceA.pushJournalEntry(deleted);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await deviceB.pullJournalAndTodoData();
    pulled = await journalRepo.getEntry('entry-1');
    expect(pulled?.body, 'Updated');
    expect(pulled?.deletedAt, isNotNull);
  });

  test('new todo tasks push immediately without debounce', () async {
    final now = utcNow();
    await todoRepo.upsertList(
      TodoListModel(
        id: 'list-1',
        name: 'Inbox',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final task = TodoTask(
      id: 'task-1',
      listId: 'list-1',
      title: 'Immediate task',
      createdAt: now,
      updatedAt: now,
    );
    await todoRepo.upsertTask(task);
    deviceA.pushTodoTaskNow(task);

    await deviceB.pullTodoTasks();
    final tasks = await todoRepo.listTasks('list-1');
    expect(tasks.single.title, 'Immediate task');
  });

  test('todo title edits use debounced push', () async {
    final now = utcNow();
    await todoRepo.upsertList(
      TodoListModel(
        id: 'list-1',
        name: 'Inbox',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final task = TodoTask(
      id: 'task-1',
      listId: 'list-1',
      title: 'Original',
      createdAt: now,
      updatedAt: now,
    );
    await todoRepo.upsertTask(task);

    final debouncedEngine = SyncEngine(
      syncRepository: syncRepo,
      deviceId: 'device-a',
      debouncer: Debouncer(delay: const Duration(milliseconds: 80)),
    );
    final debouncedSync = RemoteSyncService(
      syncRepository: syncRepo,
      journalRepository: journalRepo,
      todoRepository: todoRepo,
      weatherService: WeatherService(
        settingsRepository: DriftSettingsRepository(db),
        syncRepository: syncRepo,
        weatherApiClient: FakeWeatherApiClient(),
        deviceId: 'device-a',
      ),
      syncEngine: debouncedEngine,
    );

    debouncedSync.pushTodoTaskTitleDebounced(task.copyWith(title: 'Draft'));
    debouncedSync.pushTodoTaskTitleDebounced(task.copyWith(title: 'Final'));

    final opsBeforeDebounce = await syncRepo.listOperations('task-1');
    expect(opsBeforeDebounce, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 120));

    final ops = await syncRepo.listOperations('task-1');
    expect(ops, hasLength(1));
    final payload = jsonDecode(ops.single.payload) as Map<String, dynamic>;
    expect(payload['title'], 'Final');

    debouncedEngine.dispose();
  });

  test('live collection watch merge updates local todo tasks', () async {
    final now = utcNow();
    await todoRepo.upsertList(
      TodoListModel(
        id: 'list-1',
        name: 'Inbox',
        createdAt: now,
        updatedAt: now,
      ),
    );

    var pullCount = 0;
    final controller = LiveSyncController(
      remoteSync: deviceB,
      syncRepository: syncRepo,
      onChanged: () => pullCount++,
    );
    controller.start();

    await syncRepo.upsertDocument(
      FirestoreCollections.todoTasks,
      'task-1',
      todoTaskToFirestore(
        TodoTask(
          id: 'task-1',
          listId: 'list-1',
          title: 'From remote',
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final tasks = await todoRepo.listTasks('list-1');
    expect(tasks.single.title, 'From remote');
    expect(pullCount, greaterThan(0));

    controller.dispose();
  });
}
