// BUG-081: 25 all-day events on one day grew the Week view's all-day shelf to
// 25 rows, squeezing the hour grid of every day in the week to a strip. The
// shelf now stops at a few rows and folds the rest into "+N more".

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

CalendarEvent _allDay(String id, DateTime day) {
  final now = DateTime.utc(2026, 1, 1);
  return CalendarEvent(
    id: id,
    createdAt: now,
    updatedAt: now,
    calendarId: 'c1',
    title: id,
    start: day,
    end: DateTime(day.year, day.month, day.day, 23, 59),
    isFullDay: true,
  );
}

void main() {
  final week = [for (var i = 0; i < 7; i++) DateTime(2026, 10, 19 + i)];
  final thursday = week[3];

  test('a crowded day caps the shelf and folds the rest into the last row', () {
    final events = [
      for (var i = 0; i < 25; i++) _allDay('d$i', thursday),
      _allDay('monday', week[0]),
    ];

    final packed = calendarPackWeekAllDayShelf(events: events, weekDays: week);
    final rows = calendarWeekAllDayShelfRowCount(packed);
    expect(rows, calendarWeekAllDayShelfMaxRows);
    expect(
      calendarWeekAllDayShelfHeightFor(events: events, weekDays: week),
      calendarWeekAllDayShelfMaxRows * calendarWeekAllDayEventRowHeight,
    );

    // Thursday shows rows - 1 events; "+N more" holds the other 25 - that.
    final overflow = calendarWeekAllDayShelfOverflow(packed[3], rows);
    expect(overflow, hasLength(25 - (rows - 1)));
    // Monday's single event fits and folds nothing.
    expect(calendarWeekAllDayShelfOverflow(packed[0], rows), isEmpty);
  });

  test('a day that exactly fills the shelf shows every event', () {
    final events = [
      for (var i = 0; i < calendarWeekAllDayShelfMaxRows; i++)
        _allDay('d$i', thursday),
    ];
    final packed = calendarPackWeekAllDayShelf(events: events, weekDays: week);
    final rows = calendarWeekAllDayShelfRowCount(packed);
    expect(rows, calendarWeekAllDayShelfMaxRows);
    expect(calendarWeekAllDayShelfOverflow(packed[3], rows), isEmpty);
  });

  test(
    'a bar ends where the neighbouring column folds its row into "+N more"',
    () {
      final span = _allDay('span', week[0]);
      final rows = calendarWeekAllDayShelfMaxRows;
      // Monday fits: its third row is the span. Tuesday has more rows than the
      // shelf, so its third row is "+N more" and the span can't bridge into it.
      final packed = <List<CalendarEvent?>>[
        [_allDay('m0', week[0]), _allDay('m1', week[0]), span],
        [
          _allDay('t0', week[1]),
          _allDay('t1', week[1]),
          span,
          _allDay('t3', week[1]),
        ],
        for (var i = 2; i < 7; i++) const [],
      ];

      expect(
        calendarWeekAllDayShelfRowFolded(packed, rows, 1, rows - 1),
        isTrue,
      );
      expect(
        calendarWeekAllDayShelfRowFolded(packed, rows, 1, rows - 2),
        isFalse,
      );
      expect(
        calendarWeekAllDayShelfRowFolded(packed, rows, 0, rows - 1),
        isFalse,
      );
      // Outside the week is never folded.
      expect(
        calendarWeekAllDayShelfRowFolded(packed, rows, -1, rows - 1),
        isFalse,
      );
      expect(
        calendarWeekAllDayShelfRowFolded(packed, rows, 7, rows - 1),
        isFalse,
      );
    },
  );
}
