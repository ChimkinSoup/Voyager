import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/snippets/snippet_index.dart';
import 'package:voyager/domain/models/snippet.dart';

Snippet _s(
  String trigger,
  String replacement, {
  bool auto = false,
  bool word = false,
}) => Snippet(
  id: trigger,
  trigger: trigger,
  replacement: replacement,
  autoExpand: auto,
  wordBoundary: word,
);

void main() {
  group('parseSnippetReplacement', () {
    test('strips tabstops and records their offsets', () {
      final parsed = parseSnippetReplacement(r'($0)$1');
      expect(parsed.text, '()');
      expect(parsed.tabstops, const [
        SnippetTabstop(index: 0, offset: 1),
        SnippetTabstop(index: 1, offset: 2),
      ]);
    });

    test(r'reads Latex Suite $$0$ as literal-$, stop, literal-$', () {
      final parsed = parseSnippetReplacement(r'$$0$');
      expect(parsed.text, r'$$');
      expect(parsed.tabstops, const [SnippetTabstop(index: 0, offset: 1)]);
    });

    test(r'a bare $ with no digits after it is a literal', () {
      final parsed = parseSnippetReplacement(r'cost: $ x');
      expect(parsed.text, r'cost: $ x');
      expect(parsed.tabstops, isEmpty);
    });

    test(r'\$ escapes a $ that digits follow', () {
      final parsed = parseSnippetReplacement(r'\$0 and \$1');
      expect(parsed.text, r'$0 and $1');
      expect(parsed.tabstops, isEmpty);
    });

    test('visits ascending by index, not by position', () {
      final parsed = parseSnippetReplacement(r'\begin{$1}$0\end{}');
      expect(parsed.tabstops.map((t) => t.index), [0, 1]);
      // $1 sits earlier in the string but is visited second.
      expect(
        parsed.tabstops.first.offset,
        greaterThan(parsed.tabstops[1].offset),
      );
    });

    test('multi-digit indices parse as one tabstop', () {
      final parsed = parseSnippetReplacement(r'a$10b');
      expect(parsed.text, 'ab');
      expect(parsed.tabstops, const [SnippetTabstop(index: 10, offset: 1)]);
    });

    test(
      'a repeated index keeps only the first — mirroring is not supported',
      () {
        final parsed = parseSnippetReplacement(r'$1-$1');
        expect(parsed.text, '-');
        expect(parsed.tabstops, const [SnippetTabstop(index: 1, offset: 0)]);
      },
    );

    test('a replacement with no tabstops opens no session', () {
      expect(parseSnippetReplacement('hello').tabstops, isEmpty);
    });
  });

  group('snippetUsesPlaceholders', () {
    test(r'flags ${1:text}', () {
      expect(snippetUsesPlaceholders(r'${1:name}'), isTrue);
    });

    test('leaves ordinary tabstops and escapes alone', () {
      expect(snippetUsesPlaceholders(r'($0)$1'), isFalse);
      expect(snippetUsesPlaceholders(r'\${not a placeholder}'), isFalse);
    });
  });

  group('isSnippetWordDelimiter', () {
    test('letters, digits and underscore are word characters', () {
      for (final text in ['a', 'Z', '4', '_']) {
        expect(isSnippetWordDelimiter(text, 0), isFalse, reason: text);
      }
    });

    test('whitespace and punctuation delimit', () {
      for (final text in [' ', '\t', '\n', '.', ',', '(', '-', '#']) {
        expect(isSnippetWordDelimiter(text, 0), isTrue, reason: text);
      }
    });

    test('off either end of the field counts as a delimiter', () {
      expect(isSnippetWordDelimiter('abc', -1), isTrue);
      expect(isSnippetWordDelimiter('abc', 3), isTrue);
    });

    test('non-ASCII letters and digits are word characters', () {
      expect(isSnippetWordDelimiter('é', 0), isFalse);
      expect(isSnippetWordDelimiter('漢', 0), isFalse);
      expect(isSnippetWordDelimiter('—', 0), isTrue);
    });
  });

  group('SnippetIndex', () {
    test('an empty list matches nothing and reports itself empty', () {
      final index = SnippetIndex.from(const []);
      expect(index.isEmpty, isTrue);
      expect(index.matchAuto('ee', 2), isNull);
      expect(index.matchManual('ee', 2), isNull);
    });

    test('matches a trigger ending at the caret', () {
      final index = SnippetIndex.from([_s('ee', '', auto: true)]);
      expect(index.matchAuto('the ee', 6)?.trigger, 'ee');
    });

    test('does not match a trigger that ends past the caret', () {
      final index = SnippetIndex.from([_s('ee', '', auto: true)]);
      // Caret sits between the two e's.
      expect(index.matchAuto('ee', 1), isNull);
    });

    test('auto and manual are separate pools', () {
      final index = SnippetIndex.from([_s('aa', '', auto: true), _s('bb', '')]);
      expect(index.matchAuto('aa', 2)?.trigger, 'aa');
      expect(index.matchAuto('bb', 2), isNull);
      expect(index.matchManual('bb', 2)?.trigger, 'bb');
      expect(index.matchManual('aa', 2), isNull);
    });

    test('prefers the longest manual suffix', () {
      final index = SnippetIndex.from([_s('e', 'short'), _s('ee', 'long')]);
      expect(index.matchManual('ee', 2)?.replacement, 'long');
      expect(index.matchManual('xe', 2)?.replacement, 'short');
    });

    test('wordBoundary requires a delimiter before the trigger', () {
      final index = SnippetIndex.from([_s('ee', '', auto: true, word: true)]);
      expect(index.matchAuto('the ee', 6)?.trigger, 'ee');
      expect(index.matchAuto('(ee', 3)?.trigger, 'ee');
      // Start of the field counts.
      expect(index.matchAuto('ee', 2)?.trigger, 'ee');
      // Glued to a preceding word character: no match.
      expect(index.matchAuto('free', 4), isNull);
    });

    test('wordBoundary requires a delimiter after the caret', () {
      final index = SnippetIndex.from([_s('ee', '', auto: true, word: true)]);
      // End of field counts as a delimiter.
      expect(index.matchAuto('the ee', 6)?.trigger, 'ee');
      // Punctuation after the caret is fine.
      expect(index.matchAuto('ee.', 2)?.trigger, 'ee');
      // A word character after the caret blocks the match.
      expect(index.matchAuto('eex', 2), isNull);
      expect(index.matchManual('go eeX', 5), isNull);
    });

    test('a snippet without wordBoundary matches mid-word', () {
      final index = SnippetIndex.from([_s('ee', '', auto: true)]);
      expect(index.matchAuto('free', 4)?.trigger, 'ee');
    });

    test('falls through a blocked word-boundary snippet to a shorter one', () {
      final index = SnippetIndex.from([
        _s('ee', 'blocked', word: true),
        _s('e', 'open'),
      ]);
      // "free": `ee` is blocked by the preceding `r`, so `e` wins.
      expect(index.matchManual('free', 4)?.replacement, 'open');
    });

    test('a caret at or past the ends never matches', () {
      final index = SnippetIndex.from([_s('e', '', auto: true)]);
      expect(index.matchAuto('e', 0), isNull);
      expect(index.matchAuto('e', 5), isNull);
    });

    test('triggers longer than the text so far do not match', () {
      final index = SnippetIndex.from([_s('abcd', '', auto: true)]);
      expect(index.matchAuto('cd', 2), isNull);
    });
  });

  group('Snippet json', () {
    test('round-trips', () {
      const snippet = Snippet(
        id: 'x',
        trigger: 'ee',
        replacement: r'($0)',
        autoExpand: true,
        wordBoundary: true,
      );
      expect(Snippet.fromJson(snippet.toJson()), snippet);
    });

    test('drops unusable rows rather than the whole list', () {
      final list = Snippet.listFromJson([
        {'id': 'a', 'trigger': 'aa', 'replacement': '1'},
        {'id': '', 'trigger': 'bb'}, // no id
        {'trigger': 'cc'}, // no id at all
        {'id': 'd', 'trigger': ''}, // empty trigger
        'nonsense',
        {'id': 'e', 'trigger': 'ee'}, // no replacement: defaults to empty
      ]);
      expect(list.map((s) => s.id), ['a', 'e']);
      expect(list.last.replacement, '');
    });

    test('a non-list is an empty list', () {
      expect(Snippet.listFromJson(null), isEmpty);
      expect(Snippet.listFromJson(<String, Object>{}), isEmpty);
    });
  });
}
