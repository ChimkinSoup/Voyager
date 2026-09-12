import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/text/prose_highlight_paint.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/text/styled_runs.dart';
import 'package:voyager/core/widgets/search_highlight_text.dart';
import 'package:voyager/core/widgets/voyager_prose_text.dart';
import 'package:voyager/features/leetcode/leetcode_inline_code.dart';
import 'package:voyager/features/study/study_rich_text.dart';

/// Read mode (EMPHASIS_FORMATTING.md §5.3, §10): the surfaces that *show*
/// stored prose rather than editing it. Nothing is ever revealed here, so
/// every delimiter is laid out at zero width and the reader sees only the
/// styled word — while the string itself is untouched, which is what keeps
/// search offsets, tag pills and inline-code chips landing where they did.
void main() {
  const theme = ProseEmphasisTheme(
    delimiterColor: Color(0xFF000000),
    highlightColor: Color(0x40FF0000),
    underlineColor: Color(0xFF000000),
  );

  group('proseReadRanges', () {
    test('a delimiter is laid out at zero width, not dropped', () {
      final ranges = proseReadRanges('a **b** c', theme);
      expect(ranges.map((r) => (r.start, r.end)), [
        (2, 4),
        (4, 5),
        (5, 7),
      ]);
      expect(ranges[0].style.fontSize, 0);
      expect(ranges[1].style.fontWeight, FontWeight.bold);
      expect(ranges[2].style.fontSize, 0);
    });

    test('nesting comes back as one merged style per run', () {
      final ranges = proseReadRanges('**b *i* b**', theme);
      final styled = [
        for (final r in ranges)
          if (r.style.fontSize != 0) r,
      ];
      expect(styled.first.style.fontWeight, FontWeight.bold);
      final inner = styled.firstWhere((r) => r.style.fontStyle != null);
      expect(inner.style.fontWeight, FontWeight.bold);
      expect(inner.style.fontStyle, FontStyle.italic);
    });

    test('underline and highlight carry their colours', () {
      final underline = proseReadRanges('__u__', theme)[1];
      expect(underline.style.decoration, TextDecoration.underline);
      expect(underline.style.decorationColor, const Color(0xFF000000));
      // The highlight carries a mark, not its fill: the corners are rounded,
      // and `backgroundColor` can only paint a hard rect.
      final highlight = proseReadRanges('==h==', theme)[1];
      expect(highlight.style.backgroundColor, kProseHighlightMark);
    });

    test('plain prose produces nothing at all', () {
      expect(proseReadRanges('nothing to see', theme), isEmpty);
      expect(proseReadRanges('2 * 3 and a__b__c', theme), isEmpty);
      // §4.3: inside math the asterisk is multiplication.
      expect(proseReadRanges(r'sum $x * y$ holds', theme), isEmpty);
    });
  });

  group('applyStyledRanges', () {
    test('a range straddling two spans splits both', () {
      final out = applyStyledRanges(
        const [
          TextSpan(text: 'abc'),
          TextSpan(text: 'def', style: TextStyle(color: Color(0xFF00FF00))),
        ],
        const [
          (start: 2, end: 4, style: TextStyle(fontWeight: FontWeight.bold)),
        ],
        0,
      );
      expect(out.map((s) => s.text), ['ab', 'c', 'd', 'ef']);
      expect(out[1].style?.fontWeight, FontWeight.bold);
      expect(out[2].style?.fontWeight, FontWeight.bold);
      expect(out[2].style?.color, const Color(0xFF00FF00));
    });

    test('an offset says where the slice starts in the document', () {
      final out = applyStyledRanges(
        const [TextSpan(text: 'cd')],
        const [
          (start: 3, end: 4, style: TextStyle(fontWeight: FontWeight.bold)),
        ],
        2,
      );
      expect(out.map((s) => s.text), ['c', 'd']);
      expect(out[1].style?.fontWeight, FontWeight.bold);
    });

    test('no ranges is the identity', () {
      const spans = [TextSpan(text: 'abc')];
      expect(applyStyledRanges(spans, const [], 0), same(spans));
    });
  });

  group('surfaces', () {
    /// Every styled run the surface actually built, in document order.
    ///
    /// Across *all* the paragraphs it built, not just the outermost: a tag
    /// pill is a `WidgetSpan` holding a `Text.rich` of its own.
    List<(String, TextStyle?)> runs(WidgetTester tester) {
      final out = <(String, TextStyle?)>[];
      void walk(InlineSpan node, TextStyle? inherited) {
        if (node is! TextSpan) return;
        final style = node.style == null
            ? inherited
            : (inherited ?? const TextStyle()).merge(node.style);
        final text = node.text;
        if (text != null && text.isNotEmpty) out.add((text, style));
        for (final child in node.children ?? const <InlineSpan>[]) {
          walk(child, style);
        }
      }

      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        walk(rich.text, null);
      }
      return out;
    }

    Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: child)),
    );

    testWidgets('VoyagerProseText hides the markers and bolds the word', (
      tester,
    ) async {
      await pump(tester, const VoyagerProseText('a **big** deal'));
      expect(runs(tester).map((r) => r.$1).join(), 'a **big** deal');
      final bold = runs(tester).firstWhere((r) => r.$1 == 'big');
      expect(bold.$2?.fontWeight, FontWeight.bold);
      expect(
        runs(
          tester,
        ).where((r) => r.$1 == '**').every((r) => r.$2?.fontSize == 0),
        isTrue,
      );
    });

    testWidgets('VoyagerProseText leaves plain prose as a plain Text', (
      tester,
    ) async {
      await pump(tester, const VoyagerProseText('nothing here'));
      expect(find.text('nothing here'), findsOneWidget);
    });

    testWidgets('a search result renders its markers', (tester) async {
      await pump(
        tester,
        searchHighlightedText(
          'a **big** deal',
          style: const TextStyle(fontSize: 14),
          emphasisTheme: theme,
          brightness: Brightness.dark,
        ),
      );
      final bold = runs(tester).firstWhere((r) => r.$1 == 'big');
      expect(bold.$2?.fontWeight, FontWeight.bold);
    });

    testWidgets('a bolded tag stays a pill and comes out bold', (tester) async {
      // §4.4: the wrapper applies to the tag, and the tag stays functional.
      await pump(
        tester,
        searchHighlightedText(
          'see **#project** now',
          style: const TextStyle(fontSize: 14),
          emphasisTheme: theme,
          brightness: Brightness.dark,
        ),
      );
      expect(find.byType(Container), findsWidgets); // the pill
      final tag = runs(
        tester,
      ).where((r) => r.$1 == '#project').toList();
      expect(tag, isNotEmpty);
      expect(tag.first.$2?.fontWeight, FontWeight.bold);
    });

    testWidgets('a keyword hit inside a bold span keeps both', (tester) async {
      await pump(
        tester,
        searchHighlightedText(
          '**a big deal**',
          // A colour, because the keyword wash is derived from it.
          style: const TextStyle(fontSize: 14, color: Color(0xFF202020)),
          keywords: const ['big'],
          emphasisTheme: theme,
          brightness: Brightness.dark,
        ),
      );
      final hit = runs(tester).firstWhere((r) => r.$1 == 'big');
      expect(hit.$2?.fontWeight, FontWeight.bold);
      expect(hit.$2?.backgroundColor, isNotNull);
    });

    testWidgets('a study card bolds prose and leaves math alone', (
      tester,
    ) async {
      await pump(tester, const StudyRichText(r'**note** on $x * y$'));
      final bold = runs(tester).firstWhere((r) => r.$1 == 'note');
      expect(bold.$2?.fontWeight, FontWeight.bold);
      // The equation is rendered by `Math.tex` and has spans of its own, so
      // the `*`-stays-literal half of this is asserted on the parser above.
    });

    testWidgets('LeetCode prose leaves markers inside code literal', (
      tester,
    ) async {
      await pump(
        tester,
        const LeetCodeProseText(
          'use `a **b** c` here',
          style: TextStyle(fontSize: 14),
          language: 'python',
        ),
      );
      // The backticks are stripped on the way to the screen; everything
      // between them is code, so the asterisks stay as characters.
      expect(runs(tester).map((r) => r.$1).join(), 'use a **b** c here');
      expect(
        runs(tester).any((r) => r.$2?.fontWeight == FontWeight.bold),
        isFalse,
      );
    });

    testWidgets('LeetCode prose still bolds around a code chip', (
      tester,
    ) async {
      await pump(
        tester,
        const LeetCodeProseText(
          '**call `x` twice**',
          style: TextStyle(fontSize: 14),
          language: 'python',
        ),
      );
      final call = runs(tester).firstWhere((r) => r.$1.contains('call'));
      expect(call.$2?.fontWeight, FontWeight.bold);
    });
  });
}
