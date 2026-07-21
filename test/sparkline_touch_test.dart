import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/features/analytics/sparkline_touch.dart';

/// A series shaped like the interpolated sparklines: x is the day offset.
List<FlSpot> _series(Map<double, double> byDay) => [
  for (final e in byDay.entries) FlSpot(e.key, e.value),
];

void main() {
  group('touchedSpotIndex', () {
    test('returns -1 when nothing is hovered', () {
      expect(touchedSpotIndex(_series({0: 1, 1: 2}), null), -1);
    });

    test('returns -1 when the series is empty', () {
      expect(touchedSpotIndex(const [], 3), -1);
    });

    test('returns -1 when the x is not in the series', () {
      expect(touchedSpotIndex(_series({0: 1, 1: 2, 2: 3}), 9), -1);
    });

    test('finds the spot sitting at the hovered x', () {
      final spots = _series({0: 5, 1: 8, 2: 3});
      expect(touchedSpotIndex(spots, 0), 0);
      expect(touchedSpotIndex(spots, 1), 1);
      expect(touchedSpotIndex(spots, 2), 2);
    });

    test('follows the day across an edit that changes its value', () {
      // The whole point of the fix: the pointer hasn't moved, but the series
      // was rebuilt after a save. The same x must still resolve, and to the
      // new value.
      final before = _series({0: 5, 1: 8, 2: 3});
      final after = _series({0: 5, 1: 42, 2: 3});
      final index = touchedSpotIndex(before, 1);
      expect(index, 1);
      expect(after[touchedSpotIndex(after, 1)].y, 42);
    });

    test('follows the day when a new spot shifts the indices', () {
      // A newly recorded value can lengthen the interpolated series. An index
      // captured beforehand would now point at the wrong day; an x doesn't.
      final before = _series({0: 5, 2: 3});
      final after = _series({0: 5, 1: 9, 2: 3});
      expect(touchedSpotIndex(before, 2), 1);
      expect(touchedSpotIndex(after, 2), 2);
      expect(after[touchedSpotIndex(after, 2)].y, 3);
    });
  });

  group('resolveSparklinePeriod', () {
    final from = DateTime(2026, 7, 1);

    TrackerValue value(DateTime periodStart, int intValue) => TrackerValue(
      id: 'v${periodStart.toIso8601String()}',
      createdAt: from,
      updatedAt: from,
      trackerId: 't',
      periodStart: periodStart,
      intValue: intValue,
    );

    // Daily: each period is the day itself.
    DateTime daily(DateTime d) => DateTime(d.year, d.month, d.day);
    // Weekly: snap back to Monday, as the prompt service does.
    DateTime weekly(DateTime d) {
      final day = DateTime(d.year, d.month, d.day);
      return day.subtract(Duration(days: day.weekday - 1));
    }

    test('returns the record stored for the hovered day', () {
      final values = [value(DateTime(2026, 7, 3), 4)];
      final resolved = resolveSparklinePeriod(
        x: 2,
        from: from,
        values: values,
        periodStartOf: daily,
      );
      expect(resolved.periodStart, DateTime(2026, 7, 3));
      expect(resolved.value?.intValue, 4);
    });

    test('reports no record for a day between two logged points', () {
      // The interpolated curve draws a value here, but nothing was logged —
      // so the tooltip must not claim one, matching the empty editor a tap
      // would open.
      final values = [
        value(DateTime(2026, 7, 1), 2),
        value(DateTime(2026, 7, 5), 6),
      ];
      final resolved = resolveSparklinePeriod(
        x: 2,
        from: from,
        values: values,
        periodStartOf: daily,
      );
      expect(resolved.periodStart, DateTime(2026, 7, 3));
      expect(resolved.value, isNull);
    });

    test('resolves every day of a week to that week\'s record', () {
      // The regression that made hover and edit disagree: on non-daily
      // cadences only one x carries the logged value, and every other day in
      // the period interpolates. All of them must resolve to the same record.
      final values = [value(DateTime(2026, 7, 6), 9)];
      for (var offset = 5; offset <= 11; offset++) {
        final resolved = resolveSparklinePeriod(
          x: offset.toDouble(),
          from: from,
          values: values,
          periodStartOf: weekly,
        );
        expect(resolved.periodStart, DateTime(2026, 7, 6));
        expect(resolved.value?.intValue, 9, reason: 'day offset $offset');
      }
    });

    test('picks the same duplicate every time', () {
      // Two records land in one week. Whichever wins, hover and edit go
      // through this one lookup, so they cannot pick different ones.
      final values = [
        value(DateTime(2026, 7, 7), 1),
        value(DateTime(2026, 7, 9), 2),
      ];
      for (var offset = 5; offset <= 11; offset++) {
        final resolved = resolveSparklinePeriod(
          x: offset.toDouble(),
          from: from,
          values: values,
          periodStartOf: weekly,
        );
        expect(resolved.value?.intValue, 1, reason: 'day offset $offset');
      }
    });
  });

  _readingTests();
}

void _readingTests() {
  group('sparklineValueReading', () {
    test('a logged period reads as its record, not as an estimate', () {
      final r = sparklineValueReading(
        storedLabel: '6',
        interpolates: true,
        interpolatedY: 6.4,
      );
      expect(r.label, '6');
      expect(r.isEstimate, isFalse);
    });

    test('an unlogged period reads the curve, marked as an estimate', () {
      final r = sparklineValueReading(
        storedLabel: null,
        interpolates: true,
        interpolatedY: 6.4,
      );
      // No marker in the string — the caller greys the text instead.
      expect(r.label, '6.4');
      expect(r.isEstimate, isTrue);
    });

    test('a whole-numbered estimate drops its ".0"', () {
      expect(
        sparklineValueReading(
          storedLabel: null,
          interpolates: true,
          interpolatedY: 6.0,
        ).label,
        '6',
      );
    });

    test('a near-whole estimate rounds and drops its decimal', () {
      // Rounding happens before the ".0" test, so 5.98 shows "6", not "5.98".
      expect(
        sparklineValueReading(
          storedLabel: null,
          interpolates: true,
          interpolatedY: 5.98,
        ).label,
        '6',
      );
    });

    test('an estimate is distinguished only by its flag, never its text', () {
      // The record and the estimate can now produce the same string, so
      // isEstimate is the only thing the caller can colour from.
      final record = sparklineValueReading(
        storedLabel: '6',
        interpolates: true,
        interpolatedY: 6.0,
      );
      final estimate = sparklineValueReading(
        storedLabel: null,
        interpolates: true,
        interpolatedY: 6.0,
      );
      expect(record.label, estimate.label);
      expect(record.isEstimate, isFalse);
      expect(estimate.isEstimate, isTrue);
    });

    test('trackers with no curve keep the dash', () {
      final r = sparklineValueReading(
        storedLabel: null,
        interpolates: false,
        interpolatedY: 6.4,
      );
      expect(r.label, isNull);
      expect(r.isEstimate, isFalse);
    });

    test('a missing curve value keeps the dash', () {
      expect(
        sparklineValueReading(
          storedLabel: null,
          interpolates: true,
          interpolatedY: null,
        ).label,
        isNull,
      );
    });
  });
}
