import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/domain/services/recurrence_engine.dart';

DateTime d(int year, int month, int day) => DateTime(year, month, day);

CalendarEvent event({
  required DateTime start,
  required DateTime end,
  RecurrenceRule recurrence = RecurrenceRule.none,
  DateTime? recurrenceEndDate,
  List<DateTime> exceptionDates = const [],
}) {
  final now = DateTime.utc(2026, 1, 1);
  return CalendarEvent(
    id: 'e1',
    createdAt: now,
    updatedAt: now,
    calendarId: 'c1',
    title: 'Test',
    start: start,
    end: end,
    recurrence: recurrence,
    recurrenceEndDate: recurrenceEndDate,
    exceptionDates: exceptionDates,
  );
}

/// Every day in [from]..[to] the event covers.
List<DateTime> coveredDays(CalendarEvent e, DateTime from, DateTime to) {
  final out = <DateTime>[];
  for (var day = from; !day.isAfter(to); day = addDays(day, 1)) {
    if (calendarEventOccursOnDay(e, day)) out.add(day);
  }
  return out;
}

void main() {
  group('RecurrenceRule storage', () {
    test('plain rules round-trip as the bare frequency name', () {
      for (final f in EventRecurrence.values) {
        final rule = RecurrenceRule(frequency: f);
        expect(rule.toStorage(), f.name);
        expect(RecurrenceRule.parse(f.name), rule);
      }
    });

    test('legacy enum-only values still parse', () {
      expect(RecurrenceRule.parse('weekly').frequency, EventRecurrence.weekly);
      expect(RecurrenceRule.parse('weekly').interval, 1);
      expect(RecurrenceRule.parse('none'), RecurrenceRule.none);
      expect(RecurrenceRule.parse(null), RecurrenceRule.none);
      expect(RecurrenceRule.parse(''), RecurrenceRule.none);
    });

    test('custom rules round-trip interval and weekdays', () {
      const rule = RecurrenceRule(
        frequency: EventRecurrence.weekly,
        interval: 2,
        weekdays: {DateTime.monday, DateTime.thursday},
      );
      expect(rule.toStorage(), 'weekly;i=2;bd=1,4');
      expect(RecurrenceRule.parse(rule.toStorage()), rule);

      const everyThreeDays =
          RecurrenceRule(frequency: EventRecurrence.daily, interval: 3);
      expect(everyThreeDays.toStorage(), 'daily;i=3');
      expect(RecurrenceRule.parse('daily;i=3'), everyThreeDays);
    });

    test('unknown or malformed input degrades to none, never throws', () {
      expect(RecurrenceRule.parse('hourly'), RecurrenceRule.none);
      expect(RecurrenceRule.parse('weekly;i=abc').interval, 1);
      expect(RecurrenceRule.parse('weekly;i=0').interval, 1);
      expect(RecurrenceRule.parse('weekly;bd=9,x,3').weekdays, {3});
      expect(RecurrenceRule.parse('daily;bd=1,2').weekdays, isEmpty);
    });
  });

  group('occurrence starts', () {
    test('every 3 days steps from the anchor', () {
      const rule = RecurrenceRule(frequency: EventRecurrence.daily, interval: 3);
      final anchor = d(2026, 3, 2);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 2)), isTrue);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 3)), isFalse);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 5)), isTrue);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 8)), isTrue);
      // Nothing before the anchor ever fires.
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 2, 27)), isFalse);
    });

    test('weekly on specific weekdays fires on each of them', () {
      const rule = RecurrenceRule(
        frequency: EventRecurrence.weekly,
        weekdays: {DateTime.monday, DateTime.wednesday, DateTime.friday},
      );
      final anchor = d(2026, 3, 2); // a Monday
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 2)), isTrue);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 4)), isTrue);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 6)), isTrue);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 5)), isFalse);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 9)), isTrue);
    });

    test('every 2 weeks keeps both weekdays in the same parity week', () {
      const rule = RecurrenceRule(
        frequency: EventRecurrence.weekly,
        interval: 2,
        weekdays: {DateTime.tuesday, DateTime.thursday},
      );
      final anchor = d(2026, 3, 3); // Tuesday
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 3)), isTrue);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 5)), isTrue);
      // The following week is skipped entirely.
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 10)), isFalse);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 12)), isFalse);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 17)), isTrue);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 19)), isTrue);
    });

    test('monthly clamps a day-31 anchor to short months, never skips', () {
      const rule = RecurrenceRule(frequency: EventRecurrence.monthly);
      final anchor = d(2026, 1, 31);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 2, 28)), isTrue);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 2, 27)), isFalse);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 3, 31)), isTrue);
      expect(recurrenceStartsOnDay(anchor, rule, d(2026, 4, 30)), isTrue);
    });

    test('yearly clamps Feb 29 to Feb 28 in common years', () {
      const rule = RecurrenceRule(frequency: EventRecurrence.yearly);
      final anchor = d(2024, 2, 29);
      expect(recurrenceStartsOnDay(anchor, rule, d(2025, 2, 28)), isTrue);
      expect(recurrenceStartsOnDay(anchor, rule, d(2028, 2, 29)), isTrue);
    });
  });

  group('nextOccurrenceAfter', () {
    test('advances a daily interval past the given day', () {
      const rule = RecurrenceRule(frequency: EventRecurrence.daily, interval: 3);
      final anchor = d(2026, 3, 2);
      expect(nextOccurrenceAfter(anchor, rule, d(2026, 3, 2)), d(2026, 3, 5));
      expect(nextOccurrenceAfter(anchor, rule, d(2026, 3, 4)), d(2026, 3, 5));
      expect(nextOccurrenceAfter(anchor, rule, d(2026, 3, 5)), d(2026, 3, 8));
    });

    test('walks a multi-weekday weekly rule one weekday at a time', () {
      const rule = RecurrenceRule(
        frequency: EventRecurrence.weekly,
        weekdays: {DateTime.monday, DateTime.wednesday, DateTime.friday},
      );
      final anchor = d(2026, 3, 2);
      expect(nextOccurrenceAfter(anchor, rule, d(2026, 3, 2)), d(2026, 3, 4));
      expect(nextOccurrenceAfter(anchor, rule, d(2026, 3, 4)), d(2026, 3, 6));
      expect(nextOccurrenceAfter(anchor, rule, d(2026, 3, 6)), d(2026, 3, 9));
    });

    test('monthly from a day-31 anchor rolls Jan 31 → Feb 28 → Mar 31', () {
      const rule = RecurrenceRule(frequency: EventRecurrence.monthly);
      final anchor = d(2026, 1, 31);
      final feb = nextOccurrenceAfter(anchor, rule, d(2026, 1, 31));
      expect(feb, d(2026, 2, 28));
      // Crucially the anchor stays day-31, so March returns to the 31st rather
      // than sticking on the 28th forever.
      expect(nextOccurrenceAfter(anchor, rule, feb!), d(2026, 3, 31));
    });

    test('a due date before the anchor resolves to the anchor', () {
      const rule = RecurrenceRule(frequency: EventRecurrence.weekly);
      expect(
        nextOccurrenceAfter(d(2026, 3, 10), rule, d(2026, 3, 1)),
        d(2026, 3, 10),
      );
    });

    test('a non-repeating rule has no next occurrence', () {
      expect(
        nextOccurrenceAfter(d(2026, 3, 2), RecurrenceRule.none, d(2026, 3, 2)),
        isNull,
      );
    });
  });

  group('multi-day events repeat as a whole block', () {
    test('a 4-day monthly event is one block per month, not four marks', () {
      final e = event(
        start: d(2026, 1, 30),
        end: d(2026, 2, 2),
        recurrence: const RecurrenceRule(frequency: EventRecurrence.monthly),
      );

      // January: the anchor block runs Jan 30 → Feb 2.
      expect(
        coveredDays(e, d(2026, 1, 25), d(2026, 2, 5)),
        [d(2026, 1, 30), d(2026, 1, 31), d(2026, 2, 1), d(2026, 2, 2)],
      );

      // February clamps to the 28th and still carries the full 4-day span.
      expect(
        coveredDays(e, d(2026, 2, 20), d(2026, 3, 10)),
        [
          d(2026, 2, 28),
          d(2026, 3, 1),
          d(2026, 3, 2),
          d(2026, 3, 3),
        ],
      );

      // Apr 1 and Apr 2 are covered, but as the tail of the block that began
      // on Mar 30 — not as a standalone "1st of every month" mark. The proof
      // is that the days between blocks stay clear.
      expect(calendarEventOccursOnDay(e, d(2026, 4, 2)), isTrue);
      expect(calendarEventOccursOnDay(e, d(2026, 4, 3)), isFalse);
      expect(calendarEventOccursOnDay(e, d(2026, 4, 15)), isFalse);
      expect(calendarEventOccursOnDay(e, d(2026, 4, 29)), isFalse);
      expect(calendarEventOccursOnDay(e, d(2026, 4, 30)), isTrue);
    });

    test('a monthly block clamps its start and drags its span with it', () {
      // The sharpest split between "anchor + span" and the old "the days the
      // span touches become the pattern" reading. Under the old rule this
      // event was day-of-month {30, 31}, so February — which has neither — was
      // skipped outright. Under anchor + span the start clamps to Feb 28 and
      // the one-day span carries it into March.
      final e = event(
        start: d(2026, 1, 30),
        end: d(2026, 1, 31),
        recurrence: const RecurrenceRule(frequency: EventRecurrence.monthly),
      );
      expect(
        coveredDays(e, d(2026, 2, 1), d(2026, 3, 5)),
        [d(2026, 2, 28), d(2026, 3, 1)],
      );
      expect(
        coveredDays(e, d(2026, 3, 25), d(2026, 4, 5)),
        [d(2026, 3, 30), d(2026, 3, 31)],
      );
    });

    test('a 3-day weekly event repeats the block, not its weekdays', () {
      final e = event(
        start: d(2026, 3, 2), // Mon
        end: d(2026, 3, 4), // Wed
        recurrence: const RecurrenceRule(frequency: EventRecurrence.weekly),
      );
      expect(
        coveredDays(e, d(2026, 3, 2), d(2026, 3, 15)),
        [
          d(2026, 3, 2),
          d(2026, 3, 3),
          d(2026, 3, 4),
          d(2026, 3, 9),
          d(2026, 3, 10),
          d(2026, 3, 11),
        ],
      );
    });

    test('bars bridge inside one occurrence and break between occurrences', () {
      final e = event(
        start: d(2026, 3, 2),
        end: d(2026, 3, 4),
        recurrence: const RecurrenceRule(frequency: EventRecurrence.weekly),
      );
      expect(calendarEventBarsBridge(e, d(2026, 3, 2), d(2026, 3, 3)), isTrue);
      expect(calendarEventBarsBridge(e, d(2026, 3, 3), d(2026, 3, 4)), isTrue);
      // Between the Wednesday end and the next Monday there is no bridge.
      expect(calendarEventBarsBridge(e, d(2026, 3, 4), d(2026, 3, 5)), isFalse);

      expect(calendarEventBarStartsOnDay(e, d(2026, 3, 2)), isTrue);
      expect(calendarEventBarStartsOnDay(e, d(2026, 3, 3)), isFalse);
      expect(calendarEventBarEndsOnDay(e, d(2026, 3, 4)), isTrue);
      expect(calendarEventBarEndsOnDay(e, d(2026, 3, 3)), isFalse);
      expect(calendarEventBarStartsOnDay(e, d(2026, 3, 9)), isTrue);
    });

    test('a daily single-day event still covers every day', () {
      final e = event(
        start: d(2026, 3, 2),
        end: d(2026, 3, 2),
        recurrence: const RecurrenceRule(frequency: EventRecurrence.daily),
      );
      expect(coveredDays(e, d(2026, 3, 2), d(2026, 3, 6)).length, 5);
      // Single-day occurrences never bridge.
      expect(calendarEventBarsBridge(e, d(2026, 3, 2), d(2026, 3, 3)), isFalse);
    });

    test('a non-repeating multi-day event covers exactly its span', () {
      final e = event(start: d(2026, 3, 2), end: d(2026, 3, 5));
      expect(
        coveredDays(e, d(2026, 2, 25), d(2026, 3, 10)),
        [d(2026, 3, 2), d(2026, 3, 3), d(2026, 3, 4), d(2026, 3, 5)],
      );
    });
  });

  group('exceptions and end date', () {
    test('an exception removes exactly one occurrence and its whole span', () {
      final e = event(
        start: d(2026, 3, 2),
        end: d(2026, 3, 4),
        recurrence: const RecurrenceRule(frequency: EventRecurrence.weekly),
        exceptionDates: [d(2026, 3, 9)],
      );
      expect(calendarEventOccursOnDay(e, d(2026, 3, 2)), isTrue);
      expect(calendarEventOccursOnDay(e, d(2026, 3, 9)), isFalse);
      expect(calendarEventOccursOnDay(e, d(2026, 3, 10)), isFalse);
      expect(calendarEventOccursOnDay(e, d(2026, 3, 11)), isFalse);
      expect(calendarEventOccursOnDay(e, d(2026, 3, 16)), isTrue);
    });

    test('an overlapping neighbour survives its sibling being excepted', () {
      // A 5-day block every 3 days: occurrences overlap, so skipping one must
      // not blank out days the previous one still covers.
      final e = event(
        start: d(2026, 3, 2),
        end: d(2026, 3, 6),
        recurrence:
            const RecurrenceRule(frequency: EventRecurrence.daily, interval: 3),
        exceptionDates: [d(2026, 3, 5)],
      );
      // Mar 5 is skipped as a start, but Mar 2's block still runs to Mar 6.
      expect(calendarEventOccursOnDay(e, d(2026, 3, 5)), isTrue);
      expect(calendarEventOccursOnDay(e, d(2026, 3, 6)), isTrue);
      // Mar 7 was only ever reachable from the excepted Mar 5 block.
      expect(calendarEventOccursOnDay(e, d(2026, 3, 7)), isFalse);
      expect(calendarEventOccursOnDay(e, d(2026, 3, 8)), isTrue);
    });

    test('recurrenceEndDate caps starts but lets the last span finish', () {
      final e = event(
        start: d(2026, 3, 2),
        end: d(2026, 3, 4),
        recurrence: const RecurrenceRule(frequency: EventRecurrence.weekly),
        recurrenceEndDate: d(2026, 3, 9),
      );
      expect(calendarEventOccursOnDay(e, d(2026, 3, 9)), isTrue);
      // The Mar 9 occurrence still runs its full span past the end date.
      expect(calendarEventOccursOnDay(e, d(2026, 3, 11)), isTrue);
      expect(calendarEventOccursOnDay(e, d(2026, 3, 16)), isFalse);
    });

    test('exception dates round-trip through storage', () {
      final dates = [d(2026, 3, 9), d(2026, 1, 5)];
      final encoded = encodeExceptionDates(dates);
      expect(encoded, '2026-01-05,2026-03-09');
      expect(decodeExceptionDates(encoded), [d(2026, 1, 5), d(2026, 3, 9)]);
      expect(encodeExceptionDates(const []), '');
      expect(decodeExceptionDates(''), isEmpty);
      expect(decodeExceptionDates(null), isEmpty);
      expect(decodeExceptionDates('garbage,2026-03-09'), [d(2026, 3, 9)]);
    });

    test('duplicate exception dates collapse', () {
      expect(
        encodeExceptionDates([d(2026, 3, 9), d(2026, 3, 9)]),
        '2026-03-09',
      );
    });
  });

  group('labels', () {
    test('describe plain and custom rules', () {
      expect(recurrenceRuleLabel(RecurrenceRule.none), 'Does not repeat');
      expect(
        recurrenceRuleLabel(
          const RecurrenceRule(frequency: EventRecurrence.daily),
        ),
        'Every day',
      );
      expect(
        recurrenceRuleLabel(
          const RecurrenceRule(frequency: EventRecurrence.daily, interval: 3),
        ),
        'Every 3 days',
      );
      expect(
        recurrenceRuleLabel(
          const RecurrenceRule(
            frequency: EventRecurrence.weekly,
            interval: 2,
            weekdays: {DateTime.monday, DateTime.thursday},
          ),
        ),
        'Every 2 weeks on Mon, Thu',
      );
      expect(
        recurrenceRuleLabel(
          const RecurrenceRule(frequency: EventRecurrence.weekly),
          anchor: d(2026, 3, 2),
        ),
        'Every week on Mon',
      );
    });
  });
}
