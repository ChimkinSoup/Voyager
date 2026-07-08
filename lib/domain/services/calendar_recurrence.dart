import 'package:flutter/material.dart';
import 'package:voyager/domain/models/calendar_models.dart';

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
