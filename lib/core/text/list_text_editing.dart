/// Shared plain-text list editing behavior for multi-line "notes"-style text
/// fields: recognizing `-`/`*` bullet and `1.` numbered list lines, continuing
/// them on Enter and across a pasted block of lines, cleanly exiting an empty
/// list item, renumbering numbered lists after any edit (typing, deleting,
/// reordering, pasting), and indenting/outdenting the current line(s) with
/// Tab / Shift+Tab.
///
/// Callers wire this into an existing [TextEditingController] + [FocusNode]
/// pair; it never owns either. Call [applyListEditing] as the first statement
/// of a field's `onChanged` handler (before any other bookkeeping reads
/// `controller.text`), and call [handleListTab] from the field's
/// `FocusNode.onKeyEvent` when the Tab key is pressed.
library;

import 'package:flutter/widgets.dart';

const String listIndentUnit = '  ';

/// Depth of undo/redo restores currently applying a historical
/// [TextEditingValue]. While > 0, list helpers must not rewrite the
/// controller — Flutter's [UndoHistory] asserts the restored value sticks
/// (`widget.value.value == nextValue` in `undo_history.dart`).
///
/// Set via [suppressListEditingWrites] (Vim `u` / `<C-r>`) or
/// [ListEditingUndoGuard] (Ctrl+Z / Ctrl+Y and platform undo).
int _suppressListEditingWrites = 0;

/// Runs [body] with list-editing controller writes suppressed.
///
/// Use around any call that drives [UndoHistoryController.undo] /
/// [UndoHistoryController.redo] (or the matching intents), so an `onChanged`
/// that calls [applyListEditing] cannot desync UndoHistory mid-restore.
T suppressListEditingWrites<T>(T Function() body) {
  _suppressListEditingWrites++;
  try {
    return body();
  } finally {
    _suppressListEditingWrites--;
  }
}

bool get _listEditingWritesSuppressed => _suppressListEditingWrites > 0;

/// Ancestor [Actions] override so Ctrl+Z / Ctrl+Y (and other
/// [UndoTextIntent] / [RedoTextIntent] sources) suspend list rewriting for
/// the same reason as [suppressListEditingWrites].
///
/// Wrap every [TextField] whose `onChanged` may call [applyListEditing].
class ListEditingUndoGuard extends StatelessWidget {
  const ListEditingUndoGuard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        UndoTextIntent: _SuspendingUndoAction(),
        RedoTextIntent: _SuspendingRedoAction(),
      },
      child: child,
    );
  }
}

final class _SuspendingUndoAction extends Action<UndoTextIntent> {
  @override
  Object? invoke(UndoTextIntent intent) {
    return suppressListEditingWrites(() => callingAction?.invoke(intent));
  }
}

final class _SuspendingRedoAction extends Action<RedoTextIntent> {
  @override
  Object? invoke(RedoTextIntent intent) {
    return suppressListEditingWrites(() => callingAction?.invoke(intent));
  }
}

final RegExp _bulletPattern = RegExp(r'^(\s*)([-*])( +)(.*)$');
final RegExp _numberPattern = RegExp(r'^(\s*)(\d+)\.( +)(.*)$');
// Cheap single-pass check used to skip the full renumbering machinery
// (line-splitting, stack bookkeeping) on every keystroke of documents that
// have no numbered lines at all — the common case for bullet-only notes.
final RegExp _anyNumberedLine = RegExp(r'^\s*\d+\. ', multiLine: true);

class _LineMatch {
  const _LineMatch({
    required this.indent,
    required this.isNumbered,
    required this.marker,
    required this.spacing,
    required this.content,
  });

  final String indent;
  final bool isNumbered;
  final String marker;
  final String spacing;
  final String content;
}

_LineMatch? _matchLine(String line) {
  final bullet = _bulletPattern.firstMatch(line);
  if (bullet != null) {
    return _LineMatch(
      indent: bullet.group(1)!,
      isNumbered: false,
      marker: bullet.group(2)!,
      spacing: bullet.group(3)!,
      content: bullet.group(4)!,
    );
  }
  final number = _numberPattern.firstMatch(line);
  if (number != null) {
    return _LineMatch(
      indent: number.group(1)!,
      isNumbered: true,
      marker: number.group(2)!,
      spacing: number.group(3)!,
      content: number.group(4)!,
    );
  }
  return null;
}

