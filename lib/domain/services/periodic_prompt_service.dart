import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';

class PeriodicPromptService {
  DateTime periodStartFor(DateTime date, TrackerCadence cadence, {bool weekStartsMonday = true}) {
    switch (cadence) {
      case TrackerCadence.daily:
        return DateTime(date.year, date.month, date.day);
      case TrackerCadence.weekly:
        final weekday = date.weekday;
        final startOffset = weekStartsMonday ? weekday - DateTime.monday : weekday % 7;
        return DateTime(date.year, date.month, date.day).subtract(Duration(days: startOffset));
      case TrackerCadence.monthly:
        return DateTime(date.year, date.month, 1);
      case TrackerCadence.yearly:
        return DateTime(date.year, 1, 1);
    }
  }

  bool isDue({
    required TrackerCadence cadence,
    required DateTime now,
    required DateTime? lastCompleted,
    bool weekStartsMonday = true,
  }) {
    final currentStart = periodStartFor(now, cadence, weekStartsMonday: weekStartsMonday);
    if (lastCompleted == null) return true;
    final lastStart = periodStartFor(lastCompleted, cadence, weekStartsMonday: weekStartsMonday);
    return currentStart.isAfter(lastStart);
  }

  List<DateTime> missedPeriods({
    required TrackerCadence cadence,
    required DateTime now,
    required DateTime? lastCompleted,
    bool weekStartsMonday = true,
  }) {
    if (lastCompleted == null) {
      return [periodStartFor(now, cadence, weekStartsMonday: weekStartsMonday)];
    }

    final periods = <DateTime>[];
    var cursor = _nextPeriod(lastCompleted, cadence, weekStartsMonday: weekStartsMonday);
    final current = periodStartFor(now, cadence, weekStartsMonday: weekStartsMonday);

    while (!cursor.isAfter(current)) {
      periods.add(cursor);
      cursor = _nextPeriod(cursor, cadence, weekStartsMonday: weekStartsMonday);
    }
    return periods;
  }

  DateTime _nextPeriod(DateTime start, TrackerCadence cadence, {bool weekStartsMonday = true}) {
    switch (cadence) {
      case TrackerCadence.daily:
        return start.add(const Duration(days: 1));
      case TrackerCadence.weekly:
        return start.add(const Duration(days: 7));
      case TrackerCadence.monthly:
        return DateTime(start.year, start.month + 1, 1);
      case TrackerCadence.yearly:
        return DateTime(start.year + 1, 1, 1);
    }
  }

  int longestJournalStreak(List<JournalEntry> entries) {
    if (entries.isEmpty) return 0;
    final days = entries.map((e) => DateTime(e.entryDate.year, e.entryDate.month, e.entryDate.day)).toSet().toList()
      ..sort();
    var best = 1;
    var current = 1;
    for (var i = 1; i < days.length; i++) {
      if (days[i].difference(days[i - 1]).inDays == 1) {
        current++;
        best = current > best ? current : best;
      } else {
        current = 1;
      }
    }
    return best;
  }
}
