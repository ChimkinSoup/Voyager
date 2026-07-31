import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/spellcheck/spell_check_suggestions.dart';

void main() {
  final dictionary = {'world', 'word', 'old', 'hello', 'voyager'};

  test('suggests the correct word for a single-edit misspelling', () {
    expect(generateSuggestions('wrold', dictionary), contains('world'));
  });

  test('falls back to edit-distance-2 only when distance-1 is empty', () {
    // 'vyagr' is distance-2 from 'voyager' (missing both 'o' and 'e') — no
    // distance-1 dictionary word should match it, so this only succeeds if
    // the distance-2 fallback runs.
    final suggestions = generateSuggestions('vyagr', dictionary);
    expect(suggestions, contains('voyager'));
  });

  test('caps results at maxResults', () {
    final bigDictionary = {
      for (var i = 0; i < 20; i++) 'wor${String.fromCharCode(97 + i)}d',
    };
    final suggestions = generateSuggestions(
      'wormd',
      bigDictionary,
      maxResults: 3,
    );
    expect(suggestions.length, lessThanOrEqualTo(3));
  });

  test('returns empty list when nothing is close', () {
    expect(generateSuggestions('zzzzzzzzzz', dictionary), isEmpty);
  });
}
