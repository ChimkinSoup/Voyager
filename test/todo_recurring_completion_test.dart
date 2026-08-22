// Ticking off a repeating task moves its due date on instead of completing it.
//
// The visible half (the check, then the row coming back) is animation the page
// already owns; what is pinned here is what actually lands in the database at
// the end of it, and that the task never ends up completed.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_page.dart';

import 'fakes/fake_weather_api_client.dart';
import 'support/todo_page_harness.dart';

const _title = 'Water the plants';
const _taskId = 'repeating';

/// Pumps a real [TodoPage] over a list holding one repeating task.
///
/// Deliberately not [pumpTodoPage] plus a later insert: the page resolves its
/// providers as it settles, so a row written afterwards never appears.
Future<AppDatabase> _pumpWithRepeatingTask(
  WidgetTester tester, {
  required RecurrenceRule rule,
  required DateTime dueLocal,
  DateTime? anchorLocal,
}) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  await seedTodoTasks(db, active: 1, done: 0);

  final repo = DriftTodoRepository(db);
  final now = DateTime.now().toUtc();
  await repo.upsertTask(
    TodoTask(
      id: _taskId,
      listId: todoHarnessListId,
      title: _title,
      createdAt: now,
      updatedAt: now,
      // Ahead of the seeded "Task 0" row so it sits at the top of the section.
      sortOrder: -1000000,
      dueDate: dueLocal.toUtc(),
      recurrence: rule,
      recurrenceAnchor: (anchorLocal ?? dueLocal).toUtc(),
    ),
  );

  final settingsRepo = DriftSettingsRepository(db);
  await settingsRepo.saveSettings(
    (await settingsRepo.getSettings()).copyWith(
      lastViewedTodoListId: todoHarnessListId,
    ),
  );

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: TodoPage())),
    ),
  );
  // Not pumpAndSettle: the page keeps animations alive, so settling never
  // completes.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(find.text(_title), findsOneWidget);
  return db;
}

Future<TodoTask> _reload(AppDatabase db) async =>
    (await DriftTodoRepository(db).getTask(_taskId))!;

/// Taps the repeating row's checkbox and lets the deferred write land.
///
/// Tapped by position: the checkbox is a custom [GestureDetector], not a
/// Material [Checkbox], and its key is private to the row's State — but it is
/// reliably the leftmost control on the row.
Future<void> _tickIt(WidgetTester tester) async {
  final row = tester.getRect(find.text(_title));
  await tester.tapAt(Offset(row.left - 24, row.center.dy));
  // The write is held for _todoCompletionSaveDelay (900ms) so it lands after
  // the row has finished collapsing; pump well past that.
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a weekly task rolls to next week and stays active', (
    tester,
  ) async {
    // Anchored in the past so the roll is driven by the pattern, and dated far
    // enough back that the backlog skip lands on a predictable occurrence.
    final db = await _pumpWithRepeatingTask(
      tester,
      rule: const RecurrenceRule(frequency: EventRecurrence.weekly),
      dueLocal: DateTime.now().copyWith(
        hour: 9,
        minute: 30,
        second: 0,
        millisecond: 0,
        microsecond: 0,
      ),
    );

    final before = await _reload(db);
    await _tickIt(tester);
    final rolled = await _reload(db);

    expect(rolled.completed, isFalse, reason: 'must stay in the active list');
    final beforeDay = DateUtils.dateOnly(before.dueDate!.toLocal());
    final afterDay = DateUtils.dateOnly(rolled.dueDate!.toLocal());
    expect(afterDay.difference(beforeDay).inDays, 7);

    // "Repeat at a specific time" holds across the roll.
    expect(rolled.dueDate!.toLocal().hour, 9);
    expect(rolled.dueDate!.toLocal().minute, 30);

    // The rule and its anchor survive, so the next tick rolls again.
    expect(rolled.recurrence.frequency, EventRecurrence.weekly);
    expect(rolled.recurrenceAnchor, isNotNull);
  });

  testWidgets('a custom every-3-days task advances by three days', (
    tester,
  ) async {
    final db = await _pumpWithRepeatingTask(
      tester,
      rule: const RecurrenceRule(
        frequency: EventRecurrence.daily,
        interval: 3,
      ),
      dueLocal: DateTime.now().copyWith(
        hour: 8,
        minute: 0,
        second: 0,
        millisecond: 0,
        microsecond: 0,
      ),
    );

    final before = await _reload(db);
    await _tickIt(tester);
    final rolled = await _reload(db);

    expect(rolled.completed, isFalse);
    final beforeDay = DateUtils.dateOnly(before.dueDate!.toLocal());
    final afterDay = DateUtils.dateOnly(rolled.dueDate!.toLocal());
    expect(afterDay.difference(beforeDay).inDays, 3);
  });

  testWidgets('a non-repeating task still completes normally', (tester) async {
    final db = await _pumpWithRepeatingTask(
      tester,
      rule: RecurrenceRule.none,
      dueLocal: DateTime.now().copyWith(
        hour: 9,
        minute: 30,
        second: 0,
        millisecond: 0,
        microsecond: 0,
      ),
    );

    final before = await _reload(db);
    await _tickIt(tester);
    final done = await _reload(db);

    expect(done.completed, isTrue);
    expect(done.dueDate, before.dueDate);
  });
}