/// Applies Enter-continuation (and clean-exit) plus a full-document numbered
/// list renumbering pass to [controller], if applicable. [previousText] is
/// the controller's text before this change (typically tracked by the
/// caller as a `_lastText`-style field). Returns true if [controller] was
/// mutated, in which case callers should re-read `controller.text` rather
/// than trust whatever raw value they were handed by `TextField.onChanged`.
bool applyListEditing({
  required TextEditingController controller,
  required String previousText,
}) {
  // See [_suppressListEditingWrites] — mutating here during an undo restore
  // trips UndoHistory's post-onTriggered assert.
  if (_listEditingWritesSuppressed) return false;

  var text = controller.text;
  var selection = controller.selection;

  final continued = _applyEnterContinuation(
    text: text,
    selection: selection,
    previousText: previousText,
  );
  if (continued != null) {
    text = continued.text;
    selection = continued.selection;
  } else {
    final pasted = _applyPasteContinuation(
      text: text,
      selection: selection,
      previousText: previousText,
    );
    if (pasted != null) {
      text = pasted.text;
      selection = pasted.selection;
    }
  }

  final renumbered = _renumberDocument(text);
  final finalText = renumbered.text;
  final finalSelection = selection.isValid
      ? TextSelection(
          baseOffset: renumbered.mapOffset(selection.baseOffset),
          extentOffset: renumbered.mapOffset(selection.extentOffset),
        )
      : selection;

  if (finalText == controller.text && finalSelection == controller.selection) {
    return false;
  }

  controller.value = TextEditingValue(
    text: finalText,
    selection: finalSelection,
  );
  return true;
}

class _TextEdit {
  const _TextEdit(this.text, this.selection);
  final String text;
  final TextSelection selection;
}

_TextEdit? _applyEnterContinuation({
  required String text,
  required TextSelection selection,
  required String previousText,
}) {
  if (!selection.isCollapsed || selection.baseOffset <= 0) return null;
  if (text.length != previousText.length + 1) return null;

  final newlineOffset = selection.baseOffset - 1;
  if (newlineOffset <= 0 ||
      newlineOffset >= text.length ||
      text[newlineOffset] != '\n') {
    return null;
  }

  final previousLineStart = text.lastIndexOf('\n', newlineOffset - 1) + 1;
  final previousLine = text.substring(previousLineStart, newlineOffset);
  final match = _matchLine(previousLine);
  if (match == null) return null;

  final content = match.content;
  final String insert;
  final int replacementStart;
  if (content.trim().isEmpty) {
    // Empty list item: pressing Enter exits list mode by clearing the
    // marker rather than starting a new (also-empty) list line.
    insert = '';
    replacementStart = previousLineStart;
  } else if (match.isNumbered) {
    final nextNumber = (int.tryParse(match.marker) ?? 0) + 1;
    insert = '${match.indent}$nextNumber. ';
    replacementStart = selection.baseOffset;
  } else {
    insert = '${match.indent}${match.marker} ';
    replacementStart = selection.baseOffset;
  }

  final replacementEnd = selection.baseOffset;
  final nextText = text.replaceRange(replacementStart, replacementEnd, insert);
  final nextOffset = replacementStart + insert.length;

  return _TextEdit(nextText, TextSelection.collapsed(offset: nextOffset));
}

/// Bullet glyphs a list pasted as plain text arrives with — a browser, Word
/// and Google Docs all render `<li>` as one of these. None is a Voyager
/// marker, so a pasted line carrying one is rewritten to use the marker of
/// the list it lands in rather than keeping the glyph as literal content.
final RegExp _pastedBulletPattern = RegExp(r'^(\s*)[•‣▪◦·–—][ 	]+(.*)$');

final RegExp _leadingWhitespacePattern = RegExp(r'^[ 	]*');

/// The content of [line] with whatever list marker it already carries removed,
/// or null if it carries none.
String? _stripPastedMarker(String line) {
  final pastedBullet = _pastedBulletPattern.firstMatch(line);
  if (pastedBullet != null) return pastedBullet.group(2)!;
  return _matchLine(line)?.content;
}

