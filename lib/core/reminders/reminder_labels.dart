import 'package:intl/intl.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/services/reminder_schedule.dart';

/// "3:00 PM", "Tomorrow 3:00 PM", "Thu 3:00 PM" or "Sep 20, 3:00 PM" — the
/// nearest of those that still says which day.
String reminderWhenLabel(DateTime at, DateTime now) {
  final local = at.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final days = DateTime.utc(
    day.year,
    day.month,
    day.day,
  ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  final time = formatTime12Hour(local);
  if (days == 0) return time;
  if (days == 1) return 'Tomorrow $time';
  if (days == -1) return 'Yesterday $time';
  if (days > 1 && days < 7) return '${DateFormat.E().format(local)} $time';
  return '${DateFormat.MMMd().format(local)}, $time';
}

/// "Daily · 8:00 AM", "Mon, Thu · 8:00 AM", "Once · Sep 20, 9:00 AM".
String reminderCadenceLabel(ScheduledReminderRule rule) {
  final time = formatTime12Hour(
    atLocalMinutes(DateTime(2000), rule.localTimeMinutes),
  );
  switch (rule.scheduleKind) {
    case ReminderScheduleKind.daily:
      return 'Daily · $time';
    case ReminderScheduleKind.weekly:
      final days = rule.weeklyWeekdays.toList()..sort();
      if (days.length == 7) return 'Every day · $time';
      if (days.isEmpty) return 'Weekly · no days picked';
      // 2024-01-01 was a Monday, so day N of that week is weekday N.
      final names = [
        for (final day in days) DateFormat.E().format(DateTime(2024, 1, day)),
      ];
      return '${names.join(', ')} · $time';
    case ReminderScheduleKind.once:
      final date = rule.onceLocalDate;
      if (date == null) return 'Once · $time';
      return 'Once · ${DateFormat.MMMd().format(date)}, $time';
  }
}

/// "At time", "15 minutes before", "1 hour before", "1 day before",
/// "2 hours 30 minutes before".
String reminderOffsetLabel(int minutes) {
  if (minutes <= 0) return 'At time';
  String unit(int n, String name) => '$n $name${n == 1 ? '' : 's'}';
  final days = minutes ~/ (24 * 60);
  final hours = (minutes % (24 * 60)) ~/ 60;
  final mins = minutes % 60;
  final parts = [
    if (days > 0) unit(days, 'day'),
    if (hours > 0) unit(hours, 'hour'),
    if (mins > 0) unit(mins, 'minute'),
  ];
  return '${parts.join(' ')} before';
}
