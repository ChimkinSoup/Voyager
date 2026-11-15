import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_card_text_field.dart';

void main() {
  late TextEditingController controller;

  Future<void> pump(WidgetTester tester) async {
    controller = TextEditingController(text: 'short\n\nlonger second line');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            child: GaiaCardTextField(controller: controller, maxLines: 6),
          ),
        ),
      ),
    );
  }

  Future<void> doubleClick(WidgetTester tester, Offset at) async {
    for (var i = 0; i < 2; i++) {
      final gesture = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  /// A point on the first line, [dx] in from the field's left.
  Offset firstLine(WidgetTester tester, double dx) {
    final box = tester.getRect(find.byType(EditableText));
    return Offset(box.left + dx, box.top + 4);
  }

  testWidgets('double click on an empty line leaves a caret', (tester) async {
    await pump(tester);
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final caret = editable.getLocalRectForCaret(const TextPosition(offset: 6));
    await doubleClick(tester, editable.localToGlobal(caret.center));
    expect(controller.selection, const TextSelection.collapsed(offset: 6));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('double click on a word still selects it', (tester) async {
    await pump(tester);
    await doubleClick(tester, firstLine(tester, 10));
    expect(
      controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
