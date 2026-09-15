import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';

void main() {
  // Monday 14 Sep 2026 — mid-month, not the first week.
  final today = DateTime(2026, 9, 14);
  const weekStartsMonday = true;

  group('calendarCurrentWeekHighlightStart', () {
    test('highlights today\'s week in the current month', () {
      expect(
        calendarCurrentWeekHighlightStart(
          visibleMonth: DateTime(2026, 9, 1),
          weekStartsMonday: weekStartsMonday,
          now: today,
        ),
        DateTime(2026, 9, 14),
      );
    });

    test('returns null in other months', () {
      expect(
        calendarCurrentWeekHighlightStart(
          visibleMonth: DateTime(2026, 10, 1),
          weekStartsMonday: weekStartsMonday,
          now: today,
        ),
        isNull,
      );
    });

    test('still highlights when today\'s week spills into the prior month', () {
      // Tuesday 1 Sep 2026 — week starts Monday 31 Aug.
      final earlySept = DateTime(2026, 9, 1);
      expect(
        calendarCurrentWeekHighlightStart(
          visibleMonth: DateTime(2026, 9, 1),
          weekStartsMonday: weekStartsMonday,
          now: earlySept,
        ),
        DateTime(2026, 8, 31),
      );
    });
  });

  group('calendarWeekFocusAfterMonthToWeek', () {
    test('opens today\'s week when viewing the current month', () {
      expect(
        calendarWeekFocusAfterMonthToWeek(
          visibleMonth: DateTime(2026, 9, 1),
          weekStartsMonday: weekStartsMonday,
          lastViewedWeekStart: DateTime(2026, 8, 3),
          now: today,
        ),
        DateTime(2026, 9, 14),
      );
    });

    test('does not jump to a stale week in another month', () {
      // October + last viewed week in August → open week of Oct 1, not Aug.
      expect(
        calendarWeekFocusAfterMonthToWeek(
          visibleMonth: DateTime(2026, 10, 1),
          weekStartsMonday: weekStartsMonday,
          lastViewedWeekStart: DateTime(2026, 8, 31),
          now: today,
        ),
        DateTime(2026, 9, 28), // week containing 1 Oct 2026 (Thu)
      );
    });

    test('restores last viewed week when it still intersects the month', () {
      expect(
        calendarWeekFocusAfterMonthToWeek(
          visibleMonth: DateTime(2026, 10, 1),
          weekStartsMonday: weekStartsMonday,
          lastViewedWeekStart: DateTime(2026, 10, 12),
          now: today,
        ),
        DateTime(2026, 10, 12),
      );
    });
  });

  group('calendarMonthTargetForWeekReturn', () {
    test('prefers the last viewed month over the week-start month', () {
      // Week Mon 31 Aug – Sun 6 Sep, browsed from September: stay there
      // rather than jumping to the August the week starts in.
      expect(
        calendarMonthTargetForWeekReturn(
          lastViewedMonth: DateTime(2026, 9, 1),
          focusedWeekDate: DateTime(2026, 8, 31),
          weekStartsMonday: weekStartsMonday,
          now: today,
        ),
        DateTime(2026, 9, 1),
      );
    });

    test('keeps the last viewed month when a boundary week also touches it', () {
      // Same week, browsed from August — it is August's last row too.
      expect(
        calendarMonthTargetForWeekReturn(
          lastViewedMonth: DateTime(2026, 8, 1),
          focusedWeekDate: DateTime(2026, 8, 31),
          weekStartsMonday: weekStartsMonday,
          now: today,
        ),
        DateTime(2026, 8, 1),
      );
    });

    test('follows the week once it has been browsed out of that month', () {
      // Browsed from October back to a week with no row in October's grid.
      expect(
        calendarMonthTargetForWeekReturn(
          lastViewedMonth: DateTime(2026, 10, 1),
          focusedWeekDate: DateTime(2026, 8, 31),
          weekStartsMonday: weekStartsMonday,
          now: today,
        ),
        DateTime(2026, 9, 1),
      );
    });

    test('follows the current week into today\'s month', () {
      expect(
        calendarMonthTargetForWeekReturn(
          lastViewedMonth: DateTime(2026, 11, 1),
          focusedWeekDate: DateTime(2026, 9, 14),
          weekStartsMonday: weekStartsMonday,
          now: today,
        ),
        DateTime(2026, 9, 1),
      );
    });

    test('falls back to today\'s month when focused on the current week', () {
      expect(
        calendarMonthTargetForWeekReturn(
          lastViewedMonth: null,
          focusedWeekDate: DateTime(2026, 9, 14),
          weekStartsMonday: weekStartsMonday,
          now: today,
        ),
        DateTime(2026, 9, 1),
      );
    });

    test('falls back to mid-week month when week spans a boundary', () {
      // Week Mon 31 Aug – Sun 6 Sep; Thursday is 3 Sep → September.
      expect(
        calendarMonthTargetForWeekReturn(
          lastViewedMonth: null,
          focusedWeekDate: DateTime(2026, 8, 31),
          weekStartsMonday: weekStartsMonday,
          now: DateTime(2026, 7, 1),
        ),
        DateTime(2026, 9, 1),
      );
    });
  });
}
