import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';

class AnalyticsService {
  int countWords(String text) =>
      text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;

  int totalJournalEntries(List<JournalEntry> entries) => entries.length;

  int completedTasks(List<TodoTask> tasks) =>
      tasks.where((t) => t.completed).length;

  int booleanTrueCount(List<TrackerValue> values) =>
      values.where((v) => v.boolValue == true).length;

  Map<DateTime, int> integerSeries(List<TrackerValue> values) {
    final map = <DateTime, int>{};
    for (final value in values) {
      if (value.intValue != null) {
        map[value.periodStart] = value.intValue!;
      }
    }
    return map;
  }

  double heatmapIntensity({
    required TrackerType type,
    required TrackerValue? value,
    required StatisticTracker tracker,
    required int maxInPeriod,
  }) {
    if (value == null) return 0;
    switch (type) {
      case TrackerType.boolean:
        return value.boolValue == true ? 1 : 0;
      case TrackerType.integer:
        if (maxInPeriod == 0) return 0;
        final cap = tracker.integerCap ?? maxInPeriod;
        return (value.intValue ?? 0) / cap;
      case TrackerType.enumType:
        return value.enumValue == null || value.enumValue!.isEmpty ? 0 : 0.5;
    }
  }
}
