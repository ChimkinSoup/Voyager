// BUG-108: the amount fields dropped a typed `,` (and `-`, `e`), so `1,5`
// became 15 without a word. Typed keys are now kept for the error line to
// explain; only a paste is still cleaned.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/finance/finance_amount_formatter.dart';

TextEditingValue _value(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

String _edit(AmountInputFormatter f, String from, String to) =>
    f.formatEditUpdate(_value(from), _value(to)).text;

void main() {
  test('a typed key is kept as typed', () {
    final f = AmountInputFormatter();
    expect(_edit(f, '1', '1,'), '1,');
    expect(_edit(f, '1', '1e'), '1e');
    expect(_edit(f, '', '-'), '-');
    expect(_edit(f, '1.99', '1.999'), '1.999');
  });

  test('a paste is cleaned to digits and dots', () {
    expect(_edit(AmountInputFormatter(), '', r'$1,234.50'), '1234.50');
    expect(_edit(AmountInputFormatter(signed: true), '', '-1,234'), '-1234');
    expect(_edit(AmountInputFormatter(), '', '-1,234'), '1234');
  });

  // The text shrinks or barely grows here, so the net length change alone
  // took these for typing and kept the `$` and `,`.
  test('a paste over a selection is cleaned too', () {
    final f = AmountInputFormatter();
    expect(_edit(f, '12345.00', r'$1,234'), '1234');
    expect(_edit(f, '5', r'$1'), '1');
    expect(_edit(f, '12.50', r'1$,5.50'), '15.50');
  });
}
