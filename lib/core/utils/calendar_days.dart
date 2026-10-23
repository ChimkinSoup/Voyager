/// Calendar-day arithmetic that survives daylight-saving transitions.
///
/// [DateTime]'s own `add`/`subtract`/`difference` work in absolute elapsed
/// time, so a `Duration(days: n)` is exactly `n * 24h` — which is not what a
/// calendar day is worth across a DST boundary. In a zone that observes one,
/// `DateTime(2025, 11, 1).add(const Duration(days: 10))` lands on
/// `2025-11-10 23:00` rather than on the 11th, and
/// `DateTime(2026, 3, 15).difference(DateTime(2026, 3, 1)).inDays` is 13
/// rather than 14.
///
/// Both are wrong in a way that hides: the hour-short result *floors* to the
/// previous day. The sparklines put a calendar-day offset on their x axis, so
/// an offset computed one day short makes a hovered point resolve to the
/// period before the one under the cursor — and the hover bubble then reports
/// its neighbour's value. It only bites in the half of the year on the far
/// side of a transition from the window's start, which is why it reads as
/// intermittent rather than as broken arithmetic.
library;

/// [date] moved by [days] calendar days, at local midnight.
///
/// Goes through the [DateTime] constructor, which normalises out-of-range
/// fields (`day: 0` is the previous month's last day, `day: 32` rolls into the
/// next month) and resolves the result in local time *after* normalising — so
/// it lands on the intended calendar day whatever DST did in between.
DateTime addCalendarDays(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

/// Whole calendar days from [from] to [to], ignoring both times of day.
///
/// Compares in UTC, which has no transitions to lose an hour to. The local
/// y/m/d fields are carried across rather than converted, so this counts days
/// on the calendar instead of elapsed time between two instants.
int calendarDaysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// The day a journal or dream entry written at [moment] belongs to, at local
/// midnight, when the user's day starts at [dayStartHour] (0–6) rather than
/// midnight: a 3 AM entry with a 5 AM start counts toward the day before.
///
/// Field-based like [addCalendarDays], so a DST night can't shift it.
DateTime journalDay(DateTime moment, int dayStartHour) {
  final local = moment.toLocal();
  return DateTime(
    local.year,
    local.month,
    local.hour < dayStartHour ? local.day - 1 : local.day,
  );
}

/// The calendar day a date-only [value] names, at local midnight.
///
/// Date-only fields (a task's due day, a bill's anchor, a counter's day) are
/// stored and synced as UTC midnight of that day — see [storedCalendarDay] —
/// because local midnight as an instant reads back a day early on any device
/// further west than the one that wrote it, or on the same device once it
/// has moved west. A value exactly at UTC midnight is that day; anything else
/// (a picker's local date, or a legacy local-midnight instant) is read in this
/// device's zone, as `jobCalendarDay` reads a job's date.
DateTime calendarDayOf(DateTime value) {
  if (value.isUtc &&
      value.hour == 0 &&
      value.minute == 0 &&
      value.second == 0 &&
      value.millisecond == 0 &&
      value.microsecond == 0) {
    return DateTime(value.year, value.month, value.day);
  }
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// [value]'s calendar day (see [calendarDayOf]) as UTC midnight: the form a
/// date-only field is written to the database and to the cloud in.
DateTime storedCalendarDay(DateTime value) {
  final day = calendarDayOf(value);
  return DateTime.utc(day.year, day.month, day.day);
}

/// [storedCalendarDay] for a field that may be unset.
DateTime? storedCalendarDayOrNull(DateTime? value) =>
    value == null ? null : storedCalendarDay(value);

/// [calendarDayOf] for a field that may be unset.
DateTime? calendarDayOfOrNull(DateTime? value) =>
    value == null ? null : calendarDayOf(value);

/// [instant] as the wall clock read where it was recorded, [utcOffsetMinutes]
/// from UTC: a local [DateTime] carrying that wall clock's fields.
///
/// A journal entry or a transaction belongs to the day, and shows the time,
/// of the place it was written — not wherever the device happens to be when
/// it is read. A record from before the offset was kept (null) reads as this
/// device's local time, as it always did.
DateTime recordedWallClock(DateTime instant, int? utcOffsetMinutes) {
  if (utcOffsetMinutes == null) return instant.toLocal();
  final wall = instant.toUtc().add(Duration(minutes: utcOffsetMinutes));
  final local = DateTime(
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
    wall.millisecond,
    wall.microsecond,
  );
  // A time this device's clock skips (its own spring-forward hour) comes out
  // an hour on; remembered, so saving it unchanged keeps the moment it was.
  if (local.hour != wall.hour || local.minute != wall.minute) {
    _skippedWallClockInstants[local] = instant.toUtc();
  }
  return local;
}

final _skippedWallClockInstants = Expando<DateTime>();

/// The instant a [recordedWallClock] value names. A UTC [value] is already
/// an instant and is taken as one; so is a local one with no offset.
DateTime recordedInstant(DateTime value, int? utcOffsetMinutes) {
  if (utcOffsetMinutes == null || value.isUtc) return value;
  final skipped = _skippedWallClockInstants[value];
  if (skipped != null) return skipped;
  return DateTime.utc(
    value.year,
    value.month,
    value.day,
    value.hour,
    value.minute,
    value.second,
    value.millisecond,
    value.microsecond,
  ).subtract(Duration(minutes: utcOffsetMinutes));
}

/// The offset to store beside [value]: [utcOffsetMinutes] when the record
/// has one, otherwise this device's — a record written here without one was
/// written on this device's clock.
int recordedOffset(DateTime value, int? utcOffsetMinutes) =>
    utcOffsetMinutes ?? value.toLocal().timeZoneOffset.inMinutes;

/// Local-midnight start of the week containing [date].
DateTime calendarWeekStart(DateTime date, bool weekStartsMonday) {
  final weekday = date.weekday;
  final firstDay = weekStartsMonday ? DateTime.monday : DateTime.sunday;
  // Field-based subtraction (not Duration), so this stays correct across
  // DST transitions — Duration(days:) is a fixed elapsed-time delta and can
  // land on the wrong calendar day for a local DateTime.
  return DateTime(date.year, date.month, date.day - (weekday - firstDay) % 7);
}
