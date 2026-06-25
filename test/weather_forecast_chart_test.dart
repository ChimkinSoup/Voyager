import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/services/weather_forecast_chart.dart';

ForecastPeriod _period(int year, int month, int day, int hour, double tempC) {
  return ForecastPeriod(
    time: DateTime(year, month, day, hour),
    tempC: tempC,
    pop: 0.2,
    icon: 'cloudy',
    conditionCode: 803,
    description: 'clouds',
  );
}

void main() {
  test('chartBucketHour snaps to local 3-hour grid', () {
    expect(chartBucketHour(DateTime(2026, 6, 20, 17)), 15);
    expect(chartBucketHour(DateTime(2026, 6, 20, 18)), 18);
  });

  test('periodsForDay buckets non-grid hours into 3-hour slots', () {
    final periods = [
      _period(2026, 6, 20, 17, 19),
      _period(2026, 6, 20, 18, 18),
      _period(2026, 6, 21, 9, 16),
    ];

    final dayPeriods = periodsForDay(periods, DateTime(2026, 6, 20));
    expect(dayPeriods.length, 2);
    expect(chartBucketHour(dayPeriods[0].time.toLocal()), 15);
    expect(chartBucketHour(dayPeriods[1].time.toLocal()), 18);
  });

  test('initialForecastDayIndex selects today when present', () {
    final now = DateTime(2026, 6, 20, 14);
    final days = [
      DailyForecastSummary(
        date: DateTime(2026, 6, 19),
        highC: 20,
        lowC: 10,
        maxPop: 0.1,
        icon: 'sunny',
      ),
      DailyForecastSummary(
        date: DateTime(2026, 6, 20),
        highC: 22,
        lowC: 12,
        maxPop: 0.2,
        icon: 'cloudy',
      ),
    ];

    expect(initialForecastDayIndex(days, now), 1);
  });

  test('buildDayForecastChartSeries marks future full days', () {
    final periods = [
      for (final hour in forecastDayChartHours)
        _period(2026, 6, 21, hour, 10 + hour / 3),
      _period(2026, 6, 22, 0, 18),
    ];

    final series = buildDayForecastChartSeries(
      periods,
      DateTime(2026, 6, 21),
      now: DateTime(2026, 6, 20, 14),
    );
    expect(series.isFullDay, isTrue);
    expect(
      series.tempPoints.map((p) => p.hour),
      [...forecastDayChartHours, 24],
    );
  });

  test('buildDayForecastChartSeries bridges consecutive days at midnight', () {
    final periods = [
      for (final hour in [0, 3, 6, 9, 12, 15, 18, 21])
        _period(2026, 6, 20, hour, 20),
      _period(2026, 6, 21, 0, 14),
    ];

    final dayOne = buildDayForecastChartSeries(
      periods,
      DateTime(2026, 6, 20),
    );
    final dayTwo = buildDayForecastChartSeries(
      periods,
      DateTime(2026, 6, 21),
    );

    expect(dayOne.tempPoints.last, (hour: 24.0, tempC: 14.0));
    expect(dayTwo.tempPoints.first, (hour: 0.0, tempC: 14.0));
  });

  test('buildDayForecastChartSeries does not mark today as full day', () {
    final periods = [
      for (final hour in [15, 18, 21]) _period(2026, 6, 20, hour, 20),
    ];

    final series = buildDayForecastChartSeries(
      periods,
      DateTime(2026, 6, 20),
      now: DateTime(2026, 6, 20, 14),
    );
    expect(series.isFullDay, isFalse);
    expect(series.tempPoints.map((p) => p.hour), [15, 18, 21]);
  });

  test('chartBucketRangeCenteredOn spans 3 hours around bucket hour', () {
    expect(chartBucketRangeCenteredOn(3), (start: 1.5, end: 4.5));
    expect(chartBucketRangeCenteredOn(12), (start: 10.5, end: 13.5));
    expect(chartBucketRangeCenteredOn(0), (start: 0.0, end: 1.5));
    expect(chartBucketRangeCenteredOn(21), (start: 19.5, end: 22.5));
  });

  test('resolveForecastDayIndex restores last viewed day', () {
    final days = [
      DailyForecastSummary(
        date: DateTime(2026, 6, 19),
        highC: 20,
        lowC: 10,
        maxPop: 0.1,
        icon: 'sunny',
      ),
      DailyForecastSummary(
        date: DateTime(2026, 6, 20),
        highC: 22,
        lowC: 12,
        maxPop: 0.2,
        icon: 'cloudy',
      ),
      DailyForecastSummary(
        date: DateTime(2026, 6, 21),
        highC: 24,
        lowC: 14,
        maxPop: 0.3,
        icon: 'rain',
      ),
    ];

    expect(
      resolveForecastDayIndex(days, DateTime(2026, 6, 21)),
      2,
    );
    expect(resolveForecastDayIndex(days, DateTime(2026, 6, 99)), 0);
    expect(resolveForecastDayIndex(days, null), 0);
  });

  test('forecastRainGradientStartHour uses fetch bucket on same day', () {
    expect(
      forecastRainGradientStartHour(
        DateTime(2026, 6, 20),
        DateTime(2026, 6, 20, 17, 30),
      ),
      15,
    );
    expect(
      forecastRainGradientStartHour(
        DateTime(2026, 6, 21),
        DateTime(2026, 6, 20, 17, 30),
      ),
      0,
    );
  });

  test('rainFillBlendFactor ramps rain fill before gradient start', () {
    expect(rainFillBlendFactor(18, 18), 1);
    expect(rainFillBlendFactor(19, 18), 1);
    expect(rainFillBlendFactor(12, 18), 0);
    expect(rainFillBlendFactor(15, 18), closeTo(0, 0.001));
    expect(rainFillBlendFactor(16.5, 18), closeTo(0.5, 0.001));
    expect(rainFillBlendFactor(17.999, 18), closeTo(0.999, 0.01));
  });
}
