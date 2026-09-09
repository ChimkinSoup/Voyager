// The undo toast on the To-Do page's task delete.
//
// Two halves have to work together and neither is enough alone: the row has to
// come back on disk, *and* the page has to stop hiding it. The page drops a
// deleted task out of its optimistic order the moment the confirm closes, so a
// restore that only writes the row leaves it back in the database and still
// missing from the list.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';

import 'support/todo_page_harness.dart';

/// Right-clicks [title]'s row and picks "Delete task", then confirms.
///
/// Targets the first match, which is the row: with the editor open the title
/// is also in its own field, and the list is built before the panel.
Future<void> deleteTaskFromRow(WidgetTester tester, String title) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text(title).first),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await tester.pumpAndSettle();

  await tester.tap(find.text('Delete task'));
  await tester.pumpAndSettle();

  expect(find.text('Delete task?'), findsOneWidget);
  // The dialog's buttons are GlassButtons, not Material TextButtons.
  await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('deleting a task offers an undo that brings the row back', (
    tester,
  ) async {
    final db = await pumpTodoPage(tester, active: 4, done: 0);
    final repo = DriftTodoRepository(db);

    await deleteTaskFromRow(tester, 'Task 1');

    expect(find.text('Task 1'), findsNothing);
    expect(
      (await repo.listTasks(todoHarnessListId)).map((t) => t.title),
      isNot(contains('Task 1')),
    );

    expect(find.text('Deleted "Task 1"'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    final restored = (await repo.listTasks(
      todoHarnessListId,
    )).where((t) => t.title == 'Task 1');
    expect(restored, hasLength(1));
    expect(restored.single.deletedAt, isNull);
    expect(
      restored.single.version,
      greaterThan(1),
      reason: 'the restore has to outrank the tombstone on the next sync',
    );
    expect(
      find.byType(TodoEditPanel),
      findsOneWidget,
      reason: 'undo opens the editor on the task it brought back',
    );
    expect(
      find.descendant(
        of: find.byType(TodoEditPanel),
        matching: find.text('Task 1'),
      ),
      findsOneWidget,
      reason: 'the editor is open on the restored task, not another one',
    );
    expect(
      find.text('Task 1'),
      findsNWidgets(2),
      reason:
          'the page must stop hiding the row it optimistically dropped — one '
          'match is that row, the other the editor undo opened',
    );
  });

  testWidgets('deleting the task the editor is open on puts both back', (
    tester,
  ) async {
    // The delete unmounts the panel, so its undo has to be run by the page.
    // Left to the panel it wrote the row back and stopped there — nothing
    // invalidated the task providers, so the row only reappeared whenever
    // some unrelated refresh next happened to land, seconds later.
    final db = await pumpTodoPage(tester, active: 4, done: 0);
    final repo = DriftTodoRepository(db);

    await tester.tap(find.text('Task 1'));
    await tester.pumpAndSettle();
    expect(find.byType(TodoEditPanel), findsOneWidget);

    await deleteTaskFromRow(tester, 'Task 1');

    expect(find.text('Task 1'), findsNothing);
    expect(find.byType(TodoEditPanel), findsNothing);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(
      (await repo.listTasks(todoHarnessListId)).map((t) => t.title),
      contains('Task 1'),
    );
    expect(
      find.byType(TodoEditPanel),
      findsOneWidget,
      reason: 'undo reopens the editor the delete closed',
    );
    expect(
      find.text('Task 1'),
      findsNWidgets(2),
      reason: 'the row is back in the list without waiting on a later refresh',
    );
  });

  testWidgets('letting the offer expire leaves the task deleted', (
    tester,
  ) async {
    final db = await pumpTodoPage(tester, active: 4, done: 0);
    final repo = DriftTodoRepository(db);

    await deleteTaskFromRow(tester, 'Task 2');
    expect(find.text('Undo'), findsOneWidget);

    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();

    expect(find.text('Undo'), findsNothing);
    expect(find.text('Task 2'), findsNothing);
    expect(
      (await repo.listTasks(todoHarnessListId)).map((t) => t.title),
      isNot(contains('Task 2')),
    );
  });
}
