// The Search page's dream scope: the command boundary that enters it and the
// filter it runs, pinned here rather than through the page — the same parts a
// refactor is most likely to quietly loosen as in todo_list_search_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/features/search/dream_search.dart';

DreamEntry _dream({
  String id = 'a',
  String title = '',
  String body = '',
  String? notes,
  List<String> tags = const [],
}) {
  final now = DateTime.utc(2026, 9, 19);
  return DreamEntry(
    id: id,
    createdAt: now,
    updatedAt: now,
    title: title,
    body: body,
    notes: notes,
    entryDate: now,
    tags: tags,
  );
}

void main() {
  group('dreamSearchCommandQuery', () {
    test('a bare /dream enters the scope with no query', () {
      expect(dreamSearchCommandQuery('/dream'), '');
      expect(dreamSearchCommandQuery('/dream '), '');
    });

    test('everything after the command becomes the query', () {
      expect(dreamSearchCommandQuery('/dream falling'), 'falling');
      expect(dreamSearchCommandQuery('/dream   falling'), 'falling');
    });

    test('only triggers on a word boundary', () {
      expect(dreamSearchCommandQuery('/dreamscape'), isNull);
      expect(dreamSearchCommandQuery('/dream-scape'), isNull);
    });

    test('is case-sensitive and anchored at the start', () {
      expect(dreamSearchCommandQuery('/Dream falling'), isNull);
      expect(dreamSearchCommandQuery('a /dream falling'), isNull);
      expect(dreamSearchCommandQuery(''), isNull);
    });
  });

  group('filterDreamEntries', () {
    test('an empty query keeps everything', () {
      final entries = [_dream(id: 'a'), _dream(id: 'b')];
      expect(filterDreamEntries(entries: entries, query: '   '), entries);
    });

    test('matches the title, the body and the notepad', () {
      final entries = [
        _dream(id: 'title', title: 'Flying over water'),
        _dream(id: 'body', body: 'I was flying again'),
        _dream(id: 'notes', notes: 'flying, third time this week'),
        _dream(id: 'miss', title: 'Locked door'),
      ];
      final results = filterDreamEntries(entries: entries, query: 'flying');
      expect(results.map((e) => e.id), ['title', 'body', 'notes']);
    });

    test('every token has to match somewhere', () {
      final entries = [
        _dream(id: 'both', title: 'Flying', notes: 'over water'),
        _dream(id: 'one', title: 'Flying'),
      ];
      final results = filterDreamEntries(
        entries: entries,
        query: 'flying water',
      );
      expect(results.map((e) => e.id), ['both']);
    });

    test('matching is case-insensitive on both sides', () {
      final entries = [_dream(id: 'a', title: 'FLYING')];
      expect(
        filterDreamEntries(entries: entries, query: 'fly').map((e) => e.id),
        ['a'],
      );
    });

    test('every tag in the filter has to match, whatever its casing', () {
      final entries = [
        _dream(id: 'both', tags: ['Lucid', 'water']),
        _dream(id: 'one', tags: ['lucid']),
      ];
      final results = filterDreamEntries(
        entries: entries,
        query: '',
        tagFilter: ['lucid', 'Water'],
      );
      expect(results.map((e) => e.id), ['both']);
    });
  });
}