/// Continues the list the caret sits in across a multi-line insert — a paste —
/// by giving every inserted line after the first the marker of the line the
/// paste landed in.
///
/// [_applyEnterContinuation] cannot cover this: it only ever looks at a
/// one-character change, and a paste arrives whole, which is why until now
/// only the first pasted line joined the list and the rest landed as prose.
///
/// A line that already reads as a list item keeps its own marker and indent,
/// so pasting a nested list does not flatten it, and a blank line stays blank
/// rather than becoming an empty bullet.
_TextEdit? _applyPasteContinuation({
  required String text,
  required TextSelection selection,
  required String previousText,
}) {
  if (!selection.isCollapsed) return null;

  final shorter = text.length < previousText.length
      ? text.length
      : previousText.length;
  var prefix = 0;
  while (prefix < shorter &&
      text.codeUnitAt(prefix) == previousText.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < shorter - prefix &&
      text.codeUnitAt(text.length - 1 - suffix) ==
          previousText.codeUnitAt(previousText.length - 1 - suffix)) {
    suffix++;
  }
  final insertEnd = text.length - suffix;
  // Only an insert the user just made at the caret: a programmatic rewrite
  // (a sync merge, a controller refresh) leaves the caret somewhere else.
  if (selection.baseOffset != insertEnd) return null;
  final inserted = text.substring(prefix, insertEnd);
  // A lone newline is a typed Enter, already handled above.
  if (inserted.length < 2 || !inserted.contains('\n')) return null;

  final lineStart = _lineStartFor(text, prefix);
  // Everything before the insert is identical in both texts, so [lineStart]
  // addresses the same line in each; the pre-paste line is the one holding
  // the marker to continue.
  final pastedInto = previousText.substring(
    lineStart,
    _lineEndFor(previousText, lineStart),
  );
  final match = _matchLine(pastedInto);
  if (match == null) return null;

  final markerLength = match.isNumbered
      ? match.marker.length +
            1 // digits + '.'
      : match.marker.length;
  final contentStart =
      lineStart + match.indent.length + markerLength + match.spacing.length;
  // Pasting into the marker itself, or ahead of it, is not a continuation.
  if (prefix < contentStart) return null;

  final lines = inserted.split('\n');
  // The paste starting exactly at the marker's end means the item was still
  // empty, so a marker the first pasted line carries would otherwise sit
  // after this line's own marker as literal text.
  if (prefix == contentStart) {
    lines[0] = _stripPastedMarker(lines[0]) ?? lines[0];
  }
  var nextNumber = match.isNumbered ? (int.tryParse(match.marker) ?? 0) : 0;
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) continue;
    // Already a list line of Voyager's own: its marker and indent are the
    // pasted list's own structure, and rewriting them would flatten it. The
    // renumbering pass below still puts any numbering in order.
    if (_matchLine(line) != null) continue;
    final pastedBullet = _pastedBulletPattern.firstMatch(line);
    final String lineIndent;
    final String content;
    if (pastedBullet != null) {
      lineIndent = pastedBullet.group(1)!;
      content = pastedBullet.group(2)!;
    } else {
      lineIndent = _leadingWhitespacePattern.firstMatch(line)!.group(0)!;
      content = line.substring(lineIndent.length);
    }
    final marker = match.isNumbered ? '${++nextNumber}.' : match.marker;
    lines[i] = '${match.indent}$lineIndent$marker${match.spacing}$content';
  }

  final rewritten = lines.join('\n');
  if (rewritten == inserted) return null;
  return _TextEdit(
    text.replaceRange(prefix, insertEnd, rewritten),
    TextSelection.collapsed(offset: prefix + rewritten.length),
  );
}

class _NumberEdit {
  const _NumberEdit(this.start, this.end, this.replacement);
  final int start;
  final int end;
  final String replacement;
}

class _Counter {
  _Counter(this.indentLength, this.nextNumber);
  final int indentLength;
  int nextNumber;
}

class _RenumberResult {
  const _RenumberResult(this.text, this.mapOffset);
  final String text;
  final int Function(int offset) mapOffset;
}

