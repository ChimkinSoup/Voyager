import 'dart:math' as math;

import 'package:voyager/domain/models/weather_models.dart';

/// Local 3-hour chart slot (0, 3, 6, …, 21) for a timestamp.
int chartBucketHour(DateTime localTime) => (localTime.hour ~/ 3) * 3;

List<ForecastPeriod> periodsForDay(
  List<ForecastPeriod> periods,
  DateTime day,
) {
  final dayStart = DateTime(day.year, day.month, day.day);
  final dayEnd = dayStart.add(const Duration(days: 1));
  final buckets = <int, ForecastPeriod>{};

  for (final period in periods) {
    final local = period.time.toLocal();
    if (local.isBefore(dayStart) || !local.isBefore(dayEnd)) continue;

    final bucket = chartBucketHour(local);
    final existing = buckets[bucket];
    if (existing == null || period.time.isAfter(existing.time)) {
      buckets[bucket] = period;
    }
  }

  final hours = buckets.keys.toList()..sort();
  return [for (final hour in hours) buckets[hour]!];
}

bool isFutureForecastDay(DateTime day, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(day.year, day.month, day.day);
  return target.isAfter(today);
}

bool isTodayForecastDay(DateTime day, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(day.year, day.month, day.day);
  return target == today;
}

/// Fractional hour (0–24) for the current local time.
double currentTimeChartHour(DateTime now) =>
    now.hour + now.minute / 60.0 + now.second / 3600.0;

/// Standard 3-hour slots used across a full forecast day.
const forecastDayChartHours = [0, 3, 6, 9, 12, 15, 18, 21];

int initialForecastDayIndex(List<DailyForecastSummary> days, DateTime now) {
  if (days.isEmpty) return 0;

  final today = DateTime(now.year, now.month, now.day);
  final index = days.indexWhere(
    (day) =>
        day.date.year == today.year &&
        day.date.month == today.month &&
        day.date.day == today.day,
  );
  return index >= 0 ? index : 0;
}

/// Picks [lastViewedDay] when still in [days], otherwise the first day.
int resolveForecastDayIndex(
  List<DailyForecastSummary> days,
  DateTime? lastViewedDay,
) {
  if (days.isEmpty) return 0;
  if (lastViewedDay != null) {
    final index = days.indexWhere(
      (day) =>
          day.date.year == lastViewedDay.year &&
          day.date.month == lastViewedDay.month &&
          day.date.day == lastViewedDay.day,
    );
    if (index >= 0) return index;
  }
  return 0;
}

class DayForecastChartSeries {
  const DayForecastChartSeries({
    required this.tempPoints,
    required this.rainPoints,
    required this.minTemp,
    required this.maxTemp,
    required this.isFullDay,
  });

  final List<({double hour, double tempC})> tempPoints;
  final List<({double hour, double rainPercent})> rainPoints;
  final double minTemp;
  final double maxTemp;

  /// True when all standard 3-hour slots (0–21) are present for this day.
  final bool isFullDay;

  bool get isEmpty => tempPoints.isEmpty && rainPoints.isEmpty;
}

/// Midnight (0:00) bucket for [day], if present in [periods].
ForecastPeriod? midnightBucketForDay(
  List<ForecastPeriod> periods,
  DateTime day,
) {
  final dayStart = DateTime(day.year, day.month, day.day);
  ForecastPeriod? latest;

  for (final period in periods) {
    final local = period.time.toLocal();
    if (local.year != dayStart.year ||
        local.month != dayStart.month ||
        local.day != dayStart.day) {
      continue;
    }
    if (chartBucketHour(local) != 0) continue;
    if (latest == null || period.time.isAfter(latest.time)) {
      latest = period;
    }
  }

  return latest;
}

DayForecastChartSeries buildDayForecastChartSeries(
  List<ForecastPeriod> periods,
  DateTime day, {
  DateTime? now,
}) {
  final dayPeriods = periodsForDay(periods, day);
  if (dayPeriods.isEmpty) {
    return const DayForecastChartSeries(
      tempPoints: [],
      rainPoints: [],
      minTemp: 0,
      maxTemp: 1,
      isFullDay: false,
    );
  }

  final tempPoints = <({double hour, double tempC})>[];
  final rainPoints = <({double hour, double rainPercent})>[];
  var minTemp = dayPeriods.first.tempC;
  var maxTemp = dayPeriods.first.tempC;
  final bucketHours = <int>{};

  for (final period in dayPeriods) {
    final hour = chartBucketHour(period.time.toLocal()).toDouble();
    bucketHours.add(hour.toInt());
    minTemp = period.tempC < minTemp ? period.tempC : minTemp;
    maxTemp = period.tempC > maxTemp ? period.tempC : maxTemp;
    tempPoints.add((hour: hour, tempC: period.tempC));
    rainPoints.add((hour: hour, rainPercent: period.pop * 100));
  }

  final nextMidnight = midnightBucketForDay(
    periods,
    day.add(const Duration(days: 1)),
  );
  if (nextMidnight != null) {
    minTemp = nextMidnight.tempC < minTemp ? nextMidnight.tempC : minTemp;
    maxTemp = nextMidnight.tempC > maxTemp ? nextMidnight.tempC : maxTemp;
    tempPoints.add((hour: 24, tempC: nextMidnight.tempC));
    rainPoints.add((hour: 24, rainPercent: nextMidnight.pop * 100));
  }

  tempPoints.sort((a, b) => a.hour.compareTo(b.hour));
  rainPoints.sort((a, b) => a.hour.compareTo(b.hour));

  if (minTemp == maxTemp) {
    minTemp -= 2;
    maxTemp += 2;
  } else {
    minTemp -= 1;
    maxTemp += 1;
  }

  final reference = now ?? DateTime.now();
  final isFullDay =
      isFutureForecastDay(day, reference) &&
      forecastDayChartHours.every(bucketHours.contains) &&
      nextMidnight != null;

  return DayForecastChartSeries(
    tempPoints: tempPoints,
    rainPoints: rainPoints,
    minTemp: minTemp,
    maxTemp: maxTemp,
    isFullDay: isFullDay,
  );
}

/// Hour (0–24) where rain-weighted fill begins for [day]; uses fetch bucket on
/// the same calendar day, otherwise the start of the day.
double forecastRainGradientStartHour(DateTime day, DateTime fetchedAt) {
  final local = fetchedAt.toLocal();
  final dayStart = DateTime(day.year, day.month, day.day);
  final fetchDay = DateTime(local.year, local.month, local.day);
  if (fetchDay == dayStart) {
    return chartBucketHour(local).toDouble();
  }
  return 0;
}

/// Blends rain fill in over [fadeHours] before [gradientStartHour] to avoid a
/// hard vertical edge at the fetch bucket (e.g. 6 PM).
double rainFillBlendFactor(
  double hour,
  double gradientStartHour, {
  double fadeHours = 3,
}) {
  if (hour >= gradientStartHour) return 1;
  if (fadeHours <= 0) return 0;
  final fadeStart = gradientStartHour - fadeHours;
  if (hour <= fadeStart) return 0;
  return (hour - fadeStart) / fadeHours;
}

/// 3-hour window centered on a forecast bucket hour (e.g. 3 → 1.5–4.5, clamped).
({double start, double end}) chartBucketRangeCenteredOn(double centerHour) {
  return (
    start: math.max(0, centerHour - 1.5),
    end: math.min(24, centerHour + 1.5),
  );
}
