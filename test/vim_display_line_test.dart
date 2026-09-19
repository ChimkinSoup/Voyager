import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_session.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';

/// `gj` / `gk` move by the lines the field wraps to, not by `\n`, so they need
/// a real laid-out field: a narrow one, so plain runs of `M` soft-wrap.
void main() {
  late TextEditingController controller;

  setUp(() {
    controller = TextEditingController();
    VimRegister.text = '';
    VimRegister.linewise = false;
  });

  tearDown(() => controller.dispose());

  Future<RenderEditable> pumpWrapped(WidgetTester tester, String text) async {
    controller.text = text;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: SizedBox(
                width: 80,
                child: LabeledTextField(
                  label: 'Body',
                  controller: controller,
                  maxLines: null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    return tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
  }

  Future<void> type(WidgetTester tester, String keys) async {
    for (final ch in keys.split('')) {
      await tester.sendKeyEvent(_keyFor(ch));
      await tester.pump();
    }
  }

  Future<void> placeCaret(WidgetTester tester, int offset) async {
    controller.selection = TextSelection.collapsed(offset: offset);
    await tester.pump();
  }

  double topAt(RenderEditable editable, int offset) =>
      editable.getLocalRectForCaret(TextPosition(offset: offset)).top;

  /// Offsets at which each display line starts.
  List<int> displayLineStarts(RenderEditable editable) {
    final text = controller.text;
    final starts = <int>[];
    double? previous;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '\n') continue;
      final top = topAt(editable, i);
      if (previous == null || (top - previous).abs() > 0.5) starts.add(i);
      previous = top;
    }
    return starts;
  }

  int caret() => controller.selection.baseOffset;

  testWidgets('gj / gk step through the wraps of one logical line', (
    tester,
  ) async {
    final editable = await pumpWrapped(tester, 'M' * 20);
    final starts = displayLineStarts(editable);
    expect(starts.length, greaterThan(2), reason: 'text must wrap');

    await placeCaret(tester, 1);
    await type(tester, 'gj');
    expect(caret(), starts[1] + 1);
    await type(tester, 'gj');
    expect(caret(), starts[2] + 1);
    await type(tester, 'gk');
    await type(tester, 'gk');
    expect(caret(), 1);
  });

  testWidgets('j still moves by logical line', (tester) async {
    const text = 'MMMMMMMMMMMMMMMMMMMM\nMMM';
    final editable = await pumpWrapped(tester, text);
    expect(displayLineStarts(editable).length, greaterThan(2));

    await placeCaret(tester, 1);
    await type(tester, 'j');
    expect(caret(), text.indexOf('\n') + 2);
  });

  testWidgets('a count moves that many display lines', (tester) async {
    final editable = await pumpWrapped(tester, 'M' * 20);
    final starts = displayLineStarts(editable);

    await placeCaret(tester, 0);
    await type(tester, '2gj');
    expect(caret(), starts[2]);
  });

  testWidgets('gj on the last display line stays put', (tester) async {
    final editable = await pumpWrapped(tester, 'M' * 20);
    final last = displayLineStarts(editable).last;

    await placeCaret(tester, last);
    await type(tester, 'gj');
    expect(caret(), last);
    await type(tester, 'x');
    expect(controller.text.length, 19, reason: 'g must not stay armed');
  });

  testWidgets('g<Down> / g<Up> are gj / gk', (tester) async {
    final editable = await pumpWrapped(tester, 'M' * 20);
    final starts = displayLineStarts(editable);

    await placeCaret(tester, 1);
    await type(tester, 'g');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(caret(), starts[1] + 1);
    await type(tester, 'g');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(caret(), 1);
  });

  testWidgets('the screen column survives a short line in between', (
    tester,
  ) async {
    const long = 'MMMMMMMMMMMMMMMMMMMM';
    const text = '$long\nM\n$long';
    final editable = await pumpWrapped(tester, text);
    final starts = displayLineStarts(editable);
    final shortLine = long.length + 1;
    final belowShort = starts.indexOf(shortLine) + 1;

    await placeCaret(tester, starts[belowShort - 2] + 1);
    await type(tester, 'gj');
    expect(caret(), shortLine, reason: 'clamped onto the one-char line');
    await type(tester, 'gj');
    expect(caret(), starts[belowShort] + 1);
  });

  testWidgets('gk past a soft wrap lands on the wrapped line', (tester) async {
    // A short first line: its wrap follows the space, so aiming past its end
    // hits the wrap offset, which paints at the start of the line below.
    final editable = await pumpWrapped(tester, 'MM ${'M' * 20}');
    final starts = displayLineStarts(editable);
    expect(starts[1], 3);

    await placeCaret(tester, starts[2] - 1);
    await type(tester, 'gk');
    expect(caret(), lessThan(starts[1]));
    expect(topAt(editable, caret()), closeTo(topAt(editable, 0), 0.5));
  });

  testWidgets('dgj deletes charwise up to the same screen column', (
    tester,
  ) async {
    final editable = await pumpWrapped(tester, 'M' * 20);
    final starts = displayLineStarts(editable);

    await placeCaret(tester, 1);
    await type(tester, 'dgj');
    expect(controller.text.length, 20 - starts[1]);
    expect(caret(), 1);
  });

  testWidgets('dgj repeats with .', (tester) async {
    final editable = await pumpWrapped(tester, 'M' * 20);
    final perLine = displayLineStarts(editable)[1];

    await placeCaret(tester, 0);
    await type(tester, 'dgj');
    await type(tester, '.');
    expect(controller.text.length, 20 - 2 * perLine);
  });

  testWidgets('Visual gj extends the selection one display line', (
    tester,
  ) async {
    final editable = await pumpWrapped(tester, 'M' * 20);
    final starts = displayLineStarts(editable);

    await placeCaret(tester, 1);
    await type(tester, 'vgj');
    expect(controller.selection.start, 1);
    expect(controller.selection.end, starts[1] + 2);
  });
}

LogicalKeyboardKey _keyFor(String ch) {
  const map = <String, LogicalKeyboardKey>{
    '2': LogicalKeyboardKey.digit2,
    '.': LogicalKeyboardKey.period,
  };
  final mapped = map[ch];
  if (mapped != null) return mapped;
  return LogicalKeyboardKey.knownLogicalKeys.firstWhere(
    (k) => k.keyLabel.toLowerCase() == ch.toLowerCase(),
    orElse: () => throw ArgumentError('No key for "$ch"'),
  );
}
