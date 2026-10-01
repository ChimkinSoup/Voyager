import 'dart:convert';

import 'package:http/http.dart' as http;

/// One place a search returned.
typedef GeoapifyPlace = ({
  String name,
  String address,
  double latitude,
  double longitude,
});

/// Place search and reverse geocoding for ranking locations.
///
/// Enable with `--dart-define=GEOAPIFY_API_KEY=your_key`. Geoapify permits
/// storing its results permanently, which the synced model needs.
class GeoapifyClient {
  GeoapifyClient({required this.apiKey, http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final String apiKey;
  final http.Client _http;

  /// How far from the bias point a search reaches unless told to go
  /// everywhere. Bias alone lets same-named places in other countries in.
  static const searchRadiusMeters = 30000;

  static const requestTimeout = Duration(seconds: 10);

  /// Places matching [text], nearest [latitude]/[longitude] first.
  ///
  /// Amenities only at first: an untyped search fills its misses with junk.
  /// When that finds nothing the search is repeated untyped, which is what
  /// lets a typed street address through. [everywhere] drops the radius, and
  /// so does having no point to search around.
  Future<List<GeoapifyPlace>> searchPlaces(
    String text, {
    required double? latitude,
    required double? longitude,
    bool everywhere = false,
  }) async {
    final near = latitude == null || longitude == null
        ? null
        : '$longitude,$latitude';
    Future<List<GeoapifyPlace>> search({required bool amenityOnly}) async {
      final results = await _results('/v1/geocode/autocomplete', {
        'text': text.trim(),
        if (amenityOnly) 'type': 'amenity',
        if (near != null) 'bias': 'proximity:$near',
        if (near != null && !everywhere)
          'filter': 'circle:$near,$searchRadiusMeters',
      });
      return [
        for (final result in results)
          (
            name:
                result['name'] as String? ??
                result['address_line1'] as String? ??
                '',
            address: result['formatted'] as String? ?? '',
            latitude: (result['lat'] as num).toDouble(),
            longitude: (result['lon'] as num).toDouble(),
          ),
      ];
    }

    final amenities = await search(amenityOnly: true);
    return amenities.isNotEmpty ? amenities : search(amenityOnly: false);
  }

  /// The formatted address at a point, or `''` when the provider knows none.
  Future<String> reverseGeocode(double latitude, double longitude) async {
    final results = await _results('/v1/geocode/reverse', {
      'lat': '$latitude',
      'lon': '$longitude',
    });
    return results.firstOrNull?['formatted'] as String? ?? '';
  }

  Future<List<Map<String, dynamic>>> _results(
    String path,
    Map<String, String> query,
  ) async {
    final uri = Uri.https('api.geoapify.com', path, {
      ...query,
      'format': 'json',
      'apiKey': apiKey,
    });
    // A stalled connection would otherwise leave the caller waiting forever
    // on an address it can do without.
    final response = await _http.get(uri).timeout(requestTimeout);
    if (response.statusCode >= 400) {
      throw Exception('Geoapify request failed (${response.statusCode}).');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return [
      for (final result in data['results'] as List? ?? const [])
        Map<String, dynamic>.from(result as Map),
    ];
  }
}

/// Follows a Google Maps short link one hop and returns the link it stands
/// for, or null when it does not redirect.
///
/// Read off the `Location` header rather than followed: the target page is
/// never wanted, only its address.
Future<Uri?> resolveGoogleMapsShortLink(Uri link, http.Client client) async {
  final request = http.Request('GET', link)..followRedirects = false;
  final response = await client
      .send(request)
      .timeout(GeoapifyClient.requestTimeout);
  await response.stream.drain<void>();
  final location = response.headers['location'];
  return location == null ? null : Uri.tryParse(location);
}
