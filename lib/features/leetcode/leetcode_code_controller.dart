import 'package:flutter/material.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:voyager/core/text/newline_normalization.dart';

/// Modifiers [CodeController] ships with, minus [CloseBlockModifier].
///
/// That stock modifier outdents on `}` by rewriting several characters, but
/// [CodeController.value] then misreads the edit as a one-character backspace
/// (`EditType.backspaceBeforeCollapsedSelection`) and keeps only a single
/// deleted space — so `}` never appears and indent is eaten one keypress at a
/// time. Smart close is applied in [LeetCodeCodeController] instead.
List<CodeModifier> leetCodeCodeModifiers() => [
      for (final modifier in CodeController.defaultCodeModifiers)
        if (modifier is! CloseBlockModifier) modifier,
    ];

/// [CodeController] with correct `}` outdent, Enter-between-braces splitting,
/// VS Code's auto-close/overtype/surround rules, and no broken
/// [CloseBlockModifier].
class LeetCodeCodeController extends CodeController {
  LeetCodeCodeController({
    String? text,
    super.language,
    super.params,
  }) : super(
          text: text == null ? null : normalizeNewlines(text),
          modifiers: leetCodeCodeModifiers(),
        );

  @override
  set value(TextEditingValue newValue) {
    final current = super.value;
    // `\r` never reaches the buffer: every offset below counts a line break as
    // one character. See [normalizeNewlinesInValue].
    final incoming = normalizeNewlinesInValue(newValue);
    final adjusted = applyLeetCodeCodeEdits(
      current: current,
      incoming: incoming,
      tabSpaces: params.tabSpaces,
    );
    if (adjusted == null) {
      super.value = preferUpstreamAffinityAtLineBreak(incoming);
      return;
    }
    _setRewrittenValue(preferUpstreamAffinityAtLineBreak(adjusted));
  }

  /// Assigns a value this controller computed itself.
  ///
  /// [CodeController.value] does not store the value it is handed: it diffs it
  /// against the previous one and rebuilds the text from that diff. The diff
  /// classifies by length and caret arithmetic alone, so any of the edits here
  /// that replace several characters with a shorter run — `    ` becoming `}`,
  /// say — reads to it as a plain backspace, and it reconstructs a single
  /// deleted character instead. Going through [fullText] refreshes the
  /// highlighted [Code] and writes the text straight to
  /// [TextEditingController], skipping that diff; the second assignment then
  /// only moves the caret, which [CodeController] passes through untouched.
  ///
  /// This also skips [CodeController]'s read-only-section check, which is
  /// inert here — this editor declares no named or read-only sections.
  void _setRewrittenValue(TextEditingValue next) {
    if (next.text != super.value.text) {
      fullText = next.text;
    }
    super.value = next;
  }
}

/// The finished value for a pending edit this editor handles itself, or null
/// when the edit is ordinary typing that the stock modifiers should handle.
///
/// Null is the whole signal: a non-null result goes to
/// [LeetCodeCodeController._setRewrittenValue], which is also what keeps the
/// auto-close modifier from running. That matters for [_suppressAutoClose],
/// whose result is the *plain* insert and so would otherwise be
/// indistinguishable from "nothing to do".
@visibleForTesting
TextEditingValue? applyLeetCodeCodeEdits({
  required TextEditingValue current,
  required TextEditingValue incoming,
  required int tabSpaces,
}) {
  final closed = _smartCloseBrace(
    current: current,
    incoming: incoming,
    tabSpaces: tabSpaces,
  );
  if (closed != null) return closed;

  final skipped = _overtypeCloser(current: current, incoming: incoming);
  if (skipped != null) return skipped;

  final bare = _suppressAutoClose(current: current, incoming: incoming);
  if (bare != null) return bare;

  final surrounded = _surroundSelection(current: current, incoming: incoming);
  if (surrounded != null) return surrounded;

  final entered = _smartEnterBetweenPair(
    current: current,
    incoming: incoming,
    tabSpaces: tabSpaces,
  );
  if (entered != null) return entered;

  final emptied = _deleteEmptyPair(current: current, incoming: incoming);
  if (emptied != null) return emptied;

  return null;
}

