import 'dart:ui' show TextRange;

import 'package:flutter/services.dart' show TextSelection;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/spellcheck/autocorrect_engine.dart';
import 'package:voyager/core/text/prose_markup.dart';

/// The pure half of autocorrect (AUTOCORRECT.md §3, §4.4, §4.6), tested
/// against hand-built dictionaries so every uniqueness case is exact rather
/// than an accident of what the bundled 65k happens to contain.
void main() {
  group('cascade', () {
    test('a unique transposition is corrected', () {
      expect(autocorrectFor('wtih', {'with', 'wit', 'wish'}), 'with');
    });

    test('two known transpositions correct nothing', () {
      // `ab` swaps to `ba`; both real, so there is no answer to give.
      expect(autocorrectFor('abc', {'bac', 'acb'}), isNull);
    });

    test('a unique deletion is corrected', () {
      expect(autocorrectFor('helllo', {'hello'}), 'hello');
    });

    test('deletions that land on the same word still count as one', () {
      // Three of the six deletions of `helllo` produce `hello`. That is one
      // candidate word, not three, so the step is unambiguous.
      expect(autocorrectFor('helllo', {'hello', 'zzz'}), 'hello');
    });

    test('a unique insertion is corrected', () {
      expect(autocorrectFor('wth', {'with'}), 'with');
    });

    test('two known insertions correct nothing', () {
      expect(autocorrectFor('wth', {'with', 'wath'}), isNull);
    });

    test('transposition beats a deletion that would also have worked', () {
      // `tehn` transposes to `then` and deletes to `ten`. The cascade stops at
      // the first step that answers, so the transposition wins.
      expect(autocorrectFor('tehn', {'then', 'ten'}), 'then');
    });

    test('a substituted letter is never corrected', () {
      // `cet` reaches `cat` only by replacing a letter, which is not in the
      // model: `from`/`form` and `then`/`than` are the words this protects.
      expect(autocorrectFor('cet', {'cat', 'cot', 'set'}), isNull);
    });

    test(
      'a known word is left alone even when it is one edit from another',
      () {
        expect(autocorrectFor('form', {'form', 'from'}), isNull);
      },
    );

    test('a possessive of a known word is left alone', () {
      // Nothing in the bundled list is a possessive, so `dog's` is unknown by
      // the letter of the set — and `dogs` is exactly one deletion away, which
      // is how the apostrophe used to get corrected out of it.
      expect(autocorrectFor("dog's", {'dogs'}), 'dogs');
      expect(autocorrectFor("dog's", {'dog', 'dogs'}), isNull);
    });

    test('a token shorter than the minimum is left alone', () {
      expect(kMinAutocorrectLength, 3);
      // `eh` is one transposition from `he` and would otherwise be corrected.
      expect(autocorrectFor('eh', {'he'}), isNull);
      expect(autocorrectFor('hte', {'the'}), 'the');
    });

    test('matching is case-insensitive', () {
      expect(autocorrectFor('Wtih', {'with'}), 'with');
    });

    test('apostrophes ride along in the token', () {
      expect(autocorrectFor("dont'", {"don't"}), "don't");
    });

    test('nothing known at all corrects nothing', () {
      expect(autocorrectFor('wtih', const {}), isNull);
    });
  });

  group('case', () {
    test('a leading capital is preserved', () {
      expect(applyAutocorrectCase('Wtih', 'with'), 'With');
    });

    test('lowercase stays lowercase', () {
      expect(applyAutocorrectCase('wtih', 'with'), 'with');
    });

    test('the rest of the word is spelled as the dictionary has it', () {
      // Only the first letter's case carries over; a stray shift mid-typo is
      // a slip, not an intention.
      expect(applyAutocorrectCase('WtIh', 'with'), 'With');
      expect(applyAutocorrectCase('wTIh', 'with'), 'with');
    });

    test('a token starting with an uncased character is left alone', () {
      expect(applyAutocorrectCase("'tis", 'this'), 'this');
    });
  });

  group('all caps', () {
    test('an acronym is skipped', () {
      expect(isAllCapsToken('WTIH'), isTrue);
    });

    test('a capitalised word is not an acronym', () {
      expect(isAllCapsToken('Wtih'), isFalse);
    });

    test('a two-letter capital pair is under the length floor', () {
      expect(isAllCapsToken('OK'), isFalse);
    });
  });

  group('boundaries', () {
    test('space, newline and sentence punctuation complete a word', () {
      for (final ch in [' ', '\n', '.', ',', '!', '?', ';', ':']) {
        expect(isAutocorrectBoundary(ch), isTrue, reason: ch);
      }
    });

    test('an asterisk completes a word, since it closes emphasis', () {
      expect(isAutocorrectBoundary('*'), isTrue);
    });

    test('tab, hyphen and underscore do not', () {
      for (final ch in ['\t', '-', '_', 'a', "'", '=']) {
        expect(isAutocorrectBoundary(ch), isFalse, reason: ch);
      }
    });

    test('a closing asterisk finishes the word before it', () {
      expect(autocorrectBoundaryTokenEnd('*wtih*', 5), 5);
    });

    test('the second underscore of a closer finishes it one back', () {
      // `wtih__` — the word ends at 4, before the pair, not before the
      // keystroke at 5.
      expect(autocorrectBoundaryTokenEnd('wtih__', 5), 4);
      expect(autocorrectBoundaryTokenEnd('wtih==', 5), 4);
    });

    test('a lone underscore or equals finishes nothing', () {
      // Or `snake_case` and `x = 5` would autocorrect their first halves.
      expect(autocorrectBoundaryTokenEnd('snake_case', 5), isNull);
      expect(autocorrectBoundaryTokenEnd('wtih=', 4), isNull);
    });

    test('a word survives the first half of a closer, and nothing else', () {
      expect(isInPendingCloser('wtih__', 4, 5), isTrue);
      expect(isInPendingCloser('wtih__', 4, 6), isTrue);
      expect(isInPendingCloser('wtih==', 4, 5), isTrue);
      // A different character, a space, or the token's own end.
      expect(isInPendingCloser('wtih_=', 4, 6), isFalse);
      expect(isInPendingCloser('wtih b', 4, 5), isFalse);
      expect(isInPendingCloser('wtih__', 4, 4), isFalse);
    });
  });

  group('token spans', () {
    test('the caret after a word finds that word', () {
      expect(
        autocorrectTokenAt('hello wtih', 10),
        const TextRange(start: 6, end: 10),
      );
    });

    test('the caret inside a word finds the whole word', () {
      expect(
        autocorrectTokenAt('hello wtih', 8),
        const TextRange(start: 6, end: 10),
      );
    });

    test('an apostrophe between letters stays in the token', () {
      expect(autocorrectTokenAt("don't", 5), const TextRange(start: 0, end: 5));
    });

    test('an apostrophe at the edge is punctuation, not part of the word', () {
      expect(autocorrectTokenAt("'tis'", 5), const TextRange(start: 1, end: 4));
    });

    test('a doubled apostrophe splits the token, as wordTokenPattern does', () {
      // `[A-Za-z]+(?:'[A-Za-z]+)*` reads `don''t` as `don` and `t`, and the
      // span autocorrect measures has to be the span spellcheck flags.
      expect(
        autocorrectTokenAt("don''t", 6),
        const TextRange(start: 5, end: 6),
      );
      expect(
        autocorrectTokenAt("don''t", 3),
        const TextRange(start: 0, end: 3),
      );
    });

    test('there is no token in whitespace', () {
      expect(autocorrectTokenAt('a  b', 2), isNull);
    });

    test('digits do not join a token', () {
      expect(
        autocorrectTokenAt('sha256', 3),
        const TextRange(start: 0, end: 3),
      );
      // And a caret sitting after the digits is in no token at all, so a
      // space typed there completes nothing to correct.
      expect(autocorrectTokenAt('sha256', 6), isNull);
    });
  });

  group('excluded spans', () {
    // Autocorrect's exclusions are `ProseMarkup`'s zones, so that a code span
    // ends in the same place for autocorrect as it does for emphasis
    // (EMPHASIS_FORMATTING.md §6.2).
    bool excluded(String text, int offset) => ProseMarkup.zonesOf(
      text,
    ).any((z) => offset >= z.start && offset < z.end);

    test('a word inside a #tag is excluded', () {
      expect(excluded('see #wtih here', 5), isTrue);
    });

    test('a word after a multi-word tag is still inside it', () {
      expect(excluded('#depth-frst search', 7), isTrue);
    });

    test('an ordinary word is not in a tag', () {
      expect(excluded('see wtih here', 4), isFalse);
    });

    test('a mid-word # opens a tag, exactly as journalTagPattern does', () {
      // `#(\w+(?:-\w+)*)` has no left boundary, so `tokenizeWords` drops
      // `bar` here too. The two layers agree; neither is right about English.
      expect(excluded('foo#bar', 4), isTrue);
    });

    test('a word inside paired backticks is excluded', () {
      expect(excluded('a `wtih` b', 3), isTrue);
    });

    test('a word after the closing backtick is not', () {
      expect(excluded('a `code` wtih', 9), isFalse);
    });

    test('an unclosed backtick excludes to the end of the document', () {
      const text = 'a `code and wtih\nand a whole line later';
      expect(excluded(text, 12), isTrue);
      expect(excluded(text, text.length - 1), isTrue);
    });

    test('a word before any backtick is not excluded', () {
      expect(excluded('wtih `code`', 0), isFalse);
    });

    test(r'a word inside $...$ is excluded', () {
      expect(excluded(r'the sum $x wtih y$ holds', 11), isTrue);
      expect(excluded(r'the sum $x wtih y$ holds', 20), isFalse);
    });
  });

  group('alphanumeric runs', () {
    test('a token beside a digit is part of a longer run', () {
      // `autocorrectTokenAt` stops at the digit, so the token looks whole;
      // the squiggle drops the whole run, and a correction must too.
      expect(isInAlphanumericRun('x264enc ', 5, 8), isTrue);
      expect(isInAlphanumericRun('3D ', 1, 2), isTrue);
      // Across the apostrophe that holds one run together.
      expect(isInAlphanumericRun("xm6'sss ", 4, 7), isTrue);
    });

    test('an ordinary word is not in a run', () {
      expect(isInAlphanumericRun('the dog ran', 4, 7), isFalse);
      expect(isInAlphanumericRun('dog', 0, 3), isFalse);
      // A digit the other side of a space or a hyphen is its own run.
      expect(isInAlphanumericRun('3 dog', 2, 5), isFalse);
      expect(isInAlphanumericRun('3-dog', 2, 5), isFalse);
    });
  });

  group('non-ASCII neighbours', () {
    test('an ASCII tail of an accented word is not corrected', () {
      // `_isLetter` is ASCII-only, so `wtih` looks like a whole word here.
      // `wordTokenPattern` splits it the same way — but a squiggle under a
      // fragment is not the same as silently rewriting one.
      expect(
        autocorrectTokenAt('caféwtih', 8),
        const TextRange(start: 4, end: 8),
      );
      expect(isAsciiWordFragment('caféwtih', 4, 8), isTrue);
    });

    test('an ordinary word beside punctuation is not a fragment', () {
      expect(isAsciiWordFragment('hello wtih ', 6, 10), isFalse);
      expect(isAsciiWordFragment('wtih', 0, 4), isFalse);
      // An em dash is not a letter, so it does not make a fragment of what
      // follows it.
      expect(isAsciiWordFragment('so—wtih ', 3, 7), isFalse);
    });
  });

  group('edit spans', () {
    ({int at, int removed, int inserted}) span(
      String before,
      String after,
      int caret,
    ) => autocorrectEditSpan(
      before,
      after,
      TextSelection.collapsed(offset: caret),
    );

    test('a typed character is one insertion at the caret', () {
      expect(span('hello', 'hellos', 6), (at: 5, removed: 0, inserted: 1));
    });

    test('the caret disambiguates a repeated character', () {
      // Typing an `e` in *front* of an `e` produces the same text as typing
      // one behind it; only the caret says which.
      expect(span('ae', 'aee', 2), (at: 1, removed: 0, inserted: 1));
    });

    test('a backspace is one deletion', () {
      expect(span('hello', 'hell', 4), (at: 4, removed: 1, inserted: 0));
    });

    test('a range replacement is one span', () {
      expect(span('a wtih b', 'a with b', 6), (at: 3, removed: 2, inserted: 2));
    });
  });

  group('re-anchoring a range', () {
    const range = TextRange(start: 6, end: 10);

    test('an edit before it slides it', () {
      final moved = mapRangeAcrossEdit(range, (at: 0, removed: 0, inserted: 3));
      expect(moved, const TextRange(start: 9, end: 13));
    });

    test('an edit after it leaves it alone', () {
      expect(
        mapRangeAcrossEdit(range, (at: 10, removed: 0, inserted: 1)),
        range,
      );
    });

    test('an edit inside it grows it', () {
      expect(
        mapRangeAcrossEdit(range, (at: 8, removed: 0, inserted: 1)),
        const TextRange(start: 6, end: 11),
      );
    });

    test('an edit straddling an edge drops it', () {
      expect(
        mapRangeAcrossEdit(range, (at: 4, removed: 4, inserted: 0)),
        isNull,
      );
    });

    test('deleting the whole span drops it', () {
      expect(
        mapRangeAcrossEdit(range, (at: 6, removed: 4, inserted: 0)),
        isNull,
      );
    });
  });
}
