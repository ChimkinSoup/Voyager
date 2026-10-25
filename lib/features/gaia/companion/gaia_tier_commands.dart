import 'package:flutter/services.dart';
import 'package:voyager/domain/models/gaia_models.dart';

/// An inline tier command (GAIA_HLD.md §7.3) found in the composer's text:
/// the tier, and the text with the command taken out.
typedef GaiaTierCommand = ({GaiaTier tier, TextEditingValue value});

final _commands = {for (final tier in GaiaTier.values) tier.command: tier};

/// The first completed `/quick`, `/std` or `/deep` in [value]: a whole token
/// (at the start or after whitespace) followed by whitespace, or, when
/// [atEnd], ending the text (the user sent it). Not inside backticks or a
/// code fence. Null when there's none.
///
/// Firing on completion rather than the last letter keeps `/deep` from
/// going off inside `/deeplearning/notes.txt`.
GaiaTierCommand? findGaiaTierCommand(
  TextEditingValue value, {
  bool atEnd = false,
}) {
  final text = value.text;
  final pattern = RegExp(
    atEnd ? r'(^|\s)(/quick|/std|/deep)(\s|$)' : r'(^|\s)(/quick|/std|/deep)\s',
  );
  for (final match in pattern.allMatches(text)) {
    final start = match.start + match.group(1)!.length;
    final end = start + match.group(2)!.length;
    if (_inCode(text, start)) continue;
    // The command and one space after it, or the space before it when it
    // ends the text.
    var cutStart = start;
    var cutEnd = end;
    if (cutEnd < text.length && text[cutEnd].trim().isEmpty) {
      cutEnd++;
    } else if (cutStart > 0 && text[cutStart - 1] == ' ') {
      cutStart--;
    }
    final updated = text.replaceRange(cutStart, cutEnd, '');
    int shift(int offset) => offset <= cutStart
        ? offset
        : offset >= cutEnd
        ? offset - (cutEnd - cutStart)
        : cutStart;
    final selection = value.selection.isValid
        ? value.selection.copyWith(
            baseOffset: shift(value.selection.baseOffset),
            extentOffset: shift(value.selection.extentOffset),
          )
        : TextSelection.collapsed(offset: updated.length);
    return (
      tier: _commands[match.group(2)]!,
      value: TextEditingValue(text: updated, selection: selection),
    );
  }
  return null;
}

/// Whether [offset] is inside a ``` fence, or an inline `code` span on its
/// line.
bool _inCode(String text, int offset) {
  final before = text.substring(0, offset);
  if ('```'.allMatches(before).length.isOdd) return true;
  final line = before.substring(before.lastIndexOf('\n') + 1);
  return line.replaceAll('```', '').split('`').length.isEven;
}
