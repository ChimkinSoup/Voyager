import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/spellcheck/dictionary_search.dart';

/// A stand-in for `assets/dictionary_en.txt`: a set literal is a
/// [LinkedHashSet], so this keeps its written order the way the real asset
/// keeps its descending-frequency order.
const _bundled = {'the', 'so', 'say', 'sad', 'sap', 'unsafe', 'sa'};

void main() {
  group('empty query', () {
    test('lists the custom words A–Z and no bundled ones', () {
      final result = searchDictionary(
        query: '',
        bundled: _bundled,
        custom: const {'zsh', 'atlas'},
      );
      expect(result.custom, ['atlas', 'zsh']);
      expect(result.bundled, isEmpty);
      expect(result.truncated, isFalse);
    });

    test('whitespace is not a query', () {
      final result = searchDictionary(
        query: '   ',
        bundled: _bundled,
        custom: const {'atlas'},
      );
      expect(result.bundled, isEmpty);
    });
  });

  group('ranking', () {
    test('exact, then prefix, then contains', () {
      final result = searchDictionary(
        query: 'sa',
        bundled: _bundled,
        custom: const {},
      );
      expect(result.bundled, ['sa', 'say', 'sad', 'sap', 'unsafe']);
    });

    test('prefix matches keep the asset order, not alphabetical order', () {
      // 'say' before 'sad' before 'sap' is the order they were written in;
      // alphabetically it would be sad, sap, say.
      final result = searchDictionary(
        query: 'sa',
        bundled: _bundled,
        custom: const {},
      );
      expect(result.bundled.sublist(1, 4), ['say', 'sad', 'sap']);
    });

    test('the exact match survives a cap full of commoner prefix words', () {
      // 'sa' is the last entry in the set, so a scan that stops at the cap
      // never reaches it — the set lookup is what finds it.
      final result = searchDictionary(
        query: 'sa',
        bundled: _bundled,
        custom: const {},
        limit: 2,
      );
      expect(result.bundled, ['sa', 'say']);
      expect(result.truncated, isTrue);
    });

    test('the query is normalized', () {
      final result = searchDictionary(
        query: '  SA ',
        bundled: _bundled,
        custom: const {},
      );
      expect(result.bundled.first, 'sa');
    });

    test('no matches at all', () {
      final result = searchDictionary(
        query: 'qqq',
        bundled: _bundled,
        custom: const {'atlas'},
      );
      expect(result.bundled, isEmpty);
      expect(result.custom, isEmpty);
      expect(result.truncated, isFalse);
    });
  });

  group('custom words', () {
    test('are ranked the same way but sorted A–Z within each rank', () {
      final result = searchDictionary(
        query: 'sa',
        bundled: const {},
        custom: const {'unsafe', 'sausage', 'sa', 'sane'},
      );
      expect(result.custom, ['sa', 'sane', 'sausage', 'unsafe']);
    });

    test('are not capped, and never repeat in the bundled half', () {
      // A word cannot normally be in both sets — adding a bundled word is
      // refused — but a leftover row must not read as two separate entries.
      final result = searchDictionary(
        query: 'sa',
        bundled: _bundled,
        custom: const {'sad', 'sa'},
        limit: 2,
      );
      expect(result.custom, ['sa', 'sad']);
      expect(result.bundled, isNot(contains('sad')));
      expect(result.bundled, isNot(contains('sa')));
    });
  });

  group('candidate narrowing', () {
    test('a complete scan can be narrowed by a longer query', () {
      final wide = searchDictionary(
        query: 'sa',
        bundled: _bundled,
        custom: const {},
      );
      expect(wide.candidatesComplete, isTrue);

      final narrowed = searchDictionary(
        query: 'sap',
        bundled: _bundled,
        custom: const {},
        candidates: wide.candidates,
      );
      final fromScratch = searchDictionary(
        query: 'sap',
        bundled: _bundled,
        custom: const {},
      );
      expect(narrowed.bundled, fromScratch.bundled);
      expect(narrowed.truncated, fromScratch.truncated);
    });

    test('a scan that stopped at the cap is not offered for narrowing', () {
      final capped = searchDictionary(
        query: 'sa',
        bundled: _bundled,
        custom: const {},
        limit: 2,
      );
      expect(capped.candidatesComplete, isFalse);
    });
  });
}
