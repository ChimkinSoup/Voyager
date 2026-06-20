import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:voyager/data/remote/http_callable_client.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/repositories/weather_api_client.dart';

class CloudFunctionWeatherClient implements WeatherApiClient {
  CloudFunctionWeatherClient.fromFunctions(FirebaseFunctions functions)
    : _functions = functions,
      _httpCallable = null;

  CloudFunctionWeatherClient.fromHttp(HttpCallableClient httpCallable)
    : _functions = null,
      _httpCallable = httpCallable;

  final FirebaseFunctions? _functions;
  final HttpCallableClient? _httpCallable;

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data,
  ) async {
    if (_httpCallable != null) {
      return _httpCallable.call(name, data);
    }
    final result = await _functions!.httpsCallable(name).call(data);
    return Map<String, dynamic>.from(result.data as Map);
  }

  @override
  Future<({double lat, double lon, String label})> geocode(String query) async {
    final data = await _call('geocodeLocation', {'query': query});
    return (
      lat: (data['lat'] as num).toDouble(),
      lon: (data['lon'] as num).toDouble(),
      label: data['label'] as String,
    );
  }

  @override
  Future<WeatherSnapshot> refreshWeather({
    required double lat,
    required double lon,
    required String deviceId,
    String? locationLabel,
  }) async {
    final data = await _call('refreshWeather', {
      'lat': lat,
      'lon': lon,
      'deviceId': deviceId,
      'locationLabel': locationLabel,
    });
    return WeatherSnapshot.fromJson(data);
  }

  @override
  Future<WeatherForecast> refreshForecast({
    required double lat,
    required double lon,
    String? locationLabel,
    required int timeZoneOffsetMinutes,
    bool resetArchive = false,
  }) async {
    final data = await _call('refreshWeatherForecast', {
      'lat': lat,
      'lon': lon,
      'locationLabel': locationLabel,
      'timeZoneOffsetMinutes': timeZoneOffsetMinutes,
      'resetArchive': resetArchive,
    });
    return WeatherForecast.fromJson(data);
  }
}

class FirestoreWeatherReader {
  FirestoreWeatherReader(this._firestore, this._userId);

  final FirebaseFirestore _firestore;
  final String _userId;

  DocumentReference<Map<String, dynamic>> get _weatherDoc =>
      _firestore.doc('users/$_userId/weather/current');

  Future<WeatherSnapshot?> getCurrentWeather() async {
    final snap = await _weatherDoc.get();
    if (!snap.exists || snap.data() == null) return null;
    return WeatherSnapshot.fromJson(snap.data()!);
  }

  Stream<WeatherSnapshot?> watchCurrentWeather() {
    return _weatherDoc.snapshots().map((snap) {
      if (!snap.exists || snap.data() == null) return null;
      return WeatherSnapshot.fromJson(snap.data()!);
    });
  }
}
