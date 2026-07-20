import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/analytics/stat_number_format.dart';

void main() {
  group('compactNumberLabel', () {
    test('leaves values under a thousand alone', () {
      expect(compactNumberLabel(0), '0');
      expect(compactNumberLabel(7), '7');
      expect(compactNumberLabel(42), '42');
      expect(compactNumberLabel(999), '999');
    });

    test('abbreviates a clean thousand without a trailing .0', () {
      expect(compactNumberLabel(1000), '1k');
      expect(compactNumberLabel(12000), '12k');
      expect(compactNumberLabel(120000), '120k');
    });

    test('keeps one decimal for fractional thousands', () {
      // These are real axis ticks: a step of 500 produces 1500, a step of
      // 300 produces 1200.
      expect(compactNumberLabel(1500), '1.5k');
      expect(compactNumberLabel(1200), '1.2k');
      expect(compactNumberLabel(12500), '12.5k');
    });

    test('drops the decimal once the mantissa reaches three digits', () {
      expect(compactNumberLabel(123500), '124k');
      expect(compactNumberLabel(999000), '999k');
    });

    test('never renders more than three digits', () {
      for (final n in [
        0,
        7,
        999,
        1000,
        1500,
        9950,
        12500,
        123500,
        999499,
        999500,
        1000000,
        1500000,
        999999999,
        1234567890,
      ]) {
        final label = compactNumberLabel(n);
        final digits = label.replaceAll(RegExp(r'[^0-9]'), '').length;
        expect(digits, lessThanOrEqualTo(3), reason: '$n rendered as $label');
      }
    });

    test('promotes a tier when rounding carries', () {
      // 999_500 divides to 999.5k, which would round to a four-digit
      // "1000k" without the carry check.
      expect(compactNumberLabel(999500), '1M');
      expect(compactNumberLabel(999499), '999k');
      expect(compactNumberLabel(999500000), '1B');
    });

    test('scales past millions through the whole suffix ladder', () {
      expect(compactNumberLabel(1000000), '1M');
      expect(compactNumberLabel(1500000), '1.5M');
      expect(compactNumberLabel(1000000000), '1B');
      expect(compactNumberLabel(2500000000), '2.5B');
      expect(compactNumberLabel(1000000000000), '1T');
      expect(compactNumberLabel(1000000000000000), '1P');
      expect(compactNumberLabel(1000000000000000000), '1E');
    });

    test('handles negatives symmetrically', () {
      expect(compactNumberLabel(-42), '-42');
      expect(compactNumberLabel(-1500), '-1.5k');
      expect(compactNumberLabel(-1000000), '-1M');
    });

    test('rounds fractional input to the nearest whole value', () {
      expect(compactNumberLabel(41.4), '41');
      expect(compactNumberLabel(41.6), '42');
    });
  });

  group('niceAxisStep', () {
    test('gives round steps that cover the data', () {
      // 6 gridlines means 5 intervals above the baseline.
      expect(niceAxisStep(4.2, 6), 1);
      expect(niceAxisStep(27, 6), 6);
      expect(niceAxisStep(12, 6), 3);
      // 3 gridlines means 2 intervals.
      expect(niceAxisStep(10, 3), 5);
    });

    test('always reaches at least the data maximum', () {
      for (final max in [0.5, 1, 4.2, 7, 12, 27, 100, 1234, 98765]) {
        for (final lines in [3, 6]) {
          final step = niceAxisStep(max.toDouble(), lines);
          expect(
            step * (lines - 1),
            greaterThanOrEqualTo(max),
            reason: 'max $max with $lines lines',
          );
        }
      }
    });

    test('never drops below a whole step, so labels stay integers', () {
      expect(niceAxisStep(0, 6), 1);
      expect(niceAxisStep(1, 6), 1);
      expect(niceAxisStep(2, 6), 1);
      for (final max in [0.0, 0.1, 1, 2, 3, 4, 5]) {
        final step = niceAxisStep(max.toDouble(), 6);
        expect(step, greaterThanOrEqualTo(1));
        expect(step, step.roundToDouble());
      }
    });
  });
}
