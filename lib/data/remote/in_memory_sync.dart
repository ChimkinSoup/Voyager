import 'dart:async';

import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class InMemorySyncRepository implements SyncRepository {
  final _documents = <String, Map<String, dynamic>>{};
  final _watchers = <String, StreamController<Map<String, dynamic>>>{};
  final _collectionWatchers = <String, StreamController<void>>{};
  final _operations = <String, List<SyncOperation>>{};
  GoogleCalendarSyncLock? _calendarLock;
  WeatherFetchLock? _weatherLock;
  WeatherSnapshot? _currentWeather;
  WeatherForecast? _storedForecast;

  String _key(String collection, String id) => '$collection/$id';

  void _notifyCollection(String collection) {
    final controller = _collectionWatchers[collection];
    if (controller != null && !controller.isClosed) {
      controller.add(null);
    }
  }

  @override
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    final key = _key(collection, id);
    _documents[key] = data;
    _watchers[key]?.add(data);
    _notifyCollection(collection);
  }

  @override
  Stream<Map<String, dynamic>> watchDocument(String collection, String id) {
    final key = _key(collection, id);
    final controller = _watchers.putIfAbsent(
      key,
      StreamController<Map<String, dynamic>>.broadcast,
    );
    if (_documents.containsKey(key)) {
      controller.add(_documents[key]!);
    }
    return controller.stream;
  }

  @override
  Stream<void> watchCollection(String collection) {
    final controller = _collectionWatchers.putIfAbsent(
      collection,
      StreamController<void>.broadcast,
    );
    return controller.stream;
  }

  @override
  Future<List<({String id, Map<String, dynamic> data})>> listCollectionDocuments(
    String collection,
  ) async {
    final prefix = '$collection/';
    return _documents.entries
        .where((entry) => entry.key.startsWith(prefix))
        .map(
          (entry) => (
            id: entry.key.substring(prefix.length),
            data: Map<String, dynamic>.from(entry.value),
          ),
        )
        .toList();
  }

  Map<String, dynamic>? _remoteSettings;

  @override
  Future<Map<String, dynamic>?> getRemoteSettings() async => _remoteSettings;

  @override
  Future<void> upsertRemoteSettings(Map<String, dynamic> data) async {
    _remoteSettings = {...?_remoteSettings, ...data};
  }

  @override
  Future<GoogleCalendarSyncLock?> getCalendarLock() async => _calendarLock;

  @override
  Future<bool> claimCalendarLock(GoogleCalendarSyncLock lock) async {
    final now = DateTime.now().toUtc();
    if (_calendarLock == null || now.isAfter(_calendarLock!.expiresAt)) {
      _calendarLock = lock;
      return true;
    }
    if (_calendarLock!.deviceId == lock.deviceId) {
      _calendarLock = lock;
      return true;
    }
    return false;
  }

  @override
  Future<void> releaseCalendarLock(String deviceId) async {
    if (_calendarLock?.deviceId == deviceId) {
      _calendarLock = null;
    }
  }

  @override
  Future<WeatherFetchLock?> getWeatherFetchLock() async => _weatherLock;

  @override
  Future<bool> claimWeatherFetchLock(WeatherFetchLock lock) async {
    final now = DateTime.now().toUtc();
    if (_weatherLock == null || now.isAfter(_weatherLock!.expiresAt)) {
      _weatherLock = lock;
      return true;
    }
    if (_weatherLock!.deviceId == lock.deviceId) {
      _weatherLock = lock;
      return true;
    }
    return false;
  }

  @override
  Future<void> releaseWeatherFetchLock(String deviceId) async {
    if (_weatherLock?.deviceId == deviceId) {
      _weatherLock = null;
    }
  }

  @override
  Future<WeatherSnapshot?> getCurrentWeather() async => _currentWeather;

  @override
  Future<void> upsertCurrentWeather(WeatherSnapshot weather) async {
    _currentWeather = weather;
  }

  @override
  Future<WeatherForecast?> getStoredForecast() async => _storedForecast;

  void setStoredForecast(WeatherForecast? forecast) {
    _storedForecast = forecast;
  }

  @override
  Future<void> appendOperation(SyncOperation operation) async {
    _operations.putIfAbsent(operation.documentId, () => []).add(operation);
  }

  @override
  Future<List<SyncOperation>> listOperations(String documentId) async {
    return List.unmodifiable(_operations[documentId] ?? const []);
  }
}
