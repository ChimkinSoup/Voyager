// The Geoapify client's request shape and its one piece of policy: amenities
// preferred, untyped only when that finds nothing (RANKINGS_MAP_HLD.md §6.1).
// Both are asked at once.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voyager/data/remote/geoapify_client.dart';

http.Response _results(List<Map<String, dynamic>> results) => http.Response(
  jsonEncode({'results': results}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const _ennio = {
  'name': "Ennio's Pasta House",
  'formatted': "Ennio's Pasta House, 384 King Street North, Waterloo, ON",
  'lat': 43.4833807,
  'lon': -80.5260427,
};

void main() {
  test('searches amenities within the radius of the bias point', () async {
    final requests = <Uri>[];
    final client = GeoapifyClient(
      apiKey: 'k',
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return request.url.queryParameters.containsKey('type')
            ? _results([_ennio])
            : _results([
                {'name': 'Untyped junk', 'lat': 0, 'lon': 0},
              ]);
      }),
    );

    final places = await client.searchPlaces(
      ' ennio ',
      latitude: 43.4643,
      longitude: -80.5204,
    );

    expect(requests, hasLength(2));
    final amenities = requests.singleWhere(
      (uri) => uri.queryParameters.containsKey('type'),
    );
    final query = amenities.queryParameters;
    expect(amenities.path, '/v1/geocode/autocomplete');
    expect(query['text'], 'ennio');
    expect(query['type'], 'amenity');
    // Geoapify takes longitude first.
    expect(query['bias'], 'proximity:-80.5204,43.4643');
    expect(query['filter'], 'circle:-80.5204,43.4643,30000');
    expect(query['apiKey'], 'k');
    expect(places.single.name, "Ennio's Pasta House");
    expect(places.single.address, contains('384 King Street North'));
    expect(places.single.latitude, 43.4833807);
    expect(places.single.longitude, -80.5260427);
  });

  test('an empty amenity search falls back to the untyped one', () async {
    final requests = <Uri>[];
    final client = GeoapifyClient(
      apiKey: 'k',
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return request.url.queryParameters.containsKey('type')
            ? _results(const [])
            : _results([
                {
                  'formatted': '12 Main Road, Waterloo, ON',
                  'address_line1': '12 Main Road',
                  'lat': 43.4,
                  'lon': -80.5,
                },
              ]);
      }),
    );

    final places = await client.searchPlaces(
      '12 main road',
      latitude: 43.4643,
      longitude: -80.5204,
    );

    expect(requests, hasLength(2));
    final untyped = requests.singleWhere(
      (uri) => !uri.queryParameters.containsKey('type'),
    );
    // Still inside the radius: the fallback widens what is searched for, not
    // where.
    expect(untyped.queryParameters['filter'], isNotNull);
    // A result with no name of its own is called by its first address line.
    expect(places.single.name, '12 Main Road');
  });

  test('searching everywhere drops the radius and keeps the bias', () async {
    final requests = <Uri>[];
    final client = GeoapifyClient(
      apiKey: 'k',
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return _results([_ennio]);
      }),
    );

    await client.searchPlaces(
      'ennio',
      latitude: 43.4643,
      longitude: -80.5204,
      everywhere: true,
    );

    expect(requests, hasLength(2));
    for (final uri in requests) {
      expect(uri.queryParameters.containsKey('filter'), isFalse);
      expect(uri.queryParameters['bias'], isNotNull);
    }
  });

  test('reverse geocoding returns the formatted address', () async {
    late Uri requested;
    final client = GeoapifyClient(
      apiKey: 'k',
      httpClient: MockClient((request) async {
        requested = request.url;
        return _results([
          {'formatted': '200 University Avenue West, Waterloo, ON'},
        ]);
      }),
    );

    expect(
      await client.reverseGeocode(43.4723, -80.5449),
      '200 University Avenue West, Waterloo, ON',
    );
    expect(requested.path, '/v1/geocode/reverse');
    expect(requested.queryParameters['lat'], '43.4723');
    expect(requested.queryParameters['lon'], '-80.5449');
  });

  test('a point the provider knows nothing about has no address', () async {
    final client = GeoapifyClient(
      apiKey: 'k',
      httpClient: MockClient((_) async => _results(const [])),
    );
    expect(await client.reverseGeocode(0, 0), '');
  });

  test('a failed request throws', () async {
    final client = GeoapifyClient(
      apiKey: 'k',
      httpClient: MockClient((_) async => http.Response('', 401)),
    );
    expect(
      () => client.searchPlaces('ennio', latitude: 0, longitude: 0),
      throwsException,
    );
  });
}
