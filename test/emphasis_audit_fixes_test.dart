import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/spell_check_tokenizer.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/text/html_to_markers.dart';
import 'package:voyager/core/text/prose_highlight_paint.dart';
import 'package:voyager/core/text/prose_markup.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/text/styled_runs.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/journal_models.dart';

/// The words the dictionary is actually offered, for a document.
List<String> checkedWords(String text) => [
  for (final range in tokenizeWords(text))
    text.substring(range.start, range.end),
];

List<TextRange> readHighlights(String text) {
  const theme = ProseEmphasisTheme.metrics();
  return proseHighlightRanges(
    buildStyledRuns(text, const TextStyle(), proseReadRanges(text, theme)),
  );
}

List<TextRange> editorHighlights(String text) {
  const theme = ProseEmphasisTheme.metrics();
  return proseHighlightRanges(
    buildProseSpan(
      markup: ProseMarkup.parse(text),
      base: const TextStyle(),
      revealed: const {},
      theme: theme,
    ),
  );
}

void main() {
  group(r'$…$ pairs like math, not like prices', () {
    test('two dollar amounts are not a LaTeX zone', () {
      const text = r'I paid $5 for lunhc and $10 for dinner';
      expect(ProseMarkup.zonesOf(text), isEmpty);
      // The whole sentence stays spellchecked — `lunhc` used to fall inside
      // the zone and get neither a squiggle nor a correction.
      expect(checkedWords(text), contains('lunhc'));
    });

    test('a pair does not reach across a line', () {
      expect(ProseMarkup.zonesOf('costs \$5 today\nand \$9 tomorrow'), isEmpty);
    });

    test('real math still pairs', () {
      expect(ProseMarkup.zonesOf(r'Solve $x^{2} + 1 = 0$ for x'), [
        (start: 6, end: 21, kind: ProseZoneKind.latex, closed: true),
      ]);
    });

    test('a space just inside a delimiter is not math', () {
      expect(ProseMarkup.zonesOf(r'$ x $'), isEmpty);
    });
  });

  group('an inner single delimiter does not sink the pair', () {
    test('`__` survives a stray `_`', () {
      expect(ProseMarkup.parse('__hello _world__').spans, [
        const EmphasisSpan(
          start: 0,
          end: 16,
          kind: EmphasisKind.underline,
          delimiterLength: 2,
        ),
      ]);
    });

    test('`==` survives a stray `=`', () {
      expect(ProseMarkup.parse('==a =b==').spans, [
        const EmphasisSpan(
          start: 0,
          end: 8,
          kind: EmphasisKind.highlight,
          delimiterLength: 2,
        ),
      ]);
    });

    test('`2 * 3` and `x = 5` stay literal', () {
      expect(ProseMarkup.parse('2 * 3 and x = 5').spans, isEmpty);
    });
  });

  group('read and editor surfaces mark the same highlight', () {
    // The read path used to drop the ancestor's mark on a nested delimiter,
    // splitting one fill into abutting rects that each rounded their corners.
    for (final text in const [
      '==a **b** c==',
      '==a *b* c==',
      '==**a** b==',
      '==a __b__ c==',
      '==a ==',
      'x ==a **b** c== y ==d==',
      '**==a *b* c==**',
    ]) {
      test('$text is one run on both', () {
        expect(readHighlights(text), editorHighlights(text));
      });
    }
  });

  group('an unclosed backtick does not blind the tokenizer', () {
    const text = r'a `oops then #mytagg and $x$ done';

    test('the tag and the equation below it are still zones', () {
      expect(
        ProseMarkup.zonesOf(text).where((z) => z.closed).map((z) => z.kind),
        [ProseZoneKind.tag, ProseZoneKind.latex],
      );
    });

    test('their bodies are not offered to the dictionary', () {
      expect(checkedWords(text), ['a', 'oops', 'then', 'and', 'done']);
    });

    test('emphasis is still suppressed for the whole tail', () {
      expect(ProseMarkup.parse('a `oops **bold** here').spans, isEmpty);
    });
  });

  group('HTML paste writes only markers that survive', () {
    test('an underline abutting a word pastes plain', () {
      expect(htmlToProseMarkers('<p>foo<u>bar</u>baz</p>'), 'foobarbaz');
    });

    test('an underline with room around it still pastes', () {
      const html = '<p>Some <u>underlined</u> text</p>';
      expect(htmlToProseMarkers(html), 'Some __underlined__ text');
      expect(ProseMarkup.parse(htmlToProseMarkers(html)).spans, hasLength(1));
    });

    test('bold around its own asterisk pastes plain', () {
      expect(htmlToProseMarkers('<b>2*3</b>'), '2*3');
    });

    test('a highlight around its own `==` pastes plain', () {
      expect(htmlToProseMarkers('<mark>a==b</mark>'), 'a==b');
    });

    test("a nested italic does not withdraw its parent's bold", () {
      const html = '<b>a <i>b</i> c</b>';
      expect(htmlToProseMarkers(html), '**a *b* c**');
    });

    test('an unclosed element still balances', () {
      expect(htmlToProseMarkers('<b>bold'), '**bold**');
    });
  });

  group('`__` wrapping a tag', () {
    test('the tag body stops at the delimiter, so the pair matches', () {
      expect(ProseMarkup.zonesOf('__#tag__'), [
        (start: 2, end: 6, kind: ProseZoneKind.tag, closed: true),
      ]);
      expect(ProseMarkup.parse('__#tag__').spans, [
        const EmphasisSpan(
          start: 0,
          end: 8,
          kind: EmphasisKind.underline,
          delimiterLength: 2,
        ),
      ]);
    });

    test('`#tag_name` is still one tag', () {
      expect(ProseMarkup.zonesOf('#tag_name'), [
        (start: 0, end: 9, kind: ProseZoneKind.tag, closed: true),
      ]);
      expect(activeTagToken('#tag_name', 5)?.end, 9);
    });

    test('completion stops at a `__` instead of eating the span', () {
      // `#pro|__y__` — replacing [start, end) used to delete `__y__` too.
      expect(activeTagToken('#pro__y__', 4), (start: 0, end: 4, query: 'pro'));
    });

    test('a wrapping `__` does not read as a `C#`-style sigil', () {
      expect(activeTagToken('__#tag__', 6)?.query, 'tag');
    });

    test('`a_#tag` is still rejected', () {
      expect(activeTagToken('a_#tag', 6), isNull);
    });

    test('a caret inside the underline is not in a tag', () {
      expect(activeTagToken('#pro__y__', 7), isNull);
    });
  });

  group('a search keyword keeps its wash inside a highlight', () {
    // `==a keyword b==`: the keyword run carries its own background, and the
    // highlight around it must still read as one contiguous marked run.
    const text = '==a keyword b==';
    late List<TextSpan> spans;

    setUp(() {
      const wash = Color(0xFF00FF00);
      spans = applyStyledRanges(
        [
          const TextSpan(text: '==a '),
          const TextSpan(
            text: 'keyword',
            style: TextStyle(backgroundColor: wash),
          ),
          const TextSpan(text: ' b=='),
        ],
        proseReadRanges(text, const ProseEmphasisTheme.metrics()),
        0,
      );
    });

    test('the fill is not split around it', () {
      expect(proseHighlightRanges(TextSpan(children: spans)), [
        const TextRange(start: 2, end: 13),
      ]);
    });

    test('the wash is still on the keyword', () {
      final marked = <String>[];
      void walk(InlineSpan node, Color? inherited) {
        if (node is! TextSpan) return;
        final background = node.style?.backgroundColor ?? inherited;
        final text = node.text;
        if (text != null && background == const Color(0xFF00FF00)) {
          marked.add(text);
        }
        for (final child in node.children ?? const <InlineSpan>[]) {
          walk(child, background);
        }
      }

      walk(TextSpan(children: spans), null);
      expect(marked, ['keyword']);
    });
  });

  group('non-breaking space flanks like a space', () {
    test('a closer preceded by U+00A0 does not close', () {
      expect(ProseMarkup.parse('**word\u{00A0}**').spans, isEmpty);
    });

    test('a `*` flanked by U+00A0 is multiplication', () {
      expect(ProseMarkup.parse('2\u{00A0}*\u{00A0}3').spans, isEmpty);
    });

    test('an ordinary pair is unaffected', () {
      expect(ProseMarkup.parse('**word**').spans, hasLength(1));
    });
  });

  group('a cut window drops the delimiter it orphaned', () {
    test('a truncated preview shows no raw marker', () {
      final body = '${'a' * 110} **bolded words here** and more.';
      final preview = firstSentencePreview(body);
      expect(preview, isNot(contains('**')));
      expect(preview, endsWith('...'));
    });

    test('a preview that fits keeps its markers', () {
      expect(firstSentencePreview('a **bold** word.'), 'a **bold** word.');
    });

    test('literal asterisks and underscores survive a cut', () {
      final body = '${'b' * 110} 2*3 and _config here and more words.';
      expect(firstSentencePreview(body), contains('2*3'));
    });
  });

  group('a field that changes shape rebuilds its prose controller', () {
    Widget host({required int? maxLines, required TextEditingController c}) =>
        ProviderScope(
          overrides: [
            voyagerSpellCheckServiceProvider.overrideWithValue(
              VoyagerSpellCheckService(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 200,
                child: VoyagerTextField(controller: c, maxLines: maxLines),
              ),
            ),
          ),
        );

    testWidgets('single-line to multiline turns emphasis on', (tester) async {
      final controller = TextEditingController(text: 'a **bold** word');
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(maxLines: 1, c: controller));
      expect(
        find.byType(EditableText).evaluate().single.widget,
        isA<EditableText>().having(
          (e) => e.controller,
          'controller',
          same(controller),
        ),
      );

      await tester.pumpWidget(host(maxLines: null, c: controller));
      expect(
        find.byType(EditableText).evaluate().single.widget,
        isA<EditableText>().having(
          (e) => e.controller,
          'controller',
          isNot(same(controller)),
        ),
      );
    });

    testWidgets('multiline back to single-line turns it off', (tester) async {
      final controller = TextEditingController(text: 'a **bold** word');
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(maxLines: null, c: controller));
      await tester.pumpWidget(host(maxLines: 1, c: controller));
      expect(
        find.byType(EditableText).evaluate().single.widget,
        isA<EditableText>().having(
          (e) => e.controller,
          'controller',
          same(controller),
        ),
      );
    });
  });
}
