import 'package:flutter/services.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';

/// An inline tier command (GAIA_HLD.md §7.3) found in the composer's text:
/// the tier, and the text with the command taken out.
typedef GaiaTierCommand = ({GaiaTier tier, TextEditingValue value});

/// An account's alias used as a command (§9.2), found the same way.
typedef GaiaAccountCommand = ({GaiaAccount account, TextEditingValue value});

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
  final found = _findCommand(value, _commands.keys, atEnd: atEnd);
  return found == null
      ? null
      : (tier: _commands[found.command]!, value: found.value);
}

/// The first completed alias of [accounts] in [value], by the same rules as
/// [findGaiaTierCommand]. Null when there's none.
GaiaAccountCommand? findGaiaAccountCommand(
  TextEditingValue value,
  List<GaiaAccount> accounts, {
  bool atEnd = false,
}) {
  final byCommand = {
    for (final account in accounts)
      if (account.alias.isNotEmpty) '/${account.alias}': account,
  };
  if (byCommand.isEmpty) return null;
  final found = _findCommand(value, byCommand.keys, atEnd: atEnd);
  return found == null
      ? null
      : (account: byCommand[found.command]!, value: found.value);
}

/// One of [gaiaInlineBuiltins] found the same way.
typedef GaiaInlineBuiltin = ({GaiaBuiltin builtin, TextEditingValue value});

/// The first completed one of [gaiaInlineBuiltins], by any of its names, in
/// [value], by the same rules as [findGaiaTierCommand]. Null when there's
/// none.
GaiaInlineBuiltin? findGaiaInlineBuiltin(
  TextEditingValue value, {
  bool atEnd = false,
}) {
  final byCommand = {
    for (final builtin in gaiaInlineBuiltins)
      for (final name in builtin.names) '/$name': builtin,
  };
  final found = _findCommand(value, byCommand.keys, atEnd: atEnd);
  return found == null
      ? null
      : (builtin: byCommand[found.command]!, value: found.value);
}

({String command, TextEditingValue value})? _findCommand(
  TextEditingValue value,
  Iterable<String> commands, {
  required bool atEnd,
}) {
  final text = value.text;
  final names = commands.map(RegExp.escape).join('|');
  final pattern = RegExp(
    atEnd ? '(^|\\s)($names)(\\s|\$)' : '(^|\\s)($names)\\s',
  );
  for (final match in pattern.allMatches(text)) {
    final start = match.start + match.group(1)!.length;
    final end = start + match.group(2)!.length;
    if (gaiaInCode(text, start)) continue;
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
      command: match.group(2)!,
      value: TextEditingValue(text: updated, selection: selection),
    );
  }
  return null;
}

/// Whether [offset] is inside a ``` fence, or an inline `code` span on its
/// line.
bool gaiaInCode(String text, int offset) {
  final before = text.substring(0, offset);
  if ('```'.allMatches(before).length.isOdd) return true;
  final line = before.substring(before.lastIndexOf('\n') + 1);
  return line.replaceAll('```', '').split('`').length.isEven;
}
