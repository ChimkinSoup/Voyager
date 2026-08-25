// What a Search query actually selects.
//
// The service-level cases pin the filter itself; the page-level one pins the
// parse, since only the page decides which parts of a raw query are tags.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/services/search_service.dart';

import 'support/search_page_harness.dart';

JournalEntry _entry({
  required String id,
  required String title,
  String body = '',
  List<String> tags = const [],
}) {
  final now = DateTime(2026, 1, 1);
  return JournalEntry(
    id: id,
    journalId: searchHarnessJournalId,
    title: title,
    body: body,
    tags: tags,
    entryDate: now,
    timestamp: now,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  final service = SearchService();

  test('every tag in the filter has to match', () {
    final entries = [
      _entry(id: 'both', title: 'Both', tags: ['work', 'urgent']),
      _entry(id: 'one', title: 'One', tags: ['work']),
    ];
    final results = service.searchEntries(
      entries: entries,
      query: '',
      tagFilter: ['work', 'urgent'],
    );
    expect(results.map((e) => e.id), ['both']);
  });

  test('tag matching folds case, like keyword matching', () {
    // `extractTags` keeps the author's casing, and the query field's own
    // autocomplete suggests it back verbatim — so an exact `==` rejected the
    // very tag it had just offered.
    final entries = [
      _entry(id: 'shouty', title: 'Shouty', tags: ['Work']),
    ];
    final results = service.searchEntries(
      entries: entries,
      query: '',
      tagFilter: ['work'],
    );
    expect(results.map((e) => e.id), ['shouty']);
  });

  test('a supplied folded haystack is what keywords are matched against', () {
    // The page keeps this cache so the corpus isn't re-lowercased per
    // keystroke. If the service ever stopped consulting it, the only visible
    // symptom would be the cost — so assert it is read, using a fold that
    // disagrees with the entry on purpose.
    final entries = [_entry(id: 'a', title: 'Real title', body: 'real body')];
    expect(
      service.searchEntries(
        entries: entries,
        query: 'sentinel',
        foldedText: {'a': 'sentinel'},
      ),
      hasLength(1),
    );
    expect(
      service.searchEntries(
        entries: entries,
        query: 'real',
        foldedText: {'a': 'sentinel'},
      ),
      isEmpty,
    );
  });

  testWidgets('a second #tag filters instead of being matched as text', (
    tester,
  ) async {
    await pumpSearchPage(
      tester,
      entries: (now) => [
        _entry(id: 'both', title: 'Tagged both ways', tags: ['work', 'urgent']),
        // Tagged `work` only, but carrying the literal `#urgent` in its body —
        // which is exactly what the old single-tag parse matched on.
        _entry(
          id: 'literal',
          title: 'Mentions the other tag',
          body: 'see #urgent later',
          tags: ['work'],
        ),
      ],
    );

    await tester.enterText(
      find.descendant(
        of: find.byType(TagHighlightedTextField),
        matching: find.byType(EditableText),
      ),
      '#work #urgent',
    );
    await settle(tester);

    expect(find.text('Tagged both ways'), findsOneWidget);
    expect(find.text('Mentions the other tag'), findsNothing);

    await disposeSearchPage(tester);
  });
}
