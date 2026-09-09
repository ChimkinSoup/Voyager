import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/text/prose_highlight_paint.dart';
import 'package:voyager/core/text/prose_markup.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/text/styled_runs.dart';

const _base = TextStyle(fontSize: 16, letterSpacing: 0.3, color: Colors.black);

const _theme = ProseEmphasisTheme(
  delimiterColor: Color(0x66111111),
  highlightColor: Color(0x40FF0000),
  underlineColor: Color(0xFF000000),
);

TextSpan build(
  String source, {
  TextSelection? selection,
  ProseEmphasisTheme theme = _theme,
  List<StyledRange> extra = const [],
}) {
  final markup = ProseMarkup.parse(source);
  return buildProseSpan(
    markup: markup,
    base: _base,
    revealed: selection == null ? const {} : markup.revealedBy(selection),
    theme: theme,
    extra: extra,
  );
}

/// The style in effect at each character of [span]'s plain text.
List<TextStyle> stylePerCharacter(TextSpan span) {
  final styles = <TextStyle>[];
  void walk(InlineSpan node, TextStyle inherited) {
    if (node is! TextSpan) return;
    final style = node.style == null ? inherited : inherited.merge(node.style);
    final text = node.text;
    if (text != null) {
      for (var i = 0; i < text.length; i++) {
        styles.add(style);
      }
    }
    for (final child in node.children ?? const <InlineSpan>[]) {
      walk(child, style);
    }
  }

  walk(span, const TextStyle());
  return styles;
}

