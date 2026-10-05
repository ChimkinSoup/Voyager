// The to-do hotkey's in-app path carries the quick-add bar's draft into the
// composer. On desktop a one-line field selects all of its text when it
// gains focus, so the draft used to arrive fully selected and the first
// keystroke erased it (BUG-033).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';
import 'package:voyager/features/todo/todo_page.dart';

import 'support/todo_page_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets(
    'the carried draft arrives with the caret at its end (BUG-033)',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await pumpTodoPage(tester, active: 1, done: 0);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TodoPage)),
      );
      container.read(todoCaptureDraftProvider.notifier).state =
          const TodoCaptureDraft(title: 'draft x');
      container.read(quickCaptureRequestProvider.notifier).state =
          QuickCaptureRequest(QuickCaptureKind.todo);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      final composer = tester.widget<EditableText>(
        find.byType(EditableText).first,
      );
      expect(composer.focusNode.hasFocus, isTrue);
      expect(composer.controller.text, 'draft x');
      expect(
        composer.controller.selection,
        const TextSelection.collapsed(offset: 7),
      );
    },
  );
}
