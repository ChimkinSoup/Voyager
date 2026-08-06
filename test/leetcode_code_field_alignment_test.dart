import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';

const _code = 'code\ncode\niarse\nfor this in this:';

/// Offset of the first character of each line, for the code text above and
/// for the '1\n2\n3\n4' the gutter derives from it.
const _codeLineStarts = <int>[0, 5, 10, 16];
const _numberLineStarts = <int>[0, 2, 4, 6];

/// A theme whose `bodyLarge` and `titleMedium` deliberately disagree on size
/// and leading. The line-number column resolves its metrics from the former
/// and `CodeField` seeds its own default from the latter, so under this theme
/// any reliance on inheritance shows up as a baseline drift between the
/// gutter and the code.
ThemeData _divergedTypeScale() {
  final base = ThemeData(useMaterial3: true);
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      bodyLarge: const TextStyle(fontSize: 16, height: 1.35),
      titleMedium: const TextStyle(fontSize: 22, height: 1.90),
    ),
  );
}

Future<List<RenderEditable>> _pumpCodeView(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: _divergedTypeScale(),
      home: const Scaffold(
        body: LeetCodeCodeView(code: _code, language: 'python'),
      ),
    ),
  );
  await tester.pump();

  final renderers = tester
      .stateList<EditableTextState>(find.byType(EditableText))
      .map((state) => state.renderEditable)
      .toList();
  expect(renderers, hasLength(2), reason: 'line-number column plus the code field');
  return renderers;
}

void main() {
  testWidgets('code and line numbers share one text metric under a diverged type scale',
      (WidgetTester tester) async {
    await _pumpCodeView(tester);

    final fields = tester.widgetList<EditableText>(find.byType(EditableText)).toList();
    expect(fields.last.style.fontSize, fields.first.style.fontSize);
    expect(fields.last.style.height, fields.first.style.height);

    // Both columns must stay on the same family: with even leading
    // distribution the baseline's place in the line box comes from the font's
    // own ascent/descent, so two families would drift even at equal metrics.
    expect(fields.first.style.fontFamily, AppFonts.monoFamily);
    expect(fields.last.style.fontFamily, AppFonts.monoFamily);
  });

  testWidgets('every line number sits on its code line', (WidgetTester tester) async {
    final renderers = await _pumpCodeView(tester);
    final numbers = renderers.first;
    final code = renderers.last;

    // Comparing all four lines rather than just the first catches drift that
    // accumulates per line, which is how a line-height mismatch presents.
    for (var line = 0; line < _codeLineStarts.length; line++) {
      final numberBottom = numbers.localToGlobal(
        numbers.getLocalRectForCaret(TextPosition(offset: _numberLineStarts[line])).bottomLeft,
      );
      final codeBottom = code.localToGlobal(
        code.getLocalRectForCaret(TextPosition(offset: _codeLineStarts[line])).bottomLeft,
      );
      expect(
        numberBottom.dy,
        moreOrLessEquals(codeBottom.dy, epsilon: 0.5),
        reason: 'line ${line + 1}',
      );
    }
  });
}
