import 'package:flutter/services.dart';

/// The input formatter for a finance amount field.
///
/// A paste is cleaned down to digits and dots (and `-` for a [signed] field),
/// so `$1,234.50` copied from a statement reads `1234.50`. A typed letter or
/// other symbol is refused outright, but a typed `,` or `-` is kept as typed:
/// dropping a typed `,` turned `1,5` into 15 without a word, so the field shows
/// it and its error line says what's wrong (`amountShapeError`).
class AmountInputFormatter extends TextInputFormatter {
  AmountInputFormatter({bool signed = false})
    : _paste = FilteringTextInputFormatter.allow(
        signed ? RegExp(r'[0-9.\-]') : RegExp(r'[0-9.]'),
      );

  final FilteringTextInputFormatter _paste;

  static final _typedKey = RegExp(r'[0-9.,\-]');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final inserted = _inserted(oldValue.text, newValue.text);
    if (inserted.isEmpty) return newValue;
    if (inserted.length == 1) {
      return _typedKey.hasMatch(inserted) ? newValue : oldValue;
    }
    return _paste.formatEditUpdate(oldValue, newValue);
  }

  /// What [after] put in place of what [before] had: the text between their
  /// common prefix and common suffix. The net length change alone misses a
  /// paste that replaces a selection as long or longer.
  static String _inserted(String before, String after) {
    final shorter = before.length < after.length ? before : after;
    var prefix = 0;
    while (prefix < shorter.length && before[prefix] == after[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < shorter.length - prefix &&
        before[before.length - 1 - suffix] ==
            after[after.length - 1 - suffix]) {
      suffix++;
    }
    return after.substring(prefix, after.length - suffix);
  }
}
