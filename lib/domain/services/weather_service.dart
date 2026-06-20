import 'dart:convert';

import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/repositories/weather_api_client.dart';
import 'package:voyager/domain/services/weather_forecast_merge.dart';

class WeatherService {
  WeatherService({
    required SettingsRepository settingsRepository,
    required SyncRepository syncRepository,
    required WeatherApiClient weatherApiClient,
    required String deviceId,
    this.mergeForecastLocally = false,
  }) : _settingsRepository = settingsRepository,
       _syncRepository = syncRepository,
       _weatherApiClient = weatherApiClient,
       _deviceId = deviceId;

  static const refreshInterval = Duration(minutes: 15);
  static const _lockDuration = Duration(minutes: 2);

  final SettingsRepository _settingsRepository;
  final SyncRepository _syncRepository;
  final WeatherApiClient _weatherApiClient;
  final String _deviceId;
  final bool mergeForecastLocally;

  int get _timeZoneOffsetMinutes => DateTime.now().timeZoneOffset.inMinutes;

  Future<WeatherSnapshot?> refreshIfNeeded({bool force = false}) async {
    final settings = await _settingsRepository.getSettings();
    if (!settings.hasWeatherLocation) return null;

    var snapshot = _snapshotFromSettings(settings);
    final remote = await _syncRepository.getCurrentWeather();
    if (remote != null && remote.isNewerThan(snapshot)) {
      snapshot = remote;
      await _persistCache(settings, remote);
    }

    final now = DateTime.now().toUtc();
    if (!force &&
        snapshot != null &&
        now.difference(snapshot.fetchedAt) < refreshInterval) {
      return snapshot;
    }

    final lat = settings.weatherLat!;
    final lon = settings.weatherLon!;
    final lock = WeatherFetchLock(
      deviceId: _deviceId,
      lockedAt: now,
      expiresAt: now.add(_lockDuration),
    );
    final claimed = await _syncRepository.claimWeatherFetchLock(lock);
    if (!claimed) {
      final latest = await _syncRepository.getCurrentWeather();
      if (latest != null) {
        await _persistCache(settings, latest);
        return latest;
      }
      return snapshot;
    }

    try {
      final refreshed = await _weatherApiClient.refreshWeather(
        lat: lat,
        lon: lon,
        deviceId: _deviceId,
        locationLabel: settings.weatherLocationLabel,
      );
      await _persistCache(settings, refreshed);
      return refreshed;
    } finally {
      await _syncRepository.releaseWeatherFetchLock(_deviceId);
    }
  }

  Future<void> saveLocation(String query) async {
    final geocoded = await _weatherApiClient.geocode(query);
    final settings = await _settingsRepository.getSettings();
    final now = DateTime.now().toUtc();
    await _settingsRepository.saveSettings(
      settings.copyWith(
        weatherLocationLabel: geocoded.label,
        weatherLat: geocoded.lat,
        weatherLon: geocoded.lon,
        weatherLocationUpdatedAt: now,
        clearWeatherIcon: true,
        clearWeatherFetchedAt: true,
        clearWeatherConditionCode: true,
        clearWeatherTempC: true,
        clearWeatherForecastJson: true,
      ),
    );
    await _syncRepository.upsertRemoteSettings({
      'weatherLocationLabel': geocoded.label,
      'weatherLat': geocoded.lat,
      'weatherLon': geocoded.lon,
      'weatherLocationUpdatedAt': now.toIso8601String(),
    });
    await refreshIfNeeded(force: true);
    await fetchForecastIfNeeded(force: true, resetArchive: true);
  }

  /// Applies a newer weather location from Firestore settings, if present.
  Future<void> syncLocationFromRemote() async {
    final remote = await _syncRepository.getRemoteSettings();
    if (remote == null) return;

    final lat = remote['weatherLat'];
    final lon = remote['weatherLon'];
    if (lat is! num || lon is! num) return;

    final remoteUpdated = parseFirestoreDate(remote['weatherLocationUpdatedAt']);
    final local = await _settingsRepository.getSettings();
    if (remoteUpdated != null &&
        local.weatherLocationUpdatedAt != null &&
        !remoteUpdated.isAfter(local.weatherLocationUpdatedAt!)) {
      return;
    }

    final locationChanged =
        local.weatherLat != lat.toDouble() || local.weatherLon != lon.toDouble();

    await _settingsRepository.saveSettings(
      local.copyWith(
        weatherLocationLabel: remote['weatherLocationLabel'] as String?,
        weatherLat: lat.toDouble(),
        weatherLon: lon.toDouble(),
        weatherLocationUpdatedAt: remoteUpdated ?? utcNow(),
        clearWeatherForecastJson: locationChanged,
      ),
    );
  }

