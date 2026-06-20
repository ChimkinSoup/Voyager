import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/repositories/weather_api_client.dart';
import 'package:voyager/domain/services/openweather_mapper.dart';

/// Direct OpenWeather client for local development without Firebase Functions.
///
/// Enable with:
/// `flutter run --dart-define=USE_CLOUD_FUNCTIONS=false --dart-define=OPENWEATHER_API_KEY=your_key`
class DevOpenWeatherClient implements WeatherApiClient {
  DevOpenWeatherClient({required String apiKey, http.Client? httpClient})
    : _apiKey = apiKey,
      _http = httpClient ?? http.Client();

  final String _apiKey;
  final http.Client _http;

  @override
  Future<({double lat, double lon, String label})> geocode(String query) async {
    final uri = Uri.https('api.openweathermap.org', '/geo/1.0/direct', {
      'q': query.trim(),
      'limit': '1',
      'appid': _apiKey,
    });
    final response = await _http.get(uri);
    if (response.statusCode >= 400) {
      throw Exception('Geocoding failed (${response.statusCode}).');
    }

    final data = jsonDecode(response.body) as List<dynamic>;
    if (data.isEmpty) {
      throw Exception('Location not found.');
    }

    final place = data.first as Map<String, dynamic>;
    final label = [
      place['name'],
      place['state'],
      place['country'],
    ].whereType<String>().where((part) => part.isNotEmpty).join(', ');

    return (
      lat: (place['lat'] as num).toDouble(),
      lon: (place['lon'] as num).toDouble(),
      label: label,
    );
  }

  @override
  Future<WeatherSnapshot> refreshWeather({
    required double lat,
    required double lon,
    required String deviceId,
    String? locationLabel,
  }) async {
    final uri = Uri.https('api.openweathermap.org', '/data/2.5/weather', {
      'lat': '$lat',
      'lon': '$lon',
      'units': 'metric',
      'appid': _apiKey,
    });
    final response = await _http.get(uri);
    if (response.statusCode >= 400) {
      throw Exception('Weather request failed (${response.statusCode}).');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final weather = (data['weather'] as List<dynamic>).first as Map;
    final conditionCode = (weather['id'] as num).toInt();
    final main = data['main'] as Map<String, dynamic>;

    return WeatherSnapshot(
      icon: iconForOpenWeatherCondition(conditionCode),
      conditionCode: conditionCode,
      tempC: (main['temp'] as num).toDouble(),
      fetchedAt: utcNow(),
      lat: lat,
      lon: lon,
      locationLabel: locationLabel,
      updatedByDeviceId: deviceId,
    );
  }

  @override
  Future<WeatherForecast> refreshForecast({
    required double lat,
    required double lon,
    String? locationLabel,
    required int timeZoneOffsetMinutes,
    bool resetArchive = false,
  }) async {
    final uri = Uri.https('api.openweathermap.org', '/data/2.5/forecast', {
      'lat': '$lat',
      'lon': '$lon',
      'units': 'metric',
      'appid': _apiKey,
    });
    final response = await _http.get(uri);
    if (response.statusCode >= 400) {
      throw Exception('Forecast request failed (${response.statusCode}).');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['list'] as List<dynamic>? ?? const [];
    final periods = [
      for (final raw in list)
        _periodFromForecastItem(raw as Map<String, dynamic>),
    ];

    return WeatherForecast(
      fetchedAt: utcNow(),
      locationLabel: locationLabel,
      periods: periods,
    );
  }

  ForecastPeriod _periodFromForecastItem(Map<String, dynamic> item) {
    final weather = (item['weather'] as List<dynamic>).first as Map;
    final conditionCode = (weather['id'] as num).toInt();
    final main = item['main'] as Map<String, dynamic>;
    final dt = (item['dt'] as num).toInt();

    return ForecastPeriod(
      time: DateTime.fromMillisecondsSinceEpoch(dt * 1000, isUtc: true),
      tempC: (main['temp'] as num).toDouble(),
      pop: (item['pop'] as num?)?.toDouble() ?? 0,
      icon: iconForOpenWeatherCondition(conditionCode),
      conditionCode: conditionCode,
      description: weather['description'] as String? ?? '',
    );
  }
}