/// Flutter paints a caret that sits *on* a `\n` with
/// [TextAffinity.downstream] at the start of the next line. After a
/// type-then-backspace at end-of-line the selection often lands that way, so
/// the caret appears to jump down and the next backspace deletes the newline
/// (the "empty line below") instead of the character the user still sees as
/// selected. Prefer upstream affinity whenever the caret is on a line break.
@visibleForTesting
TextEditingValue preferUpstreamAffinityAtLineBreak(TextEditingValue value) {
  final sel = value.selection;
  if (!sel.isValid || !sel.isCollapsed) return value;
  final offset = sel.baseOffset;
  if (offset < 0 || offset >= value.text.length) return value;
  if (value.text[offset] != '\n') return value;
  if (sel.affinity == TextAffinity.upstream) return value;
  return value.copyWith(
    selection: TextSelection.collapsed(
      offset: offset,
      affinity: TextAffinity.upstream,
    ),
  );
}

/// Openers the editor auto-closes, and what it closes them with. Mirrors the
/// [InsertionCodeModifier]s [CodeController] is configured with, which is what
/// puts the closer in the buffer in the first place.
const _pairs = <String, String>{
  '(': ')',
  '[': ']',
  '{': '}',
  '"': '"',
  "'": "'",
  '`': '`',
};

/// Letters, digits and identifier punctuation, in any script — the class
/// auto-closing backs off around. Unicode-aware because the text a `'` gets
/// typed next to is as often a comment as an identifier.
final _wordChar = RegExp(r'[\p{L}\p{N}_$]', unicode: true);

bool _isWordChar(String char) => _wordChar.hasMatch(char);

/// Single-character insert of [char] at a collapsed caret, or null.
({int at, String char})? _singleInsert(
  TextEditingValue current,
  TextEditingValue incoming,
) {
  final sel = current.selection;
  if (!sel.isCollapsed || !sel.isValid) return null;
  if (incoming.text.length != current.text.length + 1) return null;
  if (!incoming.selection.isCollapsed) return null;
  if (incoming.selection.baseOffset != sel.start + 1) return null;
  final inserted = incoming.text.substring(sel.start, sel.start + 1);
  // The rest of the string must be unchanged around the insert point.
  if (incoming.text.substring(0, sel.start) !=
      current.text.substring(0, sel.start)) {
    return null;
  }
  if (incoming.text.substring(sel.start + 1) !=
      current.text.substring(sel.start)) {
    return null;
  }
  return (at: sel.start, char: inserted);
}

/// Single character [char] typed over the non-empty selection
/// `[start, end)`, or null.
({int start, int end, String char, bool reversed})? _typedOverSelection(
  TextEditingValue current,
  TextEditingValue incoming,
) {
  final sel = current.selection;
  if (!sel.isValid || sel.isCollapsed) return null;
  final start = sel.start;
  final end = sel.end;
  if (incoming.text.length != current.text.length - (end - start) + 1) {
    return null;
  }
  if (!incoming.selection.isCollapsed) return null;
  if (incoming.selection.baseOffset != start + 1) return null;
  if (incoming.text.substring(0, start) != current.text.substring(0, start)) {
    return null;
  }
  if (incoming.text.substring(start + 1) != current.text.substring(end)) {
    return null;
  }
  return (
    start: start,
    end: end,
    char: incoming.text.substring(start, start + 1),
    reversed: sel.baseOffset > sel.extentOffset,
  );
}

