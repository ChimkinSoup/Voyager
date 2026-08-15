import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/text/newline_normalization.dart';

void main() {
  group('normalizeNewlines', () {
    test('collapses CRLF and lone CR', () {
      expect(normalizeNewlines('a\r\nb\rc\nd'), 'a\nb\nc\nd');
    });

    test('returns the same string when there is nothing to do', () {
      const text = 'a\nb';
      expect(normalizeNewlines(text), same(text));
    });
  });

  group('normalizeNewlinesInValue', () {
    test('leaves a value with no carriage returns untouched', () {
      const value = TextEditingValue(
        text: 'a\nb',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(normalizeNewlinesInValue(value), same(value));
    });

    test('moves the caret onto the same character', () {
      // "ab\r\ncd", caret before 'c'.
      const value = TextEditingValue(
        text: 'ab\r\ncd',
        selection: TextSelection.collapsed(offset: 4),
      );
      final result = normalizeNewlinesInValue(value);
      expect(result.text, 'ab\ncd');
      expect(result.selection.baseOffset, 3);
    });

    test('a caret between CR and LF lands after the break', () {
      // That gap is where a click past the right edge of a line used to put
      // the caret, and it painted at the start of the next line.
      const value = TextEditingValue(
        text: 'ab\r\ncd',
        selection: TextSelection.collapsed(offset: 3),
      );
      final result = normalizeNewlinesInValue(value);
      expect(result.text, 'ab\ncd');
      expect(result.selection.baseOffset, 3);
    });

    test('keeps a range selection over the same characters', () {
      const value = TextEditingValue(
        text: 'ab\r\ncd\r\nef',
        selection: TextSelection(baseOffset: 1, extentOffset: 9),
      );
      final result = normalizeNewlinesInValue(value);
      expect(result.text, 'ab\ncd\nef');
      expect(result.selection.baseOffset, 1);
      expect(result.selection.extentOffset, 7);
      expect(
        result.text.substring(1, 7),
        'b\ncd\ne',
      );
    });

    test('carries an invalid selection through', () {
      const value = TextEditingValue(text: 'a\r\nb');
      final result = normalizeNewlinesInValue(value);
      expect(result.text, 'a\nb');
      expect(result.selection.baseOffset, -1);
    });
  });

  group('NormalizeNewlinesFormatter', () {
    test('strips carriage returns from a paste', () {
      const formatter = NormalizeNewlinesFormatter();
      final result = formatter.formatEditUpdate(
        const TextEditingValue(text: ''),
        const TextEditingValue(
          text: 'one\r\ntwo\r\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      expect(result.text, 'one\ntwo\n');
      expect(result.selection.baseOffset, 8);
    });
  });
}
