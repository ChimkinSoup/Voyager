import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';

Future<LeetCodeCodeController> _pumpEditor(
  WidgetTester tester, {
  required String code,
  required String language,
}) async {
  final controller = LeetCodeCodeController(text: code);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          child: LeetCodeCodeInput(
            controller: controller,
            language: language,
            onLanguageChanged: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('the strip button removes the language\'s line comments',
      (WidgetTester tester) async {
    final controller = await _pumpEditor(
      tester,
      code: '// lead\nint a = 1; // trail\nint b = 2;',
      language: 'java',
    );

    await tester.tap(find.byType(GlassButton));
    // CodeController debounces its analysis pass by 500ms; leaving that timer
    // pending fails the test at teardown.
    await tester.pump(const Duration(milliseconds: 600));

    expect(controller.fullText, 'int a = 1;\nint b = 2;');
    // The caret has to land somewhere inside the new text: CodeController
    // leaves the selection unset after a fullText write, which reads as
    // offset -1 and throws the moment the field is focused.
    expect(controller.selection.baseOffset, inInclusiveRange(0, controller.fullText.length));
  });

  testWidgets('the strip button follows the selected language',
      (WidgetTester tester) async {
    final controller = await _pumpEditor(
      tester,
      code: 'x = 1  # trail\ny = "a // b"',
      language: 'python',
    );

    await tester.tap(find.byType(GlassButton));
    // CodeController debounces its analysis pass by 500ms; leaving that timer
    // pending fails the test at teardown.
    await tester.pump(const Duration(milliseconds: 600));

    expect(controller.fullText, 'x = 1\ny = "a // b"');
  });

  testWidgets('the language row lays the pills and the button out without overflow',
      (WidgetTester tester) async {
    await _pumpEditor(tester, code: 'int a = 1;', language: 'java');

    final row = tester.getRect(find.byType(GlassButton));
    final field = tester.getRect(find.byType(LeetCodeCodeInput));
    expect(row.right, moreOrLessEquals(field.right, epsilon: 0.5));
    expect(row.height, lessThanOrEqualTo(32));
    expect(tester.takeException(), isNull);
  });
}
