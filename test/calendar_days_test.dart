import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/services/analytics_service.dart';
import 'package:voyager/features/analytics/sparkline_touch.dart';

/// These dates are US Eastern transitions, which is where the bug was found.
/// The assertions hold in *any* zone though — including ones with no DST at
/// all — because they only ever claim that N calendar days after a date is the
/// date N days along on the calendar. That's the property the elapsed-time
/// arithmetic these helpers replaced did not have.
void main() {
  final fallBack = DateTime(2025, 11, 1); // transition: Nov 2
  final springForward = DateTime(2026, 3, 1); // transition: Mar 8

  group('addCalendarDays', () {
    test('lands on the right date across a fall-back', () {
      // `.add(const Duration(days: 10))` gives 2025-11-10 23:00 here.
      expect(addCalendarDays(fallBack, 10), DateTime(2025, 11, 11));
    });

    test('lands on the right date across a spring-forward', () {
      expect(addCalendarDays(springForward, 14), DateTime(2026, 3, 15));
    });

    test('always returns local midnight', () {
      for (var i = 0; i < 40; i++) {
        final d = addCalendarDays(fallBack, i);
        expect(d.hour, 0, reason: 'offset $i');
      }
    });

    test('goes backwards and rolls over month boundaries', () {
      expect(addCalendarDays(DateTime(2026, 3, 3), -5), DateTime(2026, 2, 26));
      expect(addCalendarDays(DateTime(2026, 2, 26), 5), DateTime(2026, 3, 3));
    });
  });

  group('calendarDaysBetween', () {
    test('counts whole days across a spring-forward', () {
      // `.difference(...).inDays` truncates to 13 here.
      expect(calendarDaysBetween(springForward, DateTime(2026, 3, 15)), 14);
    });

    test('counts whole days across a fall-back', () {
      expect(calendarDaysBetween(fallBack, DateTime(2025, 11, 11)), 10);
    });

    test('ignores the time of day on either end', () {
      expect(
        calendarDaysBetween(
          DateTime(2026, 3, 1, 23, 59),
          DateTime(2026, 3, 15, 0, 1),
        ),
        14,
      );
    });

    test('round-trips with addCalendarDays across a transition', () {
      for (final start in [fallBack, springForward]) {
        for (var i = 0; i < 40; i++) {
          expect(
            calendarDaysBetween(start, addCalendarDays(start, i)),
            i,
            reason: 'start $start offset $i',
          );
        }
      }
    });
  });

  group('sparkline day offsets across a DST transition', () {
    final analytics = AnalyticsService();

    TrackerValue value(DateTime periodStart, int intValue) {
      final now = utcNow();
      return TrackerValue(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        trackerId: 't',
        periodStart: periodStart,
        intValue: intValue,
      );
    }

    DateTime daily(DateTime d) => DateTime(d.year, d.month, d.day);

    test('a hovered day resolves to its own period, not the one left', () {
      // The reported symptom: past a fall-back the hover resolved to the
      // previous day and reported that day's record.
      final values = [
        value(DateTime(2025, 11, 5), 3),
        value(DateTime(2025, 11, 11), 9),
      ];
      final resolved = resolveSparklinePeriod(
        x: 10,
        from: fallBack,
        values: values,
        periodStartOf: daily,
      );
      expect(resolved.periodStart, DateTime(2025, 11, 11));
      expect(resolved.value?.intValue, 9);
    });

    test('every day of the window resolves to the day at that offset', () {
      for (var i = 0; i <= 30; i++) {
        final resolved = resolveSparklinePeriod(
          x: i.toDouble(),
          from: fallBack,
          values: const [],
          periodStartOf: daily,
        );
        expect(
          resolved.periodStart,
          addCalendarDays(fallBack, i),
          reason: 'offset $i',
        );
      }
    });

    test('records land on the day index they were recorded on', () {
      // Spanning the spring-forward: the record on Mar 15 is 14 calendar days
      // out, and used to be filed under day 13.
      final spots = analytics.interpolateConsecutive(
        values: [
          value(springForward, 0),
          value(DateTime(2026, 3, 15), 14),
        ],
        from: springForward,
        to: DateTime(2026, 3, 15),
        maxDays: 14,
      );

      expect(spots.last.x, 14);
      expect(spots.last.y, 14);
      expect(spots.firstWhere((s) => s.x == 14).y, 14);
    });
  });
}
