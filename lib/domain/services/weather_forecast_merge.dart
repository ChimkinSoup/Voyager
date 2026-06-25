import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/services/weather_forecast_chart.dart';

/// Local calendar date for [utcTime] using [timeZoneOffsetMinutes].
DateTime localCalendarDate(DateTime utcTime, int timeZoneOffsetMinutes) {
  final local = utcTime.toUtc().add(Duration(minutes: timeZoneOffsetMinutes));
  return DateTime.utc(local.year, local.month, local.day);
}

String forecastBucketKey(DateTime utcTime, int timeZoneOffsetMinutes) {
  final local = utcTime.toUtc().add(Duration(minutes: timeZoneOffsetMinutes));
  final bucketHour = chartBucketHour(
    DateTime(local.year, local.month, local.day, local.hour),
  );
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final h = bucketHour.toString().padLeft(2, '0');
  return '${y}_${m}_${d}_$h';
}

DateTime? parseForecastBucketDate(String bucketKey) {
  final parts = bucketKey.split('_');
  if (parts.length != 4) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  return DateTime(year, month, day);
}

Map<String, ForecastPeriod> forecastPeriodsToBucketMap(
  Iterable<ForecastPeriod> periods,
  int timeZoneOffsetMinutes,
) {
  final map = <String, ForecastPeriod>{};
  for (final period in periods) {
    map[forecastBucketKey(period.time, timeZoneOffsetMinutes)] = period;
  }
  return map;
}

List<ForecastPeriod> mergeForecastArchive({
  required Iterable<ForecastPeriod> existingPeriods,
  required Iterable<ForecastPeriod> apiPeriods,
  required int timeZoneOffsetMinutes,
  required DateTime nowUtc,
  bool resetArchive = false,
}) {
  final today = localCalendarDate(nowUtc, timeZoneOffsetMinutes);
  var merged = <String, ForecastPeriod>{};

  if (!resetArchive) {
    for (final entry in forecastPeriodsToBucketMap(
      existingPeriods,
      timeZoneOffsetMinutes,
    ).entries) {
      final bucketDate = parseForecastBucketDate(entry.key);
      if (bucketDate == null) continue;
      if (bucketDate.isBefore(today)) continue;
      merged[entry.key] = entry.value;
    }
  }

  for (final entry in forecastPeriodsToBucketMap(
    apiPeriods,
    timeZoneOffsetMinutes,
  ).entries) {
    merged[entry.key] = entry.value;
  }

  final periods = merged.values.toList()
    ..sort((a, b) => a.time.compareTo(b.time));
  return periods;
}

/// Drops forecast buckets whose local calendar day is before [now]'s local today.
///
/// Entire today is kept — including hours that have already passed (e.g. 3 AM
/// when it is now afternoon). A day is removed only once it becomes a previous
/// calendar day (i.e. at local midnight).
List<ForecastPeriod> prunePastForecastPeriods(
  List<ForecastPeriod> periods, {
  DateTime? now,
}) {
  if (periods.isEmpty) return periods;

  final reference = (now ?? DateTime.now()).toLocal();
  final today = DateTime(reference.year, reference.month, reference.day);

  return [
    for (final period in periods)
      if (!_forecastPeriodLocalDay(period).isBefore(today)) period,
  ];
}

DateTime _forecastPeriodLocalDay(ForecastPeriod period) {
  final local = period.time.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// Returns [forecast] with [prunePastForecastPeriods] applied.
WeatherForecast prunePastForecast(WeatherForecast forecast, {DateTime? now}) {
  final pruned = prunePastForecastPeriods(forecast.periods, now: now);
  if (pruned.length == forecast.periods.length) return forecast;
  return WeatherForecast(
    fetchedAt: forecast.fetchedAt,
    locationLabel: forecast.locationLabel,
    periods: pruned,
  );
}

WeatherForecast? weatherForecastFromFirestoreArchive(
  Map<String, dynamic> data,
) {
  final rawPeriods = data['periods'];
  if (rawPeriods is! Map) return null;

  final periods = <ForecastPeriod>[];
  for (final value in rawPeriods.values) {
    if (value is! Map) continue;
    periods.add(
      ForecastPeriod.fromJson(Map<String, dynamic>.from(value)),
    );
  }
  periods.sort((a, b) => a.time.compareTo(b.time));

  return prunePastForecast(
    WeatherForecast(
      fetchedAt: parseWeatherDate(data['fetchedAt']),
      locationLabel: data['locationLabel'] as String?,
      periods: periods,
    ),
  );
}

Map<String, dynamic> weatherForecastToFirestoreArchive({
  required double lat,
  required double lon,
  required String? locationLabel,
  required DateTime fetchedAt,
  required List<ForecastPeriod> periods,
  required int timeZoneOffsetMinutes,
}) {
  final bucketMap = forecastPeriodsToBucketMap(
    periods,
    timeZoneOffsetMinutes,
  );
  return {
    'lat': lat,
    'lon': lon,
    'locationLabel': locationLabel,
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
    'periods': {
      for (final entry in bucketMap.entries) entry.key: entry.value.toJson(),
    },
  };
}

bool forecastArchiveLocationMatches(
  Map<String, dynamic>? archive,
  double lat,
  double lon,
) {
  if (archive == null) return false;
  final archiveLat = archive['lat'];
  final archiveLon = archive['lon'];
  if (archiveLat is! num || archiveLon is! num) return false;
  return archiveLat.toDouble() == lat && archiveLon.toDouble() == lon;
}
