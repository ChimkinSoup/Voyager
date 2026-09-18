import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';

// =============================================================================
// Reminder schedule math (`SCHEDULED_REMINDERS_HLD.md` §3, §4.3, §4.5).
//
// Everything here is pure and works in the device's local wall clock: `now` is
// a local DateTime, and a stored UTC instant only ever enters as something to
// compare against. Whether a source is pending, due or snoozed is derived from
// its schedule plus the one synced [ReminderDeliveryState] — never stored.
// =============================================================================

/// One natural firing of a reminder source.
class ReminderOccurrence {
  const ReminderOccurrence({required this.fireAt, required this.key});

  /// Local instant the reminder fires at.
  final DateTime fireAt;

  /// Names the occurrence across devices: the local wall-clock time of the
  /// schedule it came from (see [reminderOccurrenceKey]).
  final String key;

  @override
  bool operator ==(Object other) =>
      other is ReminderOccurrence && other.fireAt == fireAt && other.key == key;

  @override
  int get hashCode => Object.hash(fireAt, key);

  @override
  String toString() => 'ReminderOccurrence($key)';
}

/// `yyyy-MM-ddTHH:mm` of a local wall-clock time.
///
/// Wall clock rather than an instant so that two devices in different
/// timezones name the same "Tuesday 1:00 PM" the same way, and an
/// acknowledgement made on one clears it on the other.
String reminderOccurrenceKey(DateTime local) =>
    '${local.year.toString().padLeft(4, '0')}-'
    '${local.month.toString().padLeft(2, '0')}-'
    '${local.day.toString().padLeft(2, '0')}T'
    '${local.hour.toString().padLeft(2, '0')}:'
    '${local.minute.toString().padLeft(2, '0')}';

/// [day]'s date at [minutes] past local midnight.
DateTime atLocalMinutes(DateTime day, int minutes) =>
    DateTime(day.year, day.month, day.day, minutes ~/ 60, minutes % 60);

/// The time a date-only todo, or an all-day event, is reminded against.
const int kDateOnlyReminderMinutes = 9 * 60;

// -----------------------------------------------------------------------------
// Scheduled rules
// -----------------------------------------------------------------------------

/// The most recent occurrence of [rule] at or before [now] that the current
/// schedule covers, or null.
///
/// Only the latest one matters: an older unacknowledged occurrence is replaced
/// by a newer one rather than stacked under it (§3.2).
ReminderOccurrence? latestRuleOccurrence(
  ScheduledReminderRule rule,
  DateTime now,
) {
  final armed = rule.armedAt.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  DateTime? fireAt;
  switch (rule.scheduleKind) {
    case ReminderScheduleKind.daily:
      final candidate = atLocalMinutes(today, rule.localTimeMinutes);
      fireAt = candidate.isAfter(now)
          ? atLocalMinutes(_addDays(today, -1), rule.localTimeMinutes)
          : candidate;
    case ReminderScheduleKind.weekly:
      for (var i = 0; i <= 7; i++) {
        final day = _addDays(today, -i);
        if (!rule.weeklyWeekdays.contains(day.weekday)) continue;
        final candidate = atLocalMinutes(day, rule.localTimeMinutes);
        if (candidate.isAfter(now)) continue;
        fireAt = candidate;
        break;
      }
    case ReminderScheduleKind.once:
      final date = rule.onceLocalDate;
      if (date == null) return null;
      final candidate = atLocalMinutes(date, rule.localTimeMinutes);
      if (!candidate.isAfter(now)) fireAt = candidate;
  }
  if (fireAt == null || fireAt.isBefore(armed)) return null;
  return ReminderOccurrence(fireAt: fireAt, key: reminderOccurrenceKey(fireAt));
}

/// The first occurrence of [rule] strictly after [now], or null.
DateTime? nextRuleFire(ScheduledReminderRule rule, DateTime now) {
  final armed = rule.armedAt.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  bool counts(DateTime at) => at.isAfter(now) && !at.isBefore(armed);
  switch (rule.scheduleKind) {
    case ReminderScheduleKind.daily:
    case ReminderScheduleKind.weekly:
      // Eight days reach every weekday at least once past today. A rule armed
      // further ahead than that — a clock skewed by more than a week on the
      // device that armed it — waits until the local clock catches up.
      for (var i = 0; i <= 8; i++) {
        final day = _addDays(today, i);
        if (rule.scheduleKind == ReminderScheduleKind.weekly &&
            !rule.weeklyWeekdays.contains(day.weekday)) {
          continue;
        }
        final candidate = atLocalMinutes(day, rule.localTimeMinutes);
        if (counts(candidate)) return candidate;
      }
      return null;
    case ReminderScheduleKind.once:
      final date = rule.onceLocalDate;
      if (date == null) return null;
      final candidate = atLocalMinutes(date, rule.localTimeMinutes);
      return counts(candidate) ? candidate : null;
  }
}

