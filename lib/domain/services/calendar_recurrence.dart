import 'package:flutter/material.dart';
import 'package:voyager/domain/models/calendar_models.dart';

// =============================================================================
// NormalizedCalendarEvent — pre-computed date-only local start/end.
//
// Wraps a [CalendarEvent] and caches [DateUtils.dateOnly(event.start.toLocal())]
// and the equivalent end value so the year-view hot path avoids re-allocating
// DateTime objects on every [calendarEventOccursOnDay] call.
// =============================================================================

class NormalizedCalendarEvent {
  NormalizedCalendarEvent(this.event)
      : startLocal = DateUtils.dateOnly(event.start.toLocal()),
        endLocal = DateUtils.dateOnly(event.end.toLocal());

  final CalendarEvent event;

  /// [event.start] converted to local time and truncated to date-only.
  final DateTime startLocal;

  /// [event.end] converted to local time and truncated to date-only.
  final DateTime endLocal;

  /// Pre-computed duration in whole days (endLocal − startLocal).
  int get durationDays => endLocal.difference(startLocal).inDays;
}

/// Normalizes [events] into a [NormalizedCalendarEvent] list.
///
/// Call this once per render cycle (e.g., at the top of [MonthDayGrid.build]
/// for the compact/year-tile path) so each event's local dates are computed
/// exactly once rather than once per checked day.
List<NormalizedCalendarEvent> normalizeCalendarEvents(
  List<CalendarEvent> events,
) =>
    [for (final e in events) NormalizedCalendarEvent(e)];

/// Fast variant of [calendarEventOccursOnDay] that reads pre-computed
/// [NormalizedCalendarEvent] fields instead of calling [.toLocal()] and
/// [DateUtils.dateOnly] on every invocation.
bool calendarEventOccursOnDayNormalized(
  NormalizedCalendarEvent n,
  DateTime localDay, // must already be date-only local
) {
  if (localDay.isBefore(n.startLocal)) return false;

  if (n.event.recurrence == EventRecurrence.none) {
    return localDay == n.startLocal ||
        (localDay.isAfter(n.startLocal) && !localDay.isAfter(n.endLocal));
  }

  final durationDays = n.durationDays;

  switch (n.event.recurrence) {
    case EventRecurrence.daily:
      return true;
    case EventRecurrence.weekly:
      for (int i = 0; i <= durationDays; i++) {
        if (localDay.weekday ==
            n.startLocal.add(Duration(days: i)).weekday) {
          return true;
        }
      }
      return false;
    case EventRecurrence.monthly:
      for (int i = 0; i <= durationDays; i++) {
        if (localDay.day == n.startLocal.add(Duration(days: i)).day) {
          return true;
        }
      }
      return false;
    case EventRecurrence.yearly:
      for (int i = 0; i <= durationDays; i++) {
        final d = n.startLocal.add(Duration(days: i));
        if (localDay.month == d.month && localDay.day == d.day) return true;
      }
      return false;
    case EventRecurrence.none:
      return localDay == n.startLocal ||
          (localDay.isAfter(n.startLocal) && !localDay.isAfter(n.endLocal));
  }
}

bool calendarEventOccursOnDay(CalendarEvent event, DateTime day) {
  final localDay = DateUtils.dateOnly(day.toLocal());
  final startLocal = DateUtils.dateOnly(event.start.toLocal());
  final endLocal = DateUtils.dateOnly(event.end.toLocal());
  
  if (localDay.isBefore(startLocal)) return false;
  
  if (event.recurrence == EventRecurrence.none) {
    return localDay == startLocal || (localDay.isAfter(startLocal) && !localDay.isAfter(endLocal));
  }

  final durationDays = endLocal.difference(startLocal).inDays;

  switch (event.recurrence) {
    case EventRecurrence.daily:
      return true;
    case EventRecurrence.weekly:
      for (int i = 0; i <= durationDays; i++) {
        if (localDay.weekday == startLocal.add(Duration(days: i)).weekday) return true;
      }
      return false;
    case EventRecurrence.monthly:
      for (int i = 0; i <= durationDays; i++) {
        if (localDay.day == startLocal.add(Duration(days: i)).day) return true;
      }
      return false;
    case EventRecurrence.yearly:
      for (int i = 0; i <= durationDays; i++) {
        final d = startLocal.add(Duration(days: i));
        if (localDay.month == d.month && localDay.day == d.day) return true;
      }
      return false;
    case EventRecurrence.none:
      return localDay == startLocal || (localDay.isAfter(startLocal) && !localDay.isAfter(endLocal));
  }
}

