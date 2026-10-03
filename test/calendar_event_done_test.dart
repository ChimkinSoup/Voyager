import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/domain/services/calendar_recurrence_editing.dart';

DateTime d(int year, int month, int day, [int hour = 0]) =>
    DateTime(year, month, day, hour);

/// A mark's timestamp, [minute] minutes into 2026-04-01 UTC.
DateTime at(int minute) => DateTime.utc(2026, 4, 1, 0, minute);

const weekly = RecurrenceRule(frequency: EventRecurrence.weekly);

CalendarEvent event({
  RecurrenceRule recurrence = RecurrenceRule.none,
  List<DateTime> exceptionDates = const [],
  bool isDone = false,
  List<DateTime> doneDates = const [],
  Map<DateTime, CalendarDoneMark>? doneMarks,
  int version = 0,
}) {
  final now = DateTime.utc(2026, 1, 1);
  return CalendarEvent(
    id: 'master',
    createdAt: now,
    updatedAt: now,
    version: version,
    calendarId: 'c1',
    title: 'Gym',
    // Mondays, 9–10.
    start: d(2026, 3, 2, 9),
    end: d(2026, 3, 2, 10),
    isFullDay: false,
    recurrence: recurrence,
    exceptionDates: exceptionDates,
    isDone: isDone,
    doneMarks:
        doneMarks ??
        {
          for (final day in doneDates)
            day: CalendarDoneMark(done: true, at: at(0)),
        },
  );
}

List<DateTime> doneMondays(CalendarEvent e) => [
  for (
    var day = d(2026, 3, 2);
    day.isBefore(d(2026, 4, 7));
    day = DateTime(day.year, day.month, day.day + 7)
  )
    if (calendarEventDoneOn(e, day)) day,
];

