import 'package:voyager/domain/models/weather_models.dart';

abstract class WeatherApiClient {
  Future<({double lat, double lon, String label})> geocode(String query);

  Future<WeatherSnapshot> refreshWeather({
    required double lat,
    required double lon,
    required String deviceId,
    String? locationLabel,
  });

  Future<WeatherForecast> refreshForecast({
    required double lat,
    required double lon,
    String? locationLabel,
    required int timeZoneOffsetMinutes,
    bool resetArchive = false,
  });
}
