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
