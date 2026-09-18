import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/services/reminder_schedule.dart';

/// `SCHEDULED_REMINDERS_HLD.md` §11: schedule math, snooze vs. natural
/// occurrence, coalescing, and entity bell offsets.

final _stamp = DateTime.utc(2026, 1, 1);

ScheduledReminderRule _rule({
  ReminderScheduleKind kind = ReminderScheduleKind.daily,
  int minutes = 13 * 60,
  Set<int> weekdays = const {},
  DateTime? onceDate,
  DateTime? armedAt,
}) => ScheduledReminderRule(
  id: 'r1',
  createdAt: _stamp,
  updatedAt: _stamp,
  title: 'Vitamins',
  scheduleKind: kind,
  localTimeMinutes: minutes,
  weeklyWeekdays: weekdays,
  onceLocalDate: onceDate,
  armedAt: armedAt ?? DateTime(2026, 9, 1),
);

ReminderDeliveryState _state(
  String occurrenceKey,
  ReminderDeliveryStatus status, {
  DateTime? snoozeUntil,
}) => ReminderDeliveryState(
  id: 'rule:r1',
  sourceKind: ReminderSourceKind.scheduledRule,
  sourceId: 'r1',
  occurrenceKey: occurrenceKey,
  status: status,
  snoozeUntil: snoozeUntil?.toUtc(),
  createdAt: _stamp,
  updatedAt: _stamp,
);

ReminderEvaluation _evaluateRule(
  ScheduledReminderRule rule,
  DateTime now, [
  ReminderDeliveryState? state,
]) => evaluateReminder(
  latest: latestRuleOccurrence(rule, now),
  nextNatural: nextRuleFire(rule, now),
  state: state,
  now: now,
);

EntityReminder _bell(
  ReminderSourceKind kind, {
  int offsetMinutes = 0,
  DateTime? armedAt,
}) => EntityReminder(
  id: reminderSourceKey(kind, 'x'),
  createdAt: _stamp,
  updatedAt: _stamp,
  sourceKind: kind,
  entityId: 'x',
  enabled: true,
  offsetMinutes: offsetMinutes,
  armedAt: armedAt ?? DateTime(2026, 9, 1),
);

TodoTask _task(DateTime? due, {bool completed = false}) => TodoTask(
  id: 'x',
  createdAt: _stamp,
  updatedAt: _stamp,
  listId: 'l',
  title: 'Pay rent',
  dueDate: due?.toUtc(),
  completed: completed,
);

CalendarEvent _event({
  required DateTime start,
  required DateTime end,
  bool isFullDay = false,
  RecurrenceRule recurrence = RecurrenceRule.none,
}) => CalendarEvent(
  id: 'x',
  createdAt: _stamp,
  updatedAt: _stamp,
  calendarId: 'cal',
  title: 'Standup',
  start: start.toUtc(),
  end: end.toUtc(),
  isFullDay: isFullDay,
  recurrence: recurrence,
);

