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
        weatherIcon: 'cloudy',
        weatherFetchedAt: DateTime.now().toUtc().subtract(
          const Duration(minutes: 5),
        ),
        weatherConditionCode: 803,
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

  test('new entry path uses cached weather without second API call', () async {
    final weather =
        await service().refreshIfNeeded() ??
        service().readCachedSnapshot(await settingsRepo.getSettings());

    expect(weather?.icon, 'cloudy');
    expect(weatherClient.refreshCalls, 0);
  });

  test('syncLocationFromRemote applies newer remote location', () async {
    final remoteTime = DateTime.now().toUtc().add(const Duration(minutes: 1));
    await syncRepo.upsertRemoteSettings({
      'weatherLocationLabel': 'Waterloo, CA',
      'weatherLat': 43.46,
      'weatherLon': -80.52,
      'weatherLocationUpdatedAt': remoteTime.toIso8601String(),
    });

    await service().syncLocationFromRemote();
    final settings = await settingsRepo.getSettings();

    expect(settings.weatherLocationLabel, 'Waterloo, CA');
    expect(settings.weatherLat, closeTo(43.46, 0.01));
    expect(settings.weatherLon, closeTo(-80.52, 0.01));
  });

  test('saveLocation writes remote settings for other devices', () async {
    final client = FakeWeatherApiClient(
      geocodeResult: (lat: 43.46, lon: -80.52, label: 'Waterloo, CA'),
      refreshResult: WeatherSnapshot(
        icon: 'rain',
        conditionCode: 501,
        tempC: 10,
        fetchedAt: DateTime.now().toUtc(),
        lat: 43.46,
        lon: -80.52,
        locationLabel: 'Waterloo, CA',
      ),
    );
    final saveService = WeatherService(
      settingsRepository: settingsRepo,
      syncRepository: syncRepo,
      weatherApiClient: client,
      deviceId: 'test-device',
    );

    await saveService.saveLocation('Waterloo, CA');
    final remote = await syncRepo.getRemoteSettings();

    expect(remote?['weatherLocationLabel'], 'Waterloo, CA');
    expect(remote?['weatherLat'], 43.46);
    expect(remote?['weatherLon'], -80.52);
    expect(remote?['weatherLocationUpdatedAt'], isNotNull);
  });
}
