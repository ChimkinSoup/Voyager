import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';

void main() {
  group('activeTagToken', () {
    test('finds the token the caret sits at the end of', () {
      final token = activeTagToken('hello #wor', 10);
      expect(token, isNotNull);
      expect(token!.start, 6);
      expect(token.end, 10);
      expect(token.query, 'wor');
    });

    test('spans the whole tag when the caret is mid-token', () {
      // "hello #wor|ld" — completing replaces all of "#world", but only the
      // text before the caret filters the list.
      final token = activeTagToken('hello #world', 10);
      expect(token!.start, 6);
      expect(token.end, 12);
      expect(token.query, 'wor');
    });

    test('matches an empty query right after the hash', () {
      final token = activeTagToken('hello #', 7);
      expect(token!.start, 6);
      expect(token.end, 7);
      expect(token.query, '');
    });

    test('finds a tag at the very start of the text', () {
      final token = activeTagToken('#aa', 3);
      expect(token!.start, 0);
      expect(token.query, 'aa');
    });

    test('finds a tag at the start of a later line', () {
      final token = activeTagToken('one\n#two', 8);
      expect(token!.start, 4);
      expect(token.query, 'two');
    });

    test('returns null with no hash before the word', () {
      expect(activeTagToken('hello world', 11), isNull);
    });

    test('returns null when the caret is before the hash', () {
      expect(activeTagToken('hello #tag', 6), isNull);
    });

    test('returns null for a hash preceded by a word character', () {
      // "C#" is a language, not a tag.
      expect(activeTagToken('C#', 2), isNull);
      expect(activeTagToken('a#b', 3), isNull);
    });

    test('returns null once the caret leaves the token', () {
      expect(activeTagToken('#tag done', 9), isNull);
    });

    test('returns null for an out-of-range cursor', () {
      expect(activeTagToken('#tag', 99), isNull);
      expect(activeTagToken('#tag', -1), isNull);
    });
  });

  group('rankTagsByUsage', () {
    test('orders by use count, most-used first', () {
      final ranked = rankTagsByUsage([
        ['rare', 'common'],
        ['common'],
        ['common', 'mid'],
        ['mid'],
      ]);
      expect(ranked, ['common', 'mid', 'rare']);
    });

    test('breaks ties alphabetically, case-insensitively', () {
      final ranked = rankTagsByUsage([
        ['zebra'],
        ['Apple'],
        ['mango'],
      ]);
      expect(ranked, ['Apple', 'mango', 'zebra']);
    });

    test('keeps casing variants distinct', () {
      final ranked = rankTagsByUsage([
        ['Work'],
        ['work'],
        ['work'],
      ]);
      expect(ranked, ['work', 'Work']);
    });

    test('ignores empty tags and returns empty for no input', () {
      expect(rankTagsByUsage([]), isEmpty);
      expect(rankTagsByUsage([<String>[], ['']]), isEmpty);
    });
  });

  group('filterTagSuggestions', () {
    final pool = ['AA', 'BB', 'CC'];

    test('returns the whole pool, in order, for an empty query', () {
      expect(filterTagSuggestions(pool, ''), ['AA', 'BB', 'CC']);
    });

    test('narrows to prefix matches', () {
      expect(filterTagSuggestions(pool, 'C'), ['CC']);
    });

    test('matches case-insensitively', () {
      expect(filterTagSuggestions(pool, 'c'), ['CC']);
      expect(filterTagSuggestions(['dinner'], 'DIN'), ['dinner']);
    });

    test('matches on prefix only, not substring', () {
      expect(filterTagSuggestions(['groceries'], 'cer'), isEmpty);
    });

    test('offers nothing when the sole match is already typed in full', () {
      expect(filterTagSuggestions(pool, 'CC'), isEmpty);
      expect(filterTagSuggestions(pool, 'cc'), isEmpty);
    });

    test('still offers longer tags sharing a complete prefix', () {
      expect(filterTagSuggestions(['cc', 'ccc'], 'cc'), ['cc', 'ccc']);
    });

    test('returns nothing for an unmatched query', () {
      expect(filterTagSuggestions(pool, 'zz'), isEmpty);
    });

    test('caps the list at the limit, keeping the most-used', () {
      final many = List.generate(20, (i) => 'tag$i');
      expect(filterTagSuggestions(many, '', limit: 3), [
        'tag0',
        'tag1',
        'tag2',
      ]);
    });
  });
}
