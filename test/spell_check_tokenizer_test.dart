import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/spellcheck/spell_check_tokenizer.dart';

void main() {
  test('extracts plain words with correct ranges', () {
    final ranges = tokenizeWords('hello wrold');
    final words = [
      for (final r in ranges) 'hello wrold'.substring(r.start, r.end),
    ];
    expect(words, ['hello', 'wrold']);
  });

  test('handles contractions as a single token', () {
    final ranges = tokenizeWords("don't stop");
    final text = "don't stop";
    final words = [for (final r in ranges) text.substring(r.start, r.end)];
    expect(words, ["don't", 'stop']);
  });

  test('excludes tokens inside a #tag span', () {
    final text = 'remember #madeupword for later';
    final ranges = tokenizeWords(text);
    final words = [for (final r in ranges) text.substring(r.start, r.end)];
    expect(words, ['remember', 'for', 'later']);
  });

  test('ignores digits and punctuation-only spans', () {
    final ranges = tokenizeWords('42 words, and stuff!');
    final text = '42 words, and stuff!';
    final words = [for (final r in ranges) text.substring(r.start, r.end)];
    expect(words, ['words', 'and', 'stuff']);
  });

  group('digits', () {
    test('a letter beside a digit is not a word of its own', () {
      // `3D` used to tokenize to `D`, which is in no dictionary.
      expect(words('rendered in 3D today'), ['rendered', 'in', 'today']);
    });

    test("an apostrophe after a digit does not split the run either", () {
      // `XM6's` used to tokenize to `XM` and `s` — two squiggles.
      expect(words("the XM6's grip"), ['the', 'grip']);
    });

    test('a digit suffix takes the whole word out of spell-check', () {
      expect(words('1990s covid19 x264enc sha256 prose'), ['prose']);
    });

    test('a digit does not reach past a non-word character', () {
      expect(words('3 D and 3-D'), ['D', 'and', 'D']);
    });
  });

  test('excludes tokens inside an inline code span', () {
    const text = 'call `fooo bario` twice';
    expect(words(text), ['call', 'twice']);
  });

  test(r'excludes tokens inside $...$ latex', () {
    expect(words(r'given $x alpha y$ then'), ['given', 'then']);
  });

  test('emphasized words are still checked', () {
    // The markers are not word characters, so `**wrold**` tokenizes to the
    // word inside it and nothing else (EMPHASIS_FORMATTING.md §6.3).
    expect(words('a **wrold** and *one* more'), [
      'a',
      'wrold',
      'and',
      'one',
      'more',
    ]);
  });

  test('an unclosed backtick still leaves the rest of the entry checked', () {
    // Deliberately unlike emphasis and autocorrect, which both stop at the
    // stray backtick: taking the squiggles off the whole rest of a long entry
    // is a far louder failure than a squiggle inside half-written code.
    expect(words('a `code and wrold'), ['a', 'code', 'and', 'wrold']);
  });

  group('windowed', () {
    // The incremental spell check re-scans a window of a document, and offsets
    // stay absolute so the caller does not have to shift them back.
    const text = 'alpha beta gamma delta';

    test('only tokens starting inside the window come back', () {
      final ranges = tokenizeWords(text, start: 6, end: 16);
      expect(
        [for (final r in ranges) text.substring(r.start, r.end)],
        ['beta', 'gamma'],
      );
      expect(ranges.first.start, 6);
    });

    test('a zone opened before the window still excludes inside it', () {
      const coded = 'see `alpha beta gamma` now';
      // A window that starts past the opening backtick would look like plain
      // prose if zones were resolved on the substring alone.
      expect(tokenizeWords(coded, start: 11, end: 21), isEmpty);
    });
  });
}

/// The words [tokenizeWords] keeps, for the assertions above.
List<String> words(String text) => [
  for (final r in tokenizeWords(text)) text.substring(r.start, r.end),
];
