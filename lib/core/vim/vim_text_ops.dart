/// Pure text algorithms behind Voyager's Vim mode.
///
/// Everything here is a plain function over a [String] and a caret offset —
/// no widgets, no controllers, no async. That keeps the interesting logic
/// (motions, text objects, operator ranges) unit-testable without pumping a
/// widget tree, and keeps the per-keystroke cost obvious: every function below
/// scans outward from the caret and stops as soon as it has an answer, so cost
/// scales with the distance moved, not with document length. The two
/// exceptions are documented where they occur ([vimSearchMatches], which must
/// scan the whole document, and [vimLineIndexOf]).
library;

import 'dart:math' as math;

/// How Vim classifies a character for `w`/`b`/`e` and the `iw` text object.
///
/// Vim moves between *runs* of one class: `foo.bar` is three small-word
/// motions (`foo`, `.`, `bar`) but one WORD.
enum VimCharClass { blank, word, punct }

const int _kNewline = 0x0a;
const int _kSpace = 0x20;
const int _kTab = 0x09;
const int _kCarriageReturn = 0x0d;
const int _kUnderscore = 0x5f;

VimCharClass vimClassifyCodeUnit(int code) {
  if (code == _kSpace ||
      code == _kTab ||
      code == _kNewline ||
      code == _kCarriageReturn) {
    return VimCharClass.blank;
  }
  if (code == _kUnderscore) return VimCharClass.word;
  if (code >= 0x30 && code <= 0x39) return VimCharClass.word; // 0-9
  if (code >= 0x41 && code <= 0x5a) return VimCharClass.word; // A-Z
  if (code >= 0x61 && code <= 0x7a) return VimCharClass.word; // a-z
  // Anything above ASCII is treated as a word character so accented letters
  // and CJK don't split a word in half. Vim itself is configurable here
  // (`iskeyword`); this is the closest useful default for prose.
  if (code > 0x7f) return VimCharClass.word;
  return VimCharClass.punct;
}

/// Class of the character at [offset], collapsing `word` and `punct` into one
/// class when [big] is set (the WORD motions `W`/`B`/`E`).
VimCharClass _classAt(String text, int offset, bool big) {
  if (offset < 0 || offset >= text.length) return VimCharClass.blank;
  final cls = vimClassifyCodeUnit(text.codeUnitAt(offset));
  if (big && cls == VimCharClass.punct) return VimCharClass.word;
  return cls;
}

bool _isNewline(String text, int offset) =>
    offset >= 0 && offset < text.length && text.codeUnitAt(offset) == _kNewline;

bool _isSpaceOrTab(String text, int offset) {
  if (offset < 0 || offset >= text.length) return false;
  final c = text.codeUnitAt(offset);
  return c == _kSpace || c == _kTab;
}

// ---------------------------------------------------------------------------
// Ranges
// ---------------------------------------------------------------------------

/// A half-open `[start, end)` span of [String] offsets, plus whether an
/// operator should treat it as whole lines.
///
/// Linewise ranges always include the trailing newline when one exists, so
/// `dd` on a middle line removes the line *and* its line break, and the
/// yanked register replays as a full line under `p`.
class VimRange {
  const VimRange(this.start, this.end, {this.linewise = false});

  final int start;
  final int end;
  final bool linewise;

  bool get isEmpty => end <= start;
  int get length => math.max(0, end - start);

  VimRange normalized() =>
      start <= end ? this : VimRange(end, start, linewise: linewise);

  @override
  String toString() => 'VimRange($start, $end, linewise: $linewise)';

  @override
  bool operator ==(Object other) =>
      other is VimRange &&
      other.start == start &&
      other.end == end &&
      other.linewise == linewise;

  @override
  int get hashCode => Object.hash(start, end, linewise);
}

/// Whether a motion's destination offset is part of the operated range.
///
/// Vim's own distinction: `dw` is exclusive (stops before the next word's
/// first character) while `de` is inclusive (eats the word's last character),
/// and `dj` is linewise regardless of columns.
enum VimMotionKind { exclusive, inclusive, linewise }

/// A motion's result: where the caret lands, and how an operator should read
/// the span between the old and new offsets.
class VimMotion {
  const VimMotion(this.offset, this.kind);

