import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';

/// Leaving Normal mode with `i`/`a` has to leave the caret in the code box.
/// The mode badge mounting and unmounting around the field used to re-inflate
/// the editor's subtree, which dropped focus and left the user unable to type.
void main() {
  testWidgets('code field keeps focus across Normal -> Insert', (tester) async {
    final controller = LeetCodeCodeController(text: 'print(1)\nprint(2)');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.dark(),
        home: Scaffold(
          body: VimEnabledScope(
            enabled: true,
            child: LeetCodeCodeInput(
              controller: controller,
              language: 'python',
              onLanguageChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField).last);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>(),
      isNotNull,
      reason: 'tapping the code box should focus it',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('NORMAL'), findsOneWidget, reason: 'Esc enters Normal');
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>(),
      isNotNull,
      reason: 'Esc into Normal mode must not move focus off the field',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pumpAndSettle();
    expect(find.text('NORMAL'), findsNothing, reason: 'i leaves Normal');
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>(),
      isNotNull,
      reason: 'i back into Insert mode must leave the caret in the field',
    );
  });

  /// Holding the focus node is not enough on its own. The badge mounting and
  /// unmounting used to hand the field a brand new [EditableTextState] on every
  /// transition, and a fresh state built onto a node that already has focus
  /// never sees a focus *change* — so it never opens a text input connection.
  /// The field then looked focused (this is why the test above passed while the
  /// app did not) and swallowed everything typed into it.
  testWidgets('code field can still be typed into after Normal -> Insert',
      (tester) async {
    final controller = LeetCodeCodeController(text: 'print(1)\nprint(2)');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.dark(),
        home: Scaffold(
          body: VimEnabledScope(
            enabled: true,
            child: LeetCodeCodeInput(
              controller: controller,
              language: 'python',
              onLanguageChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final codeEditable = find.byWidgetPredicate(
      (widget) => widget is EditableText && widget.controller == controller,
    );
    await tester.tap(codeEditable);
    await tester.pumpAndSettle();
    final editorState = tester.state<EditableTextState>(codeEditable);

    // Esc into Normal, `v` and back out again, then `i`: every one of these
    // changes the field's ancestry or its sibling layers.
    for (final key in [
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.keyI,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(
        tester.state<EditableTextState>(codeEditable),
        same(editorState),
        reason: 'the editor must be carried across the mode change, not '
            'rebuilt — a new state loses the input connection',
      );
    }

    // What the user actually does next: type. This arrives the way the
    // platform sends it, on the connection the field currently holds.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Xprint(1)\nprint(2)',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.text, startsWith('X'),
        reason: 'the code box must accept typing once back in Insert');

    // Let CodeController's own analysis debounce expire before teardown.
    await tester.pump(const Duration(seconds: 1));
  });
}
