// Every link shape RANKINGS_MAP_HLD.md §6.2 lists, plus the ones that must be
// refused. The parser is the part of "paste a link" that breaks if Google
// changes its URLs, so each shape is pinned on its own.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voyager/data/remote/geoapify_client.dart';
import 'package:voyager/domain/rankings/google_maps_link.dart';

void main() {
  group('parseGoogleMapsLink', () {
    test('a place link reads the place, not the viewport', () {
      final place = parseGoogleMapsLink(
        'https://www.google.com/maps/place/Ennio%27s+Pasta+House/'
        '@43.4810000,-80.5300000,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x1!8m2'
        '!3d43.4833807!4d-80.5260427!16s%2Fg%2F1td',
      )!;
      expect(place.latitude, 43.4833807);
      expect(place.longitude, -80.5260427);
      expect(place.name, "Ennio's Pasta House");
    });

    test('a link with only a viewport falls back to its centre', () {
      final place = parseGoogleMapsLink(
        'https://www.google.com/maps/@43.4643,-80.5204,15z',
      )!;
      expect(place.latitude, 43.4643);
      expect(place.longitude, -80.5204);
      expect(place.name, isNull);
    });

    test('q= and ll= carry the coordinates as a query parameter', () {
      final q = parseGoogleMapsLink(
        'https://maps.google.com/?q=43.4643,-80.5204',
      )!;
      expect((q.latitude, q.longitude), (43.4643, -80.5204));
      final ll = parseGoogleMapsLink(
        'https://maps.google.com/maps?ll=-33.8688,151.2093&z=12',
      )!;
      expect((ll.latitude, ll.longitude), (-33.8688, 151.2093));
    });

    test('a link with no coordinates is refused', () {
      expect(
        parseGoogleMapsLink('https://www.google.com/maps/place/Lazeez/'),
        isNull,
      );
      expect(parseGoogleMapsLink('https://maps.google.com/?q=lazeez'), isNull);
      expect(parseGoogleMapsLink('https://maps.app.goo.gl/AbCd123'), isNull);
    });

    test('coordinates off the globe are refused', () {
      expect(
        parseGoogleMapsLink('https://www.google.com/maps/@143.4,-80.5,15z'),
        isNull,
      );
    });
  });

  test('a pasted link is told apart from a typed name', () {
    expect(looksLikeLink(' https://maps.app.goo.gl/AbCd123'), isTrue);
    expect(looksLikeLink('HTTP://google.com/maps'), isTrue);
    expect(looksLikeLink('ennio'), isFalse);
    expect(looksLikeLink('200 University Ave W'), isFalse);
  });

  test('only the short forms are followed', () {
    expect(
      isGoogleMapsShortLink(Uri.parse('https://maps.app.goo.gl/AbCd123')),
      isTrue,
    );
    expect(
      isGoogleMapsShortLink(Uri.parse('https://goo.gl/maps/AbCd123')),
      isTrue,
    );
    expect(
      isGoogleMapsShortLink(Uri.parse('https://www.google.com/maps/@1,2,3z')),
      isFalse,
    );
    expect(isGoogleMapsShortLink(Uri.parse('https://goo.gl/other')), isFalse);
  });

  test('a short link resolves to the link in its Location header', () async {
    const target =
        'https://www.google.com/maps/place/Lazeez/data=!3d43.47!4d-80.53';
    final client = MockClient((request) async {
      expect(request.followRedirects, isFalse);
      return http.Response('', 302, headers: {'location': target});
    });
    final resolved = await resolveGoogleMapsShortLink(
      Uri.parse('https://maps.app.goo.gl/AbCd123'),
      client,
    );
    final place = parseGoogleMapsLink(resolved.toString())!;
    expect((place.latitude, place.longitude), (43.47, -80.53));
    expect(place.name, 'Lazeez');
  });

  test('a short link that does not redirect resolves to nothing', () async {
    final client = MockClient((_) async => http.Response('', 404));
    expect(
      await resolveGoogleMapsShortLink(
        Uri.parse('https://maps.app.goo.gl/gone'),
        client,
      ),
      isNull,
    );
  });
}