void main() {
  // 2026-09-14 is a Monday.
  final monday = DateTime(2026, 9, 14);

  group('daily rule', () {
    test('the new day\'s occurrence takes over at the rule\'s time', () {
      final rule = _rule();
      final before = _evaluateRule(rule, DateTime(2026, 9, 14, 12, 59));
      // Sunday's occurrence is still due — nothing acknowledged it.
      expect(before.occurrence?.key, '2026-09-13T13:00');
      final at = _evaluateRule(rule, DateTime(2026, 9, 14, 13, 0));
      expect(at.phase, ReminderPhase.due);
      expect(at.occurrence!.key, '2026-09-14T13:00');
      expect(at.nextFireAt, DateTime(2026, 9, 15, 13, 0));
    });

    test('an occurrence before the rule was armed is never due', () {
      final rule = _rule(armedAt: DateTime(2026, 9, 14, 13, 30));
      final evaluation = _evaluateRule(rule, DateTime(2026, 9, 14, 14, 0));
      expect(evaluation.phase, ReminderPhase.pending);
      expect(evaluation.nextFireAt, DateTime(2026, 9, 15, 13, 0));
    });

    test('acknowledging clears it until the next natural occurrence', () {
      final rule = _rule();
      final state = _state('2026-09-14T13:00', ReminderDeliveryStatus.acked);
      final later = _evaluateRule(rule, DateTime(2026, 9, 14, 23, 0), state);
      expect(later.phase, ReminderPhase.acked);
      final tomorrow = _evaluateRule(rule, DateTime(2026, 9, 15, 13, 0), state);
      expect(tomorrow.phase, ReminderPhase.due);
      expect(tomorrow.occurrence!.key, '2026-09-15T13:00');
    });
  });

  group('snooze (§3.1)', () {
    test('tomorrow targets the next day at the clock time of the press', () {
      expect(
        snoozeTomorrowTarget(DateTime(2026, 9, 14, 15, 0)),
        DateTime(2026, 9, 15, 15, 0),
      );
      // Month and year boundaries roll over as calendar days.
      expect(
        snoozeTomorrowTarget(DateTime(2026, 12, 31, 8, 30)),
        DateTime(2027, 1, 1, 8, 30),
      );
    });

    test('ten minutes is ten minutes', () {
      expect(
        snoozeTenMinutesTarget(DateTime(2026, 9, 14, 23, 55)),
        DateTime(2026, 9, 15, 0, 5),
      );
    });

    test(
      'Mon 3 PM tomorrow-snooze is replaced by the Tue 1 PM natural one',
      () {
        final rule = _rule();
        final state = _state(
          '2026-09-14T13:00',
          ReminderDeliveryStatus.snoozed,
          snoozeUntil: DateTime(2026, 9, 15, 15, 0),
        );

        final mondayEvening = _evaluateRule(
          rule,
          DateTime(2026, 9, 14, 20, 0),
          state,
        );
        expect(mondayEvening.phase, ReminderPhase.snoozed);
        // The alert is armed for the natural 1 PM, not the 3 PM snooze.
        expect(mondayEvening.nextFireAt, DateTime(2026, 9, 15, 13, 0));

        final tuesday = _evaluateRule(
          rule,
          DateTime(2026, 9, 15, 13, 0),
          state,
        );
        expect(tuesday.phase, ReminderPhase.due);
        expect(tuesday.occurrence!.key, '2026-09-15T13:00');
        expect(tuesday.dueSince, DateTime(2026, 9, 15, 13, 0));
        expect(tuesday.supersededSnooze, isTrue);

        // Wednesday is back on the rule's own time: no permanent 3 PM shift.
        expect(tuesday.nextFireAt, DateTime(2026, 9, 16, 13, 0));
      },
    );

    test('a ten-minute snooze comes back as a new appearance', () {
      final rule = _rule();
      final state = _state(
        '2026-09-14T13:00',
        ReminderDeliveryStatus.snoozed,
        snoozeUntil: DateTime(2026, 9, 14, 13, 10),
      );
      final during = _evaluateRule(rule, DateTime(2026, 9, 14, 13, 5), state);
      expect(during.phase, ReminderPhase.snoozed);
      expect(during.nextFireAt, DateTime(2026, 9, 14, 13, 10));

      final after = _evaluateRule(rule, DateTime(2026, 9, 14, 13, 10), state);
      expect(after.phase, ReminderPhase.due);
      expect(after.supersededSnooze, isFalse);
      expect(after.instanceTag, isNot('2026-09-14T13:00'));
      expect(after.instanceTag, startsWith('2026-09-14T13:00~'));
    });

    test(
      'a ten-minute snooze is superseded if the natural one lands first',
      () {
        final rule = _rule(kind: ReminderScheduleKind.daily, minutes: 0);
        final state = _state(
          '2026-09-14T00:00',
          ReminderDeliveryStatus.snoozed,
          snoozeUntil: DateTime(2026, 9, 15, 0, 5),
        );
        final evaluation = _evaluateRule(
          rule,
          DateTime(2026, 9, 15, 0, 0),
          state,
        );
        expect(evaluation.phase, ReminderPhase.due);
        expect(evaluation.occurrence!.key, '2026-09-15T00:00');
        expect(evaluation.supersededSnooze, isTrue);
      },
    );
  });

  test('coalesce: unacknowledged day N and day N+1 are one due state', () {
    final rule = _rule();
    final evaluation = _evaluateRule(rule, DateTime(2026, 9, 18, 13, 30));
    expect(evaluation.phase, ReminderPhase.due);
    expect(evaluation.occurrence!.key, '2026-09-18T13:00');
  });

  group('weekly rule', () {
    test('fires only on the chosen weekdays', () {
      final rule = _rule(
        kind: ReminderScheduleKind.weekly,
        minutes: 8 * 60,
        weekdays: {DateTime.monday, DateTime.thursday},
      );
      final tuesday = DateTime(2026, 9, 15, 9, 0);
      expect(
        latestRuleOccurrence(rule, tuesday)!.fireAt,
        DateTime(2026, 9, 14, 8, 0),
      );
      expect(nextRuleFire(rule, tuesday), DateTime(2026, 9, 17, 8, 0));
      expect(nextRuleFire(rule, monday), DateTime(2026, 9, 14, 8, 0));
    });

    test('with no weekdays never fires', () {
      final rule = _rule(kind: ReminderScheduleKind.weekly);
      expect(latestRuleOccurrence(rule, monday), isNull);
      expect(nextRuleFire(rule, monday), isNull);
    });
  });

  group('once rule', () {
    final rule = _rule(
      kind: ReminderScheduleKind.once,
      minutes: 9 * 60,
      onceDate: DateTime(2026, 9, 20),
    );

    test('fires once at its date and time', () {
      expect(nextRuleFire(rule, monday), DateTime(2026, 9, 20, 9, 0));
      expect(latestRuleOccurrence(rule, monday), isNull);
      final after = DateTime(2026, 9, 25);
      expect(latestRuleOccurrence(rule, after)!.key, '2026-09-20T09:00');
      expect(nextRuleFire(rule, after), isNull);
    });

    test('acknowledged, nothing is left to fire', () {
      final state = _state('2026-09-20T09:00', ReminderDeliveryStatus.acked);
      final evaluation = _evaluateRule(rule, DateTime(2026, 9, 21), state);
      expect(evaluation.phase, ReminderPhase.acked);
      expect(evaluation.nextFireAt, isNull);
    });
  });

  group('todo bell', () {
    test('a timed due date fires offset before it', () {
      final bell = _bell(ReminderSourceKind.todo, offsetMinutes: 60);
      final task = _task(DateTime(2026, 9, 14, 17, 0));
      expect(nextTodoFire(task, bell, monday), DateTime(2026, 9, 14, 16, 0));
      final occurrence = latestTodoOccurrence(
        task,
        bell,
        DateTime(2026, 9, 14, 16, 0),
      );
      expect(occurrence!.fireAt, DateTime(2026, 9, 14, 16, 0));
      // Keyed on the due time, so changing the lead time does not re-raise it.
      expect(occurrence.key, '2026-09-14T17:00');
    });

    test('a date-only due date counts back from 9:00 AM', () {
      final bell = _bell(ReminderSourceKind.todo, offsetMinutes: 15);
      final task = _task(DateTime(2026, 9, 14));
      expect(nextTodoFire(task, bell, monday), DateTime(2026, 9, 14, 8, 45));
    });

    test('a completed or undated task never fires', () {
      final bell = _bell(ReminderSourceKind.todo);
      final late = DateTime(2026, 9, 20);
      expect(
        latestTodoOccurrence(
          _task(DateTime(2026, 9, 14), completed: true),
          bell,
          late,
        ),
        isNull,
      );
      expect(latestTodoOccurrence(_task(null), bell, late), isNull);
    });
  });

  group('calendar bell', () {
    test('a timed event fires an hour before its start', () {
      final bell = _bell(ReminderSourceKind.calendarEvent, offsetMinutes: 60);
      final event = _event(
        start: DateTime(2026, 9, 14, 10, 0),
        end: DateTime(2026, 9, 14, 11, 0),
      );
      expect(nextEventFire(event, bell, monday), DateTime(2026, 9, 14, 9, 0));
      expect(
        latestEventOccurrence(event, bell, DateTime(2026, 9, 14, 9, 30))!.key,
        '2026-09-14T10:00',
      );
    });

    test('an all-day event counts back from 9:00 AM on its day', () {
      final bell = _bell(
        ReminderSourceKind.calendarEvent,
        offsetMinutes: 24 * 60,
      );
      final event = _event(
        start: DateTime(2026, 9, 16),
        end: DateTime(2026, 9, 17),
        isFullDay: true,
      );
      expect(nextEventFire(event, bell, monday), DateTime(2026, 9, 15, 9, 0));
    });

    test('a repeating event resolves its latest and next occurrence', () {
      final bell = _bell(ReminderSourceKind.calendarEvent, offsetMinutes: 15);
      final event = _event(
        start: DateTime(2026, 8, 3, 9, 0),
        end: DateTime(2026, 8, 3, 9, 30),
        recurrence: const RecurrenceRule(frequency: EventRecurrence.daily),
      );
      final now = DateTime(2026, 9, 14, 12, 0);
      expect(latestEventOccurrence(event, bell, now)!.key, '2026-09-14T09:00');
      expect(nextEventFire(event, bell, now), DateTime(2026, 9, 15, 8, 45));
    });

    test('an occurrence before the bell was armed is not due', () {
      final bell = _bell(
        ReminderSourceKind.calendarEvent,
        armedAt: DateTime(2026, 9, 14, 11, 0),
      );
      final event = _event(
        start: DateTime(2026, 9, 14, 10, 0),
        end: DateTime(2026, 9, 14, 10, 30),
      );
      expect(
        latestEventOccurrence(event, bell, DateTime(2026, 9, 14, 12, 0)),
        isNull,
      );
    });
  });
}
