/// Collapsing Windows/Mac line endings to `\n` on the way into a text field.
///
/// Text pasted from a Windows editor (or copied out of a `\r\n` file, which is
/// what LeetCode solutions kept locally usually are) carries `\r\n` for every
/// line break. Flutter draws `\r\n` as one break but stores it as two
/// characters, and that gap is where the caret lands: clicking past the right
/// end of a line puts the caret *between* the `\r` and the `\n`, which paints
/// at the start of the next line. Backspace there is grapheme-aware, so it
/// deletes the whole `\r\n` cluster — the character the user aimed at survives
/// and the two lines are glued together instead.
///
/// Every offset-based helper in the app (indent math, line starts, the code
/// box's brace handling) also assumes a line break is exactly `\n`. So `\r` is
/// dropped at the field boundary and never enters a controller.
library;

import 'package:flutter/services.dart';

/// [text] with every `\r\n` and every lone `\r` replaced by `\n`.
String normalizeNewlines(String text) =>
    text.contains('\r') ? text.replaceAll(RegExp(r'\r\n?'), '\n') : text;

/// [value] with its line endings normalized and its selection and composing
/// region moved to the same characters in the shortened text.
///
/// A caret sitting between a `\r` and its `\n` maps to just *after* the
/// resulting `\n` — the start of the next line, which is where that caret was
/// being painted.
TextEditingValue normalizeNewlinesInValue(TextEditingValue value) {
  final text = value.text;
  if (!text.contains('\r')) return value;

  final buffer = StringBuffer();
  // Old offset -> offset in the normalized text, for every boundary including
  // the end of the string.
  final mapped = List<int>.filled(text.length + 1, 0);
  var i = 0;
  while (i < text.length) {
    mapped[i] = buffer.length;
    if (text[i] == '\r') {
      buffer.write('\n');
      if (i + 1 < text.length && text[i + 1] == '\n') {
        i++;
        mapped[i] = buffer.length;
      }
    } else {
      buffer.write(text[i]);
    }
    i++;
  }
  mapped[text.length] = buffer.length;

  int at(int offset) =>
      offset < 0 ? offset : mapped[offset.clamp(0, text.length)];

  final selection = value.selection;
  final composing = value.composing;
  return TextEditingValue(
    text: buffer.toString(),
    selection: selection.copyWith(
      baseOffset: at(selection.baseOffset),
      extentOffset: at(selection.extentOffset),
    ),
    composing: composing.isValid
        ? TextRange(start: at(composing.start), end: at(composing.end))
        : composing,
  );
}

/// Drops `\r` from anything typed, pasted or dropped into a field.
class NormalizeNewlinesFormatter extends TextInputFormatter {
  const NormalizeNewlinesFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => normalizeNewlinesInValue(newValue);
}
