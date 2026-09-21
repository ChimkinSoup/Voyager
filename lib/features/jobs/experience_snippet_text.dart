/// Advisory checks and the explicit Clean paste for experience snippet
/// descriptions (`JOBS_EXPERIENCE_SNIPPETS_HLD.md` §9).
///
/// Nothing here runs on its own: the editor calls [experienceTextIssues] to
/// draw its warning strip and [cleanExperienceText] only when the user presses
/// Clean paste. Save and copy never touch the text.
library;

/// One category of text a job-application form may mangle. Declared in the
/// order the warning details list them.
enum ExperienceTextIssue {
  doubleSpaces('Double spaces'),
  lineEdgeWhitespace('Spaces at the start or end of a line'),
  tabs('Tabs'),
  oddSpaces('Non-breaking or invisible spaces'),
  fancyQuotes('Curly quotes'),
  dashesOrEllipsis('En/em dashes or ellipsis characters'),
  bulletGlyphs('Bullet symbols'),
  otherNonAscii('Other non-ASCII characters');

  const ExperienceTextIssue(this.label);

  final String label;
}

/// Spaces that look like one but aren't ASCII 0x20.
const Set<int> _oddSpaces = {
  0x00A0, // no-break space
  0x1680, // ogham space mark
  0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, // en quad … four-per-em
  0x2006, 0x2007, 0x2008, 0x2009, 0x200A, // six-per-em … hair space
  0x202F, // narrow no-break space
  0x205F, // medium mathematical space
  0x3000, // ideographic space
};

/// Characters with no width at all. Grouped with [_oddSpaces] for the warning
/// — they arrive from the same PDF and web copies — but Clean paste deletes
/// them rather than turning them into a space nobody could see was missing.
const Set<int> _zeroWidth = {
  0x200B, // zero width space
  0x200C, // zero width non-joiner
  0x200D, // zero width joiner
  0x2060, // word joiner
  0xFEFF, // byte order mark / zero width no-break space
};

const Map<int, String> _quotes = {
  0x2018: "'", // ‘
  0x2019: "'", // ’
  0x201A: "'", // ‚
  0x201B: "'", // ‛
  0x2032: "'", // ′
  0x201C: '"', // “
  0x201D: '"', // ”
  0x201E: '"', // „
  0x201F: '"', // ‟
  0x2033: '"', // ″
};

const Map<int, String> _dashes = {
  0x2010: '-', // hyphen
  0x2011: '-', // non-breaking hyphen
  0x2012: '-', // figure dash
  0x2013: '-', // en dash
  0x2014: '-', // em dash
  0x2015: '-', // horizontal bar
  0x2212: '-', // minus sign
  0x2026: '...', // horizontal ellipsis
};

/// Glyphs résumés use to start a bullet line. The two private-use code points
/// are Word's Symbol and Wingdings bullets, which is what a bullet copied out
/// of a .docx usually turns out to be.
const Set<int> _bullets = {
  0x2022, // •
  0x2023, // ‣
  0x2043, // ⁃
  0x2219, // ∙
  0x25AA, // ▪
  0x25A0, // ■
  0x25B8, // ▸
  0x25BA, // ►
  0x25CB, // ○
  0x25CF, // ●
  0x25E6, // ◦
  0x27A2, // ➢
  0x27A4, // ➤
  0xF0A7, // Wingdings square bullet
  0xF0B7, // Symbol bullet
};

const int _tab = 0x09;
const int _lf = 0x0A;
const int _cr = 0x0D;
const int _space = 0x20;

final RegExp _doubleSpaces = RegExp(' {2,}');
final RegExp _lineEdgeWhitespace = RegExp(r'^[ \t]|[ \t]\r?$', multiLine: true);

/// Every category [text] trips, empty when it is clean. Never alters [text].
Set<ExperienceTextIssue> experienceTextIssues(String text) {
  final issues = <ExperienceTextIssue>{};
  if (_doubleSpaces.hasMatch(text))
    issues.add(ExperienceTextIssue.doubleSpaces);
  if (_lineEdgeWhitespace.hasMatch(text)) {
    issues.add(ExperienceTextIssue.lineEdgeWhitespace);
  }
  final runes = text.runes.toList();
  for (var i = 0; i < runes.length; i++) {
    final rune = runes[i];
    if (rune == _tab) {
      issues.add(ExperienceTextIssue.tabs);
    } else if (rune == _lf) {
      continue;
    } else if (rune == _cr) {
      // Only as half of a Windows line break; a lone CR is not a newline any
      // paste target agrees on.
      if (i + 1 >= runes.length || runes[i + 1] != _lf) {
        issues.add(ExperienceTextIssue.otherNonAscii);
      }
    } else if (rune >= _space && rune < 0x7F) {
      continue;
    } else if (_oddSpaces.contains(rune) || _zeroWidth.contains(rune)) {
      issues.add(ExperienceTextIssue.oddSpaces);
    } else if (_quotes.containsKey(rune)) {
      issues.add(ExperienceTextIssue.fancyQuotes);
    } else if (_dashes.containsKey(rune)) {
      issues.add(ExperienceTextIssue.dashesOrEllipsis);
    } else if (_bullets.contains(rune)) {
      issues.add(ExperienceTextIssue.bulletGlyphs);
    } else {
      issues.add(ExperienceTextIssue.otherNonAscii);
    }
  }
  return issues;
}

final RegExp _spaceRun = RegExp(' {2,}');

/// Clean paste (§9.3): a conservative ASCII normalise, run only when the user
/// presses the button.
///
/// Newlines are normalised first rather than last as the HLD lists them —
/// the per-line steps then see one kind of line end, and the result is the
/// same. Blank lines between paragraphs survive; the text is never joined
/// onto one line; wording and any other non-ASCII (an accented name) are left
/// alone, so the "other characters" warning can outlive a clean.
///
/// Exactly one trailing newline is dropped, if there is one: a paragraph
/// copied out of a document usually drags its break along with it.
String cleanExperienceText(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  final buffer = StringBuffer();
  for (final rune in normalized.runes) {
    if (_zeroWidth.contains(rune)) continue;
    if (_oddSpaces.contains(rune) || rune == _tab) {
      buffer.writeCharCode(_space);
    } else if (_quotes[rune] case final ascii?) {
      buffer.write(ascii);
    } else if (_dashes[rune] case final ascii?) {
      buffer.write(ascii);
    } else if (_bullets.contains(rune)) {
      buffer.write('-');
    } else {
      buffer.writeCharCode(rune);
    }
  }

  final lines = [
    for (final line in buffer.toString().split('\n'))
      line.replaceAll(_spaceRun, ' ').trim(),
  ];
  final cleaned = lines.join('\n');
  return cleaned.endsWith('\n')
      ? cleaned.substring(0, cleaned.length - 1)
      : cleaned;
}
