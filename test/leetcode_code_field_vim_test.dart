import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/widgets/selection_highlight_layer.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';

void main() {
  late LeetCodeCodeController controller;

  Future<void> pumpInput(
    WidgetTester tester, {
    required bool vimEnabled,
    String text = '',
  }) async {
    controller = LeetCodeCodeController(text: text);
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpWidget(
      MaterialApp(
        home: VimEnabledScope(
          enabled: vimEnabled,
          child: Scaffold(
            body: LeetCodeCodeInput(
              controller: controller,
              language: 'python',
              onLanguageChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    // Line numbers are an IgnorePointer TextField; the code box is last.
    await tester.tap(find.byType(TextField).last);
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
  }

  /// Unmount first, then dispose: EditableText can still write the controller
  /// on detach, which would re-arm [CodeController]'s 500ms analysis timer.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }

  testWidgets('Esc enters Normal mode in the code box', (tester) async {
    await pumpInput(tester, vimEnabled: true, text: 'abc');
    expect(find.text('NORMAL'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('NORMAL'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(controller.text, 'bc');
    await finish(tester);
  });

  testWidgets('the mode badge sits in the box, not on the last line', (
    tester,
  ) async {
    // Forty lines in a box that caps at 320px. The badge hangs off the
    // bottom-right of whatever VimTextScope calls "the field", and the editor
    // column is as tall as the code it holds — so anchoring to it put the
    // badge hundreds of pixels below the box, where the clip fit painted
    // nothing at all.
    // Focused while it is short and grown afterwards: a tap never lands on a
    // field whose own box is taller than the window.
    await pumpInput(tester, vimEnabled: true, text: 'x0 = 0');
    controller.fullText = List.generate(40, (i) => 'x$i = $i').join('\n');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    final box = tester.getRect(find.byType(LeetCodeCodeSurface));
    final badge = tester.getRect(find.text('NORMAL'));
    expect(box.contains(badge.center), isTrue, reason: 'badge left the box');
    expect(box.bottom - badge.bottom, lessThan(24));
    expect(box.right - badge.right, lessThan(24));
    await finish(tester);
  });

  testWidgets('Vim stays off in the code box when the setting is disabled',
      (tester) async {
    await pumpInput(tester, vimEnabled: false, text: 'abc');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(find.text('NORMAL'), findsNothing);
    expect(controller.text, 'abc');
    await finish(tester);
  });

  testWidgets('read-only code view never gets Vim', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VimEnabledScope(
          enabled: true,
          child: Scaffold(
            body: LeetCodeCodeView(code: 'abc', language: 'python'),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField).last);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('NORMAL'), findsNothing);
  });

  testWidgets('Enter in Insert mode indents past a trailing comment', (
    tester,
  ) async {
    // Insert mode leaves Enter to the field, so the indent comes from the
    // controller's own rule rather than the Vim layer.
    const line = '    if x:  # walk the array';
    await pumpInput(tester, vimEnabled: true, text: line);
    controller.selection = const TextSelection.collapsed(
      offset: line.length,
    );
    await tester.pump();
    expect(find.text('NORMAL'), findsNothing);

    // What the platform sends on Enter: the whole text, break included.
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '$line\n',
        selection: TextSelection.collapsed(offset: line.length + 1),
      ),
    );
    await tester.pump();

    expect(controller.text, '$line\n        ');
    await finish(tester);
  });

  testWidgets('o opens the body of a block, as Enter does', (tester) async {
    await pumpInput(
      tester,
      vimEnabled: true,
      text: 'class Solution:\n    def f(self):\n        pass',
    );
    // On the `def` line, which ends in `:` four spaces in.
    controller.selection = const TextSelection.collapsed(offset: 20);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.pump();

    expect(
      controller.text,
      'class Solution:\n    def f(self):\n        \n        pass',
    );
    expect(controller.selection.baseOffset, 41);
    await finish(tester);
  });

  testWidgets('o below a plain line keeps that line indent', (tester) async {
    await pumpInput(
      tester,
      vimEnabled: true,
      text: 'class Solution:\n    def f(self):\n        pass',
    );
    // On `pass`, which opens no block.
    controller.selection = const TextSelection.collapsed(offset: 42);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.pump();

    expect(
      controller.text,
      'class Solution:\n    def f(self):\n        pass\n        ',
    );
    await finish(tester);
  });

  testWidgets('O above a block line stays at that line indent', (tester) async {
    await pumpInput(
      tester,
      vimEnabled: true,
      text: 'class Solution:\n    def f(self):\n        pass',
    );
    controller.selection = const TextSelection.collapsed(offset: 20);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO, character: 'O');
    await tester.pump();

    expect(
      controller.text,
      'class Solution:\n    \n    def f(self):\n        pass',
    );
    await finish(tester);
  });


  // `x` on the last character of a line cuts the character and then clamps the
  // caret back onto the line, which is the same text-and-caret pair a
  // backspace one place to the right writes. The editor's keystroke rules used
  // to read it that way: on the closing half of an auto-closed pair `x` took
  // both halves and left the caret past the line's last character, where every
  // later `x` did nothing at all.
  testWidgets('x takes one character at a time off the end of a line', (
    tester,
  ) async {
    await pumpInput(tester, vimEnabled: true, text: '        for ``');
    controller.selection = const TextSelection.collapsed(offset: 14);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(controller.text, '        for `');

    // Through the indent too: `x` there used to eat a whole tab stop, the
    // backspace-outdent rule misreading the same clamped caret.
    for (var i = 0; i < 13; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pump();
      expect(controller.text.length, 12 - i);
    }
    await finish(tester);
  });

  // Undo and redo restore a value, which is no more a keystroke than a Vim
  // edit is. Read as one, the restore after a space typed into a line's indent
  // came back outdented to the tab stop below — and, because the rewrite made
  // the restored value not stick, tripped UndoHistory's own assert.
  testWidgets('Ctrl+Z gives back the indent it was typed into', (tester) async {
    await pumpInput(tester, vimEnabled: true, text: '');
    final state = tester.state<EditableTextState>(
      find.byType(EditableText).last,
    );
    // Two text changes, each far enough apart to land its own undo entry.
    state.updateEditingValue(
      const TextEditingValue(
        text: '       ',
        selection: TextSelection.collapsed(offset: 7),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    state.updateEditingValue(
      const TextEditingValue(
        text: '        ',
        selection: TextSelection.collapsed(offset: 8),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    expect(controller.text, '       ');
    await finish(tester);
  });

  // The same restore, reached through Vim's own `u` rather than an intent.
  // `x` yanks the space it cuts and `p` puts it back one place along, so the
  // entry `u` returns to sits one character behind the caret — the shape a
  // backspace writes.
  testWidgets('u gives back the indent p pasted into', (tester) async {
    await pumpInput(tester, vimEnabled: true, text: '        ');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.text, '        ');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.pump();
    expect(controller.text, '       ');
    await finish(tester);
  });

  testWidgets('Visual mode uses VimTextOverlay instead of SelectionHighlightLayer',
      (tester) async {
    await pumpInput(tester, vimEnabled: true, text: 'abc');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(SelectionHighlightLayer), findsOneWidget);
    expect(find.byType(VimTextOverlay), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(find.text('VISUAL'), findsOneWidget);
    expect(find.byType(VimTextOverlay), findsOneWidget);
    expect(find.byType(SelectionHighlightLayer), findsNothing);
  });
}