void main() {
  group('marking done', () {
    test('a one-off flips isDone', () {
      final marked = setCalendarEventDone(event(), d(2026, 3, 2), done: true);
      expect(marked.isDone, isTrue);
      expect(calendarEventDoneOn(marked, d(2026, 3, 2)), isTrue);
    });

    test('a repeating event marks just that occurrence', () {
      final marked = setCalendarEventDone(
        event(recurrence: weekly),
        d(2026, 3, 16),
        done: true,
      );
      expect(marked.isDone, isFalse);
      expect(doneMondays(marked), [d(2026, 3, 16)]);
    });

    test('unmarking one occurrence leaves the others done, and keeps it as '
        'not done', () {
      final unmarked = setCalendarEventDone(
        event(recurrence: weekly, doneDates: [d(2026, 3, 9), d(2026, 3, 16)]),
        d(2026, 3, 9),
        done: false,
      );
      expect(doneMondays(unmarked), [d(2026, 3, 16)]);
      expect(unmarked.doneMarks[d(2026, 3, 9)]?.done, isFalse);
    });

    test('days no occurrence covers are never done', () {
      final e = event(recurrence: weekly, doneDates: [d(2026, 3, 9)]);
      expect(calendarEventDoneOn(e, d(2026, 3, 10)), isFalse);
    });

    test('a series ignores isDone, so a leftover flag cannot pin it done', () {
      final e = event(recurrence: weekly, isDone: true);
      expect(doneMondays(e), isEmpty);
      expect(nextCalendarOccurrence(e, d(2026, 3, 1)), isNotNull);
    });

    test('a one-off ignores done marks', () {
      final e = event(doneDates: [d(2026, 3, 2)]);
      expect(calendarEventDoneOn(e, d(2026, 3, 2)), isFalse);
    });
  });

  group('done state crosses a repeat change', () {
    test('a done one-off made weekly keeps its first occurrence done', () {
      final before = event(isDone: true);
      final edited = carryDoneAcrossRepeatChange(
        before,
        d(2026, 3, 2),
        before.copyWith(recurrence: weekly),
      );
      expect(doneMondays(edited), [d(2026, 3, 2)]);
    });

    test('a series made one-off keeps the shown occurrence\'s state', () {
      final before = event(recurrence: weekly, doneDates: [d(2026, 3, 16)]);
      final view = occurrenceView(before, d(2026, 3, 16));
      final edited = carryDoneAcrossRepeatChange(
        before,
        d(2026, 3, 16),
        view.copyWith(recurrence: RecurrenceRule.none),
      );
      expect(edited.isDone, isTrue);
      expect(
        carryDoneAcrossRepeatChange(
          before,
          d(2026, 3, 9),
          occurrenceView(
            before,
            d(2026, 3, 9),
          ).copyWith(recurrence: RecurrenceRule.none),
        ).isDone,
        isFalse,
      );
    });
  });

  group('notifications skip done occurrences', () {
    test('a done one-off has no next occurrence', () {
      expect(
        nextCalendarOccurrence(event(isDone: true), d(2026, 3, 1)),
        isNull,
      );
    });

    test('a done occurrence is skipped for the next one', () {
      final e = event(recurrence: weekly, doneDates: [d(2026, 3, 9)]);
      expect(
        nextCalendarOccurrence(e, d(2026, 3, 9, 8))?.start,
        d(2026, 3, 16, 9),
      );
    });

    test('a done event is left out of the inbox feed', () {
      final now = d(2026, 3, 2, 8);
      List<NotificationFeedItem> feed(CalendarEvent e) => buildNotificationFeed(
        tasks: const [],
        events: [e],
        bills: const [],
        now: now,
      );
      expect(feed(event()), hasLength(1));
      expect(feed(event(isDone: true)), isEmpty);
    });
  });

  group('done marks follow the series through edits', () {
    test('a this-event-only edit carries the done mark onto the override', () {
      final master = event(recurrence: weekly, doneDates: [d(2026, 3, 16)]);
      final result = editRecurringEvent(
        master: master,
        edited: occurrenceView(master, d(2026, 3, 16)).copyWith(title: 'Swim'),
        occurrenceDate: d(2026, 3, 16),
        scope: RecurrenceEditScope.thisEvent,
        newId: () => 'override',
      );
      expect(result.upserts.last.isDone, isTrue);
    });

    test('a this-and-future split keeps each mark on its own side', () {
      final master = event(
        recurrence: weekly,
        doneDates: [d(2026, 3, 9), d(2026, 3, 23)],
      );
      final result = editRecurringEvent(
        master: master,
        edited: occurrenceView(master, d(2026, 3, 16)).copyWith(title: 'Swim'),
        occurrenceDate: d(2026, 3, 16),
        scope: RecurrenceEditScope.thisAndFuture,
        newId: () => 'tail',
      );
      expect(result.upserts.first.doneDates, [d(2026, 3, 9)]);
      expect(result.upserts.last.doneDates, [d(2026, 3, 23)]);
    });

    test('moving the whole series slides its done marks with it, leaving the '
        'old dates as not done', () {
      final master = event(recurrence: weekly, doneDates: [d(2026, 3, 9)]);
      // The Mar 16 occurrence dragged to Tuesday the 17th.
      final moved = occurrenceView(
        master,
        d(2026, 3, 16),
      ).copyWith(start: d(2026, 3, 17, 9), end: d(2026, 3, 17, 10));
      final rebased = rebaseToAnchor(moved, master, d(2026, 3, 16));
      expect(calendarEventDoneOn(rebased, d(2026, 3, 10)), isTrue);
      expect(calendarEventDoneOn(rebased, d(2026, 3, 17)), isFalse);
      // So another device's copy of the old mark cannot bring it back.
      expect(rebased.doneMarks[d(2026, 3, 9)]?.done, isFalse);
    });
  });

  group('sync', () {
    Map<String, dynamic> remote(CalendarEvent e) => calendarEventToFirestore(e);

    test('done state round-trips through Firestore', () {
      final e = event(recurrence: weekly, doneDates: [d(2026, 3, 9)]);
      final back = mergeCalendarEventFromRemote(remote(e), e.id);
      expect(back.doneMarks, e.doneMarks);
    });

    test('two devices marking different occurrences keep both', () {
      final mine = event(
        recurrence: weekly,
        version: 2,
        doneMarks: {d(2026, 3, 9): CalendarDoneMark(done: true, at: at(1))},
      );
      final theirs = event(
        recurrence: weekly,
        version: 2,
        doneMarks: {d(2026, 3, 16): CalendarDoneMark(done: true, at: at(2))},
      );
      final merged = mergeCalendarEventFromRemote(
        remote(theirs),
        'master',
        local: mine,
      );
      expect(doneMondays(merged), [d(2026, 3, 9), d(2026, 3, 16)]);
    });

    test('marks merge even when the local row wins the rest of the record', () {
      final mine = event(
        recurrence: weekly,
        version: 5,
        doneMarks: {d(2026, 3, 9): CalendarDoneMark(done: true, at: at(1))},
      );
      final theirs = event(
        recurrence: weekly,
        version: 1,
        doneMarks: {d(2026, 3, 16): CalendarDoneMark(done: true, at: at(2))},
      );
      final merged = mergeCalendarEventFromRemote(
        remote(theirs),
        'master',
        local: mine,
      );
      expect(merged.version, 5);
      expect(doneMondays(merged), [d(2026, 3, 9), d(2026, 3, 16)]);
    });

    test('a newer unmark beats an older mark, either way round', () {
      final marked = event(
        recurrence: weekly,
        doneMarks: {d(2026, 3, 9): CalendarDoneMark(done: true, at: at(1))},
      );
      final unmarked = event(
        recurrence: weekly,
        doneMarks: {d(2026, 3, 9): CalendarDoneMark(done: false, at: at(2))},
      );
      expect(
        doneMondays(
          mergeCalendarEventFromRemote(
            remote(unmarked),
            'master',
            local: marked,
          ),
        ),
        isEmpty,
      );
      expect(
        doneMondays(
          mergeCalendarEventFromRemote(
            remote(marked),
            'master',
            local: unmarked,
          ),
        ),
        isEmpty,
      );
    });

    test('an event with no marks uploads none, so it cannot wipe the stored '
        'ones', () {
      expect(remote(event(recurrence: weekly)), isNot(contains('doneMarks')));
    });

    test('a document from the date-list build reads as marked done', () {
      final data = remote(event(recurrence: weekly))
        ..['doneDates'] = '2026-03-09';
      final back = mergeCalendarEventFromRemote(data, 'master');
      expect(doneMondays(back), [d(2026, 3, 9)]);
    });
  });
}