bool _areConsecutiveCalendarDays(DateTime earlier, DateTime later) {
  final a = DateUtils.dateOnly(earlier.toLocal());
  final b = DateUtils.dateOnly(later.toLocal());
  return b.difference(a).inDays == 1;
}

Set<int> _eventTemplateWeekdays(DateTime startLocal, int durationDays) {
  return {
    for (var i = 0; i <= durationDays; i++)
      startLocal.add(Duration(days: i)).weekday,
  };
}

Set<int> _eventTemplateMonthDays(DateTime startLocal, int durationDays) {
  return {
    for (var i = 0; i <= durationDays; i++)
      startLocal.add(Duration(days: i)).day,
  };
}

Set<(int month, int day)> _eventTemplateYearDays(
  DateTime startLocal,
  int durationDays,
) {
  return {
    for (var i = 0; i <= durationDays; i++)
      (
        startLocal.add(Duration(days: i)).month,
        startLocal.add(Duration(days: i)).day,
      ),
  };
}

/// Whether month-view event bars should visually connect [earlierDay] to [laterDay].
///
/// Recurring single-day events never bridge across days. Multi-day spans bridge
/// only within one occurrence, not between separate recurrence instances.
bool calendarEventBarsBridge(
  CalendarEvent event,
  DateTime earlierDay,
  DateTime laterDay,
) {
  if (!_areConsecutiveCalendarDays(earlierDay, laterDay)) return false;
  if (!calendarEventOccursOnDay(event, earlierDay) ||
      !calendarEventOccursOnDay(event, laterDay)) {
    return false;
  }

  final earlier = DateUtils.dateOnly(earlierDay.toLocal());
  final later = DateUtils.dateOnly(laterDay.toLocal());
  final startLocal = DateUtils.dateOnly(event.start.toLocal());
  final endLocal = DateUtils.dateOnly(event.end.toLocal());
  final durationDays = endLocal.difference(startLocal).inDays;

  if (durationDays == 0) return false;

  if (event.recurrence == EventRecurrence.none) {
    return !earlier.isBefore(startLocal) && !later.isAfter(endLocal);
  }

  switch (event.recurrence) {
    case EventRecurrence.daily:
    case EventRecurrence.weekly:
      final weekdays = _eventTemplateWeekdays(startLocal, durationDays);
      return weekdays.contains(earlier.weekday) &&
          weekdays.contains(later.weekday);
    case EventRecurrence.monthly:
      final monthDays = _eventTemplateMonthDays(startLocal, durationDays);
      return monthDays.contains(earlier.day) && monthDays.contains(later.day);
    case EventRecurrence.yearly:
      final yearDays = _eventTemplateYearDays(startLocal, durationDays);
      return yearDays.contains((earlier.month, earlier.day)) &&
          yearDays.contains((later.month, later.day));
    case EventRecurrence.none:
      return false;
  }
}

bool calendarEventBarStartsOnDay(CalendarEvent event, DateTime day) {
  if (!calendarEventOccursOnDay(event, day)) return false;
  final previous = DateUtils.dateOnly(day.toLocal().subtract(const Duration(days: 1)));
  final current = DateUtils.dateOnly(day.toLocal());
  return !calendarEventBarsBridge(event, previous, current);
}

bool calendarEventBarEndsOnDay(CalendarEvent event, DateTime day) {
  if (!calendarEventOccursOnDay(event, day)) return false;
  final current = DateUtils.dateOnly(day.toLocal());
  final next = DateUtils.dateOnly(day.toLocal().add(const Duration(days: 1)));
  return !calendarEventBarsBridge(event, current, next);
}

String recurrenceLabel(EventRecurrence recurrence) {
  return switch (recurrence) {
    EventRecurrence.none => 'Does not repeat',
    EventRecurrence.daily => 'Every day',
    EventRecurrence.weekly => 'Every week',
    EventRecurrence.monthly => 'Every month',
    EventRecurrence.yearly => 'Every year',
  };
}

EventRecurrence recurrenceFromStorage(String? value) {
  if (value == null || value.isEmpty) return EventRecurrence.none;
  for (final recurrence in EventRecurrence.values) {
    if (recurrence.name == value) return recurrence;
  }
  return EventRecurrence.none;
}
