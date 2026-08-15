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
