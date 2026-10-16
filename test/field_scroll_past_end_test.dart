import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';

/// Pumps a 300px-tall expanding body holding [text] and returns the range its
/// text can scroll.
Future<double> _maxScroll(
  WidgetTester tester,
  String text, {
  required double pastEnd,
}) async {
  final controller = TextEditingController(text: text);
  final focusNode = FocusNode();
  addTearDown(controller.dispose);
  addTearDown(focusNode.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: VimEnabledScope(
          enabled: false,
          child: Scaffold(
            body: SizedBox(
              height: 300,
              child: TagHighlightedTextField(
                // A fresh key per pump, so each run builds its own field.
                key: UniqueKey(),
                controller: controller,
                focusNode: focusNode,
                expands: true,
                scrollPastEnd: pastEnd,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final scrollable = tester.state<ScrollableState>(
    find.descendant(
      of: find.byType(EditableText),
      matching: find.byType(Scrollable),
    ),
  );
  return scrollable.position.maxScrollExtent;
}

String _lines(int n) => List.generate(n, (i) => 'line $i').join('\n');

void main() {
  testWidgets('overflowing text scrolls exactly scrollPastEnd further', (
    tester,
  ) async {
    final plain = await _maxScroll(tester, _lines(40), pastEnd: 0);
    final extended = await _maxScroll(tester, _lines(40), pastEnd: 72);
    expect(plain, greaterThan(0));
    expect(extended, plain + 72);
  });

  testWidgets('text that reaches the bottom without overflowing can scroll', (
    tester,
  ) async {
    // Grow the text one line at a time until just before it overflows.
    var n = 1;
    while (await _maxScroll(tester, _lines(n + 1), pastEnd: 0) == 0) {
      n++;
    }
    expect(await _maxScroll(tester, _lines(n), pastEnd: 0), 0);
    final extended = await _maxScroll(tester, _lines(n), pastEnd: 72);
    expect(extended, greaterThan(0));
    expect(extended, lessThanOrEqualTo(72));
  });

  testWidgets('short text stays unscrollable', (tester) async {
    expect(await _maxScroll(tester, 'one line', pastEnd: 72), 0);
    expect(await _maxScroll(tester, '', pastEnd: 72), 0);
  });

  group('typing at the end', () {
    Future<ScrollPosition> pumpFocused(
      WidgetTester tester,
      TextEditingController controller,
    ) async {
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: VimEnabledScope(
              enabled: false,
              child: Scaffold(
                body: SizedBox(
                  height: 300,
                  child: TagHighlightedTextField(
                    controller: controller,
                    focusNode: focusNode,
                    expands: true,
                    scrollPastEnd: 72,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pump();
      return tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byType(EditableText),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
    }

    testWidgets('lifts the line being typed clear of the corner', (
      tester,
    ) async {
      final controller = TextEditingController(text: _lines(40));
      addTearDown(controller.dispose);
      final position = await pumpFocused(tester, controller);

      await tester.enterText(find.byType(EditableText), '${_lines(40)}\nmore');
      await tester.pumpAndSettle();

      expect(position.maxScrollExtent, greaterThan(72));
      expect(position.pixels, position.maxScrollExtent);
    });

    testWidgets('moving the caret alone does not lift it', (tester) async {
      final text = _lines(40);
      final controller = TextEditingController(text: text);
      addTearDown(controller.dispose);
      final position = await pumpFocused(tester, controller);

      controller.selection = TextSelection.collapsed(offset: text.length);
      await tester.pumpAndSettle();

      // Revealed only as far as the field's bottom edge, the text's own end.
      expect(position.pixels, position.maxScrollExtent - 72);
    });
  });
}
