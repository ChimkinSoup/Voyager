import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/weather_models.dart';

class _FakeTimestamp {
  _FakeTimestamp(this.value);

  final DateTime value;

  DateTime toDate() => value;
}

void main() {
  test('fromJson parses Firestore Timestamp-like fetchedAt', () {
    final fetchedAt = DateTime.utc(2026, 6, 20, 12, 30);
    final snapshot = WeatherSnapshot.fromJson({
      'icon': 'rain',
      'conditionCode': 501,
      'tempC': 12.5,
      'fetchedAt': _FakeTimestamp(fetchedAt),
      'locationLabel': 'Waterloo, CA',
      'lat': 43.46,
      'lon': -80.52,
    });

    expect(snapshot.fetchedAt, fetchedAt);
    expect(snapshot.icon, 'rain');
  });

  test('buildDailyForecastSummaries groups periods by local day', () {
    final periods = [
      ForecastPeriod(
        time: DateTime.utc(2026, 6, 20, 12),
        tempC: 20,
        pop: 0.1,
        icon: 'sunny',
        conditionCode: 800,
        description: 'clear',
      ),
      ForecastPeriod(
        time: DateTime.utc(2026, 6, 20, 18),
        tempC: 16,
        pop: 0.6,
        icon: 'rain',
        conditionCode: 500,
        description: 'rain',
      ),
      ForecastPeriod(
        time: DateTime.utc(2026, 6, 21, 12),
        tempC: 18,
        pop: 0.2,
        icon: 'cloudy',
        conditionCode: 803,
        description: 'clouds',
      ),
    ];

    final summaries = buildDailyForecastSummaries(periods);
    expect(summaries.length, 2);
    expect(summaries.first.highC, 20);
    expect(summaries.first.lowC, 16);
    expect(summaries.first.maxPop, 0.6);
    expect(summaries.first.icon, 'rain');
  });
}