// -----------------------------------------------------------------------------
// Entity bells
// -----------------------------------------------------------------------------

/// The local time a todo's bell counts back from, or null without a due date.
///
/// A due date with no time is stored as local midnight, the same reading the
/// todo panel uses to decide whether to print a time — so a task due at
/// exactly 12:00 AM is treated as date-only and reminded at 9:00 AM.
DateTime? todoReminderBase(TodoTask task) {
  final due = task.dueDate?.toLocal();
  if (due == null) return null;
  if (due.hour == 0 && due.minute == 0) {
    return atLocalMinutes(due, kDateOnlyReminderMinutes);
  }
  return due;
}

DateTime _eventReminderBase(CalendarEvent event, DateTime occurrenceStart) =>
    event.isFullDay
    ? atLocalMinutes(occurrenceStart, kDateOnlyReminderMinutes)
    : occurrenceStart;

ReminderOccurrence _entityOccurrence(DateTime base, int offsetMinutes) =>
    ReminderOccurrence(
      fireAt: base.subtract(Duration(minutes: offsetMinutes)),
      // The base, not the fire time: changing the lead time on an occurrence
      // already acknowledged must not raise it again.
      key: reminderOccurrenceKey(base),
    );

bool _todoRemindable(TodoTask task) =>
    task.deletedAt == null && !task.completed && task.dueDate != null;

/// The due bell occurrence of [task], or null. A task has one occurrence at a
/// time: a repeating one rolls its due date forward when ticked off.
ReminderOccurrence? latestTodoOccurrence(
  TodoTask task,
  EntityReminder reminder,
  DateTime now,
) {
  if (!_todoRemindable(task)) return null;
  final occurrence = _entityOccurrence(
    todoReminderBase(task)!,
    reminder.offsetMinutes,
  );
  if (occurrence.fireAt.isAfter(now)) return null;
  if (occurrence.fireAt.isBefore(reminder.armedAt.toLocal())) return null;
  return occurrence;
}

DateTime? nextTodoFire(TodoTask task, EntityReminder reminder, DateTime now) {
  if (!_todoRemindable(task)) return null;
  final fireAt = _entityOccurrence(
    todoReminderBase(task)!,
    reminder.offsetMinutes,
  ).fireAt;
  if (!fireAt.isAfter(now)) return null;
  if (fireAt.isBefore(reminder.armedAt.toLocal())) return null;
  return fireAt;
}

/// How far back [latestEventOccurrence] looks, widening only when the nearer
/// window holds nothing. A daily series is answered by the first; the last
/// covers a yearly one.
const List<Duration> _eventLookbackWindows = [
  Duration(days: 2),
  Duration(days: 35),
  Duration(days: 400),
];

const Duration _eventLookahead = Duration(days: 400);

/// Occurrence starts of [event] in `[from, to]`, in order.
Iterable<DateTime> _eventStartsBetween(
  CalendarEvent event,
  DateTime from,
  DateTime to,
) sync* {
  var cursor = from;
  // Bounded for the same reason [nextCalendarOccurrence] is.
  for (var i = 0; i < 1000; i++) {
    final occurrence = nextCalendarOccurrence(event, cursor);
    if (occurrence == null || occurrence.start.isAfter(to)) return;
    if (!occurrence.start.isBefore(from)) yield occurrence.start;
    final end = occurrence.end.isAfter(cursor) ? occurrence.end : cursor;
    cursor = end.add(const Duration(microseconds: 1));
  }
}

/// The latest bell occurrence of [event] at or before [now], or null.
ReminderOccurrence? latestEventOccurrence(
  CalendarEvent event,
  EntityReminder reminder,
  DateTime now,
) {
  if (event.deletedAt != null) return null;
  final armed = reminder.armedAt.toLocal();
  final offset = Duration(minutes: reminder.offsetMinutes);
  final to = now.add(offset);
  // An all-day occurrence is reminded up to nine hours after it starts, so the
  // floor sits a day under the earliest start that could still count.
  final floor = armed.add(offset).subtract(const Duration(days: 1));
  for (final window in _eventLookbackWindows) {
    var from = to.subtract(window);
    final reachedFloor = !from.isAfter(floor);
    if (reachedFloor) from = floor;
    ReminderOccurrence? latest;
    for (final start in _eventStartsBetween(event, from, to)) {
      final occurrence = _entityOccurrence(
        _eventReminderBase(event, start),
        reminder.offsetMinutes,
      );
      if (occurrence.fireAt.isAfter(now)) continue;
      if (occurrence.fireAt.isBefore(armed)) continue;
      latest = occurrence;
    }
    if (latest != null || reachedFloor) return latest;
  }
  return null;
}

