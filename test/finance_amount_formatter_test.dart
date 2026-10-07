// BUG-108: the amount fields dropped a typed `,` (and `-`), so `1,5` became
// 15 without a word. A typed `,` or `-` is now kept for the error line to
// explain; a typed letter or other symbol is refused, and a paste is cleaned.

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
  test('a typed comma or minus is kept as typed', () {
    final f = AmountInputFormatter();
    expect(_edit(f, '1', '1,'), '1,');
    expect(_edit(f, '', '-'), '-');
    expect(_edit(f, '1.99', '1.999'), '1.999');
  });

  test('a typed letter or other symbol is refused', () {
    final f = AmountInputFormatter();
    expect(_edit(f, '1', '1e'), '1');
    expect(_edit(f, '1', '1a'), '1');
    expect(_edit(f, '', r'$'), '');
    expect(_edit(f, '1', '1 '), '1');
  });

  test('a deletion leaves the rest of the text alone', () {
    expect(_edit(AmountInputFormatter(), r'$12', r'$1'), r'$1');
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
