// The experience editor's advisory warnings and its explicit Clean paste
// (JOBS_EXPERIENCE_SNIPPETS_HLD.md §9). Warnings only ever read the text;
// Clean paste is the one rewrite, and it keeps paragraphs apart.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/jobs/experience_snippet_text.dart';

void main() {
  group('experienceTextIssues', () {
    test('plain ASCII prose with blank lines and CRLF is clean', () {
      expect(
        experienceTextIssues(
          '- Built the billing API in Go.\r\n\r\n- Cut p99 latency by 40%.\n',
        ),
        isEmpty,
      );
      expect(experienceTextIssues(''), isEmpty);
    });

    test('ASCII - and * bullets do not warn', () {
      expect(experienceTextIssues('- one\n* two'), isEmpty);
    });

    Set<ExperienceTextIssue> issues(String text) => experienceTextIssues(text);

    test('double spaces', () {
      expect(issues('Built  it'), {ExperienceTextIssue.doubleSpaces});
    });

    test('whitespace at either edge of any line', () {
      expect(issues(' Led'), {ExperienceTextIssue.lineEdgeWhitespace});
      expect(issues('Led\nShipped '), {ExperienceTextIssue.lineEdgeWhitespace});
      expect(issues('Shipped \r\nLed'), {
        ExperienceTextIssue.lineEdgeWhitespace,
      });
    });

    test('tabs', () {
      expect(issues('a\tb'), {ExperienceTextIssue.tabs});
    });

    test('non-breaking, typographic and zero-width spaces', () {
      for (final odd in ['\u00A0', '\u2007', '\u202F', '\u2009', '\u200B']) {
        expect(issues('a${odd}b'), {
          ExperienceTextIssue.oddSpaces,
        }, reason: odd.codeUnitAt(0).toRadixString(16));
      }
    });

    test('curly quotes', () {
      expect(issues('‘a’ “b”'), {ExperienceTextIssue.fancyQuotes});
    });

    test('dashes and ellipsis', () {
      expect(issues('2019–2021 — and so on…'), {
        ExperienceTextIssue.dashesOrEllipsis,
      });
    });

    test('bullet glyphs, including the one Word pastes', () {
      expect(issues('• one'), {ExperienceTextIssue.bulletGlyphs});
      expect(issues('\uF0B7 one'), {ExperienceTextIssue.bulletGlyphs});
    });

    test('anything else outside printable ASCII', () {
      expect(issues('José'), {ExperienceTextIssue.otherNonAscii});
      expect(issues('shipped 🚀'), {ExperienceTextIssue.otherNonAscii});
      // A carriage return that is not half of a CRLF.
      expect(issues('a\rb'), {ExperienceTextIssue.otherNonAscii});
    });

    test('reports every category that hits at once', () {
      expect(issues('•  “Led”\t'), {
        ExperienceTextIssue.bulletGlyphs,
        ExperienceTextIssue.doubleSpaces,
        ExperienceTextIssue.fancyQuotes,
        ExperienceTextIssue.tabs,
        ExperienceTextIssue.lineEdgeWhitespace,
      });
    });
  });

  group('cleanExperienceText', () {
    test('swaps typographic characters for ASCII', () {
      expect(
        cleanExperienceText('“Led” the team’s 2019–2021 re-write — twice…'),
        '"Led" the team\'s 2019-2021 re-write - twice...',
      );
    });

    test('odd spaces become one space; zero-width ones vanish', () {
      expect(cleanExperienceText('a\u00A0b\u202Fc'), 'a b c');
      expect(cleanExperienceText('Go\u200Blang'), 'Golang');
    });

    test('bullet glyphs become hyphens', () {
      expect(
        cleanExperienceText('• Built X\n\uF0B7\tShipped Y'),
        '- Built X\n- Shipped Y',
      );
    });

    test('collapses runs of spaces within a line, never across lines', () {
      expect(cleanExperienceText('Built   the  API'), 'Built the API');
      expect(cleanExperienceText('one \n two'), 'one\ntwo');
    });

    test('strips leading and trailing whitespace on every line', () {
      expect(
        cleanExperienceText('  - Built X  \n\t- Shipped Y\t'),
        '- Built X\n- Shipped Y',
      );
    });

    test('keeps blank lines between paragraphs', () {
      expect(
        cleanExperienceText('Para one.\r\n\r\nPara two.'),
        'Para one.\n\nPara two.',
      );
      // A whitespace-only line is emptied, not removed.
      expect(cleanExperienceText('a\n   \nb'), 'a\n\nb');
    });

    test('normalizes CRLF and lone CR to LF', () {
      expect(cleanExperienceText('a\r\nb\rc'), 'a\nb\nc');
    });

    test('drops exactly one trailing newline', () {
      expect(cleanExperienceText('Built X\n'), 'Built X');
      expect(cleanExperienceText('Built X\n\n'), 'Built X\n');
    });

    test('leaves wording and other non-ASCII alone', () {
      expect(cleanExperienceText('Worked with José'), 'Worked with José');
    });

    test('clean text is a fixed point', () {
      const text = '- Built the billing API in Go.\n\n- Cut p99 by 40%.';
      expect(cleanExperienceText(text), text);
    });

    test('clears every warning but the non-ASCII one', () {
      final cleaned = cleanExperienceText(
        ' •  “Led”\u00A0the team – José…\t\r\n',
      );
      expect(experienceTextIssues(cleaned), {
        ExperienceTextIssue.otherNonAscii,
      });
    });
  });
}