/// Renumbers every contiguous numbered-list block in [text] so its numbers
/// stay sequential, independently per nesting depth. A block is a run of
/// numbered lines sharing the same leading indent; blank lines don't break a
/// block, but any other non-numbered line does (closing every open counter).
/// The first item of a fresh block keeps whatever number the user typed.
_RenumberResult _renumberDocument(String text) {
  if (!_anyNumberedLine.hasMatch(text)) {
    return _RenumberResult(text, (offset) => offset);
  }

  final lines = text.split('\n');
  final edits = <_NumberEdit>[];
  final stack = <_Counter>[];

  var offset = 0;
  for (final line in lines) {
    final lineStart = offset;
    if (line.trim().isEmpty) {
      // Blank line: transparent, doesn't close open list blocks.
    } else {
      final match = _numberPattern.firstMatch(line);
      if (match != null) {
        final indent = match.group(1)!;
        final indentLength = indent.length;
        while (stack.isNotEmpty && stack.last.indentLength > indentLength) {
          stack.removeLast();
        }
        final numberGroup = match.group(2)!;
        if (stack.isNotEmpty && stack.last.indentLength == indentLength) {
          final counter = stack.last;
          final newNumber = counter.nextNumber;
          counter.nextNumber += 1;
          final newNumberText = newNumber.toString();
          if (newNumberText != numberGroup) {
            final numberStart = lineStart + indentLength;
            final numberEnd = numberStart + numberGroup.length;
            edits.add(_NumberEdit(numberStart, numberEnd, newNumberText));
          }
        } else {
          final startingNumber = int.tryParse(numberGroup) ?? 1;
          stack.add(_Counter(indentLength, startingNumber + 1));
        }
      } else {
        // Non-blank line that isn't a numbered item (prose, or a bullet)
        // ends every open numbered block.
        stack.clear();
      }
    }
    offset += line.length + 1;
  }

  if (edits.isEmpty) {
    return _RenumberResult(text, (offset) => offset);
  }

  final buffer = StringBuffer();
  var cursor = 0;
  for (final edit in edits) {
    buffer.write(text.substring(cursor, edit.start));
    buffer.write(edit.replacement);
    cursor = edit.end;
  }
  buffer.write(text.substring(cursor));

  int mapOffset(int offset) {
    var delta = 0;
    for (final edit in edits) {
      if (offset < edit.start) break;
      if (offset < edit.end) {
        // Offset fell inside a digit run being replaced (rare: cursor sitting
        // in another line's number while unrelated edits shift it); clamp to
        // the end of the new number rather than producing a bogus offset.
        return edit.start + delta + edit.replacement.length;
      }
      delta += edit.replacement.length - (edit.end - edit.start);
    }
    return offset + delta;
  }

  return _RenumberResult(buffer.toString(), mapOffset);
}

int _lineStartFor(String text, int offset) {
  if (offset <= 0) return 0;
  return text.lastIndexOf('\n', offset - 1) + 1;
}

int _lineEndFor(String text, int lineStart) {
  final nextNewline = text.indexOf('\n', lineStart);
  return nextNewline == -1 ? text.length : nextNewline;
}

