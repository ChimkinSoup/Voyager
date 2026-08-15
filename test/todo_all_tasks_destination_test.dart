// The "All tasks" view spans every list, so the composer has no list on
// screen to write into. These pin which list it actually picks — and that
// reopening the app into that view doesn't lose track of it, which is the bug
// the journal page had.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

import 'support/todo_page_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('restores the all-tasks view across a restart', (tester) async {
    await pumpTodoPage(tester, active: 3, done: 1, showAllTasks: true);

    expect(find.text('All tasks'), findsOneWidget);
  });

  testWidgets('a task added from the all-tasks view goes to the last list', (
    tester,
  ) async {
    final db = await pumpTodoPage(
      tester,
      active: 3,
      done: 1,
      showAllTasks: true,
    );

    await tester.enterText(find.byType(TextField).first, 'Buy milk');
    await tester.tap(find.text('Add'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    final tasks = await DriftTodoRepository(db).listTasks(todoHarnessListId);
    final added = tasks.where((t) => t.title == 'Buy milk');
    // Not the default "To-do" list, which is what a restart into the all-view
    // used to fall back to once the concrete id had been overwritten.
    expect(added, hasLength(1));
    expect(added.single.listId, todoHarnessListId);
    expect(added.single.listId, isNot(legacyTodoListId));
  });

  testWidgets('the composer names the list a new task will land in', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 3, done: 1, showAllTasks: true);

    // "Harness" is the seeded list; the plain "Add task" hint would leave the
    // destination invisible at the moment of typing.
    expect(find.text('Add task to Harness'), findsOneWidget);
    expect(find.text('Add task'), findsNothing);
  });

  testWidgets('the composer hint stays plain outside the all-tasks view', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 3, done: 1);

    expect(find.text('Add task'), findsOneWidget);
  });
}
