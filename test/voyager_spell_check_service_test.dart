import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';

/// Flags for [text] as `word -> isKnown` in left-to-right order, used to
/// describe expected results without hardcoding character offsets.
List<String> _flaggedWords(String text, List<SuggestionSpan> spans) =>
    spans.map((s) => text.substring(s.range.start, s.range.end)).toList();

VoyagerSpellCheckService _serviceWith(Set<String> dictionary) {
  final service = VoyagerSpellCheckService();
  service.updateDictionary(dictionary);
  return service;
}

void main() {
  group('checkTextSync', () {
    test('flags unknown words and skips known ones', () {
      final service = _serviceWith({'the', 'quick', 'fox'});
      final spans = service.checkTextSync('the quikc fox jumps');
      expect(_flaggedWords('the quikc fox jumps', spans), ['quikc', 'jumps']);
    });

    test('returns nothing before the dictionary has loaded', () {
      final service = VoyagerSpellCheckService();
      expect(service.checkTextSync('anything gzqx'), isEmpty);
    });
  });

  group('checkIncremental — deferral', () {
    test('skips suggestion generation for the token still being typed', () {
      final service = _serviceWith({'hello', 'world'});
      var text = '';
      var spans = <SuggestionSpan>[];

      for (final ch in 'xqz'.split('')) {
        final newText = text + ch;
        spans = service.checkIncremental(oldText: text, oldSpans: spans, newText: newText);
        text = newText;
        expect(spans, isEmpty, reason: 'mid-word "$text" should not be flagged yet');
      }

      // Same call repeated with identical text (mirrors the two real call
      // sites — EditableText's own pass and SpellCheckSquiggleLayer's
      // listener — invoking this within one keystroke) must agree.
      final again = service.checkIncremental(oldText: text, oldSpans: spans, newText: text);
      expect(again, isEmpty);

      // Finishing the word (space appended, "xqz" no longer the active
      // token) should finally flag it for real.
      final finishedText = '$text ';
      final finished = service.checkIncremental(
        oldText: text,
        oldSpans: spans,
        newText: finishedText,
      );
      expect(_flaggedWords(finishedText, finished), ['xqz']);
    });

    test('allowDeferral: false always returns the complete result, even mid-edit', () {
      final service = _serviceWith({'hello'});
      final forced = service.checkIncremental(
        oldText: '',
        oldSpans: const [],
        newText: 'xq',
        allowDeferral: false,
      );
      expect(_flaggedWords('xq', forced), ['xq']);
    });

    test('a pure deletion has nothing to defer and checks the result normally', () {
      final service = _serviceWith({'hello'});
      final oldText = 'helloo';
      final oldSpans = service.checkTextSync(oldText);
      expect(_flaggedWords(oldText, oldSpans), ['helloo']);

      // Backspace the extra 'o' -> "hello", a known word.
      final newText = 'hello';
      final result = service.checkIncremental(
        oldText: oldText,
        oldSpans: oldSpans,
        newText: newText,
      );
      expect(result, isEmpty);
    });
  });

  group('checkIncremental — span reuse / shifting', () {
    test('spans before the edit are left untouched', () {
      final service = _serviceWith({'the', 'cat', 'sat'});
      const oldText = 'zzz the cat';
      final oldSpans = service.checkTextSync(oldText);
      expect(_flaggedWords(oldText, oldSpans), ['zzz']);
      final leadingSpanBefore = oldSpans.single.range;

      const newText = 'zzz the cats';
      final result = service.checkIncremental(
        oldText: oldText,
        oldSpans: oldSpans,
        newText: newText,
        allowDeferral: false,
      );
      final leading = result.firstWhere((s) => newText.substring(s.range.start, s.range.end) == 'zzz');
      expect(leading.range, leadingSpanBefore);
    });

    test('spans after the edit are shifted by the length delta', () {
      final service = _serviceWith({'the', 'cat'});
      const oldText = 'the cat qqzz';
      final oldSpans = service.checkTextSync(oldText);
      expect(_flaggedWords(oldText, oldSpans), ['qqzz']);

      // Insert extra characters early in the text so everything after
      // shifts right.
      const newText = 'thethe cat qqzz';
      final result = service.checkIncremental(
        oldText: oldText,
        oldSpans: oldSpans,
        newText: newText,
        allowDeferral: false,
      );
      expect(_flaggedWords(newText, result), ['thethe', 'qqzz']);
      final shifted = result.firstWhere((s) => newText.substring(s.range.start, s.range.end) == 'qqzz');
      expect(shifted.range, const TextRange(start: 11, end: 15));
    });

    test('a mid-document edit only touches the affected word', () {
      final service = _serviceWith({'cat', 'dog', 'end'});
      const oldText = 'cat dog fisz end';
      final oldSpans = service.checkTextSync(oldText);
      expect(_flaggedWords(oldText, oldSpans), ['fisz']);

      // Insert a character in the middle of "fisz" -> "fishz" (still
      // unknown), leaving "cat", "dog", "end" untouched.
      const newText = 'cat dog fishz end';
      final result = service.checkIncremental(
        oldText: oldText,
        oldSpans: oldSpans,
        newText: newText,
        allowDeferral: false,
      );
      expect(_flaggedWords(newText, result), ['fishz']);
    });

    test('a large/unrelated text swap falls back to a full recheck', () {
      final service = _serviceWith({'hello'});
      const oldText = 'hello there this is entry one with plenty of words in it';
      final oldSpans = service.checkTextSync(oldText);

      const newText = 'a completely different entry with its own unrelated qqzzxx word';
      final result = service.checkIncremental(
        oldText: oldText,
        oldSpans: oldSpans,
        newText: newText,
        allowDeferral: false,
      );
      expect(_flaggedWords(newText, result), containsAll(['qqzzxx', 'unrelated']));
    });
  });

  group('checkIncremental — dictionary/custom-word changes', () {
    test('generation bumps when the dictionary or custom words change', () {
      final service = VoyagerSpellCheckService();
      final g0 = service.generation;
      service.updateDictionary({'hello'});
      expect(service.generation, greaterThan(g0));
      final g1 = service.generation;
      service.updateCustomWords({'voyager'});
      expect(service.generation, greaterThan(g1));
    });

    test('a newly-added custom word is recognized on the next check', () {
      final service = _serviceWith({'hello'});
      const text = 'hello voyager';
      final before = service.checkTextSync(text);
      expect(_flaggedWords(text, before), ['voyager']);

      service.updateCustomWords({'voyager'});
      final after = service.checkTextSync(text);
      expect(after, isEmpty);
    });
  });

  group('checkIncremental — fuzz equivalence to checkTextSync', () {
    // The strongest guarantee for offset-shifting logic like this: after any
    // sequence of random edits, the incrementally-maintained result must be
    // byte-for-byte identical (ranges + suggestions) to a fresh, from-scratch
    // check of the final text. allowDeferral: false is used throughout so
    // this isolates the splicing/shifting logic from the (separately tested)
    // deferral behavior, which is a deliberate divergence from a full check.
    const words = ['the', 'quick', 'brown', 'fox', 'jumps', 'over', 'lazy', 'dog'];
    const misspellings = ['teh', 'qwik', 'brwon', 'foxx', 'jmups', 'ovr', 'lasy', 'dogg'];

    String randomWord(Random rng) =>
        rng.nextBool() ? words[rng.nextInt(words.length)] : misspellings[rng.nextInt(misspellings.length)];

    String applyRandomEdit(String text, Random rng) {
      final op = rng.nextInt(3);
      if (text.isEmpty || op == 0) {
        // Insert a word (plus surrounding space) at a random position.
        final pos = text.isEmpty ? 0 : rng.nextInt(text.length + 1);
        final insert = '${randomWord(rng)} ';
        return text.substring(0, pos) + insert + text.substring(pos);
      } else if (op == 1 && text.isNotEmpty) {
        // Delete a random small chunk.
        final pos = rng.nextInt(text.length);
        final len = min(1 + rng.nextInt(4), text.length - pos);
        return text.substring(0, pos) + text.substring(pos + len);
      } else {
        // Insert a single character at a random position (simulates
        // mid-word typing).
        final pos = rng.nextInt(text.length + 1);
        final ch = String.fromCharCode(97 + rng.nextInt(26));
        return text.substring(0, pos) + ch + text.substring(pos);
      }
    }

    for (final seed in [1, 2, 3, 4, 5, 42, 1337, 99999]) {
      test('random edit sequence (seed $seed) matches full recheck at every step', () {
        final service = _serviceWith(words.toSet());
        final rng = Random(seed);
        var text = '';
        var spans = <SuggestionSpan>[];

        for (var i = 0; i < 60; i++) {
          final newText = applyRandomEdit(text, rng);
          final incremental = service.checkIncremental(
            oldText: text,
            oldSpans: spans,
            newText: newText,
            allowDeferral: false,
          );
          final full = service.checkTextSync(newText);

          expect(
            incremental.map((s) => (s.range.start, s.range.end, s.suggestions)).toList(),
            full.map((s) => (s.range.start, s.range.end, s.suggestions)).toList(),
            reason: 'step $i: "$text" -> "$newText"',
          );

          text = newText;
          spans = incremental;
        }
      });
    }
  });
}
