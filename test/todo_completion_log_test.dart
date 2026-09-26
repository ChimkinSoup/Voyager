// Every tick of a task's checkbox is recorded: a one-off keeps the moment on
// `completedAt`, and every tick — repeats included — appends a
// `TodoTaskCompletion` that an un-tick takes back.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/todo/todo_recurring_completion.dart';

import 'fakes/fake_weather_api_client.dart';

const _taskId = 'task';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late AppDatabase db;
  late ProviderContainer container;
  late DriftTodoRepository repo;
  // Read on first use rather than in setUp: building the service starts a
  // settings load, which a test that never touches the database would leave
  // running into the teardown's close.
  RemoteSyncService sync() => container.read(remoteSyncServiceProvider);

  setUp(() {
    db = AppDatabase.inMemory();
    addTearDown(db.close);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ],
    );
    addTearDown(container.dispose);
    repo = DriftTodoRepository(db);
  });

  DateTime today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).toUtc();
  }

  Future<TodoTask> seed({RecurrenceRule rule = RecurrenceRule.none}) async {
    final now = DateTime.now().toUtc();
    final task = TodoTask(
      id: _taskId,
      listId: 'list',
      title: 'Water the plants',
      createdAt: now,
      updatedAt: now,
      dueDate: today(),
      recurrence: rule,
      recurrenceAnchor: today(),
    );
    await repo.upsertTask(task);
    return task;
  }

  Future<List<TodoTaskCompletion>> live() async => [
    for (final c in await repo.getAllCompletions())
      if (c.deletedAt == null) c,
  ];

  Future<void> complete() async {
    await completeTodoTask(repo: repo, sync: sync(), taskId: _taskId);
  }

  group('completedAt', () {
    test('follows the completed flag through copyWith', () async {
      final task = await seed();
      final ticked = task.copyWith(completed: true);
      expect(ticked.completedAt, isNotNull);
      expect(ticked.copyWith(title: 'renamed').completedAt, ticked.completedAt);
      expect(
        ticked.copyWith(completed: true).completedAt,
        ticked.completedAt,
        reason: 're-asserting the same state must not move the stamp',
      );
      expect(ticked.copyWith(completed: false).completedAt, isNull);
    });

    test('survives the database and the Firestore mapper', () async {
      await seed();
      await complete();
      final stored = (await repo.getTask(_taskId))!;
      expect(stored.completedAt, isNotNull);

      final remote = mergeTodoTaskFromRemote(
        todoTaskToFirestore(stored),
        stored.id,
      );
      expect(remote.completedAt, stored.completedAt);
    });
  });

  group('completion log', () {
    test('a one-off tick logs one row at the task\'s completedAt', () async {
      await seed();
      await complete();

      final stored = (await repo.getTask(_taskId))!;
      final rows = await live();
      expect(rows, hasLength(1));
      expect(rows.single.taskId, _taskId);
      expect(rows.single.completedAt, stored.completedAt);
      expect(rows.single.dueDate, today());
    });

    test('each roll-forward of a repeat logs the occurrence it ticked',
        () async {
      await seed(
        rule: const RecurrenceRule(frequency: EventRecurrence.weekly),
      );
      await complete();
      final afterFirst = (await repo.getTask(_taskId))!;
      await complete();

      final stored = (await repo.getTask(_taskId))!;
      expect(stored.completed, isFalse);
      expect(stored.completedAt, isNull);

      final dues = [for (final c in await live()) c.dueDate]..sort();
      expect(dues, [today(), afterFirst.dueDate]);
    });

    test('a tick saved before the roll-forward is logged once', () async {
      // The calendar popup writes the tick with its other edits, logs it, and
      // only then hands the task to completeTodoTask to roll forward.
      final before = await seed(
        rule: const RecurrenceRule(frequency: EventRecurrence.weekly),
      );
      final ticked = before.copyWith(completed: true);
      await repo.upsertTask(ticked);
      await recordTodoCompletionChange(
        repo: repo,
        sync: sync(),
        before: before,
        after: ticked,
      );
      await complete();

      expect(await live(), hasLength(1));
    });

    test('an un-tick takes the row back, and a re-tick brings it back',
        () async {
      final open = await seed();
      final ticked = open.copyWith(completed: true);
      await repo.upsertTask(ticked);
      await recordTodoCompletionChange(
        repo: repo,
        sync: sync(),
        before: open,
        after: ticked,
      );
      final storedTick = (await repo.getTask(_taskId))!;
      final unticked = storedTick.copyWith(completed: false);
      await repo.upsertTask(unticked);
      await recordTodoCompletionChange(
        repo: repo,
        sync: sync(),
        before: storedTick,
        after: unticked,
      );

      expect(await live(), isEmpty);
      final tombstone = (await repo.getAllCompletions()).single;
      expect(tombstone.version, 1, reason: 'must outrank the live copy');

      await complete();
      expect(await live(), hasLength(1));
      final revived = (await repo.getAllCompletions()).single;
      expect(revived.version, 2, reason: 'must outrank the tombstone');
      expect(revived.completedAt, (await repo.getTask(_taskId))!.completedAt);
    });

    test('an un-tick after the due date moved still finds the tick', () async {
      final open = await seed();
      final ticked = open.copyWith(completed: true);
      await repo.upsertTask(ticked);
      await recordTodoCompletionChange(
        repo: repo,
        sync: sync(),
        before: open,
        after: ticked,
      );
      final moved = ticked.copyWith(
        dueDate: today().add(const Duration(days: 3)),
      );
      await repo.upsertTask(moved);
      final stored = (await repo.getTask(_taskId))!;
      await recordTodoCompletionChange(
        repo: repo,
        sync: sync(),
        before: stored,
        after: stored.copyWith(completed: false),
      );

      expect(await live(), isEmpty);
      expect(await repo.getAllCompletions(), hasLength(1));
    });

    test('an un-tick that beats the tick\'s own sync still takes it back',
        () async {
      // Another device ticked; its task write is here, its log row isn't yet.
      final open = await seed();
      final ticked = open.copyWith(completed: true);
      await repo.upsertTask(ticked);
      final stored = (await repo.getTask(_taskId))!;
      await recordTodoCompletionChange(
        repo: repo,
        sync: sync(),
        before: stored,
        after: stored.copyWith(completed: false),
      );

      final arriving = TodoTaskCompletion(
        id: todoTaskCompletionId(_taskId, stored.dueDate),
        taskId: _taskId,
        completedAt: stored.completedAt!,
        dueDate: stored.dueDate,
      );
      final merged = mergeTodoTaskCompletionFromRemote(
        todoTaskCompletionToFirestore(arriving),
        arriving.id,
        local: await repo.getCompletion(arriving.id),
      );
      expect(merged.deletedAt, isNotNull);
    });

    test('two devices ticking the same occurrence log one row, and an un-tick '
        'takes it back whichever moment the task kept', () async {
      final open = await seed();
      final id = todoTaskCompletionId(_taskId, open.dueDate);
      // This device's tick is on record; the task kept the other device's.
      await repo.logCompletion(
        TodoTaskCompletion(
          id: id,
          taskId: _taskId,
          completedAt: DateTime.utc(2026, 9, 25, 8),
          dueDate: open.dueDate,
        ),
      );
      final theirs = mergeTodoTaskCompletionFromRemote(
        todoTaskCompletionToFirestore(
          TodoTaskCompletion(
            id: id,
            taskId: _taskId,
            completedAt: DateTime.utc(2026, 9, 25, 9),
            dueDate: open.dueDate,
          ),
        ),
        id,
        local: await repo.getCompletion(id),
      );
      await repo.logCompletion(theirs, recordLocalActivity: false);
      expect(await live(), hasLength(1));

      final ticked = TodoTask.fromJson({
        ...open.toJson(),
        'completed': true,
        'completedAt': DateTime.utc(2026, 9, 25, 9).toIso8601String(),
      });
      await repo.upsertTask(ticked);
      final stored = (await repo.getTask(_taskId))!;
      await recordTodoCompletionChange(
        repo: repo,
        sync: sync(),
        before: stored,
        after: stored.copyWith(completed: false),
      );
      expect(await live(), isEmpty);
    });

    test('purging a task drops its completions with it', () async {
      await seed();
      await complete();
      final deletedAt = DateTime.now().toUtc().subtract(
        const Duration(days: 31),
      );
      final task = (await repo.getTask(_taskId))!;
      await repo.upsertTask(task.copyWith(deletedAt: deletedAt));
      await repo.logCompletion(
        TodoTaskCompletion(
          id: 'other',
          taskId: 'other-task',
          completedAt: deletedAt,
        ),
      );

      await repo.purgeExpiredDeleted(DateTime.now().toUtc());

      expect(await repo.getTask(_taskId), isNull);
      expect([for (final c in await repo.getAllCompletions()) c.id], [
        'other',
      ]);
    });

    test('an un-tick of a task completed before the log existed is a no-op',
        () async {
      final legacy = (await seed()).copyWith(completed: true);
      // As the migration leaves it: completed, but never stamped.
      final unstamped = TodoTask.fromJson({
        ...legacy.toJson(),
        'completedAt': null,
      });
      await recordTodoCompletionChange(
        repo: repo,
        sync: sync(),
        before: unstamped,
        after: unstamped.copyWith(completed: false),
      );
      expect(await repo.getAllCompletions(), isEmpty);
    });

    test('merges version-first, so a tombstone beats the live row', () {
      final liveRow = TodoTaskCompletion(
        id: 'c',
        taskId: _taskId,
        completedAt: DateTime.utc(2026, 9, 25, 8),
        dueDate: DateTime.utc(2026, 9, 25),
      );
      final tombstone = liveRow.deleted();

      final fromRemote = mergeTodoTaskCompletionFromRemote(
        todoTaskCompletionToFirestore(tombstone),
        'c',
        local: liveRow,
      );
      expect(fromRemote.deletedAt, isNotNull);

      final stale = mergeTodoTaskCompletionFromRemote(
        todoTaskCompletionToFirestore(liveRow),
        'c',
        local: tombstone,
      );
      expect(stale.deletedAt, isNotNull);
      expect(stale.dueDate, liveRow.dueDate);
    });
  });
}
