import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_text_ops.dart';

/// Edge cases in the pure motion/range layer that the command-level tests in
/// `vim_session_test.dart` don't reach directly.
void main() {
  group('line geometry', () {
    const text = 'one\n  two\n\nfour';

    test('start/end/first-non-blank', () {
      expect(vimLineStart(text, 6), 4);
      expect(vimLineEnd(text, 6), 9);
      expect(vimFirstNonBlank(text, 4), 6);
      expect(vimLastNonBlank(text, 4), 8);
    });

    test('an empty line collapses start, end and first-non-blank', () {
      expect(vimLineStart(text, 10), 10);
      expect(vimLineEnd(text, 10), 10);
      expect(vimFirstNonBlank(text, 10), 10);
    });

    test('caret clamping keeps Normal mode on a character', () {
      expect(vimClampCaret('abc', 3), 2);
      expect(vimClampCaret('abc', 3, allowLineEnd: true), 3);
      expect(vimClampCaret('', 0), 0);
    });

    test('append offset stays on the same line', () {
      const text = 'one\ntwo';
      expect(vimAppendOffset(text, 2), 3); // after last char of "one"
      expect(vimAppendOffset(text, 1), 2); // mid-line
      expect(vimAppendOffset(text, 3), 3); // already at the newline
      expect(vimAppendOffset('one\n\ntwo', 4), 4); // empty line
      expect(vimAppendOffset('abc', 2), 3);
      expect(vimAppendOffset('', 0), 0);
    });
  });

  group('word motions', () {
    test('classify splits words from punctuation', () {
      expect(vimClassifyCodeUnit('a'.codeUnitAt(0)), VimCharClass.word);
      expect(vimClassifyCodeUnit('_'.codeUnitAt(0)), VimCharClass.word);
      expect(vimClassifyCodeUnit('é'.codeUnitAt(0)), VimCharClass.word);
      expect(vimClassifyCodeUnit('.'.codeUnitAt(0)), VimCharClass.punct);
      expect(vimClassifyCodeUnit(' '.codeUnitAt(0)), VimCharClass.blank);
    });

    test('W treats punctuation as part of the WORD', () {
      const source = 'a.b cd';
      expect(vimWordForward(source, 0), 1); // small word stops at '.'
      expect(vimWordForward(source, 0, big: true), 4); // WORD skips to 'cd'
    });

    test('w stops on an empty line', () {
      expect(vimWordForward('one\n\ntwo', 0), 4);
    });

    test('e never moves past the last character', () {
      expect(vimWordEnd('ab', 1), 1);
      expect(vimWordEnd('', 0), 0);
    });
  });

  group('character search', () {
    const search = VimCharSearch(character: ',', forward: true, till: false);

    test('stays inside the caret line', () {
      expect(vimFindChar('a,b\nc,d', 0, search), 1);
      expect(vimFindChar('ab\nc,d', 0, search), isNull);
    });

    test('till stops one short, and repeats skip the adjacent match', () {
      const till = VimCharSearch(character: ',', forward: true, till: true);
      expect(vimFindChar('a,b,c', 0, till), 0);
      expect(vimFindChar('a,b,c', 0, till, skipAdjacent: true), 2);
    });
  });

  group('linewise ranges', () {
    const text = 'one\ntwo\nthree';

    test('a linewise range includes the trailing newline', () {
      expect(
        vimLinewiseRange(text, 0, 0),
        const VimRange(0, 4, linewise: true),
      );
    });

    test('the last line absorbs the preceding newline only for deletes', () {
      final range = vimLineSpan(text, 9, 1);
      expect(range, const VimRange(8, 13, linewise: true));
      expect(
        vimAbsorbPrecedingNewline(text, range),
        const VimRange(7, 13, linewise: true),
      );
    });

    test('a mid-document range is left alone', () {
      final range = vimLineSpan(text, 0, 1);
      expect(vimAbsorbPrecedingNewline(text, range), range);
    });
  });

  group('text objects', () {
    test('aw falls back to leading space at the end of a line', () {
      const source = 'one two';
      expect(
        vimTextObject(source, 5, object: 'w', inner: false),
        const VimRange(3, 7),
      );
      expect(
        vimTextObject(source, 1, object: 'w', inner: false),
        const VimRange(0, 4),
      );
    });

    test('quote objects are line-local and skip escaped quotes', () {
      const source = r'say "a\"b" end';
      expect(
        vimTextObject(source, 6, object: '"', inner: true),
        const VimRange(5, 9),
      );
    });

    test('ap swallows the blank lines after the paragraph', () {
      const source = 'one\ntwo\n\n\nfour';
      expect(
        vimTextObject(source, 0, object: 'p', inner: true),
        const VimRange(0, 8, linewise: true),
      );
      expect(
        vimTextObject(source, 0, object: 'p', inner: false),
        const VimRange(0, 10, linewise: true),
      );
    });

    test('an unmatched bracket yields no range, so the operator aborts', () {
      expect(vimTextObject('no brackets', 3, object: '(', inner: true), isNull);
    });
  });

  group('transformations', () {
    test('shift leaves empty lines alone and counts a tab as one width', () {
      final indented = vimShiftLines('a\n\nb', 0, 3, indent: true);
      expect(indented.text, '  a\n\n  b');

      final dedented = vimShiftLines('\ta\n    b', 0, 7, indent: false);
      expect(dedented.text, 'a\n  b');
    });

    test('join collapses indentation, and adds no space before a paren', () {
      expect(vimJoinLines('foo\n    bar', 0, 1).text, 'foo bar');
      expect(vimJoinLines('foo\n)', 0, 1).text, 'foo)');
      expect(vimJoinLines('foo\n\nbar', 0, 1).text, 'foo\nbar');
    });

    test('case ops', () {
      expect(vimApplyCase('aBc', VimCaseOp.toggle), 'AbC');
      expect(vimApplyCase('aBc', VimCaseOp.toUpper), 'ABC');
      expect(vimApplyCase('aBc', VimCaseOp.toLower), 'abc');
    });
  });

  group('search', () {
    test('smartcase: lowercase is insensitive, any uppercase is not', () {
      expect(vimSearchMatches('Foo foo FOO', 'foo'), [0, 4, 8]);
      expect(vimSearchMatches('Foo foo FOO', 'Foo'), [0]);
    });

    test('overlapping matches are all found', () {
      expect(vimSearchMatches('aaaa', 'aa'), [0, 1, 2]);
    });

    test('next-match index wraps in both directions', () {
      const matches = [2, 8, 14];
      expect(vimNextMatchIndex(matches, 0, forward: true), 0);
      expect(vimNextMatchIndex(matches, 14, forward: true), 0);
      expect(vimNextMatchIndex(matches, 0, forward: false), 2);
      expect(vimNextMatchIndex(const [], 0, forward: true), isNull);
    });
  });
}