/// Indents or outdents the list line(s) touched by [controller]'s current
/// selection by one [listIndentUnit], then renumbers the document. Returns
/// true if it handled the key (the current line, or at least one line in a
/// range selection, is a list line) — callers should treat this as
/// "consumed" and not fall through to their normal Tab behavior. Returns
/// false if no line in the selection is a list line, meaning the caller
/// should proceed with whatever Tab normally does (focus traversal, etc.).
bool handleListTab({
  required TextEditingController controller,
  required bool outdent,
}) {
  if (_listEditingWritesSuppressed) return false;

  final text = controller.text;
  final selection = controller.selection;
  if (!selection.isValid) return false;

  final start = selection.start;
  final end = selection.end;
  final firstLineStart = _lineStartFor(text, start);
  final lastAnchor = end > start ? end - 1 : end;
  final lastLineStart = _lineStartFor(text, lastAnchor);

  final lineStarts = <int>[];
  var pos = firstLineStart;
  while (pos <= lastLineStart) {
    lineStarts.add(pos);
    final lineEnd = _lineEndFor(text, pos);
    if (lineEnd >= text.length) break;
    pos = lineEnd + 1;
  }

  final edits =
      <_NumberEdit>[]; // reused as a generic (start,end,replacement) splice
  for (final lineStart in lineStarts) {
    final lineEnd = _lineEndFor(text, lineStart);
    final line = text.substring(lineStart, lineEnd);
    final match = _matchLine(line);
    if (match == null) continue;
    if (!outdent) {
      edits.add(_NumberEdit(lineStart, lineStart, listIndentUnit));
    } else {
      final removable = match.indent.length < listIndentUnit.length
          ? match.indent.length
          : listIndentUnit.length;
      if (removable > 0) {
        edits.add(_NumberEdit(lineStart, lineStart + removable, ''));
      }
    }
  }

  if (edits.isEmpty) return false;

  final buffer = StringBuffer();
  var cursor = 0;
  for (final edit in edits) {
    buffer.write(text.substring(cursor, edit.start));
    buffer.write(edit.replacement);
    cursor = edit.end;
  }
  buffer.write(text.substring(cursor));
  final indentedText = buffer.toString();

  int mapOffset(int offset) {
    var delta = 0;
    for (final edit in edits) {
      if (offset < edit.start) break;
      if (offset < edit.end) {
        // Offset was inside removed leading whitespace (outdent): clamp to
        // the (now-shorter) start of that line's content.
        return edit.start + delta;
      }
      delta += edit.replacement.length - (edit.end - edit.start);
    }
    return offset + delta;
  }

  final indentedSelection = TextSelection(
    baseOffset: mapOffset(selection.baseOffset),
    extentOffset: mapOffset(selection.extentOffset),
  );

  final renumbered = _renumberDocument(indentedText);
  final finalSelection = TextSelection(
    baseOffset: renumbered.mapOffset(indentedSelection.baseOffset),
    extentOffset: renumbered.mapOffset(indentedSelection.extentOffset),
  );

  controller.value = TextEditingValue(
    text: renumbered.text,
    selection: finalSelection,
  );
  return true;
}

/// Whether the line the cursor is currently on matches a bullet or numbered
/// list pattern. Callers use this to decide whether a key that normally
/// does something else (e.g. Enter submitting a form) should instead defer
/// to list handling for this keystroke.
bool isOnListLine(TextEditingController controller) {
  final selection = controller.selection;
  if (!selection.isValid) return false;
  final text = controller.text;
  final lineStart = _lineStartFor(text, selection.start);
  final lineEnd = _lineEndFor(text, lineStart);
  return _matchLine(text.substring(lineStart, lineEnd)) != null;
}

/// If the cursor sits immediately after a list marker (e.g. right after
/// `"- "` or `"12. "`, before any of the line's own content), Backspace
/// removes the whole marker — including its indent — in one keystroke
/// instead of requiring the user to delete it character by character.
/// Renumbers afterward. Returns true if it handled the key; false means the
/// caller should fall through to normal Backspace behavior.
bool handleListBackspace({required TextEditingController controller}) {
  if (_listEditingWritesSuppressed) return false;

  final text = controller.text;
  final selection = controller.selection;
  if (!selection.isCollapsed) return false;

  final cursor = selection.baseOffset;
  if (cursor <= 0) return false;

  final lineStart = _lineStartFor(text, cursor);
  final lineEnd = _lineEndFor(text, lineStart);
  final line = text.substring(lineStart, lineEnd);
  final match = _matchLine(line);
  if (match == null) return false;

  final markerLength = match.isNumbered
      ? match.marker.length +
            1 // digits + '.'
      : match.marker.length; // '-' or '*'
  final prefixEnd =
      lineStart + match.indent.length + markerLength + match.spacing.length;
  if (cursor != prefixEnd) return false;

  final nextText = text.replaceRange(lineStart, prefixEnd, '');
  final renumbered = _renumberDocument(nextText);
  final newOffset = renumbered.mapOffset(lineStart);

  controller.value = TextEditingValue(
    text: renumbered.text,
    selection: TextSelection.collapsed(offset: newOffset),
  );
  return true;
}
