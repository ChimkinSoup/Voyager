import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';

/// The `#tag` pill layer used to read a 200ms-debounced copy of the text, so a
/// tag deleted outright left its pill on screen for a beat after the letters
/// were gone. It has to follow the text on the very next frame.
void main() {
  RenderObject pillLayer(WidgetTester tester) => tester.renderObject(
    find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_TagHighlightPainter',
    ),
  );

  testWidgets('a deleted tag loses its pill on the next frame', (
    tester,
  ) async {
    final controller = TextEditingController(text: '#tam');
    addTearDown(controller.dispose);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TagHighlightedTextField(
            controller: controller,
            focusNode: focusNode,
            useNotchedBorder: false,
          ),
        ),
      ),
    );
    expect(pillLayer(tester), paints..rrect());

    controller.text = '';
    await tester.pump();
    expect(pillLayer(tester), isNot(paints..rrect()));

    controller.text = '#tam';
    await tester.pump();
    expect(pillLayer(tester), paints..rrect());
  });
}
