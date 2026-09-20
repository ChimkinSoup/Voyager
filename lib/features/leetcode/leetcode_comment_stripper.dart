/// Removes a language's comments from a block of pasted code.
///
/// [stripLeetCodeLineComments] touches line comments only — `#` in Python,
/// `//` everywhere else — and leaves block comments (`/* ... */`) and Python
/// docstrings exactly as they are; block comments come out through
/// [stripLeetCodeBlockComments], which only the starter extractor runs. In
/// either, a comment marker that falls inside a string literal is not a
/// comment: `"http://x"` and `print('# 1')` survive intact.
///
/// A line that held nothing but a comment is dropped entirely; a line with code
/// before the marker keeps the code, trailing whitespace trimmed. Lines that
/// were already blank are left alone — this strips comments, it does not
/// compact the source. The one exception is the very last line, which is
/// dropped when it is blank: see [stripLeetCodeTrailingBlankLine].
library;

/// How one language spells the things this scanner has to step over.
class _Syntax {
  const _Syntax({
    required this.lineComment,
    this.blockComments = true,
    this.singleQuoteStrings = false,
    this.charLiterals = false,
    this.backtickStrings = false,
    this.tripleQuotedStrings = false,
  });

  final String lineComment;

  /// Whether `/* ... */` runs exist. Their contents are skipped rather than
  /// stripped, so a `//` written inside one stays put.
  final bool blockComments;

  /// `'` opens an ordinary string (Python, JS/TS).
  final bool singleQuoteStrings;

  /// `'` opens a single-character literal — only when a closing quote follows
  /// on the same line, so Rust's `&'a str` lifetimes aren't read as strings.
  final bool charLiterals;

  /// Backtick-delimited strings that may span lines: JS/TS templates, Go raw
  /// strings.
  final bool backtickStrings;

  /// Python's `"""` / `'''` runs.
  final bool tripleQuotedStrings;
}

const _python = _Syntax(
  lineComment: '#',
  blockComments: false,
  singleQuoteStrings: true,
  tripleQuotedStrings: true,
);

const _cStyle = _Syntax(lineComment: '//', charLiterals: true);

const _jsStyle = _Syntax(
  lineComment: '//',
  singleQuoteStrings: true,
  backtickStrings: true,
);

const _goStyle = _Syntax(
  lineComment: '//',
  charLiterals: true,
  backtickStrings: true,
);

_Syntax _syntaxFor(String language) => switch (language) {
  'javascript' || 'typescript' => _jsStyle,
  'go' => _goStyle,
  'java' || 'cpp' || 'csharp' || 'rust' => _cStyle,
  _ => _python,
};

/// The scanner's position between characters: plain code, inside a string, or
/// inside a block comment.
enum _State { code, string, blockComment }

