import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/recurrence_engine.dart';

// =============================================================================
// Calendar-side recurrence: occurrence starts (from recurrence_engine.dart)
// plus the three things only a calendar event has — a multi-day span, an
// exception list, and an end date.
//
// The span belongs to the *occurrence*, never to the pattern. A Jan 30 → Feb 2
// event repeating monthly is one four-day block beginning on the 30th of each
// month; it is not four separate marks on the 30th, 31st, 1st and 2nd. That is
// what [_coveringOccurrenceStart] encodes: a day is covered when the most
// recent occurrence began no more than the span ago.
// =============================================================================

// =============================================================================
// NormalizedCalendarEvent — pre-computed date-only local start/end.
//
// Wraps a [CalendarEvent] and caches the local date-only start/end and the
// exception set so the year-view hot path avoids re-allocating DateTime
// objects and re-parsing exceptions on every occurrence check.
// =============================================================================

class NormalizedCalendarEvent {
  NormalizedCalendarEvent(this.event)
    : startLocal = DateUtils.dateOnly(event.start.toLocal()),
      endLocal = DateUtils.dateOnly(event.end.toLocal()),
      untilLocal = event.recurrenceEndDate == null
          ? null
          : DateUtils.dateOnly(event.recurrenceEndDate!.toLocal()),
      exceptionDays = {
        for (final d in event.exceptionDates)
          epochDay(DateUtils.dateOnly(d.toLocal())),
      },
      doneDays = {
        for (final d in event.doneDates)
          epochDay(DateUtils.dateOnly(d.toLocal())),
      };

  final CalendarEvent event;

  /// [CalendarEvent.start] converted to local time and truncated to date-only.
  final DateTime startLocal;

  /// [CalendarEvent.end] converted to local time and truncated to date-only.
  final DateTime endLocal;

  /// Inclusive last day an occurrence may *start* on, or null when open-ended.
  final DateTime? untilLocal;

  /// Skipped occurrence starts, as epoch day numbers for cheap lookup.
  final Set<int> exceptionDays;

  /// Occurrence starts marked done, as epoch day numbers.
  final Set<int> doneDays;

  /// Span of one occurrence in whole days (0 for a single-day event).
  int get durationDays => epochDay(endLocal) - epochDay(startLocal);
}

/// Normalizes [events] into a [NormalizedCalendarEvent] list.
///
/// Call this once per render cycle (e.g., at the top of [MonthDayGrid.build]
/// for the compact/year-tile path) so each event's local dates are computed
/// exactly once rather than once per checked day.
List<NormalizedCalendarEvent> normalizeCalendarEvents(
  List<CalendarEvent> events,
) => [for (final e in events) NormalizedCalendarEvent(e)];

/// The start date of the occurrence that covers [localDay], or null when none
/// does.
///
/// Walks back through occurrence starts while they are still within span reach
/// of [localDay], skipping exception dates. The loop matters only when the span
/// is longer than the interval (a 5-day event repeating every 3 days), where
/// deleting one occurrence must not punch a hole in an overlapping neighbour.
DateTime? _coveringOccurrenceStart(
  NormalizedCalendarEvent n,
  DateTime localDay, // must already be date-only local
) {
  if (localDay.isBefore(n.startLocal)) return null;

  final rule = n.event.recurrence;
  final span = n.durationDays;

  // A non-repeating event is the degenerate case: one occurrence at the anchor.
  if (!rule.repeats) {
    return epochDay(localDay) - epochDay(n.startLocal) <= span
        ? n.startLocal
        : null;
  }

  // [recurrenceEndDate] caps where an occurrence may *begin*; one that began
  // on or before it still runs its full span past it.
  var probe = localDay;
  final until = n.untilLocal;
  if (until != null) {
    if (until.isBefore(n.startLocal)) return null;
    if (probe.isAfter(until)) probe = until;
  }

  while (true) {
    final occurrence = latestOccurrenceOnOrBefore(n.startLocal, rule, probe);
    if (occurrence == null) return null;
    if (epochDay(localDay) - epochDay(occurrence) > span) return null;
    if (!n.exceptionDays.contains(epochDay(occurrence))) return occurrence;
    probe = addDays(occurrence, -1);
    if (probe.isBefore(n.startLocal)) return null;
  }
}

/// Fast variant of [calendarEventOccursOnDay] that reads pre-computed
/// [NormalizedCalendarEvent] fields instead of calling `.toLocal()` and
/// [DateUtils.dateOnly] on every invocation.
bool calendarEventOccursOnDayNormalized(
  NormalizedCalendarEvent n,
  DateTime localDay, // must already be date-only local
) => _coveringOccurrenceStart(n, localDay) != null;

