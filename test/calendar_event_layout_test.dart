import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_overlap_engine.dart';

DateTime _d(int year, int month, int day, [int hour = 0, int minute = 0]) =>
    DateTime(year, month, day, hour, minute);

CalendarEvent _timed({
  required String id,
  required DateTime start,
  required DateTime end,
  RecurrenceRule recurrence = RecurrenceRule.none,
}) {
  final now = DateTime.utc(2026, 1, 1);
  return CalendarEvent(
    id: id,
    createdAt: now,
    updatedAt: now,
    calendarId: 'c1',
    title: id,
    start: start,
    end: end,
    isFullDay: false,
    recurrence: recurrence,
  );
}

void main() {
  group('Calendar event layout and styling', () {
    test('calendarMonthEventBarHeight expands for 4 events to reach bottom padding', () {
      const style = MonthDayCellStyle.full;
      const cellHeight = 100.0;
      
      final heightFor3 = calendarMonthEventBarHeight(
        cellHeight: cellHeight,
        style: style,
        visibleEventCount: 3,
      );
      
      final heightFor4 = calendarMonthEventBarHeight(
        cellHeight: cellHeight,
        style: style,
        visibleEventCount: 4,
      );

      // 4 events should span an extra 3.0px (cellPadding.bottom) across the cell
      expect(heightFor4 * 4 + 3, equals(heightFor3 * 4 + 3 + style.cellPadding.bottom));
    });
  });

  group('week column overlap layout', () {
    const weekly = RecurrenceRule(frequency: EventRecurrence.weekly);

    CalendarOverlapSlot only(List<CalendarOverlapSlot> slots) {
      expect(slots, hasLength(1));
      return slots.single;
    }

    test('a repeating event keeps its height on later occurrences', () {
      final event = _timed(
        id: 'standup',
        start: _d(2026, 3, 2, 10),
        end: _d(2026, 3, 2, 12),
        recurrence: weekly,
      );

      for (final day in [_d(2026, 3, 2), _d(2026, 3, 9), _d(2026, 3, 30)]) {
        final slot = only(layoutDayColumn(
          day: day,
          events: [event],
          todos: const [],
          pxPerHour: 60,
          taskBarHeight: 18,
        ));
        // 10:00 → 12:00 is two hours on every occurrence, not an 18px stub on
        // all of them but the first.
        expect(slot.top, 600.0, reason: '$day');
        expect(slot.height, 120.0, reason: '$day');
      }
    });

    test('repeating events still cluster on later occurrences', () {
      final a = _timed(
        id: 'a',
        start: _d(2026, 3, 2, 10),
        end: _d(2026, 3, 2, 12),
        recurrence: weekly,
      );
      final b = _timed(
        id: 'b',
        start: _d(2026, 3, 2, 11),
        end: _d(2026, 3, 2, 13),
        recurrence: weekly,
      );

      final slots = layoutDayColumn(
        day: _d(2026, 3, 23),
        events: [a, b],
        todos: const [],
        pxPerHour: 60,
        taskBarHeight: 18,
      );

      // An inverted interval overlaps nothing, so before the fix both events
      // claimed the full column and drew on top of each other.
      expect(slots, hasLength(2));
      expect(slots.map((s) => s.width), everyElement(0.5));
      expect(slots.map((s) => s.left).toSet(), {0.0, 0.5});
    });

    test('a one-off event is unaffected', () {
      final slot = only(layoutDayColumn(
        day: _d(2026, 3, 2),
        events: [
          _timed(id: 'x', start: _d(2026, 3, 2, 9), end: _d(2026, 3, 2, 9, 30)),
        ],
        todos: const [],
        pxPerHour: 60,
        taskBarHeight: 18,
      ));
      expect(slot.top, 540.0);
      expect(slot.height, 30.0);
    });
  });

  group('calendarPackWeekEvents', () {
    test('packs a repeating event onto every day it occurs on', () {
      final week = [for (var i = 2; i <= 8; i++) _d(2026, 3, i)];
      final weekly = _timed(
        id: 'weekly',
        start: _d(2026, 2, 2, 10),
        end: _d(2026, 2, 2, 11),
        recurrence: const RecurrenceRule(frequency: EventRecurrence.weekly),
      );
      final oneOff = _timed(
        id: 'oneOff',
        start: _d(2026, 3, 4, 10),
        end: _d(2026, 3, 4, 11),
      );

      final packed = calendarPackWeekEvents(week, [weekly, oneOff]);

      // Mon Mar 2 is the weekly occurrence; Wed Mar 4 holds the one-off only.
      expect(packed[0].whereType<CalendarEvent>().map((e) => e.id), ['weekly']);
      expect(packed[2].whereType<CalendarEvent>().map((e) => e.id), ['oneOff']);
      for (final column in [1, 3, 4, 5, 6]) {
        expect(packed[column].whereType<CalendarEvent>(), isEmpty);
      }
    });

    test('stacks two same-day events into separate rows', () {
      final week = [for (var i = 2; i <= 8; i++) _d(2026, 3, i)];
      final a = _timed(id: 'a', start: _d(2026, 3, 4, 9), end: _d(2026, 3, 4, 10));
      final b = _timed(id: 'b', start: _d(2026, 3, 4, 11), end: _d(2026, 3, 4, 12));

      final packed = calendarPackWeekEvents(week, [a, b]);
      expect(packed[2].map((e) => e?.id), ['a', 'b']);
    });
  });

  group('calendarDateInWeek', () {
    test('covers exactly the seven days from the week start', () {
      final start = _d(2026, 3, 2);
      expect(calendarDateInWeek(_d(2026, 3, 1), start), isFalse);
      expect(calendarDateInWeek(_d(2026, 3, 2), start), isTrue);
      expect(calendarDateInWeek(_d(2026, 3, 8), start), isTrue);
      expect(calendarDateInWeek(_d(2026, 3, 9), start), isFalse);
    });

    test('does not spill into an eighth day across a spring-forward week', () {
      // US spring-forward is Mar 8 2026; the week starting Mar 2 contains it.
      expect(calendarDateInWeek(_d(2026, 3, 9), _d(2026, 3, 2)), isFalse);
      // EU spring-forward is Mar 29 2026.
      expect(calendarDateInWeek(_d(2026, 4, 5), _d(2026, 3, 29)), isFalse);
    });
  });
}
