import 'package:flutter/material.dart';
import 'package:voyager/domain/models/calendar_models.dart';

bool calendarEventOccursOnDay(CalendarEvent event, DateTime day) {
  final localDay = DateUtils.dateOnly(day.toLocal());
  final startLocal = DateUtils.dateOnly(event.start.toLocal());
  if (localDay.isBefore(startLocal)) return false;
  if (event.recurrence == EventRecurrence.none) {
    return localDay == startLocal;
  }

  switch (event.recurrence) {
    case EventRecurrence.daily:
      return true;
    case EventRecurrence.weekly:
      return localDay.weekday == startLocal.weekday;
    case EventRecurrence.monthly:
      return localDay.day == startLocal.day;
    case EventRecurrence.yearly:
      return localDay.month == startLocal.month && localDay.day == startLocal.day;
    case EventRecurrence.none:
      return localDay == startLocal;
  }
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