  const VimMotion.exclusive(this.offset) : kind = VimMotionKind.exclusive;
  const VimMotion.inclusive(this.offset) : kind = VimMotionKind.inclusive;
  const VimMotion.linewise(this.offset) : kind = VimMotionKind.linewise;

  final int offset;
  final VimMotionKind kind;
}

// ---------------------------------------------------------------------------
// Line geometry
// ---------------------------------------------------------------------------

/// Offset of the first character of the line containing [offset].
int vimLineStart(String text, int offset) {
  final o = offset.clamp(0, text.length);
  if (o == 0) return 0;
  final i = text.lastIndexOf('\n', o - 1);
  return i < 0 ? 0 : i + 1;
}

/// Offset of the line's terminating `\n`, or [String.length] on the last line.
/// This is the *exclusive* end of the line's text content.
int vimLineEnd(String text, int offset) {
  final o = offset.clamp(0, text.length);
  final i = text.indexOf('\n', o);
  return i < 0 ? text.length : i;
}

/// Offset just past the line's `\n`, i.e. the start of the next line. Equal to
/// [vimLineEnd] on the final line.
int vimLineEndInclusive(String text, int offset) {
  final end = vimLineEnd(text, offset);
  return end < text.length ? end + 1 : end;
}

/// First non-blank character of the line (Vim's `^`), or the line's end if the
/// line is blank.
int vimFirstNonBlank(String text, int offset) {
  final start = vimLineStart(text, offset);
  final end = vimLineEnd(text, offset);
  var i = start;
  while (i < end && _isSpaceOrTab(text, i)) {
    i++;
  }
  return i;
}

/// Last non-blank character of the line (Vim's `g_`).
int vimLastNonBlank(String text, int offset) {
  final start = vimLineStart(text, offset);
  var i = vimLineEnd(text, offset) - 1;
  while (i > start && _isSpaceOrTab(text, i)) {
    i--;
  }
  return math.max(start, i);
}

/// Zero-based line number containing [offset].
///
/// O(offset) — only used for the search-bar match counter and `G`/`gg`
/// bookkeeping, never on a per-motion path.
int vimLineIndexOf(String text, int offset) {
  final o = offset.clamp(0, text.length);
  var line = 0;
  for (var i = 0; i < o; i++) {
    if (text.codeUnitAt(i) == _kNewline) line++;
  }
  return line;
}

/// Start offset of line [line] (clamped to the document).
int vimOffsetOfLine(String text, int line) {
  if (line <= 0) return 0;
  var seen = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == _kNewline) {
      seen++;
      if (seen == line) return i + 1;
    }
  }
  return vimLineStart(text, text.length);
}

/// Caret's visual column within its line.
int vimColumnOf(String text, int offset) =>
    offset.clamp(0, text.length) - vimLineStart(text, offset);

/// Clamps [offset] so the caret rests *on* a character rather than past the
/// end of the line, which is what Normal mode requires (Insert mode may sit at
/// the line end, so it uses [clampToLineEnd] = false).
int vimClampCaret(String text, int offset, {bool allowLineEnd = false}) {
  var o = offset.clamp(0, text.length);
  if (allowLineEnd) return o;
  final start = vimLineStart(text, o);
  final end = vimLineEnd(text, o);
  if (o >= end) o = math.max(start, end - 1);
  return o;
}

/// Insert offset for Vim's `a` (append after the caret).
///
/// One past [offset], but never onto the next line. Stepping past this line's
/// `\n` is what dropped the Insert caret onto the left of the line below when
/// `a` was pressed on the last character — Flutter paints a caret sitting on
/// a newline at the start of the following line.
int vimAppendOffset(String text, int offset) {
  if (text.isEmpty) return 0;
  final o = offset.clamp(0, text.length);
  final lineEnd = vimLineEnd(text, o);
  if (o >= lineEnd) return lineEnd;
  return o + 1;
}

// ---------------------------------------------------------------------------
// Vertical motions
// ---------------------------------------------------------------------------

