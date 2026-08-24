import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/domain/services/calendar_recurrence_editing.dart';
import 'package:voyager/domain/services/recurrence_engine.dart';

DateTime d(int year, int month, int day, [int hour = 0, int minute = 0]) =>
    DateTime(year, month, day, hour, minute);

CalendarEvent series({
  required DateTime start,
  required DateTime end,
  RecurrenceRule recurrence = const RecurrenceRule(
    frequency: EventRecurrence.weekly,
  ),
  List<DateTime> exceptionDates = const [],
  DateTime? recurrenceEndDate,
  String title = 'Standup',
}) {
  final now = DateTime.utc(2026, 1, 1);
  return CalendarEvent(
    id: 'master',
    createdAt: now,
    updatedAt: now,
    calendarId: 'c1',
    title: title,
    start: start,
    end: end,
    recurrence: recurrence,
    exceptionDates: exceptionDates,
    recurrenceEndDate: recurrenceEndDate,
  );
}

int idCounter = 0;
String fakeNewId() => 'new-${++idCounter}';

void main() {
  setUp(() => idCounter = 0);

  group('delete scope', () {
    final master = series(start: d(2026, 3, 2, 9), end: d(2026, 3, 2, 10));

    test('this event only adds an exception, keeping the series', () {
      final result = deleteRecurringEvent(
        master,
        d(2026, 3, 16),
        RecurrenceEditScope.thisEvent,
      );
      expect(result.softDeletes, isEmpty);
      expect(result.upserts, hasLength(1));
      final updated = result.upserts.single;
      expect(calendarEventOccursOnDay(updated, d(2026, 3, 16)), isFalse);
      expect(calendarEventOccursOnDay(updated, d(2026, 3, 9)), isTrue);
      expect(calendarEventOccursOnDay(updated, d(2026, 3, 23)), isTrue);
    });

    test('this and future truncates the series the day before', () {
      final result = deleteRecurringEvent(
        master,
        d(2026, 3, 16),
        RecurrenceEditScope.thisAndFuture,
      );
      expect(result.softDeletes, isEmpty);
      final updated = result.upserts.single;
      expect(updated.recurrenceEndDate, d(2026, 3, 15));
      expect(calendarEventOccursOnDay(updated, d(2026, 3, 9)), isTrue);
      expect(calendarEventOccursOnDay(updated, d(2026, 3, 16)), isFalse);
      expect(calendarEventOccursOnDay(updated, d(2026, 3, 23)), isFalse);
    });

    test('this and future from the first occurrence drops the series', () {
      final result = deleteRecurringEvent(
        master,
        d(2026, 3, 2),
        RecurrenceEditScope.thisAndFuture,
      );
      expect(result.softDeletes, ['master']);
      expect(result.upserts, isEmpty);
    });

    test('all events soft-deletes the series row', () {
      final result = deleteRecurringEvent(
        master,
        d(2026, 3, 16),
        RecurrenceEditScope.allEvents,
      );
      expect(result.softDeletes, ['master']);
    });
  });

  group('occurrence view', () {
    test('moves a single-day event onto the clicked occurrence', () {
      final master = series(start: d(2026, 3, 2, 9), end: d(2026, 3, 2, 10));
      final view = occurrenceView(master, d(2026, 3, 16));
      expect(view.start, d(2026, 3, 16, 9));
      expect(view.end, d(2026, 3, 16, 10));
    });

    test('carries a multi-day span along', () {
      final master = series(start: d(2026, 3, 2, 9), end: d(2026, 3, 4, 17));
      final view = occurrenceView(master, d(2026, 3, 16));
      expect(view.start, d(2026, 3, 16, 9));
      expect(view.end, d(2026, 3, 18, 17));
    });

    test('is a no-op on the anchor occurrence', () {
      final master = series(start: d(2026, 3, 2, 9), end: d(2026, 3, 2, 10));
      expect(identical(occurrenceView(master, d(2026, 3, 2)), master), isTrue);
    });

    test('rebaseToAnchor undoes it when nothing moved', () {
      final master = series(start: d(2026, 3, 2, 9), end: d(2026, 3, 4, 17));
      final view = occurrenceView(master, d(2026, 3, 16));
      final back = rebaseToAnchor(view, master, d(2026, 3, 16));
      expect(back.start, master.start);
      expect(back.end, master.end);
    });

    test('rebaseToAnchor carries a date change back as a shift', () {
      final master = series(start: d(2026, 3, 2, 9), end: d(2026, 3, 2, 10));
      // The user opened Mar 16 and dragged it to Mar 18 — two days later.
      final moved = occurrenceView(master, d(2026, 3, 16)).copyWith(
        start: d(2026, 3, 18, 11),
        end: d(2026, 3, 18, 12),
      );
      final back = rebaseToAnchor(moved, master, d(2026, 3, 16));
      // The whole series shifts by the same two days, keeping the new time.
      expect(back.start, d(2026, 3, 4, 11));
      expect(back.end, d(2026, 3, 4, 12));
    });

    test('rebaseToAnchor slides the exception dates with the pattern', () {
      final master = series(
        start: d(2026, 3, 2, 9),
        end: d(2026, 3, 2, 10),
        exceptionDates: [d(2026, 3, 9), d(2026, 3, 23)],
      );
      final moved = occurrenceView(master, d(2026, 3, 16)).copyWith(
        start: d(2026, 3, 18, 9),
        end: d(2026, 3, 18, 10),
      );
      final back = rebaseToAnchor(moved, master, d(2026, 3, 16));

      // Left where they were, the exceptions would no longer land on any
      // occurrence and both deleted occurrences would come back.
      expect(back.exceptionDates, [d(2026, 3, 11), d(2026, 3, 25)]);
      for (final skipped in back.exceptionDates) {
        expect(calendarEventOccursOnDay(back, skipped), isFalse);
      }
      expect(calendarEventOccursOnDay(back, d(2026, 3, 18)), isTrue);
    });

    test('rebaseToAnchor leaves the exception dates alone when nothing moved',
        () {
      final master = series(
        start: d(2026, 3, 2, 9),
        end: d(2026, 3, 2, 10),
        exceptionDates: [d(2026, 3, 9)],
      );
      final view = occurrenceView(master, d(2026, 3, 16));
      final back = rebaseToAnchor(view, master, d(2026, 3, 16));
      expect(back.exceptionDates, [d(2026, 3, 9)]);
    });

    test('rebaseToAnchor slides the series end date with the pattern', () {
      // Weekly Mondays from Mar 2, capped so the last occurrence is Mar 30.
      final master = series(
        start: d(2026, 3, 2, 9),
        end: d(2026, 3, 2, 10),
        recurrenceEndDate: d(2026, 3, 30),
      );
      // The user opened Mar 16 and moved it to Mar 18 — the whole series slides
      // two days, onto Wednesdays.
      final moved = occurrenceView(master, d(2026, 3, 16)).copyWith(
        start: d(2026, 3, 18, 9),
        end: d(2026, 3, 18, 10),
      );
      final back = rebaseToAnchor(moved, master, d(2026, 3, 16));

      expect(back.recurrenceEndDate, d(2026, 4, 1));
      // Left at Mar 30, the cap would fall before the moved final occurrence
      // and quietly drop it from the series.
      expect(calendarEventOccursOnDay(back, d(2026, 4, 1)), isTrue);
      expect(calendarEventOccursOnDay(back, d(2026, 4, 8)), isFalse);
    });

    test('rebaseToAnchor leaves an open-ended series open-ended', () {
      final master = series(start: d(2026, 3, 2, 9), end: d(2026, 3, 2, 10));
      final moved = occurrenceView(master, d(2026, 3, 16)).copyWith(
        start: d(2026, 3, 18, 9),
        end: d(2026, 3, 18, 10),
      );
      expect(
        rebaseToAnchor(moved, master, d(2026, 3, 16)).recurrenceEndDate,
        isNull,
      );
    });

    test('rebaseToAnchor leaves the end date alone when nothing moved', () {
      final master = series(
        start: d(2026, 3, 2, 9),
        end: d(2026, 3, 2, 10),
        recurrenceEndDate: d(2026, 3, 30),
      );
      final view = occurrenceView(master, d(2026, 3, 16));
      expect(
        rebaseToAnchor(view, master, d(2026, 3, 16)).recurrenceEndDate,
        d(2026, 3, 30),
      );
    });

    test('recurrenceRebaseShiftDays reports the days the user moved by', () {
      final master = series(start: d(2026, 3, 2, 9), end: d(2026, 3, 2, 10));
      final moved = occurrenceView(master, d(2026, 3, 16))
          .copyWith(start: d(2026, 3, 18, 9));
      expect(recurrenceRebaseShiftDays(moved, d(2026, 3, 16)), 2);
      expect(
        recurrenceRebaseShiftDays(
          occurrenceView(master, d(2026, 3, 16)),
          d(2026, 3, 16),
        ),
        0,
      );
    });
  });

  group('edit scope', () {
    final master = series(start: d(2026, 3, 2, 9), end: d(2026, 3, 2, 10));

    test('this event only splits off a detached, non-repeating row', () {
      final edited = occurrenceView(
        master,
        d(2026, 3, 16),
      ).copyWith(title: 'Retro');
      final result = editRecurringEvent(
        master: master,
        edited: edited,
        occurrenceDate: d(2026, 3, 16),
        scope: RecurrenceEditScope.thisEvent,
        newId: fakeNewId,
      );
      expect(result.upserts, hasLength(2));

      final updatedMaster = result.upserts.first;
      expect(updatedMaster.id, 'master');
      expect(updatedMaster.title, 'Standup');
      expect(calendarEventOccursOnDay(updatedMaster, d(2026, 3, 16)), isFalse);

      final override = result.upserts.last;
      expect(override.id, 'new-1');
      expect(override.title, 'Retro');
      expect(override.recurrence, RecurrenceRule.none);
      expect(override.recurrenceParentId, 'master');
      expect(override.recurrenceDate, d(2026, 3, 16));
      expect(override.start, d(2026, 3, 16, 9));
    });

    test('this and future truncates the head and starts a new series', () {
      final edited = occurrenceView(master, d(2026, 3, 16)).copyWith(
        title: 'Retro',
        start: d(2026, 3, 16, 14),
        end: d(2026, 3, 16, 15),
      );
      final result = editRecurringEvent(
        master: master,
        edited: edited,
        occurrenceDate: d(2026, 3, 16),
        scope: RecurrenceEditScope.thisAndFuture,
        newId: fakeNewId,
      );
      expect(result.upserts, hasLength(2));

      final head = result.upserts.first;
      expect(head.id, 'master');
      expect(head.title, 'Standup');
      expect(head.recurrenceEndDate, d(2026, 3, 15));
      expect(calendarEventOccursOnDay(head, d(2026, 3, 9)), isTrue);
      expect(calendarEventOccursOnDay(head, d(2026, 3, 16)), isFalse);

      final tail = result.upserts.last;
      expect(tail.title, 'Retro');
      expect(tail.start, d(2026, 3, 16, 14));
      expect(tail.recurrence, master.recurrence);
      // The tail picks up exactly where the head stopped, with no gap and no
      // overlap.
      expect(calendarEventOccursOnDay(tail, d(2026, 3, 16)), isTrue);
      expect(calendarEventOccursOnDay(tail, d(2026, 3, 23)), isTrue);
      expect(calendarEventOccursOnDay(tail, d(2026, 3, 9)), isFalse);
    });

    test('this and future from the first occurrence is an all-events edit', () {
      final edited = master.copyWith(title: 'Retro');
      final result = editRecurringEvent(
        master: master,
        edited: edited,
        occurrenceDate: d(2026, 3, 2),
        scope: RecurrenceEditScope.thisAndFuture,
        newId: fakeNewId,
      );
      expect(result.upserts, hasLength(1));
      expect(result.upserts.single.id, 'master');
      expect(result.upserts.single.recurrenceEndDate, isNull);
    });

    test('a split divides existing exceptions between the two halves', () {
      final withSkips = series(
        start: d(2026, 3, 2, 9),
        end: d(2026, 3, 2, 10),
        exceptionDates: [d(2026, 3, 9), d(2026, 3, 30)],
      );
      final result = editRecurringEvent(
        master: withSkips,
        edited: occurrenceView(withSkips, d(2026, 3, 16)),
        occurrenceDate: d(2026, 3, 16),
        scope: RecurrenceEditScope.thisAndFuture,
        newId: fakeNewId,
      );
      expect(result.upserts.first.exceptionDates, [d(2026, 3, 9)]);
      expect(result.upserts.last.exceptionDates, [d(2026, 3, 30)]);
    });

    test('all events rewrites the series row in place', () {
      final edited = master.copyWith(title: 'Retro');
      final result = editRecurringEvent(
        master: master,
        edited: edited,
        occurrenceDate: d(2026, 3, 16),
        scope: RecurrenceEditScope.allEvents,
        newId: fakeNewId,
      );
      expect(result.upserts, hasLength(1));
      expect(result.upserts.single.id, 'master');
      expect(result.upserts.single.title, 'Retro');
    });
  });

  group('task roll-forward', () {
    const weekly = RecurrenceRule(frequency: EventRecurrence.weekly);

    test('advances by one interval and keeps the time of day', () {
      final next = nextTaskDueDate(
        dueDate: d(2026, 3, 2, 9, 30),
        anchor: d(2026, 3, 2, 9, 30),
        rule: weekly,
        now: d(2026, 3, 2, 12),
      );
      expect(next, d(2026, 3, 9, 9, 30));
    });

    test('an overdue task skips the backlog in one tick', () {
      const daily = RecurrenceRule(frequency: EventRecurrence.daily);
      // Due five days ago; ticking it should land tomorrow, not yesterday.
      final next = nextTaskDueDate(
        dueDate: d(2026, 3, 2, 8),
        anchor: d(2026, 3, 2, 8),
        rule: daily,
        now: d(2026, 3, 7, 12),
      );
      expect(next, d(2026, 3, 8, 8));
    });

    test('a skipped backlog still lands on a real occurrence', () {
      const everyThree =
          RecurrenceRule(frequency: EventRecurrence.daily, interval: 3);
      final next = nextTaskDueDate(
        dueDate: d(2026, 3, 2),
        anchor: d(2026, 3, 2),
        rule: everyThree,
        now: d(2026, 3, 7),
      );
      // Occurrences are Mar 2, 5, 8, 11 — the first one after today.
      expect(next, d(2026, 3, 8));
      expect(recurrenceStartsOnDay(d(2026, 3, 2), everyThree, next!), isTrue);
    });

    test('the frozen anchor stops a day-31 monthly task drifting', () {
      const monthly = RecurrenceRule(frequency: EventRecurrence.monthly);
      final anchor = d(2026, 1, 31, 7);

      final feb = nextTaskDueDate(
        dueDate: anchor,
        anchor: anchor,
        rule: monthly,
        now: d(2026, 1, 31),
      );
      expect(feb, d(2026, 2, 28, 7));

      // The second roll measures from the *anchor*, not from Feb 28, so March
      // returns to the 31st instead of sticking on the 28th.
      final mar = nextTaskDueDate(
        dueDate: feb!,
        anchor: anchor,
        rule: monthly,
        now: d(2026, 2, 28),
      );
      expect(mar, d(2026, 3, 31, 7));
    });

    test('a non-repeating rule yields no next date', () {
      expect(
        nextTaskDueDate(
          dueDate: d(2026, 3, 2),
          anchor: d(2026, 3, 2),
          rule: RecurrenceRule.none,
          now: d(2026, 3, 2),
        ),
        isNull,
      );
    });

    test('weekly on specific days walks day by day', () {
      const rule = RecurrenceRule(
        frequency: EventRecurrence.weekly,
        weekdays: {DateTime.monday, DateTime.wednesday, DateTime.friday},
      );
      final anchor = d(2026, 3, 2, 9); // Monday
      final wed = nextTaskDueDate(
        dueDate: anchor,
        anchor: anchor,
        rule: rule,
        now: anchor,
      );
      expect(wed, d(2026, 3, 4, 9));
      final fri = nextTaskDueDate(
        dueDate: wed!,
        anchor: anchor,
        rule: rule,
        now: wed,
      );
      expect(fri, d(2026, 3, 6, 9));
      final mon = nextTaskDueDate(
        dueDate: fri!,
        anchor: anchor,
        rule: rule,
        now: fri,
      );
      expect(mon, d(2026, 3, 9, 9));
    });
  });
}
