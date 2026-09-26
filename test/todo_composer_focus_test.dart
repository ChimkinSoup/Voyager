// Entering tasks back to back: the composer keeps the keyboard the whole way,
// even while the previous add is still being written. It used to let go on
// every Enter and take it back only once the write landed, so keys typed in
// between went nowhere — and an Enter on the field that left empty let go for
// good.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

import 'support/todo_page_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('rapid Enter keeps the composer focused and adds every task', (
    tester,
  ) async {
    final db = await pumpTodoPage(tester, active: 3, done: 1);
    final composer = find.byType(EditableText).first;
    await tester.tap(composer);
    await tester.pump();

    bool composerFocused() =>
        tester.widget<EditableText>(composer).focusNode.hasFocus;

    for (final title in ['one', 'two', 'three']) {
      await tester.enterText(composer, title);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      // No time for the write to land before the next key.
      await tester.pump();
      expect(composerFocused(), isTrue, reason: 'after "$title"');
    }
    // Enter again on the now-empty field, as a lost keystroke leaves it.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(composerFocused(), isTrue, reason: 'after an empty Enter');

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(composerFocused(), isTrue);
    final tasks = await DriftTodoRepository(db).listTasks(todoHarnessListId);
    final titles = [for (final t in tasks) t.title];
    expect(titles, containsAll(['one', 'two', 'three']));
  });
}
