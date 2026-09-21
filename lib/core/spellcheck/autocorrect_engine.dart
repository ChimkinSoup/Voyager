import 'dart:ui' show TextRange;

import 'package:flutter/services.dart' show TextSelection;

import 'package:voyager/core/spellcheck/word_token.dart';

/// The pure half of autocorrect: which typos have an unambiguous fix, where a
/// word token sits, and which keystrokes finish a word.
///
/// Which *spans* are off limits is not here any more: `#tag`, `` `code` `` and
/// `$…$` are exclusion zones in `ProseMarkup`, so autocorrect and emphasis
/// agree on them by construction rather than by two implementations happening
/// to (EMPHASIS_FORMATTING.md §6.2).
///
/// Nothing here reads a controller, a setting or a clock — `AutocorrectSession`
/// owns all of that. See AUTOCORRECT.md §3 and §4.

/// Shortest token autocorrect will look at (AUTOCORRECT.md §2).
///
/// Two-letter typos are almost all one edit away from several real words
/// (`fo` → `of`, `so`, `for`, `fog`…), so they would fail the uniqueness rule
/// below anyway. The floor makes that cheap rather than merely certain.
const int kMinAutocorrectLength = 3;

/// The characters that complete a word (AUTOCORRECT.md §2).
///
/// Tab is deliberately absent: it inserts nothing in Voyager's fields — it
/// advances a snippet tabstop, indents a list line, or moves focus — so there
/// is no boundary keystroke for the gate to hang on. `-` and `_` are absent
/// for the opposite reason: they are *inside* words as far as the reader is
/// concerned, and splitting on them would autocorrect the halves of a
/// hyphenated word separately.
///
/// `*` is here because it closes emphasis (EMPHASIS_FORMATTING.md §6.2), and
/// it can be a plain boundary character because it is never inside a word:
/// `*wtih*` and `**wtih**` both finish the word on the first closing `*`.
const String kAutocorrectBoundaryChars = ' \n.,!?;:*';

bool isAutocorrectBoundary(String character) =>
    character.length == 1 && kAutocorrectBoundaryChars.contains(character);

/// The delimiter characters that finish a word only once the **pair** is
/// complete (EMPHASIS_FORMATTING.md §6.2).
///
/// `_` and `=` have no single-character emphasis form, and both turn up in
/// ordinary text on their own — `snake_case`, `x = 5` — so neither can join
/// [kAutocorrectBoundaryChars]. Only the second character of `__` or `==`
/// counts, and only when the word ends where the run begins.
const String kPairedBoundaryChars = '_=';

/// Where a word has to end for the character just typed at [at] to have
/// completed it, or null when that character completes nothing.
///
/// [at] for an ordinary boundary character; one offset earlier for the second
/// half of a `__` or `==` closer, since the word it finishes ends before the
/// pair rather than before the keystroke.
int? autocorrectBoundaryTokenEnd(String text, int at) {
  if (at < 0 || at >= text.length) return null;
  final character = text[at];
  if (isAutocorrectBoundary(character)) return at;
  if (!kPairedBoundaryChars.contains(character)) return null;
  if (at == 0 || text[at - 1] != character) return null;
  return at - 1;
}

/// Whether [offset] sits inside a run of one [kPairedBoundaryChars] character
/// beginning exactly at [tokenEnd].
///
/// This is the half-typed `__`: the word before it has to stay the tracked
/// token across the first `_` so that the second one can finish it. Nothing
/// else keeps a token alive once the caret has left it.
bool isInPendingCloser(String text, int tokenEnd, int offset) {
  if (tokenEnd < 0 || offset <= tokenEnd || offset > text.length) return false;
  if (tokenEnd >= text.length) return false;
  final opener = text[tokenEnd];
  if (!kPairedBoundaryChars.contains(opener)) return false;
  for (var i = tokenEnd + 1; i < offset; i++) {
    if (text[i] != opener) return false;
  }
  return true;
}

/// The correction for [token], or null when there isn't an unambiguous one.
///
/// The cascade is transpose → delete → insert, and each step must find
/// **exactly one** known word or the whole thing gives up (AUTOCORRECT.md
/// §3.1). Substituting one letter for another is not in the model at all:
/// `from` → `form`, `then` → `than` and `cat` → `car` are all a single
/// replacement apart, and each is a word the user might well have meant.
///
/// Uniqueness is counted over distinct *results*, not distinct edits — two
/// deletions of the same doubled letter produce one candidate word, not two.
String? autocorrectFor(String token, Set<String> known) {
  final lower = token.toLowerCase();
  if (lower.length < kMinAutocorrectLength) return null;
  // A word the dictionary already knows is not a typo, whatever else it is
  // one edit away from (AUTOCORRECT.md §4.5) — including a possessive, which
  // the bundled list has no entries for and which `dogs` sits one deletion
  // away from.
  if (isKnownWord(lower, known)) return null;
  return _onlyKnown(_transpositions(lower), known) ??
      _onlyKnown(_deletions(lower), known) ??
      _onlyKnown(_insertions(lower), known);
}

