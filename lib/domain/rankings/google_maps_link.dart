/// What a pasted Google Maps link says about a place: where it is, and what
/// the link calls it when it names one.
typedef GoogleMapsPlace = ({double latitude, double longitude, String? name});

const _number = r'(-?\d+(?:\.\d+)?)';
final _placePattern = RegExp('!3d$_number!4d$_number');
final _viewportPattern = RegExp('@$_number,$_number');
final _pairPattern = RegExp('^$_number,\\s*$_number\$');
final _googleHost = RegExp(
  r'^(?:www\.|maps\.)?google\.[a-z]{2,3}(?:\.[a-z]{2})?$',
);

/// Whether [input] is a link to resolve rather than a name to search for.
bool looksLikeLink(String input) =>
    RegExp(r'^https?://', caseSensitive: false).hasMatch(input.trim());

/// Whether [link] is one of Google's short forms, which carry no coordinates
/// themselves and have to be followed to the link they stand for.
bool isGoogleMapsShortLink(Uri link) =>
    link.host == 'maps.app.goo.gl' ||
    (link.host == 'goo.gl' && link.path.startsWith('/maps'));

/// Whether [link] is a Google Maps page: `maps.google.<tld>`, or
/// `google.<tld>/maps` with or without `www.` (BUG-170).
bool _isGoogleMapsLink(Uri link) {
  final host = link.host.toLowerCase();
  if (!_googleHost.hasMatch(host)) return false;
  return host.startsWith('maps.') || link.path.startsWith('/maps');
}

/// Reads the coordinates out of a full Google Maps link, or null when it holds
/// none or isn't a Google Maps link. The link is read and thrown away —
/// nothing of it is stored.
///
/// `!3d…!4d…` is the place itself and is preferred; `@lat,lng` is only where
/// the viewport was centred when the link was copied, which can sit well off
/// the pin. `query=` is the Maps URLs API form (`…/maps/search/?api=1&…`).
///
/// A short link can land on Google's cookie-consent page instead of the map
/// (`consent.google.<tld>/…?continue=<the Maps link>`); the Maps link it
/// carries is read in its place.
GoogleMapsPlace? parseGoogleMapsLink(String link) {
  final uri = Uri.tryParse(link.trim());
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  if (host.startsWith('consent.') &&
      _googleHost.hasMatch(host.substring('consent.'.length))) {
    final target = uri.queryParameters['continue'];
    return target == null || target.contains('consent.')
        ? null
        : parseGoogleMapsLink(target);
  }
  if (!_isGoogleMapsLink(uri)) return null;

  final match =
      _placePattern.firstMatch(link) ??
      _viewportPattern.firstMatch(link) ??
      _pairPattern.firstMatch(uri.queryParameters['q'] ?? '') ??
      _pairPattern.firstMatch(uri.queryParameters['query'] ?? '') ??
      _pairPattern.firstMatch(uri.queryParameters['ll'] ?? '');
  if (match == null) return null;
  final latitude = double.parse(match.group(1)!);
  final longitude = double.parse(match.group(2)!);
  if (latitude.abs() > 90 || longitude.abs() > 180) return null;

  final segments = uri.pathSegments;
  final place = segments.indexOf('place');
  final name = place >= 0 && place + 1 < segments.length
      ? segments[place + 1].replaceAll('+', ' ').trim()
      : '';
  return (
    latitude: latitude,
    longitude: longitude,
    name: name.isEmpty ? null : name,
  );
}