/// Strips [language]'s line comments out of [code]. Returns [code] unchanged
/// when it holds none.
String stripLeetCodeLineComments(String code, String language) {
  if (code.isEmpty) return code;
  final syntax = _syntaxFor(language);
  final lines = code.split('\n');
  final out = <String>[];
  var state = _State.code;
  // Set while [state] is [_State.string]: the run that closes the string, and
  // whether reaching the end of the line closes it too.
  var closer = '';
  var stringSpansLines = false;
  var stripped = false;

  for (final line in lines) {
    var cut = -1; // Where this line's comment starts, if it has one.
    var i = 0;
    while (i < line.length) {
      switch (state) {
        case _State.string:
          if (line.startsWith(r'\', i)) {
            i += 2;
          } else if (line.startsWith(closer, i)) {
            i += closer.length;
            state = _State.code;
          } else {
            i++;
          }
        case _State.blockComment:
          if (line.startsWith('*/', i)) {
            i += 2;
            state = _State.code;
          } else {
            i++;
          }
        case _State.code:
          if (line.startsWith(syntax.lineComment, i)) {
            cut = i;
            i = line.length; // Everything after the marker is comment.
          } else if (syntax.blockComments && line.startsWith('/*', i)) {
            i += 2;
            state = _State.blockComment;
          } else {
            final opened = _openString(line, i, syntax);
            if (opened == null) {
              i++;
            } else {
              closer = opened.closer;
              stringSpansLines = opened.spansLines;
              i += opened.opener.length;
              state = _State.string;
            }
          }
      }
    }
    // An unterminated one-line string is a typo, not a multi-line string;
    // letting it run on would swallow every comment below it.
    if (state == _State.string && !stringSpansLines) state = _State.code;

    if (cut < 0) {
      out.add(line);
      continue;
    }
    stripped = true;
    final kept = line.substring(0, cut).trimRight();
    // A line that was only a comment goes with it; one with code keeps the
    // code.
    if (kept.isNotEmpty) out.add(kept);
  }

  return stripped ? out.join('\n') : code;
}

/// Strips [language]'s block comments (`/* ... */`) out of [code]. Returns
/// [code] unchanged when it holds none, and for a language that has no block
/// comment run at all.
///
/// Only the starter extractor runs this. LeetCode hands out `ListNode` and
/// friends as a `/** Definition for singly-linked list. */` header whose body
/// is written as code, and a line-oriented reader takes ` * public class
/// ListNode {` for a declaration and emits it. The Strip button leaves block
/// comments where they are — those are the user's own notes.
///
/// A line the comment consumed entirely goes with it; a line with code beside
/// the comment keeps the code, trailing whitespace trimmed.
String stripLeetCodeBlockComments(String code, String language) {
  final syntax = _syntaxFor(language);
  if (code.isEmpty || !syntax.blockComments) return code;
  final lines = code.split('\n');
  final out = <String>[];
  var state = _State.code;
  var closer = '';
  var stringSpansLines = false;
  var stripped = false;

  for (final line in lines) {
    // A line that opens inside a comment belongs to it even when it is empty.
    var touched = state == _State.blockComment;
    final kept = StringBuffer();
    var i = 0;
    while (i < line.length) {
      switch (state) {
        case _State.string:
          if (line.startsWith(r'\', i)) {
            kept.write(
              line.substring(i, i + 2 < line.length ? i + 2 : line.length),
            );
            i += 2;
          } else if (line.startsWith(closer, i)) {
            kept.write(closer);
            i += closer.length;
            state = _State.code;
          } else {
            kept.write(line[i]);
            i++;
          }
        case _State.blockComment:
          if (line.startsWith('*/', i)) {
            i += 2;
            state = _State.code;
          } else {
            i++;
          }
        case _State.code:
          if (line.startsWith(syntax.lineComment, i)) {
            // A line comment hides the rest of the line, a `/*` included.
            kept.write(line.substring(i));
            i = line.length;
          } else if (line.startsWith('/*', i)) {
            touched = true;
            stripped = true;
            i += 2;
            state = _State.blockComment;
          } else {
            final opened = _openString(line, i, syntax);
            if (opened == null) {
              kept.write(line[i]);
              i++;
            } else {
              closer = opened.closer;
              stringSpansLines = opened.spansLines;
              kept.write(opened.opener);
              i += opened.opener.length;
              state = _State.string;
            }
          }
      }
    }
    // An unterminated one-line string is a typo, not a multi-line string.
    if (state == _State.string && !stringSpansLines) state = _State.code;

    if (!touched) {
      out.add(line);
      continue;
    }
    final remains = kept.toString().trimRight();
    if (remains.isNotEmpty) out.add(remains);
  }

  return stripped ? out.join('\n') : code;
}

/// Drops a single trailing blank line from [code].
///
/// Pasted code almost always arrives with the newline that ended the last
/// statement still on it, which shows in the editor as an empty line under the
/// code and as a blank final row wherever the snippet is later rendered. Only
/// one line goes, and only the last one: blank lines *inside* the code are
/// spacing the author chose, and so is a run of them at the end.
///
/// Whitespace-only counts as blank — a line of stray indentation is the same
/// empty row on screen. Language-independent: nothing here reads as syntax.
String stripLeetCodeTrailingBlankLine(String code) {
  final lastBreak = code.lastIndexOf('\n');
  if (lastBreak < 0) return code;
  if (code.substring(lastBreak + 1).trim().isNotEmpty) return code;
  return code.substring(0, lastBreak);
}

/// A string literal opening at an index: what was typed to open it, what closes
/// it, and whether it may run past the end of the line.
class _StringOpener {
  const _StringOpener(this.opener, this.closer, this.spansLines);

  final String opener;
  final String closer;
  final bool spansLines;
}

/// The string literal starting at [i], or null if [line] has none there.
_StringOpener? _openString(String line, int i, _Syntax syntax) {
  final char = line[i];
  if (syntax.tripleQuotedStrings && (char == '"' || char == "'")) {
    final triple = char * 3;
    if (line.startsWith(triple, i)) {
      return _StringOpener(triple, triple, true);
    }
  }
  if (char == '"') return const _StringOpener('"', '"', false);
  if (syntax.backtickStrings && char == '`') {
    return const _StringOpener('`', '`', true);
  }
  if (char == "'") {
    if (syntax.singleQuoteStrings) return const _StringOpener("'", "'", false);
    if (syntax.charLiterals && _closesAsCharLiteral(line, i)) {
      return const _StringOpener("'", "'", false);
    }
  }
  return null;
}

/// Whether the `'` at [i] closes soon enough to be a character literal.
///
/// Rust spells lifetimes with a lone `'` (`&'a str`, `impl<'de>`), which would
/// otherwise open a string and hide the rest of the line from the scanner. A
/// real literal is short — `'\u{1F600}'` is the longest — so a closing quote
/// within a few characters is the tell.
bool _closesAsCharLiteral(String line, int i) {
  const maxBody = 10;
  var j = i + 1;
  final limit = (i + 1 + maxBody).clamp(0, line.length);
  while (j < limit) {
    if (line.startsWith(r'\', j)) {
      j += 2;
      continue;
    }
    if (line[j] == "'") return true;
    j++;
  }
  return false;
}
