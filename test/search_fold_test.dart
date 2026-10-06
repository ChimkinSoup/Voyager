// Search matches what the reader sees, not what is stored: formatting markers
// a result hides don't count (BUG-089), and accents fold away (BUG-090).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/text/search_fold.dart';
import 'package:voyager/core/widgets/search_highlight_text.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/services/search_service.dart';
import 'package:voyager/features/search/dream_search.dart';

JournalEntry _entry(String id, String body, {String title = ''}) {
  final now = DateTime(2026, 1, 1);
  return JournalEntry(
    id: id,
    journalId: 'j',
    title: title,
    body: body,
    entryDate: now,
    timestamp: now,
    createdAt: now,
    updatedAt: now,
  );
}

/// The substrings painted with the search wash. Checked by background rather
/// than weight: a match inside `**bold**` takes the emphasis' heavier weight.
List<String> _washed(WidgetTester tester) {
  final hits = <String>[];
  tester.widget<Text>(find.byType(Text).first).textSpan?.visitChildren((child) {
    if (child is TextSpan &&
        child.text != null &&
        child.style?.backgroundColor != null &&
        (child.style?.fontSize ?? 1) > 0) {
      hits.add(child.text!);
    }
    return true;
  });
  return hits;
}

void main() {
  group('searchFold', () {
    test('lowercases and drops accents', () {
      expect(searchFold('Café NAÏVE crème brûlée'), 'cafe naive creme brulee');
    });

    test('drops combining marks from decomposed text', () {
      expect(searchFold('café'), 'cafe');
    });

    test('expands ligatures and sharp s', () {
      expect(searchFold('Straße Æsir'), 'strasse aesir');
    });

    test('folds Greek final sigma to sigma', () {
      expect(searchFold('ΟΔΟΣ'), searchFold('οδος'));
    });

    test('leaves scripts it has no folding for alone', () {
      expect(searchFold('東京 مرحبا 😀'), '東京 مرحبا 😀');
    });

    test('maps every folded unit back to its source', () {
      final folded = searchFoldMapped('aß', skip: {0}, skipBase: 0);
      expect(folded.text, 'ss');
      expect(folded.starts, [1, 1]);
      expect(folded.ends, [2, 2]);
    });
  });

  group('SearchService', () {
    final service = SearchService();
    final emphasis = _entry(
      'emphasis',
      'This has **boldword** and foo**bar** and ==marked== text',
    );
    final accents = _entry('accents', 'Coffee at the café was naïve fun');
    final literal = _entry('literal', 'Math 2*3 stays as typed');

    List<String> search(String query) => service
        .searchEntries(entries: [emphasis, accents, literal], query: query)
        .map((e) => e.id)
        .toList();

    test('a word split by markers matches as displayed (BUG-089)', () {
      expect(search('foobar'), ['emphasis']);
      expect(search('marked text'), ['emphasis']);
    });

    test('paired markers match nothing; literal ones still do', () {
      expect(search('**'), isEmpty);
      expect(search('=='), isEmpty);
      expect(search('2*3'), ['literal']);
    });

    test('an unaccented query finds accented text and back (BUG-090)', () {
      expect(search('cafe'), ['accents']);
      expect(search('naive'), ['accents']);
      expect(search('CAFÉ'), ['accents']);
    });

    test('a tag filter folds accents too', () {
      final tagged = _entry('tagged', '').copyWith(tags: ['Café']);
      final results = service.searchEntries(
        entries: [tagged],
        query: '',
        tagFilter: ['cafe'],
      );
      expect(results.map((e) => e.id), ['tagged']);
    });
  });

  test('dreams match as displayed and fold accents', () {
    final now = DateTime(2026, 1, 1);
    final dream = DreamEntry(
      id: 'd',
      createdAt: now,
      updatedAt: now,
      title: 'Café dream',
      body: 'a moon**lit** walk',
      entryDate: now,
    );
    List<DreamEntry> run(String q) =>
        filterDreamEntries(entries: [dream], query: q);
    expect(run('moonlit'), hasLength(1));
    expect(run('cafe'), hasLength(1));
    expect(run('**'), isEmpty);
  });

  group('result rows', () {
    Future<void> pump(
      WidgetTester tester,
      String text,
      String keyword, {
      bool fold = true,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: searchHighlightedText(
            text,
            style: const TextStyle(fontSize: 14, color: Color(0xFF000000)),
            keywords: [keyword],
            emphasisTheme: ProseEmphasisTheme.of(
              const ColorScheme.dark(),
              Colors.blue,
            ),
            brightness: Brightness.dark,
            fold: fold,
          ),
        ),
      ),
    );

    testWidgets('highlight a match across hidden markers', (tester) async {
      await pump(tester, 'and foo**bar** and', 'foobar');
      expect(_washed(tester).join(), 'foobar');
    });

    testWidgets('highlight an accented match, keeping its accents', (
      tester,
    ) async {
      await pump(tester, 'at the café today', 'cafe');
      expect(_washed(tester), ['café']);
    });

    testWidgets('fold only on request: other surfaces match as before', (
      tester,
    ) async {
      // To-Do, LeetCode and Study filter without folding accents, so their
      // highlight mustn't fold either (it would mark what never matched).
      await pump(tester, 'at the café today', 'cafe', fold: false);
      expect(_washed(tester), isEmpty);
      await pump(tester, 'and foo**bar** and', 'foobar', fold: false);
      expect(_washed(tester), isEmpty);
    });

    test('the snippet travels to a folded match', () {
      final body = '${List.filled(80, 'filler').join(' ')} a crème brûlée';
      final snippet = searchSnippet(body, keywords: ['creme'], fold: true);
      expect(snippet, startsWith('…'));
      expect(snippet, contains('crème'));
      expect(searchSnippet(body, keywords: ['creme']), startsWith('filler'));
    });

    test('the snippet travels to a match across markers', () {
      final body = '${List.filled(80, 'filler').join(' ')} then foo**bar**';
      // Stored text: the row hides the markers when it renders the snippet.
      final snippet = searchSnippet(body, keywords: ['foobar'], fold: true);
      expect(snippet, startsWith('…'));
      expect(snippet, endsWith('then foo**bar**'));
    });
  });
}
