// On a short window the edit panel's fields were capped at 60% of its height
// to leave room for the subtask list, so with no subtasks the image strip and
// "Add subtask" sat below the fold above an empty area (BUG-070).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';

import 'support/todo_page_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('with no subtasks, "Add subtask" is in view on a short panel', (
    tester,
  ) async {
    // Tall enough for the fields to fit whole, short enough that 60% of the
    // panel does not hold them.
    tester.view.physicalSize = const Size(640, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpTodoPage(tester, active: 1, done: 0);
    await tester.tap(find.text('Task 0'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    final addSubtask = find.descendant(
      of: find.byType(TodoEditPanel),
      matching: find.text('Add subtask'),
    );
    final fieldsViewport = tester.getRect(
      find.ancestor(of: addSubtask, matching: find.byType(Scrollable)).first,
    );
    final hint = tester.getRect(addSubtask);
    expect(hint.bottom, lessThanOrEqualTo(fieldsViewport.bottom));
  });
}
