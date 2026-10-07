// BUG-097 follow-up: a tracker number field never trims away digits that were
// already there. Text added at the end is trimmed to what fits, as before; an
// edit in the middle that breaks the rule is rejected.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/analytics/tracker_entry_row.dart';

void main() {
  /// [newText] with the caret at [caret] (default: the end).
  String apply(
    TextInputFormatter f,
    String oldText,
    String newText, {
    int? caret,
  }) => f
      .formatEditUpdate(
        TextEditingValue(text: oldText),
        TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: caret ?? newText.length),
        ),
      )
      .text;

  final value = trackerNumberFormatter(signed: false);

  test('a digit typed into the middle of a full field is rejected', () {
    expect(apply(value, '123456789', '1023456789', caret: 2), '123456789');
  });

  test('a letter typed into the middle keeps the digits after it', () {
    expect(apply(value, '123', '12a3', caret: 3), '123');
  });

  test('text added at the end is trimmed to what fits', () {
    expect(apply(value, '123456789', '1234567890'), '123456789');
    expect(apply(value, '', '12.345'), '12.34');
    expect(apply(value, '', '9' * 400), '9' * 9);
  });

  test('numbers within the rule pass unchanged', () {
    expect(apply(value, '', '7'), '7');
    expect(apply(value, '12', '12.'), '12.');
    expect(apply(value, '12.3', '12.34'), '12.34');
    expect(apply(value, '1234', '124', caret: 2), '124');
  });

  test('a minus only where the field is signed, decimals only where '
      'allowed', () {
    expect(apply(value, '', '-'), '');
    expect(apply(trackerNumberFormatter(signed: true), '', '-5'), '-5');
    final whole = trackerNumberFormatter(signed: true, decimal: false);
    expect(apply(whole, '5', '5.'), '5');
    expect(apply(whole, '', '-123456789'), '-123456789');
  });
}
