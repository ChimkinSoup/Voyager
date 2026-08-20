// Per-list settings on the todo page: a list can keep its tasks out of the
// combined "All tasks" view, and one list can claim the page's opening view.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';

import 'support/todo_page_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('both lists show in the all-tasks view by default', (
    tester,
  ) async {
    await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      showAllTasks: true,
      seedSecondList: true,
    );

    expect(find.text('All tasks'), findsOneWidget);
    expect(find.text('Task 0'), findsOneWidget);
    expect(find.text('Second Task 1'), findsOneWidget);
  });

  testWidgets('a list opted out of the all-tasks view is absent from the '
      'combined list', (tester) async {
    await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      showAllTasks: true,
      seedSecondList: true,
      configureList: (list) => list.copyWith(includeInAllView: false),
    );

    expect(find.text('Second Task 1'), findsOneWidget);
    expect(find.text('Task 0'), findsNothing);
    expect(find.text('Task 1'), findsNothing);
  });

  testWidgets('opting out hides tasks from the combined view only, not from '
      'the list itself', (tester) async {
    await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      seedSecondList: true,
      configureList: (list) => list.copyWith(includeInAllView: false),
    );

    // Same excluded list, but viewed directly rather than through "All tasks".
    expect(find.text('Task 0'), findsOneWidget);
    expect(find.text('Second Task 1'), findsNothing);
  });

  testWidgets('a default list wins over the saved all-tasks view', (
    tester,
  ) async {
    await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      showAllTasks: true,
      defaultTodoListId: todoHarnessListId,
    );

    expect(find.text('All tasks'), findsNothing);
    expect(find.text('Harness'), findsOneWidget);
  });

  testWidgets('a default list wins over the last-viewed list', (tester) async {
    // lastViewedTodoListId is the harness list; the default points at the
    // second one, and the default is what the page has to open into.
    await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      seedSecondList: true,
      defaultTodoListId: todoHarnessSecondListId,
    );

    expect(find.text('Second Task 1'), findsOneWidget);
    expect(find.text('Task 0'), findsNothing);
  });

  testWidgets('a default list pointing at a missing list falls back to the '
      'last-viewed one', (tester) async {
    await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      defaultTodoListId: 'no-such-list',
    );

    expect(find.text('Task 0'), findsOneWidget);
  });
}
