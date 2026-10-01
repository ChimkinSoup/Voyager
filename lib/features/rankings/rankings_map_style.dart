import 'dart:math';
import 'dart:ui';

/// The map's base style, redrawn in the app's own colours and font.
///
/// [base] is `assets/rankings_map_style.json`: the layers of Geoapify's
/// `positron` style, which is monochrome — every colour in it is a shade
/// between its paper and its ink. That makes it a ramp rather than a palette,
/// and a ramp can be laid between any two colours. Each shade is placed the
/// same distance from [land] toward [ink] as it sat from positron's paper
/// toward black, so the light theme and the dark one are the same style read
/// in opposite directions. Water leans toward [accent], which is what tells
/// it from land once both are neutral, and major roads lean further, so the
/// routes through a place carry the app's colour.
///
/// Every label is set in [fontFamily], a little larger than positron sets it,
/// and without positron's halo: its colour is [accent] taken far enough from
/// [land] to read on its own — see [_labelInk]. Places to eat and drink, which
/// positron leaves out, are the exception: they keep a grey off the ramp, so
/// they sit behind the street and place names and the rankings' own markers.
/// They are also marked `overlay`, which keeps them out of the tiles: the map
/// draws them itself — see `RankingsTileLayer`.
Map<String, dynamic> voyagerMapStyle(
  Map<String, dynamic> base, {
  required Color land,
  required Color ink,
  required Color accent,
  required String fontFamily,
}) => {
  ...base,
  // Rendered tiles are cached by the style's id, so each palette needs its
  // own or a switch between light and dark would show the other's tiles.
  // The `v8` changes whenever the same palette is drawn differently — v2 the
  // vendored renderer's label-collision fix, v3 accented major roads, v4
  // accented labels and the renderer's tile-edge fix, v5 haloless labels in
  // a deeper accent, v6 food and drink labels, v7 building seams closed, v8
  // labels drawn across tile edges, v9 food and drink labels left out of the
  // tiles — so tiles cached under the old drawing are not reused.
  'id': 'voyager-v9-${_hex(land)}-${_hex(ink)}-${_hex(accent)}',
  'layers': [
    for (final layer in base['layers'] as List)
      _layer(
        Map<String, dynamic>.from(layer as Map),
        land: land,
        ink: ink,
        accent: accent,
        fontFamily: fontFamily,
      ),
  ],
};

Map<String, dynamic> _layer(
  Map<String, dynamic> layer, {
  required Color land,
  required Color ink,
  required Color accent,
  required String fontFamily,
}) {
  final id = layer['id'] as String;
  final tint = id.startsWith('water')
      ? _waterTint
      : _majorRoad.hasMatch(id)
      ? _roadTint
      : null;
  Object? recolor(Object? value) => switch (value) {
    final Map map => {
      for (final entry in map.entries) entry.key: recolor(entry.value),
    },
    final List list => [for (final item in list) recolor(item)],
    final String text => _recolored(
      text,
      land,
      ink,
      tint: tint == null ? null : (color: accent, amount: tint),
    ),
    _ => value,
  };
  final isLabel = layer['type'] == 'symbol';
  final isPoi = id.startsWith('poi');
  final layout = layer['layout'] as Map?;
  return {
    ...layer,
    if (isPoi) 'metadata': {'overlay': true},
    if (layer['paint'] != null)
      'paint': {
        for (final MapEntry(:key, :value)
            in (recolor(layer['paint'])! as Map).entries)
          if (!isLabel || !(key as String).startsWith('text-halo')) key: value,
        if (isLabel && !isPoi) 'text-color': _css(_labelInk(accent, land), 1),
      },
    if (isLabel)
      'layout': {
        ...?layout,
        'text-font': [fontFamily],
        if (layout?['text-size'] != null)
          'text-size': _enlarged(layout!['text-size']),
      },
  };
}

/// [size] — a number, or zoom stops of numbers — a step larger, so labels in
/// the accent read at a glance.
Object? _enlarged(Object? size) => switch (size) {
  final num points => points + _labelGrowth,
  final Map map => {
    ...map,
    if (map['stops'] case final List stops)
      'stops': [
        for (final stop in stops) [(stop as List)[0], _enlarged(stop[1])],
      ],
  },
  _ => size,
};

/// [accent] with its hue held, taken away from [land] — toward black on a
/// light map, white on a dark one — until it clears [_labelContrast] against
/// it. The move the app makes for a label on an accent fill (`onColorLabel`),
/// pointed at the map's ground instead, so a label stands off both the land
/// and the accented roads it crosses without a halo.
Color _labelInk(Color accent, Color land) {
  final away = land.computeLuminance() > 0.5
      ? const Color(0xFF000000)
      : const Color(0xFFFFFFFF);
  for (var step = 0; step < 20; step++) {
    final ink = Color.lerp(accent, away, step / 20)!;
    if (_contrast(ink, land) >= _labelContrast) return ink;
  }
  return away;
}

double _contrast(Color a, Color b) {
  final (la, lb) = (a.computeLuminance(), b.computeLuminance());
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}

/// How far a label's colour stands off the land: WCAG's enhanced floor for
/// text. The minimum, 4.5, left the accent itself on a dark map, faint where
/// a name runs along an accented road.
const _labelContrast = 7.0;

/// Points added to every label's size over positron's.
const _labelGrowth = 2;

String _css(Color color, Object alpha) {
  int byte(double component) => (component * 255).round();
  return 'rgba(${byte(color.r)},${byte(color.g)},${byte(color.b)},$alpha)';
}

String _hex(Color color) => color.toARGB32().toRadixString(16);

final _rgba = RegExp(r'^rgba\((\d+),(\d+),(\d+),([\d.]+)\)$');

/// Positron's paper, `rgb(242,243,240)`, as a luminance. The zero of the ramp.
const _paperLuminance = (0.299 * 242 + 0.587 * 243 + 0.114 * 240) / 255;

/// How far the accent pulls a water shade off the neutral ramp.
const _waterTint = 0.18;

/// How far the accent pulls a major road's shades, casing and fill alike.
const _roadTint = 0.3;

/// Motorways, trunks and primary to tertiary roads, on the ground, bridged
/// or tunnelled — not their name labels.
final _majorRoad = RegExp(r'^(highway_(major|motorway)|tunnel_motorway)');

String _recolored(
  String value,
  Color land,
  Color ink, {
  required ({Color color, double amount})? tint,
}) {
  final match = _rgba.firstMatch(value);
  if (match == null) return value;
  String rgba(Color color) => _css(color, match.group(4)!);
  final luminance =
      (0.299 * int.parse(match.group(1)!) +
          0.587 * int.parse(match.group(2)!) +
          0.114 * int.parse(match.group(3)!)) /
      255;
  // Negative for the few shades lighter than the paper — road fills. On a
  // light theme those sit just past [land], whiter than the page. A dark
  // theme has nowhere darker worth going, so there they step toward [ink]
  // like everything else and a road still reads lighter than its ground.
  final raw = (_paperLuminance - luminance) / _paperLuminance;
  final t = ink.computeLuminance() > land.computeLuminance() ? raw.abs() : raw;
  double channel(double from, double to) =>
      (from + (to - from) * t).clamp(0, 1);
  var color = Color.from(
    alpha: 1,
    red: channel(land.r, ink.r),
    green: channel(land.g, ink.g),
    blue: channel(land.b, ink.b),
  );
  if (tint != null) color = Color.lerp(color, tint.color, tint.amount)!;
  return rgba(color);
}
