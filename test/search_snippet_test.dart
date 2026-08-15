// The blurb under a search result. Its whole job is to explain why the result
// is in the list, which the opening words of a long body can't do when the
// match is a thousand characters down — so the window has to travel to the
// match, keep it far enough from the clipped end to survive `maxLines`, and
// mark that it started mid-text.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/search_highlight_text.dart';

/// Every character the widget would actually paint, math and pills included.
String _renderedText(WidgetTester tester, Finder finder) {
  final widget = tester.widget<Text>(finder);
  final span = widget.textSpan;
  return span == null ? widget.data ?? '' : span.toPlainText();
}

/// The substrings drawn with the search emphasis (bold + wash).
List<String> _highlighted(WidgetTester tester, Finder finder) {
  final span = tester.widget<Text>(finder).textSpan;
  final hits = <String>[];
  span?.visitChildren((child) {
    if (child is TextSpan &&
        child.text != null &&
        child.style?.fontWeight == FontWeight.w600) {
      hits.add(child.text!);
    }
    return true;
  });
  return hits;
}

Future<void> _pumpText(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(home: Scaffold(body: DefaultTextStyle(
    style: const TextStyle(fontSize: 14, color: Color(0xFF000000)),
    child: child,
  ))),
);

void main() {
  group('searchSnippet', () {
    test('travels to a match buried deep in the body', () {
      final body = '${'filler word ' * 200}AAA and the rest';

      final snippet = searchSnippet(body, keywords: ['AAA']);

      expect(snippet, startsWith('…'));
      expect(snippet, contains('AAA and the rest'));
      // The match must sit near the front of the window: callers clip this to
      // two lines, so a centred match would be clipped straight back out.
      expect(snippet.indexOf('AAA'), lessThan(40));
    });

    test('keeps the opening words when nothing matches', () {
      final body = 'Opening words that go on ${'and on ' * 50}';

      final snippet = searchSnippet(body, keywords: ['ZZZ']);

      expect(snippet, startsWith('Opening words that go on'));
    });

    test('keeps the opening words when the match is already near the start', () {
      final snippet = searchSnippet('A quick AAA appears early', keywords: ['AAA']);

      expect(snippet, 'A quick AAA appears early');
      expect(snippet, isNot(startsWith('…')));
    });

    test('collapses newlines so both visible lines carry text', () {
      final snippet = searchSnippet('Sept 3\n\n\nWent to the market');

      expect(snippet, 'Sept 3 Went to the market');
    });

    test('cuts the lead-in at a word boundary, never mid-word', () {
      final body = '${'alpha bravo ' * 40}charlie AAA delta';

      final snippet = searchSnippet(body, keywords: ['AAA']);

      // Whatever the window opens on is a whole word, so the blurb never
      // starts on a fragment like "…vo charlie".
      final firstWord = snippet.substring(1).split(' ').first;
      expect(['alpha', 'bravo', 'charlie'], contains(firstWord));
    });

    test('anchors on the earliest keyword of a multi-word query', () {
      final body = '${'x ' * 100}beta ${'y ' * 100}alpha';

      final snippet = searchSnippet(body, keywords: ['alpha', 'beta']);

      // 'beta' occurs first, so it is what the window opens onto — 'alpha'
      // only shows here because the tail happens to reach it.
      expect(snippet.indexOf('beta'), lessThan(40));
    });

    test('caps the tail without marking it, leaving the ellipsis to overflow', () {
      final snippet = searchSnippet('word ' * 500, maxLength: 100);

      expect(snippet.length, 100);
      expect(snippet, isNot(endsWith('…')));
    });

    test('ignores blank and whitespace-only keywords', () {
      final body = '${'filler ' * 100}AAA tail';

      expect(searchSnippet(body, keywords: ['', '   ']), startsWith('filler'));
    });

    test('matches case-insensitively', () {
      final body = '${'filler ' * 100}Needle tail';

      expect(searchSnippet(body, keywords: ['NEEDLE']), contains('Needle tail'));
    });
  });

  group('snippet survives the caller clip', () {
    // The point of the whole feature is that the reader *sees* the match, so
    // it has to land inside the two lines the search page actually paints.
    // A narrow pane is the hostile case: fewest characters per line.
    testWidgets('the match lands inside the visible two lines', (tester) async {
      const style = TextStyle(fontSize: 14);
      final body = '${'filler word here ' * 300}AAA and the rest of it';
      final snippet = searchSnippet(body, keywords: ['AAA']);

      final painter = TextPainter(
        text: TextSpan(text: snippet, style: style),
        maxLines: 2,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 280);

      final lastVisible = painter
          .getPositionForOffset(Offset(painter.width, painter.height - 1))
          .offset;
      expect(snippet.indexOf('AAA') + 3, lessThanOrEqualTo(lastVisible));
    });

    testWidgets('without the snippet the same match is clipped away', (
      tester,
    ) async {
      const style = TextStyle(fontSize: 14);
      final body = '${'filler word here ' * 300}AAA and the rest of it';

      final painter = TextPainter(
        text: TextSpan(text: body, style: style),
        maxLines: 2,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 280);

      final lastVisible = painter
          .getPositionForOffset(Offset(painter.width, painter.height - 1))
          .offset;
      expect(body.indexOf('AAA'), greaterThan(lastVisible));
    });
  });

  group('keywordHighlightedText', () {
    testWidgets('emphasises each occurrence, preserving the original casing', (
      tester,
    ) async {
      await _pumpText(
        tester,
        keywordHighlightedText(
          'Aaa then aaa then AAA',
          style: const TextStyle(fontSize: 14, color: Color(0xFF000000)),
          keywords: ['aaa'],
        ),
      );

      final text = find.byType(Text);
      expect(_highlighted(tester, text), ['Aaa', 'aaa', 'AAA']);
      expect(_renderedText(tester, text), 'Aaa then aaa then AAA');
    });

    testWidgets('leaves text untouched when no keyword is given', (
      tester,
    ) async {
      await _pumpText(
        tester,
        keywordHighlightedText(
          'nothing to mark',
          style: const TextStyle(fontSize: 14),
        ),
      );

      expect(_highlighted(tester, find.byType(Text)), isEmpty);
    });

    testWidgets('inherits the ambient style when given none', (tester) async {
      await _pumpText(
        tester,
        keywordHighlightedText(
          'find the needle here',
          highlightColor: const Color(0x33000000),
          keywords: ['needle'],
        ),
      );

      final hit = tester
          .widget<Text>(find.byType(Text))
          .textSpan!
          .toPlainText();
      expect(hit, 'find the needle here');
      expect(_highlighted(tester, find.byType(Text)), ['needle']);
      // No explicit style means the tile's own text style still applies.
      expect(tester.widget<Text>(find.byType(Text)).style, isNull);
    });
  });

  group('searchHighlightedText', () {
    testWidgets('highlights keywords around tag pills', (tester) async {
      await _pumpText(
        tester,
        searchHighlightedText(
          'walked #outside with AAA today',
          style: const TextStyle(fontSize: 14, color: Color(0xFF000000)),
          keywords: ['AAA'],
        ),
      );

      expect(_highlighted(tester, find.byType(Text).first), ['AAA']);
      expect(find.text('#outside'), findsOneWidget);
    });
  });
}
