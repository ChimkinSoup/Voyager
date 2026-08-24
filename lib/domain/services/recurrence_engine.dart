import 'package:flutter/material.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';

// =============================================================================
// Recurrence date math.
//
// Every function here answers a question about where an occurrence *starts*.
// Nothing in this file knows how long an occurrence lasts — a multi-day
// calendar event's span is layered on top by calendar_recurrence.dart, which is
// what keeps "repeat monthly" meaning "one four-day block per month" rather
// than "four separate days each month".
//
// All inputs are treated as date-only local dates. Day arithmetic goes through
// [epochDay] and [addDays] rather than DateTime.difference()/add(Duration)
// because both are off by one across a DST boundary, which would slide
// every occurrence after the change by a day.
// =============================================================================

/// Days since the epoch for a date-only local date, DST-proof.
///
/// Public because callers doing their own span math need the same DST-proof
/// day difference; `a.difference(b).inDays` is off by one across a clock
/// change.
int epochDay(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

/// [date] shifted by [days], staying on local midnight.
///
/// Not `add(Duration(days:))`: that adds absolute time, so a local midnight
/// plus seven days across a fall-back transition lands at 23:00 on day six.
/// Overflowing the day field instead lets DateTime renormalize the calendar
/// date, which is what every caller here actually wants.
DateTime addDays(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

/// [dateTime] shifted by [days] calendar days, keeping its local wall clock.
///
/// [addDays]'s counterpart for values that carry a time of day: the same field
/// arithmetic, so the shift survives a DST transition, but the hour and minute
/// come along — sliding a series must not move "every Tuesday at 10:00" off
/// 10:00, and must not flatten it to midnight either.
DateTime addDaysKeepingTime(DateTime dateTime, int days) {
  final local = dateTime.toLocal();
  return DateTime(
    local.year,
    local.month,
    local.day + days,
    local.hour,
    local.minute,
    local.second,
    local.millisecond,
  );
}

int _monthIndex(DateTime date) => date.year * 12 + (date.month - 1);

int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// The Monday that starts the week [date] falls in.
///
/// Weekly rules count their interval in whole weeks, so "every 2 weeks on Tue
/// and Thu" needs a fixed week boundary to count from; without one the two
/// weekdays could land in different parity buckets. Monday is the iCalendar
/// default (WKST=MO) and is not user-configurable here.
DateTime _weekStart(DateTime date) =>
    addDays(DateUtils.dateOnly(date), -(date.weekday - 1));

int _clampDay(int day, int year, int month) {
  final last = _daysInMonth(year, month);
  return day < last ? day : last;
}

/// [anchor] advanced by [months], with the day-of-month clamped to the target
/// month's length.
///
/// Clamping rather than skipping: a monthly task due on the 31st rolls to
/// Feb 28 and then back to Mar 31, instead of skipping February entirely and
/// surprising the user with a two-month jump.
DateTime _addMonthsClamped(DateTime anchor, int months) {
  final index = _monthIndex(anchor) + months;
  final year = index ~/ 12;
  final month = index % 12 + 1;
  return DateTime(year, month, _clampDay(anchor.day, year, month));
}

DateTime _addYearsClamped(DateTime anchor, int years) {
  final year = anchor.year + years;
  return DateTime(
    year,
    anchor.month,
    _clampDay(anchor.day, year, anchor.month),
  );
}

/// The weekdays a weekly [rule] fires on, defaulting to the weekday [anchor]
/// itself falls on when the user has not picked any.
Set<int> effectiveWeekdays(RecurrenceRule rule, DateTime anchor) =>
    rule.weekdays.isEmpty ? {DateUtils.dateOnly(anchor).weekday} : rule.weekdays;

/// Whether an occurrence of [rule] anchored at [anchor] *starts* on [day].
bool recurrenceStartsOnDay(
  DateTime anchor,
  RecurrenceRule rule,
  DateTime day,
) {
  final a = DateUtils.dateOnly(anchor);
  final d = DateUtils.dateOnly(day);
  if (d.isBefore(a)) return false;
  if (!rule.repeats) return d == a;

  final interval = rule.interval < 1 ? 1 : rule.interval;

  switch (rule.frequency) {
    case EventRecurrence.none:
      return d == a;
    case EventRecurrence.daily:
      return (epochDay(d) - epochDay(a)) % interval == 0;
    case EventRecurrence.weekly:
      if (!effectiveWeekdays(rule, a).contains(d.weekday)) return false;
      final weeks = (epochDay(_weekStart(d)) - epochDay(_weekStart(a))) ~/ 7;
      return weeks % interval == 0;
    case EventRecurrence.monthly:
      final months = _monthIndex(d) - _monthIndex(a);
      if (months % interval != 0) return false;
      return d.day == _clampDay(a.day, d.year, d.month);
    case EventRecurrence.yearly:
      if ((d.year - a.year) % interval != 0) return false;
      if (d.month != a.month) return false;
      return d.day == _clampDay(a.day, d.year, d.month);
  }
}

/// The latest occurrence start at or before [day], or null when [rule] has not
/// started yet by then.
///
/// This is the primitive multi-day coverage is built on: an event covers [day]
/// when its most recent occurrence started no more than its span ago.
DateTime? latestOccurrenceOnOrBefore(
  DateTime anchor,
  RecurrenceRule rule,
  DateTime day,
) {
  final a = DateUtils.dateOnly(anchor);
  final d = DateUtils.dateOnly(day);
  if (d.isBefore(a)) return null;
  if (!rule.repeats) return a;

  final interval = rule.interval < 1 ? 1 : rule.interval;

  switch (rule.frequency) {
    case EventRecurrence.none:
      return a;
    case EventRecurrence.daily:
      final steps = (epochDay(d) - epochDay(a)) ~/ interval;
      return addDays(a, steps * interval);
    case EventRecurrence.weekly:
      // Bounded scan: the gap between consecutive weekly occurrences can never
      // exceed one skipped stretch plus the tail of a week.
      final limit = 7 * interval + 7;
      for (var back = 0; back <= limit; back++) {
        final candidate = addDays(d, -back);
        if (candidate.isBefore(a)) return null;
        if (recurrenceStartsOnDay(a, rule, candidate)) return candidate;
      }
      return null;
    case EventRecurrence.monthly:
      var periods = (_monthIndex(d) - _monthIndex(a)) ~/ interval;
      var candidate = _addMonthsClamped(a, periods * interval);
      // The clamped day can land after [d] inside the aligned month (an anchor
      // on the 31st read on the 5th), so step back at most one period.
      if (candidate.isAfter(d)) {
        periods -= 1;
        if (periods < 0) return null;
        candidate = _addMonthsClamped(a, periods * interval);
      }
      return candidate.isBefore(a) ? null : candidate;
    case EventRecurrence.yearly:
      var periods = (d.year - a.year) ~/ interval;
      var candidate = _addYearsClamped(a, periods * interval);
      if (candidate.isAfter(d)) {
        periods -= 1;
        if (periods < 0) return null;
        candidate = _addYearsClamped(a, periods * interval);
      }
      return candidate.isBefore(a) ? null : candidate;
  }
}

/// The first occurrence start strictly after [after], or null when [rule] does
/// not repeat.
///
/// Used by the to-do roll-forward: ticking off an occurrence moves the due date
/// here rather than marking the task done.
DateTime? nextOccurrenceAfter(
  DateTime anchor,
  RecurrenceRule rule,
  DateTime after,
) {
  if (!rule.repeats) return null;
  final a = DateUtils.dateOnly(anchor);
  final t = DateUtils.dateOnly(after);
  final interval = rule.interval < 1 ? 1 : rule.interval;

  // Anything before the anchor resolves to the anchor itself.
  if (t.isBefore(a)) return a;

  switch (rule.frequency) {
    case EventRecurrence.none:
      return null;
    case EventRecurrence.daily:
      final steps = (epochDay(t) - epochDay(a)) ~/ interval + 1;
      return addDays(a, steps * interval);
    case EventRecurrence.weekly:
      final limit = 7 * interval + 7;
      for (var ahead = 1; ahead <= limit; ahead++) {
        final candidate = addDays(t, ahead);
        if (recurrenceStartsOnDay(a, rule, candidate)) return candidate;
      }
      return null;
    case EventRecurrence.monthly:
      // Clamping means the aligned period can still sit at or before [t], so
      // probe a couple of periods forward rather than assuming the first hits.
      final base = (_monthIndex(t) - _monthIndex(a)) ~/ interval;
      for (var periods = base; periods <= base + 2; periods++) {
        final candidate = _addMonthsClamped(a, periods * interval);
        if (candidate.isAfter(t)) return candidate;
      }
      return null;
    case EventRecurrence.yearly:
      final base = (t.year - a.year) ~/ interval;
      for (var periods = base; periods <= base + 2; periods++) {
        final candidate = _addYearsClamped(a, periods * interval);
        if (candidate.isAfter(t)) return candidate;
      }
      return null;
  }
}

const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Three-letter name for a [DateTime.monday]..[DateTime.sunday] value.
String shortWeekdayName(int weekday) => _weekdayNames[(weekday - 1) % 7];

/// Human-readable summary of [rule], e.g. "Every 2 weeks on Mon, Thu".
///
/// [anchor] supplies the weekday a plain weekly rule fires on, so the label
/// reads the same as what the calendar will actually draw.
String recurrenceRuleLabel(RecurrenceRule rule, {DateTime? anchor}) {
  if (!rule.repeats) return 'Does not repeat';
  final interval = rule.interval < 1 ? 1 : rule.interval;

  switch (rule.frequency) {
    case EventRecurrence.none:
      return 'Does not repeat';
    case EventRecurrence.daily:
      return interval == 1 ? 'Every day' : 'Every $interval days';
    case EventRecurrence.weekly:
      final unit = interval == 1 ? 'Every week' : 'Every $interval weeks';
      final days = anchor != null
          ? effectiveWeekdays(rule, anchor)
          : rule.weekdays;
      if (days.isEmpty) return unit;
      final sorted = days.toList()..sort();
      return '$unit on ${sorted.map(shortWeekdayName).join(', ')}';
    case EventRecurrence.monthly:
      return interval == 1 ? 'Every month' : 'Every $interval months';
    case EventRecurrence.yearly:
      return interval == 1 ? 'Every year' : 'Every $interval years';
  }
}

/// The due date a repeating task moves to when its current occurrence is ticked
/// off, or null when [rule] does not repeat.
///
/// [anchor] is the frozen series anchor, not the current due date: measuring
/// from the due date would let a "monthly on the 31st" task that rolled to
/// Feb 28 re-anchor there and stay on the 28th for good.
///
/// [now] skips a backlog. A daily task five days overdue advances to tomorrow
/// rather than to yesterday, so one tick clears it instead of six — and the
/// occurrence it lands on is still exactly one the pattern defines.
///
/// The wall-clock time of [dueDate] is carried over, which is what makes
/// "repeat at 09:00" hold across the roll.
/// The recurrence anchor a task should carry after the user reschedules it by
/// hand.
///
/// The anchor is frozen the first time a repeat is set and only moves on a
/// manual reschedule. Letting it follow every due date would re-anchor it on
/// each roll-forward, and a "monthly on the 31st" task that landed on Feb 28
/// would stay on the 28th from then on.
///
/// Clearing the due date clears the anchor with it: `repeats` reads false
/// without a due date, so the pattern goes dormant, and a stale anchor left
/// behind would silently revive the *old* pattern the moment any new date was
/// picked.
DateTime? rescheduledRecurrenceAnchor({
  required RecurrenceRule rule,
  required DateTime? newDue,
}) {
  if (!rule.repeats || newDue == null) return null;
  return newDue;
}

DateTime? nextTaskDueDate({
  required DateTime dueDate,
  required DateTime anchor,
  required RecurrenceRule rule,
  required DateTime now,
}) {
  if (!rule.repeats) return null;
  final dueLocal = dueDate.toLocal();
  final anchorLocal = DateUtils.dateOnly(anchor.toLocal());
  final from = DateUtils.dateOnly(dueLocal);
  final today = DateUtils.dateOnly(now.toLocal());
  final after = from.isBefore(today) ? today : from;

  final next = nextOccurrenceAfter(anchorLocal, rule, after);
  if (next == null) return null;
  return DateTime(
    next.year,
    next.month,
    next.day,
    dueLocal.hour,
    dueLocal.minute,
    dueLocal.second,
    dueLocal.millisecond,
  );
}
