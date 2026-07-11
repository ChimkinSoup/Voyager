import 'package:flutter/material.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/services/analytics_service.dart';

class HeatmapCalendar extends StatelessWidget {
  const HeatmapCalendar({
    super.key,
    required this.tracker,
    required this.values,
    required this.month,
  });

  final StatisticTracker tracker;
  final List<TrackerValue> values;
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final analytics = AnalyticsService();
    final max = values.fold<int>(0, (m, v) {
      final current = v.intValue ?? 0;
      return current > m ? current : m;
    });

    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: List.generate(daysInMonth, (index) {
        final day = DateTime(month.year, month.month, index + 1);
        final value = values.cast<TrackerValue?>().firstWhere(
          (v) =>
              v != null &&
              v.periodStart.year == day.year &&
              v.periodStart.month == day.month &&
              v.periodStart.day == day.day,
          orElse: () => null,
        );
        final intensity = analytics.heatmapIntensity(
          type: tracker.type,
          value: value,
          tracker: tracker,
          maxInPeriod: max == 0 ? 1 : max,
          allValues: values,
        );
        return Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Color(
              tracker.colorValue,
            ).withValues(alpha: 0.2 + (0.8 * intensity)),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}
