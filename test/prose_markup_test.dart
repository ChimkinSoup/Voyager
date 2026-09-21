import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/text/prose_markup.dart';

/// `kind:start..end` for each span, in the parser's pre-order.
List<String> shape(String source) => [
  for (final span in ProseMarkup.parse(source).spans)
    '${span.kind.name}:${span.start}..${span.end}',
];

/// The substrings each span covers, delimiters included.
List<String> covered(String source) => [
  for (final span in ProseMarkup.parse(source).spans)
    source.substring(span.start, span.end),
];

/// The substrings each span styles, delimiters excluded.
List<String> contents(String source) => [
  for (final span in ProseMarkup.parse(source).spans)
    source.substring(span.contentStart, span.contentEnd),
];

void main() {
  group('basic pairs', () {
    test('each delimiter produces its own kind', () {
      expect(shape('**important**'), ['bold:0..13']);
      expect(shape('*emphasis*'), ['italic:0..10']);
      expect(shape('__key point__'), ['underline:0..13']);
      expect(shape('==remember=='), ['highlight:0..12']);
    });

    test('spans sit inside surrounding prose', () {
      expect(contents('a **b** c'), ['b']);
      expect(covered('a **b** c'), ['**b**']);
    });

    test('independent adjacent spans', () {
      expect(shape('__u__ next to **b**'), ['underline:0..5', 'bold:14..19']);
    });

    test('plain prose parses to nothing', () {
      expect(ProseMarkup.parse('just words').hasEmphasis, isFalse);
      expect(ProseMarkup.parse('').spans, isEmpty);
    });
  });

  group('nesting', () {
    test('bold wrapping italic', () {
      // `**bold *and italic* bold**`
      expect(shape('**bold *and italic* bold**'), [
        'bold:0..26',
        'italic:7..19',
      ]);
      expect(contents('**bold *and italic* bold**'), [
        'bold *and italic* bold',
        'and italic',
      ]);
    });

    test('triple asterisks are bold and italic together', () {
      final spans = ProseMarkup.parse('***bold italic***').spans;
      expect(spans.map((s) => s.kind), [
        EmphasisKind.italic,
        EmphasisKind.bold,
      ]);
      // Properly nested: the italic wraps the bold, and the innermost content
      // is the words themselves.
      expect(spans.first.start, 0);
      expect(spans.first.end, 17);
      expect(spans.last.start, 1);
      expect(spans.last.end, 16);
      expect(
        '***bold italic***'.substring(
          spans.last.contentStart,
          spans.last.contentEnd,
        ),
        'bold italic',
      );
    });

    test('highlight nested in bold', () {
      expect(shape('**bold ==highlighted==**'), [
        'bold:0..24',
        'highlight:7..22',
      ]);
    });

    test('spans are always a properly nested forest', () {
      // Interleaved delimiters would overlap if the parser kept both.
      for (final source in [
        '*a ==b* c==',
        '**a __b** c__',
        '*one **two*',
        '==x *y== z*',
      ]) {
        final spans = ProseMarkup.parse(source).spans;
        for (var i = 0; i < spans.length; i++) {
          for (var j = i + 1; j < spans.length; j++) {
            final outer = spans[i];
            final inner = spans[j];
            final disjoint = inner.start >= outer.end;
            final contained =
                inner.start >= outer.start && inner.end <= outer.end;
            expect(
              disjoint || contained,
              isTrue,
              reason: '$source: $inner partially overlaps $outer',
            );
          }
        }
      }
    });
  });

  group('unclosed and mismatched', () {
    test('unclosed delimiters stay literal', () {
      expect(ProseMarkup.parse('**hello').spans, isEmpty);
      expect(ProseMarkup.parse('__hello').spans, isEmpty);
      expect(ProseMarkup.parse('==hello').spans, isEmpty);
      expect(ProseMarkup.parse('hello**').spans, isEmpty);
    });

    test('greedy left-to-right leaves invalid tails literal', () {
      expect(contents('*one **two*'), ['two']);
    });

    test('a lone delimiter run is literal', () {
      expect(ProseMarkup.parse('****').spans, isEmpty);
      expect(ProseMarkup.parse('a * b').spans, isEmpty);
      expect(ProseMarkup.parse('_ x _').spans, isEmpty);
    });

    test('single _ and = have no one-character form', () {
      expect(ProseMarkup.parse('_x_').spans, isEmpty);
      expect(ProseMarkup.parse('=x=').spans, isEmpty);
    });
  });

  group('flanking', () {
    test('spaced asterisks are arithmetic, not emphasis', () {
      expect(ProseMarkup.parse('2 * 3').spans, isEmpty);
      expect(ProseMarkup.parse('2 * 3 * 4').spans, isEmpty);
    });

    test('tight asterisks do pair', () {
      expect(contents('2*3*4'), ['3']);
    });

    test('** pairs inside a word', () {
      expect(contents('foo**bar**baz'), ['bar']);
    });

    test('__ does not pair inside a word', () {
      expect(ProseMarkup.parse('a__b__c').spans, isEmpty);
      expect(ProseMarkup.parse('my_var__name').spans, isEmpty);
      expect(ProseMarkup.parse('snake_case__thing__here').spans, isEmpty);
    });

    test('__ pairs at word edges and against punctuation', () {
      expect(contents('__key point__'), ['key point']);
      expect(contents('(__x__)'), ['x']);
      expect(contents('say __this__, then'), ['this']);
    });

    test('__ pairs across a unicode word edge', () {
      expect(ProseMarkup.parse('café__x__').spans, isEmpty);
    });
  });

  group('list bullets', () {
    test('a line-start bullet marker never opens italic', () {
      expect(ProseMarkup.parse('* item one').spans, isEmpty);
      expect(ProseMarkup.parse('  * indented item').spans, isEmpty);
      expect(ProseMarkup.parse('a\n* item\nb').spans, isEmpty);
    });

    test('mid-line emphasis on a bullet line still works', () {
      expect(contents('* item with *emphasis*'), ['emphasis']);
    });

    test('a line-start asterisk with no space is not a bullet', () {
      expect(contents('*italic* opener'), ['italic']);
    });
  });

  group('exclusion zones', () {
    test('inline code is opaque', () {
      expect(ProseMarkup.parse('`code **not bold**`').spans, isEmpty);
      expect(contents('**b** `x **y**` **c**'), ['b', 'c']);
    });

    test('backticks only pair on their own line', () {
      // Unclosed on its line: emphasis stops for the rest of the document.
      expect(ProseMarkup.parse('a `b **c**\nd **e**').spans, isEmpty);
      expect(contents('**a**\nx `y` **b**'), ['a', 'b']);
    });

    test('latex is opaque', () {
      expect(ProseMarkup.parse(r'$x * y$').spans, isEmpty);
      expect(contents(r'**a** $x * y$ **b**'), ['a', 'b']);
    });

    test('latex outranks inline code', () {
      // The backtick is inside the math, so it never opens a code zone and
      // never suppresses the bold that follows.
      expect(contents(r'$a`b$ **c**'), ['c']);
    });

    test(r'an empty $$ is not math', () {
      expect(contents(r'$$ **a**'), ['a']);
    });

    test('tag bodies are opaque but wrappable', () {
      expect(ProseMarkup.parse('#foo__bar').spans, isEmpty);
      final wrapped = ProseMarkup.parse('**#project-alpha**');
      expect(wrapped.spans.single.kind, EmphasisKind.bold);
      expect(
        '**#project-alpha**'.substring(
          wrapped.spans.single.contentStart,
          wrapped.spans.single.contentEnd,
        ),
        '#project-alpha',
      );
    });

    test('a delimiter run stops at a zone boundary', () {
      // The `**` before the code zone is one run, not a run merged with
      // whatever sits inside the backticks.
      expect(contents('**a**`**`'), ['a']);
    });

    test('zones are recorded for the tokenizers', () {
      final markup = ProseMarkup.parse(r'a `code` b $x$ c #tag d');
      expect(markup.zones.map((z) => z.kind), [
        ProseZoneKind.inlineCode,
        ProseZoneKind.latex,
        ProseZoneKind.tag,
      ]);
      expect(markup.inZone(3), isTrue);
      expect(markup.inZone(9), isFalse);
      expect(markup.inZone(12, kind: ProseZoneKind.latex), isTrue);
      expect(markup.inZone(12, kind: ProseZoneKind.tag), isFalse);
    });
  });

  group('reveal mask', () {
    final markup = ProseMarkup.parse('a **bold *it* end** z');
    // offsets: `a ` 0..1, `**` 2..3, `bold ` 4..8, `*` 9, `it` 10..11,
    // `*` 12, ` end` 13..16, `**` 17..18, ` z` 19..20
    final bold = markup.spans.first;
    final italic = markup.spans.last;

    test('spans parsed as expected', () {
      expect(bold.kind, EmphasisKind.bold);
      expect(italic.kind, EmphasisKind.italic);
      expect(bold.start, 2);
      expect(bold.end, 19);
      expect(italic.start, 9);
      expect(italic.end, 13);
    });

    test('a caret outside every span reveals nothing', () {
      expect(
        markup.revealedBy(const TextSelection.collapsed(offset: 0)),
        isEmpty,
      );
      expect(
        markup.revealedBy(const TextSelection.collapsed(offset: 20)),
        isEmpty,
      );
    });

    test('a caret inside the inner span reveals it and its ancestors', () {
      expect(markup.revealedBy(const TextSelection.collapsed(offset: 11)), {
        bold,
        italic,
      });
    });

    test('a caret inside only the outer span reveals only it', () {
      expect(markup.revealedBy(const TextSelection.collapsed(offset: 5)), {
        bold,
      });
    });

    test('a caret on a span edge reveals it', () {
      expect(markup.revealedBy(const TextSelection.collapsed(offset: 2)), {
        bold,
      });
      expect(markup.revealedBy(const TextSelection.collapsed(offset: 19)), {
        bold,
      });
    });

    test('a selection reveals every span it touches', () {
      expect(
        markup.revealedBy(const TextSelection(baseOffset: 0, extentOffset: 21)),
        {bold, italic},
      );
      expect(
        markup.revealedBy(const TextSelection(baseOffset: 0, extentOffset: 5)),
        {bold},
      );
    });

    test('an invalid selection reveals nothing', () {
      expect(
        markup.revealedBy(const TextSelection.collapsed(offset: -1)),
        isEmpty,
      );
    });
  });

  group('proseStrip', () {
    test('takes out every paired delimiter, nested ones included', () {
      expect(proseStrip('**Dinner** with *friends*'), 'Dinner with friends');
      expect(proseStrip('**bold *both* bold**'), 'bold both bold');
      expect(proseStrip('__u__ and ==h=='), 'u and h');
    });

    test('leaves anything that never paired exactly as typed', () {
      expect(proseStrip('2*3 and a__b__c'), '2*3 and a__b__c');
      expect(proseStrip('**unclosed'), '**unclosed');
      expect(proseStrip(r'sum $x * y$ holds'), r'sum $x * y$ holds');
    });
  });
}