/// Single-character backspace at a collapsed caret, or null. [at] is where the
/// caret was *before* the delete, so the character removed is `at - 1`.
({int at})? _singleBackspace(
  TextEditingValue current,
  TextEditingValue incoming,
) {
  final sel = current.selection;
  if (!sel.isCollapsed || !sel.isValid || sel.start == 0) return null;
  if (incoming.text.length != current.text.length - 1) return null;
  if (!incoming.selection.isCollapsed) return null;
  if (incoming.selection.baseOffset != sel.start - 1) return null;
  if (incoming.text.substring(0, sel.start - 1) !=
      current.text.substring(0, sel.start - 1)) {
    return null;
  }
  if (incoming.text.substring(sel.start - 1) !=
      current.text.substring(sel.start)) {
    return null;
  }
  return (at: sel.start);
}

TextEditingValue? _smartCloseBrace({
  required TextEditingValue current,
  required TextEditingValue incoming,
  required int tabSpaces,
}) {
  final insert = _singleInsert(current, incoming);
  if (insert == null || insert.char != '}') return null;

  final text = current.text;
  final at = insert.at;
  // A closer already sitting at the caret is the one this keystroke means —
  // step over it rather than adding a second. Only *at* the caret: a `}` on
  // some later line belongs to an outer block the user is not closing here,
  // and swallowing it silently unbalances the file.
  final overtype = at < text.length && text[at] == '}';

  final lineStart = _lineStart(text, at);
  final prefix = text.substring(lineStart, at);
  if (prefix.isNotEmpty && !_isSpacesOnly(prefix)) {
    // Mid-line `}` — nothing to re-indent, so only the overtype applies.
    if (overtype) {
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: at + 1),
      );
    }
    return null;
  }

  final matchIndent = _matchingOpenIndent(text, at);
  final targetIndent = matchIndent ?? _outdentByTab(prefix.length, tabSpaces);

  final replacement = '${' ' * targetIndent}}';
  final next = text.replaceRange(
    lineStart,
    overtype ? at + 1 : at,
    replacement,
  );
  final caret = lineStart + replacement.length;
  return TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: caret),
  );
}

/// Typing a closer that is already at the caret steps over it instead of
/// doubling it — the pair was auto-inserted, and typing it out is how anyone
/// who is not watching for that closes the block.
///
/// `}` is excluded because [_smartCloseBrace] handles it, overtype included:
/// that one also has to re-indent the line it lands on.
TextEditingValue? _overtypeCloser({
  required TextEditingValue current,
  required TextEditingValue incoming,
}) {
  final insert = _singleInsert(current, incoming);
  if (insert == null) return null;
  final char = insert.char;
  if (char == '}' || !_pairs.containsValue(char)) return null;

  final text = current.text;
  final at = insert.at;
  if (at >= text.length || text[at] != char) return null;
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: at + 1),
  );
}

/// Typing an opener where a closer would only be in the way inserts the bare
/// character, leaving [InsertionCodeModifier] out of it.
///
/// Two rules, both VS Code's:
///  - Nothing auto-closes directly before a word character. `foo|bar` typing
///    `(` means "wrap what follows", and `foo(|)bar` is never that.
///  - A quote directly *after* a word character is an apostrophe, not the
///    start of a string. This is the `don't` case, and in a Python file it
///    comes up in every other comment.
///
/// Returning the plain insert is not a no-op: it is what routes the edit
/// around the modifier — see [applyLeetCodeCodeEdits].
TextEditingValue? _suppressAutoClose({
  required TextEditingValue current,
  required TextEditingValue incoming,
}) {
  final insert = _singleInsert(current, incoming);
  if (insert == null) return null;
  final closer = _pairs[insert.char];
  if (closer == null) return null;

  final text = current.text;
  final at = insert.at;
  final nextIsWord = at < text.length && _isWordChar(text[at]);
  // Only a quote — where the same character opens and closes — reads as an
  // apostrophe when it follows a word.
  final apostrophe = closer == insert.char &&
      at > 0 &&
      _isWordChar(text[at - 1]);
  if (!nextIsWord && !apostrophe) return null;

  return incoming;
}