DateTime? nextEventFire(
  CalendarEvent event,
  EntityReminder reminder,
  DateTime now,
) {
  if (event.deletedAt != null) return null;
  final armed = reminder.armedAt.toLocal();
  final offset = Duration(minutes: reminder.offsetMinutes);
  final from = now.add(offset).subtract(const Duration(days: 1));
  for (final start in _eventStartsBetween(
    event,
    from,
    from.add(_eventLookahead),
  )) {
    final fireAt = _entityOccurrence(
      _eventReminderBase(event, start),
      reminder.offsetMinutes,
    ).fireAt;
    if (fireAt.isAfter(now) && !fireAt.isBefore(armed)) return fireAt;
  }
  return null;
}

// -----------------------------------------------------------------------------
// Delivery
// -----------------------------------------------------------------------------

enum ReminderPhase { pending, due, snoozed, acked }

class ReminderEvaluation {
  const ReminderEvaluation({
    required this.phase,
    this.occurrence,
    this.dueSince,
    this.snoozeUntil,
    this.nextFireAt,
    this.supersededSnooze = false,
  });

  final ReminderPhase phase;

  /// The occurrence that is due, snoozed or acknowledged. Null while pending.
  final ReminderOccurrence? occurrence;

  /// When the sticky became due: the natural fire time, or the end of the
  /// snooze it came back from.
  final DateTime? dueSince;
  final DateTime? snoozeUntil;

  /// The next instant this source needs attention — an OS alert and a
  /// re-evaluation. For a snooze, whichever comes first of its end and the
  /// next natural occurrence, since the natural one replaces it.
  final DateTime? nextFireAt;

  /// True when a snooze on an older occurrence was just replaced by a newer
  /// natural one (§3.1 step 3).
  final bool supersededSnooze;

  /// Names this particular appearance of a due sticky. A snooze coming back
  /// is a new appearance of the same occurrence, and deserves its own alert.
  String? get instanceTag {
    final key = occurrence?.key;
    if (key == null || phase != ReminderPhase.due) return null;
    final snoozed = snoozeUntil;
    if (snoozed == null) return key;
    return '$key~${snoozed.toUtc().toIso8601String()}';
  }
}

/// Where a source stands at [now], from its [latest] natural occurrence, its
/// [nextNatural] one and the last thing the user did about it.
///
/// A natural occurrence newer than the one [state] was recorded against wins
/// outright — over an unacknowledged older one, and over a snooze still
/// running (§3 "Natural occurrence wins").
ReminderEvaluation evaluateReminder({
  required ReminderOccurrence? latest,
  required DateTime? nextNatural,
  required ReminderDeliveryState? state,
  required DateTime now,
}) {
  if (latest == null) {
    return ReminderEvaluation(
      phase: ReminderPhase.pending,
      nextFireAt: nextNatural,
    );
  }
  if (state == null || state.occurrenceKey != latest.key) {
    return ReminderEvaluation(
      phase: ReminderPhase.due,
      occurrence: latest,
      dueSince: latest.fireAt,
      nextFireAt: nextNatural,
      supersededSnooze: state?.status == ReminderDeliveryStatus.snoozed,
    );
  }
  switch (state.status) {
    case ReminderDeliveryStatus.acked:
      return ReminderEvaluation(
        phase: ReminderPhase.acked,
        occurrence: latest,
        nextFireAt: nextNatural,
      );
    case ReminderDeliveryStatus.snoozed:
      final until = state.snoozeUntil?.toLocal() ?? latest.fireAt;
      if (!until.isAfter(now)) {
        return ReminderEvaluation(
          phase: ReminderPhase.due,
          occurrence: latest,
          dueSince: until,
          snoozeUntil: until,
          nextFireAt: nextNatural,
        );
      }
      return ReminderEvaluation(
        phase: ReminderPhase.snoozed,
        occurrence: latest,
        snoozeUntil: until,
        nextFireAt: nextNatural != null && nextNatural.isBefore(until)
            ? nextNatural
            : until,
      );
  }
}

/// "Remind me in 10 min".
DateTime snoozeTenMinutesTarget(DateTime now) =>
    now.add(const Duration(minutes: 10));

/// "Remind me tomorrow": the next calendar day at the clock time the snooze
/// was pressed (§3 — Mon 3:00 PM → Tue 3:00 PM), whatever the rule's own time.
DateTime snoozeTomorrowTarget(DateTime now) => DateTime(
  now.year,
  now.month,
  now.day + 1,
  now.hour,
  now.minute,
  now.second,
);

/// Whole calendar days rather than a Duration, so a DST change in between does
/// not land on 11 PM or 1 AM.
DateTime _addDays(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);
