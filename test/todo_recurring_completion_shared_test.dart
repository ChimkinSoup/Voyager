// Ticking a repeating task means the same thing wherever it is ticked.
//
// The To-Do page's own animation-driven path is covered by
// `todo_recurring_completion_test.dart`; this pins the shared write the
// calendar's task panel and the notification inbox make, which used to be a
// flat `completed: true` that dropped the repeat for good.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/todo/todo_recurring_completion.dart';

import 'fakes/fake_weather_api_client.dart';

const _listId = 'list';
const _taskId = 'repeating';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late AppDatabase db;
  late ProviderContainer container;
  late DriftTodoRepository repo;

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

  Future<void> seed({
    required RecurrenceRule rule,
    required DateTime dueLocal,
  }) async {
    final now = DateTime.now().toUtc();
    await repo.upsertTask(
      TodoTask(
        id: _taskId,
        listId: _listId,
        title: 'Water the plants',
        createdAt: now,
        updatedAt: now,
        dueDate: dueLocal.toUtc(),
        recurrence: rule,
        recurrenceAnchor: dueLocal.toUtc(),
      ),
    );
  }

  Future<TodoCompletionOutcome?> complete() => completeTodoTask(
    repo: repo,
    sync: container.read(remoteSyncServiceProvider),
    taskId: _taskId,
  );

  test('a weekly task rolls a week on and stays active', () async {
    // Due today: `nextTaskDueDate` skips occurrences already past, so a fixed
    // date in the calendar would roll to whichever week the suite happens to
    // run in rather than to the one after this.
    final now = DateTime.now();
    final due = DateTime(now.year, now.month, now.day);
    await seed(
      rule: const RecurrenceRule(frequency: EventRecurrence.weekly),
      dueLocal: due,
    );

    final outcome = await complete();

    expect(outcome, isNotNull);
    expect(outcome!.rolledForward, isTrue);
    expect(outcome.listId, _listId);
    final task = (await repo.getTask(_taskId))!;
    expect(task.completed, isFalse);
    expect(task.dueDate!.toLocal(), DateTime(due.year, due.month, due.day + 7));
  });

  test('a one-off task is written as plainly completed', () async {
    final due = DateTime(2026, 3, 2);
    await seed(rule: RecurrenceRule.none, dueLocal: due);

    final outcome = await complete();

    expect(outcome!.rolledForward, isFalse);
    final task = (await repo.getTask(_taskId))!;
    expect(task.completed, isTrue);
    expect(task.dueDate!.toLocal(), due);
  });

  test(
    'a repeat whose due date was cleared completes rather than stranding',
    () async {
      await seed(
        rule: const RecurrenceRule(frequency: EventRecurrence.weekly),
        dueLocal: DateTime(2026, 3, 2),
      );
      // A repeat is anchored on a due date; without one there is no occurrence
      // to move on to, and returning early would leave a row showing a check
      // that was never written.
      final seeded = (await repo.getTask(_taskId))!;
      await repo.upsertTask(
        seeded.copyWith(clearDueDate: true, clearRecurrenceAnchor: true),
      );

      final outcome = await complete();

      expect(outcome!.rolledForward, isFalse);
      expect((await repo.getTask(_taskId))!.completed, isTrue);
    },
  );

  test('a task that is gone writes nothing', () async {
    expect(
      await completeTodoTask(
        repo: repo,
        sync: container.read(remoteSyncServiceProvider),
        taskId: 'missing',
      ),
      isNull,
    );
  });
}
