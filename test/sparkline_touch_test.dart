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

  group('sparklinePeriodAnchorX', () {
    final from = DateTime(2026, 1, 1);

    TrackerValue value(DateTime periodStart, int intValue) => TrackerValue(
      id: 'v${periodStart.toIso8601String()}',
      createdAt: from,
      updatedAt: from,
      trackerId: 't',
      periodStart: periodStart,
      intValue: intValue,
    );

    DateTime monthly(DateTime d) => DateTime(d.year, d.month, 1);

    // A day per x, as `interpolateConsecutive` emits: Jan 1 2026 through the
    // end of March.
    final spots = [for (var day = 0; day <= 89; day++) FlSpot(day.toDouble(), 0)];

    // Jan 1 is day 0, Feb 1 is day 31, Mar 1 is day 59.
    final janAndMar = [
      value(DateTime(2026, 1, 1), 4),
      value(DateTime(2026, 3, 1), 9),
    ];

    // Dec 1 2025 (day -31) is included the way the page includes it: the
    // window's leading days belong to the period that opened before it.
    const monthStarts = <double>[-31, 0, 31, 59];

    double anchor(
      double rawX, {
      List<TrackerValue>? values,
      List<double> periodStarts = monthStarts,
    }) => sparklinePeriodAnchorX(
      rawX: rawX,
      from: from,
      values: values ?? janAndMar,
      periodStartOf: monthly,
      spots: spots,
      periodStarts: periodStarts,
    );

    test('every day of an unlogged period collapses to one x', () {
      // The reported bug: February has no record, so each of its 28 days
      // carried its own interpolated reading. They must all land on one.
      // February's zone runs 16..44 — midway to January on one side, midway
      // to March on the other.
      final febDays = [for (var day = 16; day <= 44; day++) anchor(day.toDouble())];
      expect(febDays.toSet(), {31.0});
    });

    test('an unlogged period anchors on its first day', () {
      expect(anchor(40), 31.0);
    });

    test('every day of a logged period collapses onto its record', () {
      // The other half: drifting a little off January used to swap its stored
      // value for a nearby interpolated one.
      final janDays = [for (var day = 0; day <= 15; day++) anchor(day.toDouble())];
      expect(janDays.toSet(), {0.0});
      expect(anchor(70), 59.0);
    });

    test('a hover zone splits midway between two periods', () {
      // The reported bug: a pointer a day short of February still read
      // January, because a period owned all of its own span to the right and
      // none of the space to its left. The split now sits at day 15.5, the
      // midpoint between Jan 1 (day 0) and Feb 1 (day 31).
      expect(anchor(15), 0.0);
      expect(anchor(16), 31.0);
    });

    test('a period reaches as far left as it reaches right', () {
      // February's zone is 15 days either side of day 31, and a hover landing
      // exactly on a boundary goes to the later period.
      expect(anchor(16), 31.0);
      expect(anchor(44), 31.0);
      expect(anchor(45), 59.0);
    });

    test('a record filed mid-period anchors on its own knot, not day one', () {
      // Non-daily records need not sit on the period's first day; the curve is
      // pinned to the day they were filed under, so the anchor has to be too.
      final values = [value(DateTime(2026, 2, 10), 7)];
      expect(anchor(16, values: values), 40.0);
      expect(anchor(44, values: values), 40.0);
    });

    test('clamps a period that starts before the window', () {
      // The window opens mid-period more often than not, and there is no spot
      // out to the left to land on. From Jan 5, Jan 1 is day -4 and Feb 1 is
      // day 27, so days 0..11 still belong to January.
      final late = DateTime(2026, 1, 5);
      expect(
        sparklinePeriodAnchorX(
          rawX: 3,
          from: late,
          values: const [],
          periodStartOf: monthly,
          spots: [for (var day = 0; day <= 40; day++) FlSpot(day.toDouble(), 0)],
          periodStarts: const [-4, 27],
        ),
        0.0,
      );
    });

    test('leaves the x alone when there is no series to land on', () {
      expect(
        sparklinePeriodAnchorX(
          rawX: 7,
          from: from,
          values: janAndMar,
          periodStartOf: monthly,
          spots: const [],
          periodStarts: monthStarts,
        ),
        7,
      );
    });

    test('a daily tracker is unaffected — each period is already one day', () {
      DateTime daily(DateTime d) => DateTime(d.year, d.month, d.day);
      final dayStarts = [for (var day = -1; day <= 89; day++) day.toDouble()];
      for (final day in [0, 5, 31, 60]) {
        expect(
          sparklinePeriodAnchorX(
            rawX: day.toDouble(),
            from: from,
            values: janAndMar,
            periodStartOf: daily,
            spots: spots,
            periodStarts: dayStarts,
          ),
          day.toDouble(),
        );
      }
    });
  });
}
