import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/services/weather_forecast_merge.dart';

ForecastPeriod _period(DateTime time, double tempC, {double pop = 0.2}) {
  return ForecastPeriod(
    time: time.toUtc(),
    tempC: tempC,
    pop: pop,
    icon: 'cloudy',
    conditionCode: 803,
    description: 'clouds',
  );
}

void main() {
  const offsetMinutes = 0;

  test('mergeForecastArchive drops buckets before today', () {
    final now = DateTime.utc(2026, 6, 21, 10);
    final merged = mergeForecastArchive(
      existingPeriods: [
        _period(DateTime.utc(2026, 6, 20, 15), 18),
        _period(DateTime.utc(2026, 6, 21, 6), 12),
      ],
      apiPeriods: const [],
      timeZoneOffsetMinutes: offsetMinutes,
      nowUtc: now,
    );

    expect(merged.length, 1);
    expect(merged.first.time, DateTime.utc(2026, 6, 21, 6));
  });

  test('mergeForecastArchive keeps past buckets on today not in API', () {
    final now = DateTime.utc(2026, 6, 21, 10);
    final merged = mergeForecastArchive(
      existingPeriods: [
        _period(DateTime.utc(2026, 6, 21, 0), 8),
        _period(DateTime.utc(2026, 6, 21, 3), 9),
        _period(DateTime.utc(2026, 6, 21, 6), 10),
      ],
      apiPeriods: [
        _period(DateTime.utc(2026, 6, 21, 12), 14),
        _period(DateTime.utc(2026, 6, 21, 15), 16),
      ],
      timeZoneOffsetMinutes: offsetMinutes,
      nowUtc: now,
    );

    expect(merged.map((p) => p.time.hour), [0, 3, 6, 12, 15]);
    expect(merged.first.tempC, 8);
    expect(merged.last.tempC, 16);
  });

  test('mergeForecastArchive overwrites buckets when API returns them', () {
    final now = DateTime.utc(2026, 6, 21, 10);
    final merged = mergeForecastArchive(
      existingPeriods: [
        _period(DateTime.utc(2026, 6, 21, 6), 10),
      ],
      apiPeriods: [
        _period(DateTime.utc(2026, 6, 21, 6), 11),
      ],
      timeZoneOffsetMinutes: offsetMinutes,
      nowUtc: now,
    );

    expect(merged.single.tempC, 11);
  });

  test('mergeForecastArchive resetArchive ignores existing periods', () {
    final now = DateTime.utc(2026, 6, 21, 10);
    final merged = mergeForecastArchive(
      existingPeriods: [
        _period(DateTime.utc(2026, 6, 21, 6), 10),
      ],
      apiPeriods: [
        _period(DateTime.utc(2026, 6, 21, 12), 14),
      ],
      timeZoneOffsetMinutes: offsetMinutes,
      nowUtc: now,
      resetArchive: true,
    );

    expect(merged.length, 1);
    expect(merged.single.time.hour, 12);
  });

  test('forecastBucketKey uses local 3-hour buckets', () {
    expect(
      forecastBucketKey(DateTime.utc(2026, 6, 21, 17), offsetMinutes),
      '2026_06_21_15',
    );
  });
}