/// First-letter case preservation, and nothing else (AUTOCORRECT.md §2).
///
/// `Wtih` → `With`, `wtih` → `with`. The rest of the correction is left as the
/// dictionary spells it: a typo carries no information about how the letters
/// after the first were meant to be cased, and a mid-word capital in prose is
/// far more often a slip than an intention.
String applyAutocorrectCase(String typo, String correction) {
  if (typo.isEmpty || correction.isEmpty) return correction;
  final first = typo[0];
  // Guards the uncased characters a token can start with — an apostrophe has
  // the same upper and lower case, and is not a capital letter.
  if (first == first.toLowerCase() || first != first.toUpperCase()) {
    return correction;
  }
  return correction[0].toUpperCase() + correction.substring(1);
}

/// Whether [token] is an acronym as far as §4.6 is concerned: nothing but
/// capitals. Deliberately not applied to a token holding an apostrophe or a
/// digit, matching the spec's `^[A-Z]+$`.
bool isAllCapsToken(String token) {
  if (token.length < kMinAutocorrectLength) return false;
  for (var i = 0; i < token.length; i++) {
    final unit = token.codeUnitAt(i);
    if (unit < 0x41 || unit > 0x5A) return false;
  }
  return true;
}

/// The single known word in [candidates], or null when there are none or
/// several. Stops as soon as a second distinct one turns up.
String? _onlyKnown(Iterable<String> candidates, Set<String> known) {
  String? found;
  for (final candidate in candidates) {
    if (!known.contains(candidate)) continue;
    if (found == null) {
      found = candidate;
    } else if (found != candidate) {
      return null;
    }
  }
  return found;
}

Iterable<String> _transpositions(String word) sync* {
  for (var i = 0; i + 1 < word.length; i++) {
    if (word.codeUnitAt(i) == word.codeUnitAt(i + 1)) continue;
    yield word.substring(0, i) + word[i + 1] + word[i] + word.substring(i + 2);
  }
}

Iterable<String> _deletions(String word) sync* {
  for (var i = 0; i < word.length; i++) {
    yield word.substring(0, i) + word.substring(i + 1);
  }
}

Iterable<String> _insertions(String word) sync* {
  for (var i = 0; i <= word.length; i++) {
    final left = word.substring(0, i);
    final right = word.substring(i);
    for (var unit = 0x61; unit <= 0x7A; unit++) {
      yield left + String.fromCharCode(unit) + right;
    }
  }
}

