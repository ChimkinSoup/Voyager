import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
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
    List<TrackerValue>? allValues,
  }) {
    if (value == null) return 0;
    switch (type) {
      case TrackerType.boolean:
        return value.boolValue == true ? 1 : 0;
      case TrackerType.integer:
        if (maxInPeriod == 0) return 0;
        final cap = tracker.integerCap ?? maxInPeriod;
        if (allValues != null &&
            allValues.where((v) => v.intValue != null).length == 1) {
          return (value.intValue ?? 0) > 0 ? 0.5 : 0.0;
        }
        return (value.intValue ?? 0) / cap;
      case TrackerType.enumType:
        return value.enumValue == null || value.enumValue!.isEmpty ? 0 : 0.5;
    }
  }

  /// Rolling maximum of [intValue] across the last [days] calendar days.
  int rollingMax(List<TrackerValue> values, {int days = 365}) {
    if (values.isEmpty) return 1;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    return values
        .where((v) => v.periodStart.isAfter(cutoff) && v.intValue != null)
        .fold<int>(1, (m, v) => v.intValue! > m ? v.intValue! : m);
  }

  /// Produces a continuous [FlSpot] list for a Consecutive integer tracker.
  ///
  /// Uses the same Cardinal tension-spline (tension = 0, Catmull-Rom tangents)
  /// as [WeatherChartCurve] to fill gaps between recorded values. The X axis
  /// is the day offset from [from]; the Y axis is the recorded or interpolated
  /// integer value. If fewer than 2 data points exist the raw spots are returned.
  List<FlSpot> interpolateConsecutive({
    required List<TrackerValue> values,
    required DateTime from,
    required DateTime to,
  }) {
    // Build day-index → value map from raw data
    final dayMap = <int, double>{};
    for (final v in values) {
      if (v.intValue == null) continue;
      final diff = v.periodStart
          .difference(DateTime(from.year, from.month, from.day))
          .inDays;
      if (diff >= 0) dayMap[diff] = v.intValue!.toDouble();
    }

    if (dayMap.isEmpty) return const [];

    final totalDays =
        to.difference(DateTime(from.year, from.month, from.day)).inDays;

    // If only one data point, return it as a flat line
    if (dayMap.length == 1) {
      final entry = dayMap.entries.first;
      return [FlSpot(entry.key.toDouble(), entry.value)];
    }

    // Sorted known spots
    final knownX = dayMap.keys.toList()..sort();
    final knownSpots =
        knownX.map((x) => (x: x.toDouble(), y: dayMap[x]!)).toList();

    // Cardinal tangent helper (tension = 0 → Catmull-Rom)
    ({double dx, double dy}) tangentAt(int i) {
      if (knownSpots.length <= 1) return (dx: 0.0, dy: 0.0);
      if (i == 0) {
        return (
          dx: knownSpots[1].x - knownSpots[0].x,
          dy: knownSpots[1].y - knownSpots[0].y,
        );
      }
      if (i == knownSpots.length - 1) {
        return (
          dx: knownSpots[i].x - knownSpots[i - 1].x,
          dy: knownSpots[i].y - knownSpots[i - 1].y,
        );
      }
      return (
        dx: (knownSpots[i + 1].x - knownSpots[i - 1].x) / 2,
        dy: (knownSpots[i + 1].y - knownSpots[i - 1].y) / 2,
      );
    }

    // Hermite cubic interpolation between consecutive known points
    double hermite(int segIndex, double t) {
      final p0 = knownSpots[segIndex];
      final p1 = knownSpots[segIndex + 1];
      final m0 = tangentAt(segIndex);
      final m1 = tangentAt(segIndex + 1);
      final dx = p1.x - p0.x;
      if (dx <= 0) return p0.y;
      // Normalise t to [0,1] within the segment
      final nt = t;
      final h00 = 2 * nt * nt * nt - 3 * nt * nt + 1;
      final h10 = nt * nt * nt - 2 * nt * nt + nt;
      final h01 = -2 * nt * nt * nt + 3 * nt * nt;
      final h11 = nt * nt * nt - nt * nt;
      return h00 * p0.y +
          h10 * dx * (m0.dy / m0.dx.abs().clamp(0.001, double.infinity)) +
          h01 * p1.y +
          h11 * dx * (m1.dy / m1.dx.abs().clamp(0.001, double.infinity));
    }

    final result = <FlSpot>[];

    for (var day = 0; day <= math.min(totalDays, 365); day++) {
      if (dayMap.containsKey(day)) {
        result.add(FlSpot(day.toDouble(), dayMap[day]!));
        continue;
      }
      // Find surrounding segment
      int? segIdx;
      for (var i = 0; i < knownSpots.length - 1; i++) {
        if (knownSpots[i].x <= day && day <= knownSpots[i + 1].x) {
          segIdx = i;
          break;
        }
      }
      if (segIdx == null) {
        // Outside range: clamp to nearest endpoint
        if (day < knownSpots.first.x) {
          result.add(FlSpot(day.toDouble(), knownSpots.first.y));
        } else {
          result.add(FlSpot(day.toDouble(), knownSpots.last.y));
        }
        continue;
      }
      final p0 = knownSpots[segIdx];
      final p1 = knownSpots[segIdx + 1];
      final dx = p1.x - p0.x;
      final t = dx <= 0 ? 0.0 : (day - p0.x) / dx;
      final y = hermite(segIdx, t).clamp(0.0, double.infinity);
      result.add(FlSpot(day.toDouble(), y));
    }

    return result;
  }
}