void main() {
  group('the stored string always round-trips', () {
    test('one character in, one character out', () {
      for (final source in [
        'plain prose',
        '**bold**',
        'a **bold *it* end** z',
        '***triple***',
        '__u__ and ==h==',
        '* bullet with *emphasis*',
        r'`code **x**` $y * z$ #tag **b**',
        '**unclosed and 2 * 3',
        '',
      ]) {
        for (final selection in [
          null,
          const TextSelection.collapsed(offset: 0),
          TextSelection(baseOffset: 0, extentOffset: source.length),
        ]) {
          final span = build(source, selection: selection);
          expect(
            span.toPlainText(),
            source,
            reason: 'round-trip failed for "$source" at $selection',
          );
        }
      }
    });

    test('every character carries exactly one style', () {
      const source = 'a **bold *it* end** z';
      expect(stylePerCharacter(build(source)).length, source.length);
    });
  });

  group('hidden delimiters', () {
    test('collapse to zero size and drop the field tracking', () {
      final styles = stylePerCharacter(build('a **b** c'));
      // offsets: `a ` 0..1, `**` 2..3, `b` 4, `**` 5..6, ` c` 7..8
      for (final offset in [2, 3, 5, 6]) {
        expect(styles[offset].fontSize, 0, reason: 'offset $offset');
        expect(styles[offset].letterSpacing, 0, reason: 'offset $offset');
        expect(styles[offset].color!.a, 0, reason: 'offset $offset');
      }
      expect(styles[4].fontSize, 16);
      expect(styles[4].fontWeight, FontWeight.bold);
    });

    test('content keeps its own weight while the markers vanish', () {
      final styles = stylePerCharacter(build('*x*'));
      expect(styles[1].fontStyle, FontStyle.italic);
      expect(styles[0].fontSize, 0);
    });
  });

  group('revealed delimiters', () {
    test('a caret inside shows the markers at full size, muted', () {
      final styles = stylePerCharacter(
        build('a **b** c', selection: const TextSelection.collapsed(offset: 4)),
      );
      for (final offset in [2, 3, 5, 6]) {
        expect(styles[offset].fontSize, 16, reason: 'offset $offset');
        expect(styles[offset].color, _theme.delimiterColor);
      }
      expect(styles[4].fontWeight, FontWeight.bold);
    });

    test('markers are not themselves styled by their own span', () {
      final styles = stylePerCharacter(
        build('**b**', selection: const TextSelection.collapsed(offset: 2)),
      );
      expect(styles[0].fontWeight, isNot(FontWeight.bold));
      expect(styles[2].fontWeight, FontWeight.bold);
    });

    test('a caret in a nested span reveals both pairs', () {
      const source = 'a **bold *it* end** z';
      final styles = stylePerCharacter(
        build(source, selection: const TextSelection.collapsed(offset: 11)),
      );
      // outer `**` at 2..3 and 17..18, inner `*` at 9 and 12
      for (final offset in [2, 3, 9, 12, 17, 18]) {
        expect(styles[offset].fontSize, 16, reason: 'offset $offset');
      }
    });

    test('a caret in the outer span leaves the inner markers hidden', () {
      const source = 'a **bold *it* end** z';
      final styles = stylePerCharacter(
        build(source, selection: const TextSelection.collapsed(offset: 5)),
      );
      expect(styles[2].fontSize, 16);
      expect(styles[9].fontSize, 0);
      expect(styles[12].fontSize, 0);
    });

    test('an unfocused field reveals nothing even mid-span', () {
      final styles = stylePerCharacter(build('a **b** c'));
      expect(styles[2].fontSize, 0);
    });
  });

  group('nested styles compose', () {
    test('bold, italic and highlight stack on the innermost text', () {
      const source = '**b *i ==h==* e**';
      final styles = stylePerCharacter(build(source));
      final h = source.indexOf('h');
      expect(styles[h].fontWeight, FontWeight.bold);
      expect(styles[h].fontStyle, FontStyle.italic);
      expect(styles[h].backgroundColor, kProseHighlightMark);
    });

    test('underline draws a solid line in the theme colour', () {
      final styles = stylePerCharacter(build('__u__'));
      expect(styles[2].decoration, TextDecoration.underline);
      expect(styles[2].decorationColor, _theme.underlineColor);
      expect(styles[2].decorationStyle, TextDecorationStyle.solid);
    });
  });

  group('metrics-only theme', () {
    test('keeps weight and slant but paints nothing', () {
      const source = '**b** __u__ ==h==';
      final styles = stylePerCharacter(
        build(source, theme: const ProseEmphasisTheme.metrics()),
      );
      expect(styles[source.indexOf('b')].fontWeight, FontWeight.bold);
      expect(styles[source.indexOf('u')].decoration, isNot(TextDecoration.underline));
      // The one mark a metrics-only theme still emits: it is transparent, so
      // it is no ink either, and it is how the layer beneath a field finds its
      // ranges in the paragraph it already builds.
      expect(styles[source.indexOf('h')].backgroundColor, kProseHighlightMark);
    });

    test('revealed markers still take up their width, invisibly', () {
      final styles = stylePerCharacter(
        build(
          '**b**',
          selection: const TextSelection.collapsed(offset: 2),
          theme: const ProseEmphasisTheme.metrics(),
        ),
      );
      expect(styles[0].fontSize, 16);
      expect(styles[0].color!.a, 0);
    });

    test('a metrics paragraph wraps identically to the painted one', () {
      const source = 'the **most important** thing we ==ever== did';
      TextPainter layout(ProseEmphasisTheme theme) => TextPainter(
        text: build(source, theme: theme),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 180);

      final painted = layout(_theme);
      final metrics = layout(const ProseEmphasisTheme.metrics());
      expect(metrics.width, painted.width);
      expect(metrics.height, painted.height);
      expect(
        metrics.computeLineMetrics().map((m) => m.width),
        painted.computeLineMetrics().map((m) => m.width),
      );
    });
  });

  group('extra ranges', () {
    const squiggle = TextStyle(decoration: TextDecoration.underline);

    test('compose on top of emphasis without disturbing the text', () {
      const source = 'a **bold** c';
      final span = build(
        source,
        extra: const [(start: 4, end: 8, style: squiggle)],
      );
      expect(span.toPlainText(), source);
      final styles = stylePerCharacter(span);
      expect(styles[4].decoration, TextDecoration.underline);
      expect(styles[4].fontWeight, FontWeight.bold);
      expect(styles[3].decoration, isNot(TextDecoration.underline));
    });

    test('a range crossing a delimiter is split, not dropped', () {
      const source = 'a **bold** c';
      final span = build(
        source,
        extra: const [(start: 0, end: 12, style: squiggle)],
      );
      expect(span.toPlainText(), source);
      final styles = stylePerCharacter(span);
      for (var i = 0; i < source.length; i++) {
        expect(styles[i].decoration, TextDecoration.underline, reason: 'at $i');
      }
    });

    test('several ranges are consumed in order', () {
      const source = 'aa **bb** cc';
      final span = build(
        source,
        extra: const [
          (start: 0, end: 2, style: squiggle),
          (start: 5, end: 7, style: squiggle),
          (start: 10, end: 12, style: squiggle),
        ],
      );
      expect(span.toPlainText(), source);
      final styles = stylePerCharacter(span);
      expect(styles[1].decoration, TextDecoration.underline);
      expect(styles[3].decoration, isNot(TextDecoration.underline));
      expect(styles[6].decoration, TextDecoration.underline);
      expect(styles[11].decoration, TextDecoration.underline);
    });
  });

  group('flatProseSpan', () {
    test('leaves markers literal and applies only the extra ranges', () {
      const source = 'a **bold** c';
      final span = flatProseSpan(
        source,
        _base,
        extra: const [(start: 4, end: 8, style: TextStyle(fontSize: 9))],
      );
      expect(span.toPlainText(), source);
      final styles = stylePerCharacter(span);
      expect(styles[2].fontSize, 16);
      expect(styles[4].fontSize, 9);
      expect(styles[4].fontWeight, isNull);
    });
  });
}