/// Moves [count] logical lines down (or up when negative), preserving
/// [desiredColumn] where the target line is long enough — Vim's "sticky
/// column" behaviour, so `jjj` through a ragged paragraph returns to the
/// original column rather than creeping left.
int vimVerticalMove(
  String text,
  int offset,
  int deltaLines, {
  required int desiredColumn,
}) {
  if (deltaLines == 0) return offset;
  var lineStart = vimLineStart(text, offset);
  var remaining = deltaLines;
  while (remaining > 0) {
    final end = vimLineEnd(text, lineStart);
    if (end >= text.length) break; // no line below
    lineStart = end + 1;
    remaining--;
  }
  while (remaining < 0) {
    if (lineStart == 0) break; // no line above
    lineStart = vimLineStart(text, lineStart - 1);
    remaining++;
  }
  final end = vimLineEnd(text, lineStart);
  return math
      .min(lineStart + desiredColumn, math.max(lineStart, end - 1))
      .clamp(lineStart, end);
}

// ---------------------------------------------------------------------------
// Word motions
// ---------------------------------------------------------------------------

/// Vim's `w`/`W`: start of the next word.
int vimWordForward(String text, int offset, {bool big = false}) {
  final n = text.length;
  var o = offset.clamp(0, n);
  if (o >= n) return n;

  final startClass = _classAt(text, o, big);
  if (startClass != VimCharClass.blank) {
    while (o < n && _classAt(text, o, big) == startClass) {
      o++;
    }
  }
  while (o < n && _classAt(text, o, big) == VimCharClass.blank) {
    // An empty line is a word of its own in Vim, so `w` stops on it rather
    // than skipping the whole blank gap.
    if (_isNewline(text, o) && _isNewline(text, o + 1)) return o + 1;
    o++;
  }
  return o;
}

/// Vim's `b`/`B`: start of the previous word.
int vimWordBackward(String text, int offset, {bool big = false}) {
  var o = offset.clamp(0, text.length);
  if (o <= 0) return 0;
  o--;
  while (o > 0 && _classAt(text, o, big) == VimCharClass.blank) {
    if (_isNewline(text, o) && _isNewline(text, o - 1)) return o;
    o--;
  }
  final cls = _classAt(text, o, big);
  if (cls == VimCharClass.blank) return o;
  while (o > 0 && _classAt(text, o - 1, big) == cls) {
    o--;
  }
  return o;
}

/// Vim's `e`/`E`: last character of the current or next word (inclusive).
int vimWordEnd(String text, int offset, {bool big = false}) {
  final n = text.length;
  var o = offset.clamp(0, n);
  if (n == 0) return 0;
  if (o >= n - 1) return n - 1;
  o++;
  while (o < n && _classAt(text, o, big) == VimCharClass.blank) {
    o++;
  }
  if (o >= n) return n - 1;
  final cls = _classAt(text, o, big);
  while (o + 1 < n && _classAt(text, o + 1, big) == cls) {
    o++;
  }
  return o;
}

// ---------------------------------------------------------------------------
// Character search (f / F / t / T)
// ---------------------------------------------------------------------------

/// One `f`/`F`/`t`/`T` search, stored so `;` and `,` can replay it.
class VimCharSearch {
  const VimCharSearch({
    required this.character,
    required this.forward,
    required this.till,
  });

  final String character;
  final bool forward;
  final bool till;

  VimCharSearch get reversed =>
      VimCharSearch(character: character, forward: !forward, till: till);
}

/// Runs [search] [count] times from [offset], staying inside the caret's line
/// (Vim's `f` family never crosses a line break). Returns null when the
/// character isn't found, which leaves the caret untouched.
///
/// [skipAdjacent] handles the `;`-after-`t` case: repeating `t,` from the
/// character immediately before the match would find the same match forever,
/// so the repeat starts one character further along.
int? vimFindChar(
  String text,
  int offset,
  VimCharSearch search, {
  int count = 1,
  bool skipAdjacent = false,
}) {
  if (search.character.isEmpty) return null;
  final lineStart = vimLineStart(text, offset);
  final lineEnd = vimLineEnd(text, offset);
  var pos = offset.clamp(0, text.length);

  for (var i = 0; i < count; i++) {
    if (search.forward) {
      var from = pos + 1;
      if (search.till && i == 0 && skipAdjacent) from = pos + 2;
      if (from > lineEnd) return null;
      final idx = text.indexOf(search.character, from);
      if (idx < 0 || idx >= lineEnd) return null;
      pos = idx;
    } else {
      var from = pos - 1;
      if (search.till && i == 0 && skipAdjacent) from = pos - 2;
      if (from < lineStart) return null;
      final idx = text.lastIndexOf(search.character, from);
      if (idx < 0 || idx < lineStart) return null;
      pos = idx;
    }
  }
  if (!search.till) return pos;
  final result = search.forward ? pos - 1 : pos + 1;
  if (result < lineStart || result > lineEnd) return null;
  return result;
}