/// The word token [offset] sits in or against, or null when there is no word
/// there.
///
/// Same shape as `wordTokenPattern`: letters, with apostrophes allowed between
/// them so `don't` is one token. An offset at either end of a word counts as
/// inside it — the caret after the last letter is still in the word being
/// typed.
TextRange? autocorrectTokenAt(String text, int offset) {
  if (offset < 0 || offset > text.length) return null;
  // An apostrophe is only ever *between* two letters, which is what
  // `wordTokenPattern` says too: `don't` is one token, `don''t` is two. Walked
  // rather than trimmed afterwards, because a trim cannot tell which side of a
  // doubled apostrophe the offset was on.
  var start = offset;
  while (start > 0) {
    final unit = text.codeUnitAt(start - 1);
    if (_isLetter(unit)) {
      start--;
    } else if (unit == 0x27 &&
        start >= 2 &&
        _isLetter(text.codeUnitAt(start - 2))) {
      start -= 2;
    } else {
      break;
    }
  }
  var end = offset;
  while (end < text.length) {
    final unit = text.codeUnitAt(end);
    if (_isLetter(unit)) {
      end++;
    } else if (unit == 0x27 &&
        end + 1 < text.length &&
        _isLetter(text.codeUnitAt(end + 1))) {
      end += 2;
    } else {
      break;
    }
  }
  // Apostrophes only count between letters, so any at the edges belong to the
  // punctuation around the word rather than to the word.
  while (start < end && !_isLetter(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && !_isLetter(text.codeUnitAt(end - 1))) {
    end--;
  }
  if (start >= end) return null;
  return TextRange(start: start, end: end);
}

/// Whether [start]–[end] is only the ASCII part of a longer word.
///
/// [_isLetter] is ASCII-only, so `café` splits into `caf` and a token nobody
/// can see the start of, and typing `caféwtih` leaves `wtih` looking like a
/// whole word. `wordTokenPattern` splits it the same way, so this is the app's
/// existing tokenisation rather than a new divergence — but the consequence
/// differs in kind. A squiggle under a fragment is a mark the reader can
/// ignore; rewriting one silently changes a word they did not offer.
///
/// Only the BMP is covered: a letter from a supplementary plane arrives as a
/// surrogate half, which no letter class matches, and the correction goes
/// ahead. That is the pre-existing behaviour, and the whole point of this
/// check is the accented Latin that actually turns up in prose.
bool isAsciiWordFragment(String text, int start, int end) =>
    _isLetterLikeNonAscii(text, start - 1) || _isLetterLikeNonAscii(text, end);

/// Whether [start]–[end] is part of a longer alphanumeric run — the `enc` of
/// `x264enc`, the `D` of `3D`.
///
/// `tokenizeWords` drops a run holding a digit whole (`runHasDigit`), so there
/// is no squiggle under any of it: a model number or an identifier is not
/// prose. Correcting a piece of one would rewrite the very text spell-check
/// deliberately has no opinion about, and `autocorrectTokenAt` stops at a
/// digit rather than seeing the run.
bool isInAlphanumericRun(String text, int start, int end) {
  for (var i = start - 1; i >= 0 && _isRunChar(text.codeUnitAt(i)); i--) {
    if (_isDigit(text.codeUnitAt(i))) return true;
  }
  for (var i = end; i < text.length && _isRunChar(text.codeUnitAt(i)); i++) {
    if (_isDigit(text.codeUnitAt(i))) return true;
  }
  return false;
}

/// A character `wordRunPattern` can carry: a letter, a digit, or the
/// apostrophe that holds `XM6's` together as one run.
bool _isRunChar(int unit) => _isLetter(unit) || _isDigit(unit) || unit == 0x27;

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

final RegExp _unicodeLetter = RegExp(r'[\p{L}\p{M}]', unicode: true);

bool _isLetterLikeNonAscii(String text, int index) {
  if (index < 0 || index >= text.length) return false;
  if (text.codeUnitAt(index) < 0x80) return false;
  return _unicodeLetter.hasMatch(text[index]);
}

bool _isLetter(int unit) =>
    (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);

/// One edit, recovered from the text either side of it as a single replaced
/// span: common prefix, common suffix, and whatever differs between them.
///
/// Not the true minimal diff for every conceivable rewrite, but exact for the
/// edits that reach a focused field — typing, backspace, a paste at the caret
/// — and [selection] settles the cases the two strings cannot. Typing an `e`
/// in front of an `e` produces exactly the same text as typing one behind it,
/// and the prefix scan always reads it as the latter. Same recovery as
/// `SnippetSession._absorbEdit`, which needs it for the same reason.
({int at, int removed, int inserted}) autocorrectEditSpan(
  String old,
  String next,
  TextSelection selection,
) {
  var prefix = 0;
  final maxPrefix = old.length < next.length ? old.length : next.length;
  while (prefix < maxPrefix &&
      old.codeUnitAt(prefix) == next.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  final maxSuffix = maxPrefix - prefix;
  while (suffix < maxSuffix &&
      old.codeUnitAt(old.length - 1 - suffix) ==
          next.codeUnitAt(next.length - 1 - suffix)) {
    suffix++;
  }
  final removed = old.length - prefix - suffix;
  final inserted = next.length - prefix - suffix;

  var at = prefix;
  if (selection.isValid && selection.isCollapsed) {
    final candidate = selection.baseOffset - inserted;
    if (candidate >= 0 && candidate < at) {
      // Accepted only if it explains the same text: everything from there to
      // the prefix has to survive being shifted by the edit.
      var explains = true;
      for (var i = candidate; i < prefix; i++) {
        if (old.codeUnitAt(i + removed) != next.codeUnitAt(i + inserted)) {
          explains = false;
          break;
        }
      }
      if (explains) at = candidate;
    }
  }
  return (at: at, removed: removed, inserted: inserted);
}

/// Re-anchors [range] across [edit], or null when the edit reached across one
/// of its edges.
///
/// Both callers want that null. For the token being typed it means a token
/// half-rewritten by something other than typing, which is no longer a token
/// the user typed; for the flash it means the word it was drawn around is
/// gone, and the highlight has nothing left to sit behind.
TextRange? mapRangeAcrossEdit(
  TextRange range,
  ({int at, int removed, int inserted}) edit,
) {
  final end = edit.at + edit.removed;
  final delta = edit.inserted - edit.removed;
  if (end <= range.start) {
    return TextRange(start: range.start + delta, end: range.end + delta);
  }
  if (edit.at >= range.end) return range;
  if (edit.at >= range.start && end <= range.end) {
    final newEnd = range.end + delta;
    return newEnd > range.start
        ? TextRange(start: range.start, end: newEnd)
        : null;
  }
  return null;
}
