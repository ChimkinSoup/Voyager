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