// ---------------------------------------------------------------------------
// Paragraph motions
// ---------------------------------------------------------------------------

bool _isBlankLine(String text, int lineStart) =>
    vimLineEnd(text, lineStart) == lineStart;

/// Vim's `}`: the next empty line (or end of document).
int vimParagraphForward(String text, int offset) {
  final n = text.length;
  var lineStart = vimLineStart(text, offset);
  final startedBlank = _isBlankLine(text, lineStart);
  while (true) {
    final end = vimLineEnd(text, lineStart);
    if (end >= n) return n;
    lineStart = end + 1;
    final blank = _isBlankLine(text, lineStart);
    if (blank && !startedBlank) return lineStart;
    if (!blank && startedBlank) {
      // Skipped out of a run of blank lines; keep going to the next gap.
      return vimParagraphForward(text, lineStart);
    }
  }
}

/// Vim's `{`: the previous empty line (or start of document).
int vimParagraphBackward(String text, int offset) {
  var lineStart = vimLineStart(text, offset);
  final startedBlank = _isBlankLine(text, lineStart);
  while (lineStart > 0) {
    lineStart = vimLineStart(text, lineStart - 1);
    final blank = _isBlankLine(text, lineStart);
    if (blank && !startedBlank) return lineStart;
    if (!blank && startedBlank) return vimParagraphBackward(text, lineStart);
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Bracket matching (%)
// ---------------------------------------------------------------------------

const Map<String, String> _kBracketPairs = {
  '(': ')',
  '[': ']',
  '{': '}',
  '<': '>',
};

const Map<String, String> _kClosingToOpening = {
  ')': '(',
  ']': '[',
  '}': '{',
  '>': '<',
};

/// Vim's `%`: from the first bracket at or after the caret on its line, jump
/// to the matching bracket. Null when there's no bracket or no match.
int? vimMatchBracket(String text, int offset) {
  final lineEnd = vimLineEnd(text, offset);
  var i = offset.clamp(0, text.length);
  String? open;
  String? close;
  var forward = true;

  while (i < lineEnd) {
    final ch = text[i];
    final closer = _kBracketPairs[ch];
    if (closer != null) {
      open = ch;
      close = closer;
      forward = true;
      break;
    }
    final opener = _kClosingToOpening[ch];
    if (opener != null) {
      open = opener;
      close = ch;
      forward = false;
      break;
    }
    i++;
  }
  if (open == null || close == null) return null;

  var depth = 0;
  if (forward) {
    for (var j = i; j < text.length; j++) {
      final ch = text[j];
      if (ch == open) depth++;
      if (ch == close) {
        depth--;
        if (depth == 0) return j;
      }
    }
  } else {
    for (var j = i; j >= 0; j--) {
      final ch = text[j];
      if (ch == close) depth++;
      if (ch == open) {
        depth--;
        if (depth == 0) return j;
      }
    }
  }
  return null;
}

/// Scans outward from [offset] for the innermost `open`/`close` pair that
/// encloses it, honouring nesting. Returns the two bracket offsets.
({int open, int close})? _enclosingPair(
  String text,
  int offset,
  String open,
  String close,
) {
  final n = text.length;
  if (n == 0) return null;
  final int lastIndex = n - 1;
  final int o = offset.clamp(0, lastIndex);

  // Standing on a bracket counts as being inside its own pair, matching Vim.
  var openIndex = -1;
  if (o < n && text[o] == open) {
    openIndex = o;
  } else {
    var depth = 0;
    for (var i = o; i >= 0; i--) {
      final ch = text[i];
      if (ch == close && i != o) {
        depth++;
      } else if (ch == open) {
        if (depth == 0) {
          openIndex = i;
          break;
        }
        depth--;
      }
    }
  }
  if (openIndex < 0) return null;

  var depth = 0;
  for (var i = openIndex; i < n; i++) {
    final ch = text[i];
    if (ch == open) {
      depth++;
    } else if (ch == close) {
      depth--;
      if (depth == 0) return (open: openIndex, close: i);
    }
  }
  return null;
}

/// Innermost quoted span containing (or starting at) [offset], searched within
/// the caret's line — Vim's quote objects are line-local.
({int open, int close})? _enclosingQuote(
  String text,
  int offset,
  String quote,
) {
  final lineStart = vimLineStart(text, offset);
  final lineEnd = vimLineEnd(text, offset);
  final positions = <int>[];
  for (var i = lineStart; i < lineEnd; i++) {
    if (text[i] == quote && (i == lineStart || text[i - 1] != r'\')) {
      positions.add(i);
    }
  }
  for (var i = 0; i + 1 < positions.length; i += 2) {
    final open = positions[i];
    final close = positions[i + 1];
    if (offset <= close) return (open: open, close: close);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Text objects
// ---------------------------------------------------------------------------

/// Resolves a text object such as `iw`, `aw`, `i"`, `a(`, `ip`.
///
/// [object] is the trailing character the user typed (`w`, `W`, `"`, `(`,
/// `p`, …); [inner] distinguishes `i` from `a`. Returns null when the caret
/// isn't inside a matching construct, which aborts the pending operator
/// without touching the text.
VimRange? vimTextObject(
  String text,
  int offset, {
  required String object,
  required bool inner,
}) {
  if (text.isEmpty) return null;
  final int lastIndex = text.length - 1;
  final int o = offset.clamp(0, lastIndex);

  switch (object) {
    case 'w':
    case 'W':
      return _wordObject(text, o, big: object == 'W', inner: inner);
    case 'p':
      return _paragraphObject(text, o, inner: inner);
    case '"':
    case "'":
    case '`':
      final pair = _enclosingQuote(text, o, object);
      if (pair == null) return null;
      if (inner) return VimRange(pair.open + 1, pair.close);
      var end = pair.close + 1;
      while (_isSpaceOrTab(text, end)) {
        end++;
      }
      return VimRange(pair.open, end);
    case '(':
    case ')':
    case 'b':
      return _bracketObject(text, o, '(', ')', inner: inner);
    case '{':
    case '}':
    case 'B':
      return _bracketObject(text, o, '{', '}', inner: inner);
    case '[':
    case ']':
      return _bracketObject(text, o, '[', ']', inner: inner);
    case '<':
    case '>':
      return _bracketObject(text, o, '<', '>', inner: inner);
    default:
      return null;
  }
}

VimRange? _bracketObject(
  String text,
  int offset,
  String open,
  String close, {
  required bool inner,
}) {
  final pair = _enclosingPair(text, offset, open, close);
  if (pair == null) return null;
  return inner
      ? VimRange(pair.open + 1, pair.close)
      : VimRange(pair.open, pair.close + 1);
}

VimRange _wordObject(
  String text,
  int offset, {
  required bool big,
  required bool inner,
}) {
  final cls = _classAt(text, offset, big);
  var start = offset;
  var end = offset;
  while (start > 0 && _classAt(text, start - 1, big) == cls) {
    start--;
  }
  while (end + 1 < text.length && _classAt(text, end + 1, big) == cls) {
    end++;
  }
  end++; // half-open

  if (inner) return VimRange(start, end);

  // `aw` swallows the whitespace after the word; when there is none (end of
  // line/document) it swallows the whitespace before it instead.
  var outerEnd = end;
  while (_isSpaceOrTab(text, outerEnd)) {
    outerEnd++;
  }
  if (outerEnd != end) return VimRange(start, outerEnd);
  var outerStart = start;
  while (outerStart > 0 && _isSpaceOrTab(text, outerStart - 1)) {
    outerStart--;
  }
  return VimRange(outerStart, end);
}

VimRange _paragraphObject(String text, int offset, {required bool inner}) {
  final onBlank = _isBlankLine(text, vimLineStart(text, offset));
  var startLine = vimLineStart(text, offset);
  while (startLine > 0) {
    final prev = vimLineStart(text, startLine - 1);
    if (_isBlankLine(text, prev) != onBlank) break;
    startLine = prev;
  }
  var endLine = vimLineStart(text, offset);
  while (true) {
    final next = vimLineEnd(text, endLine);
    if (next >= text.length) {
      endLine = text.length;
      break;
    }
    if (_isBlankLine(text, next + 1) != onBlank) {
      endLine = next + 1;
      break;
    }
    endLine = next + 1;
  }

  if (inner) return VimRange(startLine, endLine, linewise: true);

  // `ap` extends through the blank lines that follow the paragraph.
  var end = endLine;
  while (end < text.length && _isBlankLine(text, end) != onBlank) {
    final lineEnd = vimLineEnd(text, end);
    if (lineEnd >= text.length) {
      end = text.length;
      break;
    }
    end = lineEnd + 1;
  }
  return VimRange(startLine, end, linewise: true);
}

// ---------------------------------------------------------------------------
// Line-range helpers for operators
// ---------------------------------------------------------------------------

/// Expands an arbitrary span into whole lines, including each line's trailing
/// newline so `dd` removes the line break along with the text.
///
/// The range stops at [String.length] on the last line, which has no newline
/// to include — deleting it would then leave the *previous* line's break
/// dangling as an empty final line, so the delete operator (and only the
/// delete operator, not yank) applies [vimAbsorbPrecedingNewline] on top.
VimRange vimLinewiseRange(String text, int startOffset, int endOffset) {
  final lo = math.min(startOffset, endOffset);
  final hi = math.max(startOffset, endOffset);
  return VimRange(
    vimLineStart(text, lo),
    vimLineEndInclusive(text, hi),
    linewise: true,
  );
}

/// The `[start, end)` span covering [count] whole lines from [offset]'s line.
VimRange vimLineSpan(String text, int offset, int count) {
  final start = vimLineStart(text, offset);
  var end = start;
  for (var i = 0; i < count; i++) {
    final lineEnd = vimLineEnd(text, end);
    if (lineEnd >= text.length) {
      end = text.length;
      break;
    }
    end = lineEnd + 1;
  }
  return VimRange(start, end, linewise: true);
}

/// Extends a linewise range backwards over the newline that precedes it, when
/// the range runs to the end of the document.
///
/// Only a *deletion* wants this: `dd` on the final line must take the break
/// that used to separate it from the line above, or the buffer keeps a blank
/// last line. A yank of the same range must not, or the register would start
/// with a stray newline.
VimRange vimAbsorbPrecedingNewline(String text, VimRange range) {
  if (range.end < text.length) return range;
  if (range.start <= 0) return range;
  return VimRange(range.start - 1, range.end, linewise: range.linewise);
}

// ---------------------------------------------------------------------------
// Text transformations
// ---------------------------------------------------------------------------

/// Number of spaces one `>>` step adds. Two matches the surrounding Dart and
/// Markdown this app is mostly used to write.
const int kVimShiftWidth = 2;

/// Indents (or with [indent] false, dedents) every line the span touches.
/// Returns the new text plus the caret's new resting offset.
({String text, int caret}) vimShiftLines(
  String text,
  int startOffset,
  int endOffset, {
  required bool indent,
  int count = 1,
}) {
  final firstLine = vimLineStart(text, math.min(startOffset, endOffset));
  final lastLineEnd = vimLineEnd(text, math.max(startOffset, endOffset));
  final prefix = text.substring(0, firstLine);
  final body = text.substring(firstLine, lastLineEnd);
  final suffix = text.substring(lastLineEnd);
  final pad = ' ' * (kVimShiftWidth * count);

  final lines = body.split('\n');
  final shifted = lines.map((line) {
    if (indent) {
      if (line.isEmpty) return line; // Vim leaves empty lines alone
      return '$pad$line';
    }
    var removed = 0;
    var i = 0;
    while (i < line.length && removed < pad.length) {
      final c = line.codeUnitAt(i);
      if (c == _kSpace) {
        removed++;
        i++;
      } else if (c == _kTab) {
        removed += kVimShiftWidth;
        i++;
      } else {
        break;
      }
    }
    return line.substring(i);
  }).toList();

  final newBody = shifted.join('\n');
  final newText = '$prefix$newBody$suffix';
  final caret = vimFirstNonBlank(newText, firstLine);
  return (text: newText, caret: caret);
}

/// Vim's `J`: joins [count] following lines onto the caret's line, collapsing
/// the break plus the next line's indentation into a single space (no space
/// when the next line starts with `)` or is empty). Returns the caret offset
/// at the join seam, which is where Vim leaves it.
({String text, int caret}) vimJoinLines(String text, int offset, int count) {
  var result = text;
  var caret = offset;
  final joins = math.max(1, count);
  for (var i = 0; i < joins; i++) {
    final lineEnd = vimLineEnd(result, caret);
    if (lineEnd >= result.length) break;
    var nextStart = lineEnd + 1;
    while (_isSpaceOrTab(result, nextStart)) {
      nextStart++;
    }
    var trimmedEnd = lineEnd;
    while (trimmedEnd > vimLineStart(result, lineEnd) &&
        _isSpaceOrTab(result, trimmedEnd - 1)) {
      trimmedEnd--;
    }
    final nextIsEmpty =
        nextStart >= result.length || _isNewline(result, nextStart);
    final nextChar = nextStart < result.length ? result[nextStart] : '';
    final separator =
        (nextIsEmpty ||
            nextChar == ')' ||
            trimmedEnd == vimLineStart(result, lineEnd))
        ? ''
        : ' ';
    caret = trimmedEnd;
    result =
        result.substring(0, trimmedEnd) +
        separator +
        result.substring(nextStart);
  }
  return (text: result, caret: caret);
}

enum VimCaseOp { toLower, toUpper, toggle }

String vimApplyCase(String source, VimCaseOp op) {
  switch (op) {
    case VimCaseOp.toLower:
      return source.toLowerCase();
    case VimCaseOp.toUpper:
      return source.toUpperCase();
    case VimCaseOp.toggle:
      final buffer = StringBuffer();
      for (final char in source.split('')) {
        final lower = char.toLowerCase();
        buffer.write(char == lower ? char.toUpperCase() : lower);
      }
      return buffer.toString();
  }
}

// ---------------------------------------------------------------------------
// Search (/ n N)
// ---------------------------------------------------------------------------

/// All match offsets for [pattern], using Vim's "smartcase" rule: an
/// all-lowercase pattern matches case-insensitively, any uppercase character
/// makes the search case-sensitive.
///
/// This is the one whole-document scan in this library. It's run once per
/// keystroke while the `/` bar is open and once per `n`/`N`, on plain
/// [String.indexOf] — microseconds even for a long journal entry — and the
/// caller caches the result until the text changes.
///
/// [foldedText] is `text.toLowerCase()`, when the caller already has it. The
/// scan itself is cheap; folding the document to run it is not, and the
/// pattern changes on every keystroke of the `/` bar, so a caller that keeps
/// the folded copy across those keystrokes turns a per-keystroke allocation of
/// the whole document into one [String.indexOf] sweep.
List<int> vimSearchMatches(String text, String pattern, {String? foldedText}) {
  if (pattern.isEmpty || text.isEmpty) return const [];
  final caseSensitive = pattern != pattern.toLowerCase();
  final haystack = caseSensitive ? text : (foldedText ?? text.toLowerCase());
  final needle = caseSensitive ? pattern : pattern.toLowerCase();

  final matches = <int>[];
  var from = 0;
  while (true) {
    final idx = haystack.indexOf(needle, from);
    if (idx < 0) break;
    matches.add(idx);
    from = idx + 1;
  }
  return matches;
}

/// Index into [matches] of the next match strictly after [offset], wrapping to
/// the top of the document. Null when there are no matches.
int? vimNextMatchIndex(List<int> matches, int offset, {required bool forward}) {
  if (matches.isEmpty) return null;
  if (forward) {
    for (var i = 0; i < matches.length; i++) {
      if (matches[i] > offset) return i;
    }
    return 0;
  }
  for (var i = matches.length - 1; i >= 0; i--) {
    if (matches[i] < offset) return i;
  }
  return matches.length - 1;
}
