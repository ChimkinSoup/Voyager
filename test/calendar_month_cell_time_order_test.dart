// BUG-076: the month grid packed each event into one lane for the whole week
// row, sorted by the series start. An all-day event on the row's Sunday then
// pushed the daily 7 AM walk to lane 1 all week, so Monday's 9 AM standup took
// lane 0 and was listed above the walk. Lanes are now given per occurrence.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';

CalendarEvent _event(
  String id,
  DateTime start,
  DateTime end, {
  RecurrenceRule recurrence = RecurrenceRule.none,
  bool isFullDay = false,
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
    isFullDay: isFullDay,
    recurrence: recurrence,
  );
}

List<String?> _ids(List<CalendarEvent?> column) =>
    column.map((e) => e?.id).toList();

void main() {
  // The logged October 2026 data.
  final walk = _event(
    'walk',
    DateTime(2026, 10, 1, 7),
    DateTime(2026, 10, 1, 7, 30),
    recurrence: const RecurrenceRule(frequency: EventRecurrence.daily),
  );
  final standup = _event(
    'standup',
    DateTime(2026, 10, 5, 9),
    DateTime(2026, 10, 5, 9, 30),
    recurrence: const RecurrenceRule(frequency: EventRecurrence.weekly),
  );
  final rent = _event(
    'rent',
    DateTime(2026, 10, 1),
    DateTime(2026, 10, 1, 23, 59),
    isFullDay: true,
    recurrence: const RecurrenceRule(frequency: EventRecurrence.monthly),
  );

  test('Monday Oct 26 lists the 7 AM walk above the 9 AM standup', () {
    // Monday-first row Oct 26 – Nov 1; "rent" falls on Sunday Nov 1.
    final week = [for (var i = 0; i < 7; i++) DateTime(2026, 10, 26 + i)];

    final packed = calendarPackWeekEvents(week, [standup, rent, walk]);

    expect(_ids(packed[0]), ['walk', 'standup']);
    expect(_ids(packed[6]), ['rent', 'walk']);
  });

  test('every Monday of October keeps the same order', () {
    for (final monday in [5, 12, 19, 26]) {
      final week = [for (var i = 0; i < 7; i++) DateTime(2026, 10, monday + i)];
      final packed = calendarPackWeekEvents(week, [standup, rent, walk]);
      expect(
        packed[0].whereType<CalendarEvent>().map((e) => e.id).toList(),
        ['walk', 'standup'],
        reason: 'week of Oct $monday',
      );
    }
  });

  test('a multi-day occurrence keeps one lane across its days', () {
    final week = [for (var i = 0; i < 7; i++) DateTime(2026, 10, 5 + i)];
    final span = _event(
      'span',
      DateTime(2026, 10, 6, 6),
      DateTime(2026, 10, 8, 6, 30),
    );

    final packed = calendarPackWeekEvents(week, [walk, span]);

    final lane = packed[1].indexWhere((e) => e?.id == 'span');
    expect(lane, isNonNegative);
    for (final c in [1, 2, 3]) {
      expect(packed[c][lane]?.id, 'span', reason: 'column $c');
    }
  });

  test('events with the same start and length keep one order', () {
    final week = [for (var i = 0; i < 7; i++) DateTime(2026, 10, 5 + i)];
    final a = _event(
      'a-sync',
      DateTime(2026, 10, 5, 9),
      DateTime(2026, 10, 5, 10),
      recurrence: const RecurrenceRule(frequency: EventRecurrence.daily),
    );
    final b = _event(
      'b-sync',
      DateTime(2026, 10, 5, 9),
      DateTime(2026, 10, 5, 10),
      recurrence: const RecurrenceRule(frequency: EventRecurrence.daily),
    );

    for (final input in [
      [a, b],
      [b, a],
    ]) {
      final packed = calendarPackWeekEvents(week, input);
      for (final column in packed) {
        expect(_ids(column), ['a-sync', 'b-sync']);
      }
    }
  });
}