bool calendarEventOccursOnDay(CalendarEvent event, DateTime day) =>
    calendarEventOccursOnDayNormalized(
      NormalizedCalendarEvent(event),
      DateUtils.dateOnly(day.toLocal()),
    );

/// The start date of the occurrence of [event] that covers [day].
///
/// This is the identity of a single occurrence: it is what the delete/edit
/// scope prompt records as an exception date, and what an override row stores
/// in [CalendarEvent.recurrenceDate].
DateTime? calendarOccurrenceStartOn(CalendarEvent event, DateTime day) =>
    _coveringOccurrenceStart(
      NormalizedCalendarEvent(event),
      DateUtils.dateOnly(day.toLocal()),
    );

/// Whether the occurrence of [event] that covers [day] is marked done.
///
/// A row that does not repeat is done or not as a whole, by
/// [CalendarEvent.isDone]. A series goes by the occurrence covering [day], and
/// is not done on a day no occurrence covers.
bool calendarEventDoneOn(CalendarEvent event, DateTime day) {
  if (!event.recurrence.repeats) return event.isDone;
  if (event.doneMarks.isEmpty) return false;
  final n = _normalizedCache[event] ??= NormalizedCalendarEvent(event);
  final occurrence = _coveringOccurrenceStart(
    n,
    DateUtils.dateOnly(day.toLocal()),
  );
  return occurrence != null && n.doneDays.contains(epochDay(occurrence));
}

/// One [NormalizedCalendarEvent] per event instance, for
/// [calendarEventDoneOn] and [nextCalendarOccurrence]: views ask the first
/// about every pill on every cell, and on every frame of a morph, and a
/// reminder check asks the second up to a thousand times per event. Events are immutable, so an entry never goes stale,
/// and the expando lets go of it along with the event.
final _normalizedCache = Expando<NormalizedCalendarEvent>();

/// How many occurrence starts [nextCalendarOccurrence] will step over before
/// giving up.
///
/// Only exception dates and already-finished occurrences make it loop, so the
/// scan is normally one or two steps; the cap is what stops a series whose
/// every occurrence has been excepted from spinning forever.
const int _occurrenceScanLimit = 500;

/// The occurrence of [event] that is running at [from], or the next one due
/// after it, as concrete local instants.
///
/// [CalendarEvent.start]/[end] are the *anchor's* instants, so for a repeating
/// event they sit on the first occurrence and nowhere near the next one. Any
/// caller asking "when does this event happen next" has to resolve that slide
/// itself, or a series whose first occurrence has passed reads as an event
/// that is permanently over — which is exactly how repeating events used to
/// fall out of the notification feed.
///
/// Skips exception dates and occurrences marked done, stops at
/// [CalendarEvent.recurrenceEndDate], and carries the whole span forward, so a
/// multi-day occurrence still counts as current until its last day is over.
/// Returns null when nothing is left.
///
/// Its callers are the notification feed and the reminder schedule, and a done
/// occurrence is one neither should surface.
({DateTime start, DateTime end})? nextCalendarOccurrence(
  CalendarEvent event,
  DateTime from,
) {
  final localStart = event.start.toLocal();
  final localEnd = event.end.toLocal();
  if (!event.recurrence.repeats) {
    if (event.isDone) return null;
    return localEnd.isBefore(from) ? null : (start: localStart, end: localEnd);
  }

  final n = _normalizedCache[event] ??= NormalizedCalendarEvent(event);
  final until = n.untilLocal;
  final span = n.durationDays;
  final fromDay = DateUtils.dateOnly(from.toLocal());

  // Starts from the earliest occurrence whose span could still reach [from]:
  // one beginning more than [span] days before that day ended before it. The
  // probe sits a day earlier still because [nextOccurrenceAfter] is strict.
  var cursor = addDays(fromDay, -span - 1);
  if (cursor.isBefore(n.startLocal)) cursor = addDays(n.startLocal, -1);

  for (var step = 0; step < _occurrenceScanLimit; step++) {
    final day = nextOccurrenceAfter(n.startLocal, event.recurrence, cursor);
    if (day == null) return null;
    if (until != null && day.isAfter(until)) return null;
    cursor = day;
    if (n.exceptionDays.contains(epochDay(day))) continue;
    if (n.doneDays.contains(epochDay(day))) continue;
    // Slid by whole calendar days rather than by a Duration, so an occurrence
    // on the far side of a DST change keeps the series' wall-clock time.
    final shift = epochDay(day) - epochDay(n.startLocal);
    final start = addDaysKeepingTime(localStart, shift);
    final end = addDaysKeepingTime(localEnd, shift);
    if (!end.isBefore(from)) return (start: start, end: end);
  }
  return null;
}

