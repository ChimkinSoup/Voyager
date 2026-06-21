import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/services/weather_service.dart';
import 'fakes/fake_weather_api_client.dart';

void main() {
  late AppDatabase db;
  late DriftSettingsRepository settingsRepo;
  late InMemorySyncRepository syncRepo;
  late FakeWeatherApiClient weatherClient;

  setUp(() async {
    db = AppDatabase.inMemory();
    settingsRepo = DriftSettingsRepository(db);
    syncRepo = InMemorySyncRepository();
    weatherClient = FakeWeatherApiClient();
    await settingsRepo.saveSettings(
      (await settingsRepo.getSettings()).copyWith(
        weatherLocationLabel: 'Chicago, US',
        weatherLat: 41.88,
        weatherLon: -87.63,
      ),
    );
  });

  tearDown(() async {
    await db.close();
  });

  WeatherService service() {
    return WeatherService(
      settingsRepository: settingsRepo,
      syncRepository: syncRepo,
      weatherApiClient: weatherClient,
      deviceId: 'test-device',
    );
  }

  test('returns null when location is not configured', () async {
    await settingsRepo.saveSettings(await settingsRepo.getSettings());
    final cleared = (await settingsRepo.getSettings()).copyWith(
      clearWeatherLat: true,
      clearWeatherLon: true,
    );
    await settingsRepo.saveSettings(cleared);

    final result = await service().refreshIfNeeded();
    expect(result, isNull);
    expect(weatherClient.refreshCalls, 0);
  });

  test('uses cached weather when fetched within refresh interval', () async {
    final fetchedAt = DateTime.now().toUtc().subtract(
      const Duration(minutes: 10),
    );
    await settingsRepo.saveSettings(
      (await settingsRepo.getSettings()).copyWith(
        weatherIcon: 'cloudy',
        weatherFetchedAt: fetchedAt,
        weatherConditionCode: 803,
      ),
    );

    final result = await service().refreshIfNeeded();
    expect(result?.icon, 'cloudy');
    expect(weatherClient.refreshCalls, 0);
  });

  test('refreshes when cache is older than refresh interval', () async {
    final stale = DateTime.now().toUtc().subtract(const Duration(minutes: 20));
    await settingsRepo.saveSettings(
      (await settingsRepo.getSettings()).copyWith(
        weatherIcon: 'sunny',
        weatherFetchedAt: stale,
        weatherConditionCode: 800,
      ),
    );

    final result = await service().refreshIfNeeded();
    expect(result?.icon, 'rain');
    expect(weatherClient.refreshCalls, 1);
  });

  test('isCacheStale is false for fresh cache', () async {
    await settingsRepo.saveSettings(
      (await settingsRepo.getSettings()).copyWith(
        weatherIcon: 'cloudy',
        weatherFetchedAt: DateTime.now().toUtc().subtract(
          const Duration(minutes: 5),
        ),
        weatherConditionCode: 803,
      ),
    );

    expect(await service().isCacheStale(), isFalse);
  });

  test('isCacheStale is true for expired cache', () async {
    await settingsRepo.saveSettings(
      (await settingsRepo.getSettings()).copyWith(
        weatherIcon: 'cloudy',
        weatherFetchedAt: DateTime.now().toUtc().subtract(
          const Duration(minutes: 20),
        ),
        weatherConditionCode: 803,
      ),
    );

    expect(await service().isCacheStale(), isTrue);
  });

  test('prefers newer firestore snapshot without refresh', () async {
    final stale = DateTime.now().toUtc().subtract(const Duration(minutes: 20));
    await settingsRepo.saveSettings(
      (await settingsRepo.getSettings()).copyWith(
        weatherIcon: 'sunny',
        weatherFetchedAt: stale,
        weatherConditionCode: 800,
      ),
    );
    await syncRepo.upsertCurrentWeather(
      WeatherSnapshot(
        icon: 'snow',
        conditionCode: 600,
        fetchedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 10)),
        lat: 41.88,
        lon: -87.63,
      ),
    );

    final result = await service().refreshIfNeeded();
    expect(result?.icon, 'snow');
    expect(weatherClient.refreshCalls, 0);
  });

  test('fetchForecastIfNeeded uses cached forecast within interval', () async {
    final fetchedAt = DateTime.now().toUtc().subtract(const Duration(minutes: 10));
    await settingsRepo.saveSettings(
      (await settingsRepo.getSettings()).copyWith(
        weatherForecastJson:
            '{"fetchedAt":"${fetchedAt.toIso8601String()}","locationLabel":"Chicago, US","periods":[{"time":"2026-06-20T12:00:00.000Z","tempC":14,"pop":0.2,"icon":"cloudy","conditionCode":803,"description":"clouds"}]}',
      ),
    );

    final result = await service().fetchForecastIfNeeded();
    expect(result?.locationLabel, 'Chicago, US');
    expect(weatherClient.forecastCalls, 0);
  });

  test('fetchForecastIfNeeded refreshes stale forecast', () async {
    final stale = DateTime.now().toUtc().subtract(const Duration(minutes: 20));
    await settingsRepo.saveSettings(
      (await settingsRepo.getSettings()).copyWith(
        weatherForecastJson:
            '{"fetchedAt":"${stale.toIso8601String()}","locationLabel":"Chicago, US","periods":[]}',
      ),
    );

    final result = await service().fetchForecastIfNeeded();
    expect(result?.periods, isNotEmpty);
    expect(weatherClient.forecastCalls, 1);
  });
}
