import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/repositories/weather_api_client.dart';

class FakeWeatherApiClient implements WeatherApiClient {
  FakeWeatherApiClient({
    this.geocodeResult = (lat: 41.88, lon: -87.63, label: 'Chicago, US'),
    this.refreshResult,
    this.forecastResult,
  });

  final ({double lat, double lon, String label}) geocodeResult;
  WeatherSnapshot? refreshResult;
  WeatherForecast? forecastResult;
  var geocodeCalls = 0;
  var refreshCalls = 0;
  var forecastCalls = 0;

  @override
  Future<({double lat, double lon, String label})> geocode(String query) async {
    geocodeCalls++;
    return geocodeResult;
  }

  @override
  Future<WeatherSnapshot> refreshWeather({
    required double lat,
    required double lon,
    required String deviceId,
    String? locationLabel,
  }) async {
    refreshCalls++;
    return refreshResult ??
        WeatherSnapshot(
          icon: 'rain',
          conditionCode: 501,
          tempC: 12,
          fetchedAt: DateTime.now().toUtc(),
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
    forecastCalls++;
    return forecastResult ??
        WeatherForecast(
          fetchedAt: DateTime.now().toUtc(),
          locationLabel: locationLabel,
          periods: [
            ForecastPeriod(
              time: DateTime.now().toUtc().add(const Duration(hours: 3)),
              tempC: 14,
              pop: 0.4,
              icon: 'rain',
              conditionCode: 500,
              description: 'light rain',
            ),
          ],
        );
  }
}
