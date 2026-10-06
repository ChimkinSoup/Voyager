// A task moved to another list from the edit panel leaves the page on the old
// list, and the panel used to be refreshed only from that list, so it kept a
// stale copy: a roll-forward, or any other write to the moved task, never
// reached it (BUG-065).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/voyager_checkbox.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';
import 'package:voyager/features/todo/todo_page.dart';

import 'support/todo_page_harness.dart';

const _title = 'Water the plants';
const _taskId = 'repeating';

Future<void> _pump(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

TodoTask _panelTask(WidgetTester tester) =>
    tester.widget<TodoEditPanel>(find.byType(TodoEditPanel)).task;

/// Opens a daily task due today at 9:30 in the panel and moves it to the
/// second list with the panel's list flag. The page stays on the first list.
Future<({AppDatabase db, DateTime due})> _openAndMove(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final due = DateTime.now().copyWith(
    hour: 9,
    minute: 30,
    second: 0,
    millisecond: 0,
    microsecond: 0,
  );
  final db = await pumpTodoPage(
    tester,
    active: 1,
    done: 0,
    seedSecondList: true,
    seedExtra: (repo) async {
      final now = DateTime.now().toUtc();
      await repo.upsertTask(
        TodoTask(
          id: _taskId,
          listId: todoHarnessListId,
          title: _title,
          createdAt: now,
          updatedAt: now,
          sortOrder: -1000000,
          dueDate: due.toUtc(),
          recurrence: const RecurrenceRule(frequency: EventRecurrence.daily),
          recurrenceAnchor: due.toUtc(),
        ),
      );
    },
  );

  await tester.tap(find.text(_title));
  await _pump(tester);
  expect(find.byType(TodoEditPanel), findsOneWidget);

  await tester.tap(
    find.descendant(
      of: find.byType(TodoEditPanel),
      matching: find.byType(JournalTitleCornerFlag),
    ),
  );
  await _pump(tester);
  await tester.tap(find.text(todoHarnessSecondListName).last);
  await _pump(tester);

  final moved = (await DriftTodoRepository(db).getTask(_taskId))!;
  expect(moved.listId, todoHarnessSecondListId);
  return (db: db, due: due);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets(
    'the panel shows the next due date of a task moved, then ticked',
    (tester) async {
      final (:db, :due) = await _openAndMove(tester);

      await tester.tap(
        find.descendant(
          of: find.byType(TodoEditPanel),
          matching: find.byType(VoyagerCheckbox),
        ),
      );
      await _pump(tester, frames: 24);

      final rolled = (await DriftTodoRepository(db).getTask(_taskId))!;
      expect(rolled.completed, isFalse);
      expect(rolled.dueDate, isNot(due.toUtc()));
      expect(_panelTask(tester).dueDate, rolled.dueDate);
    },
  );

  testWidgets('a write from elsewhere to a moved task reaches the panel', (
    tester,
  ) async {
    final (:db, :due) = await _openAndMove(tester);

    // What a pull of another device's edit does: write the row, then
    // invalidate the list it is in.
    final repo = DriftTodoRepository(db);
    final later = due.add(const Duration(days: 3)).toUtc();
    final current = (await repo.getTask(_taskId))!;
    await repo.upsertTask(current.copyWith(dueDate: later, version: 99));
    ProviderScope.containerOf(
      tester.element(find.byType(TodoPage)),
    ).invalidate(todoTasksProvider(todoHarnessSecondListId));
    await _pump(tester);

    expect(_panelTask(tester).dueDate, later);
  });
}