/// Typing a pair character over a selection wraps it instead of replacing it.
///
/// The selection survives on the text now inside the pair, so a second
/// keystroke wraps again — which is how nesting a quote inside a call gets
/// done in one gesture.
TextEditingValue? _surroundSelection({
  required TextEditingValue current,
  required TextEditingValue incoming,
}) {
  final typed = _typedOverSelection(current, incoming);
  if (typed == null) return null;
  final closer = _pairs[typed.char];
  if (closer == null) return null;

  final text = current.text;
  final inner = text.substring(typed.start, typed.end);
  final base = typed.start + 1;
  final extent = base + inner.length;
  return TextEditingValue(
    text: text.replaceRange(
      typed.start,
      typed.end,
      '${typed.char}$inner$closer',
    ),
    selection: typed.reversed
        ? TextSelection(baseOffset: extent, extentOffset: base)
        : TextSelection(baseOffset: base, extentOffset: extent),
  );
}

/// Enter pressed between an auto-paired opener and its closer opens the block:
/// a blank indented line for the caret, with the closer pushed down onto its
/// own line at the opener's indent.
///
/// Quote pairs are left alone — a line break inside `"|"` is not a block.
TextEditingValue? _smartEnterBetweenPair({
  required TextEditingValue current,
  required TextEditingValue incoming,
  required int tabSpaces,
}) {
  final insert = _singleInsert(current, incoming);
  if (insert == null || insert.char != '\n') return null;

  final text = current.text;
  final at = insert.at;
  if (at == 0 || at >= text.length) return null;
  final opener = text[at - 1];
  final closer = _pairs[opener];
  if (closer == null || closer == opener || text[at] != closer) return null;

  final openLineStart = _lineStart(text, at - 1);
  var outerIndent = 0;
  while (openLineStart + outerIndent < at - 1 &&
      text[openLineStart + outerIndent] == ' ') {
    outerIndent++;
  }
  final inner = ' ' * (outerIndent + tabSpaces);
  final outer = ' ' * outerIndent;
  final replacement = '\n$inner\n$outer';
  final next = text.replaceRange(at, at, replacement);
  final caret = at + 1 + inner.length;
  return TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: caret),
  );
}

/// Backspacing the opener of an empty pair takes the closer with it, so
/// undoing an auto-insert never leaves the orphan `)` behind.
TextEditingValue? _deleteEmptyPair({
  required TextEditingValue current,
  required TextEditingValue incoming,
}) {
  final backspace = _singleBackspace(current, incoming);
  if (backspace == null) return null;

  final text = current.text;
  final at = backspace.at;
  if (at >= text.length) return null;
  final closer = _pairs[text[at - 1]];
  if (closer == null || text[at] != closer) return null;

  return TextEditingValue(
    text: text.replaceRange(at - 1, at + 1, ''),
    selection: TextSelection.collapsed(offset: at - 1),
  );
}

int _lineStart(String text, int offset) {
  if (offset <= 0) return 0;
  final i = text.lastIndexOf('\n', offset - 1);
  return i < 0 ? 0 : i + 1;
}

bool _isSpacesOnly(String s) {
  for (var i = 0; i < s.length; i++) {
    if (s[i] != ' ') return false;
  }
  return true;
}

int _outdentByTab(int spaces, int tabSpaces) {
  if (spaces <= 0) return 0;
  if (spaces >= tabSpaces) return spaces - tabSpaces;
  return 0;
}

/// Indent of the line that holds the `{` matching a closer at [closeAt].
int? _matchingOpenIndent(String text, int closeAt) {
  var depth = 0;
  for (var i = closeAt - 1; i >= 0; i--) {
    final ch = text[i];
    if (ch == '}') {
      depth++;
    } else if (ch == '{') {
      if (depth == 0) {
        final start = _lineStart(text, i);
        var indent = 0;
        while (start + indent < i && text[start + indent] == ' ') {
          indent++;
        }
        return indent;
      }
      depth--;
    }
  }
  return null;
}