  /// Pulls merged forecast archive from Firestore into local SQLite cache.
  Future<void> syncForecastFromRemote() async {
    final settings = await _settingsRepository.getSettings();
    if (!settings.hasWeatherLocation) return;

    try {
      final remote = await _syncRepository.getStoredForecast();
      if (remote == null) return;

      final local = readCachedForecast(settings);
      if (local == null || remote.fetchedAt.isAfter(local.fetchedAt)) {
        await _persistForecast(settings, remote);
      }
    } catch (_) {
      // Ignore malformed or unreadable remote forecast archives.
    }
  }

  /// Local-only check: true when cached weather is missing or older than [refreshInterval].
  Future<bool> isCacheStale() async {
    final settings = await _settingsRepository.getSettings();
    if (!settings.hasWeatherLocation) return false;
    final snapshot = _snapshotFromSettings(settings);
    if (snapshot == null) return true;
    final age = DateTime.now().toUtc().difference(snapshot.fetchedAt);
    return age >= refreshInterval;
  }

  Future<bool> isForecastCacheStale() async {
    final settings = await _settingsRepository.getSettings();
    if (!settings.hasWeatherLocation) return false;
    final forecast = readCachedForecast(settings);
    if (forecast == null) return true;
    final age = DateTime.now().toUtc().difference(forecast.fetchedAt);
    return age >= refreshInterval;
  }

  WeatherSnapshot? readCachedSnapshot(AppSettings settings) {
    return _snapshotFromSettings(settings);
  }

  Future<WeatherForecast?> fetchForecastIfNeeded({
    bool force = false,
    bool resetArchive = false,
  }) async {
    var settings = await _settingsRepository.getSettings();
    if (!settings.hasWeatherLocation) return null;

    await syncForecastFromRemote();
    settings = await _settingsRepository.getSettings();

    var forecast = readCachedForecast(settings);
    final now = DateTime.now().toUtc();
    if (!force &&
        forecast != null &&
        now.difference(forecast.fetchedAt) < refreshInterval) {
      return forecast;
    }

    final apiForecast = await _weatherApiClient.refreshForecast(
      lat: settings.weatherLat!,
      lon: settings.weatherLon!,
      locationLabel: settings.weatherLocationLabel,
      timeZoneOffsetMinutes: _timeZoneOffsetMinutes,
      resetArchive: resetArchive,
    );

    final merged = mergeForecastLocally
        ? WeatherForecast(
            fetchedAt: apiForecast.fetchedAt,
            locationLabel: apiForecast.locationLabel,
            periods: mergeForecastArchive(
              existingPeriods: resetArchive
                  ? const []
                  : (forecast?.periods ?? const []),
              apiPeriods: apiForecast.periods,
              timeZoneOffsetMinutes: _timeZoneOffsetMinutes,
              nowUtc: now,
              resetArchive: resetArchive,
            ),
          )
        : apiForecast;

    await _persistForecast(settings, merged);
    return merged;
  }

  WeatherForecast? readCachedForecast(AppSettings settings) {
    final raw = settings.weatherForecastJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      return WeatherForecast.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  WeatherSnapshot? _snapshotFromSettings(AppSettings settings) {
    if (settings.weatherIcon == null ||
        settings.weatherFetchedAt == null ||
        settings.weatherLat == null ||
        settings.weatherLon == null) {
      return null;
    }
    return WeatherSnapshot(
      icon: settings.weatherIcon!,
      conditionCode: settings.weatherConditionCode ?? 800,
      tempC: settings.weatherTempC,
      fetchedAt: settings.weatherFetchedAt!,
      locationLabel: settings.weatherLocationLabel,
      lat: settings.weatherLat!,
      lon: settings.weatherLon!,
    );
  }

  Future<void> _persistCache(
    AppSettings settings,
    WeatherSnapshot snapshot,
  ) async {
    await _settingsRepository.saveSettings(
      settings.copyWith(
        weatherIcon: snapshot.icon,
        weatherFetchedAt: snapshot.fetchedAt,
        weatherConditionCode: snapshot.conditionCode,
        weatherTempC: snapshot.tempC,
        weatherLocationLabel:
            snapshot.locationLabel ?? settings.weatherLocationLabel,
        weatherLat: snapshot.lat,
        weatherLon: snapshot.lon,
      ),
    );
  }

  Future<void> _persistForecast(
    AppSettings settings,
    WeatherForecast forecast,
  ) async {
    await _settingsRepository.saveSettings(
      settings.copyWith(
        weatherForecastJson: jsonEncode(forecast.toJson()),
      ),
    );
  }
}