bool _areConsecutiveCalendarDays(DateTime earlier, DateTime later) {
  final a = DateUtils.dateOnly(earlier.toLocal());
  final b = DateUtils.dateOnly(later.toLocal());
  return epochDay(b) - epochDay(a) == 1;
}

/// Whether month-view event bars should visually connect [earlierDay] to
/// [laterDay].
///
/// Two days bridge exactly when they belong to the same occurrence. Separate
/// occurrences of a recurring event never join, however close together the
/// pattern places them.
bool calendarEventBarsBridge(
  CalendarEvent event,
  DateTime earlierDay,
  DateTime laterDay,
) {
  if (!_areConsecutiveCalendarDays(earlierDay, laterDay)) return false;

  final n = NormalizedCalendarEvent(event);
  final earlier = _coveringOccurrenceStart(
    n,
    DateUtils.dateOnly(earlierDay.toLocal()),
  );
  if (earlier == null) return false;
  final later = _coveringOccurrenceStart(
    n,
    DateUtils.dateOnly(laterDay.toLocal()),
  );
  return later != null && earlier == later;
}

bool calendarEventBarStartsOnDay(CalendarEvent event, DateTime day) {
  if (!calendarEventOccursOnDay(event, day)) return false;
  final current = DateUtils.dateOnly(day.toLocal());
  return !calendarEventBarsBridge(event, addDays(current, -1), current);
}

bool calendarEventBarEndsOnDay(CalendarEvent event, DateTime day) {
  if (!calendarEventOccursOnDay(event, day)) return false;
  final current = DateUtils.dateOnly(day.toLocal());
  return !calendarEventBarsBridge(event, current, addDays(current, 1));
}

// ---------------------------------------------------------------------------
// Storage codecs
// ---------------------------------------------------------------------------

RecurrenceRule recurrenceFromStorage(String? value) =>
    RecurrenceRule.parse(value);

/// Encodes exception dates as a comma-separated `yyyy-MM-dd` list.
///
/// Date-only and local: an exception identifies a day in the pattern, not an
/// instant, so round-tripping it through UTC could move it either side of
/// midnight for users far from Greenwich.
String encodeExceptionDates(List<DateTime> dates) {
  if (dates.isEmpty) return '';
  final seen = <String>{};
  for (final date in dates) {
    seen.add(calendarDateKey(date));
  }
  final sorted = seen.toList()..sort();
  return sorted.join(',');
}

List<DateTime> decodeExceptionDates(String? value) {
  if (value == null || value.isEmpty) return const [];
  final out = <DateTime>[];
  for (final token in value.split(',')) {
    if (parseCalendarDateKey(token.trim()) case final day?) out.add(day);
  }
  return out;
}

/// [day] as the `yyyy-MM-dd` key exception dates and done marks are stored
/// under.
String calendarDateKey(DateTime day) {
  final d = DateUtils.dateOnly(day.toLocal());
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// The date a [calendarDateKey] names, or null for a malformed key.
DateTime? parseCalendarDateKey(String key) {
  final parts = key.split('-');
  if (parts.length != 3) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  return DateTime(year, month, day);
}

/// Encodes done marks as JSON: `{"yyyy-MM-dd": {"done": bool, "at": ISO}}`.
String encodeDoneMarks(Map<DateTime, CalendarDoneMark> marks) => jsonEncode({
  for (final entry in marks.entries)
    calendarDateKey(entry.key): {
      'done': entry.value.done,
      'at': entry.value.at.toUtc().toIso8601String(),
    },
});

Map<DateTime, CalendarDoneMark> decodeDoneMarks(String? value) {
  if (value == null || value.isEmpty) return const {};
  final marks = <DateTime, CalendarDoneMark>{};
  for (final entry in (jsonDecode(value) as Map<String, dynamic>).entries) {
    final day = parseCalendarDateKey(entry.key);
    final mark = entry.value as Map<String, dynamic>;
    final at = DateTime.tryParse(mark['at'] as String? ?? '');
    if (day == null || at == null) continue;
    marks[day] = CalendarDoneMark(done: mark['done'] == true, at: at.toUtc());
  }
  return marks;
}

/// [a] and [b] merged date by date, the newer mark winning; [a]'s on a tie.
///
/// How two devices' done marks for one series come together: marking and
/// unmarking different occurrences on each never loses either.
Map<DateTime, CalendarDoneMark> mergeDoneMarks(
  Map<DateTime, CalendarDoneMark> a,
  Map<DateTime, CalendarDoneMark> b,
) {
  final merged = {...a};
  for (final entry in b.entries) {
    final mine = merged[entry.key];
    if (mine == null || entry.value.at.isAfter(mine.at)) {
      merged[entry.key] = entry.value;
    }
  }
  return merged;
}
