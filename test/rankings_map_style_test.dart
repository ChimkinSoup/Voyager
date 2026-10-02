// The map's base style is a monochrome ramp laid between the theme's surface
// and its ink. These pin where the ends of the ramp land, and that the bundled
// style still reads as one the renderer accepts.

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;
import 'package:voyager/features/rankings/rankings_map_style.dart';

const _cream = Color(0xFFFAF7F0);
const _slate = Color(0xFF2B303B);
const _blue = Color(0xFF7C9EFF);

Map<String, dynamic> _base(List<Map<String, dynamic>> layers) => {
  'version': 8,
  'sources': {
    'default': {'type': 'vector'},
  },
  'layers': layers,
};

Map<String, dynamic> _styled(
  List<Map<String, dynamic>> layers, {
  Color land = _cream,
  Color ink = _slate,
}) => voyagerMapStyle(
  _base(layers),
  land: land,
  ink: ink,
  accent: _blue,
  fontFamily: 'IosevkaAile',
);

Object? _paint(Map<String, dynamic> style, int layer, String key) =>
    ((style['layers'] as List)[layer] as Map)['paint'][key];

void main() {
  test("positron's paper becomes the theme's land", () {
    final style = _styled([
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': 'rgba(242,243,240,1)'},
      },
    ]);
    expect(_paint(style, 0, 'background-color'), 'rgba(250,247,240,1)');
  });

  test('black becomes the ink, and alpha is kept', () {
    final style = _styled([
      {
        'id': 'road',
        'type': 'line',
        'paint': {'line-color': 'rgba(0,0,0,0.5)'},
      },
    ]);
    expect(_paint(style, 0, 'line-color'), 'rgba(43,48,59,0.5)');
  });

  test('colours inside zoom stops are redrawn too', () {
    final style = _styled([
      {
        'id': 'road',
        'type': 'line',
        'paint': {
          'line-color': {
            'base': 1,
            'stops': [
              [5, 'rgba(242,243,240,1)'],
              [6, 'rgba(0,0,0,1)'],
            ],
          },
        },
      },
    ]);
    final stops = (_paint(style, 0, 'line-color') as Map)['stops'] as List;
    expect(stops[0], [5, 'rgba(250,247,240,1)']);
    expect(stops[1], [6, 'rgba(43,48,59,1)']);
  });

  test('a shade lighter than paper goes whiter on light, toward ink on '
      'dark', () {
    final road = [
      {
        'id': 'road',
        'type': 'line',
        'paint': {'line-color': 'rgba(255,255,255,1)'},
      },
    ];
    // Light: past the cream, on the side away from the ink.
    expect(_paint(_styled(road), 0, 'line-color'), 'rgba(255,255,249,1)');
    // Dark: a road still reads lighter than its ground.
    const night = Color(0xFF242428);
    const paleInk = Color(0xFFE6E6EA);
    final dark = _paint(
      _styled(road, land: night, ink: paleInk),
      0,
      'line-color',
    );
    final red = int.parse(
      RegExp(r'rgba\((\d+)').firstMatch(dark! as String)![1]!,
    );
    expect(red, greaterThan(0x24));
  });

  test('water leans toward the accent; land of the same shade does not', () {
    Map<String, dynamic> layer(String id) => {
      'id': id,
      'type': 'fill',
      'paint': {'fill-color': 'rgba(194,200,202,1)'},
    };
    final style = _styled([layer('water'), layer('park')]);
    expect(
      _paint(style, 0, 'fill-color'),
      isNot(_paint(style, 1, 'fill-color')),
    );
  });

  test('major roads lean toward the accent; minor roads and labels do not', () {
    Map<String, dynamic> layer(String id) => {
      'id': id,
      'type': 'line',
      'paint': {'line-color': 'rgba(213,213,213,1)'},
    };
    final style = _styled([
      layer('highway_minor'),
      layer('highway_major_casing'),
      layer('highway_motorway_inner'),
      layer('tunnel_motorway_casing'),
      layer('highway_name_motorway'),
    ]);
    final neutral = _paint(style, 0, 'line-color');
    for (final major in [1, 2, 3]) {
      expect(_paint(style, major, 'line-color'), isNot(neutral));
    }
    expect(_paint(style, 4, 'line-color'), neutral);
  });

  test('labels are set in the app font, a step larger, in the accent taken '
      'off the land far enough to need no halo', () {
    Map<String, dynamic> label(Color land, Color ink) =>
        (_styled(
                      [
                        {
                          'id': 'place_city',
                          'type': 'symbol',
                          'layout': {'text-field': '{name}', 'text-size': 12},
                          'paint': {
                            'text-color': 'rgba(117,129,145,1)',
                            'text-halo-color': 'rgba(255,255,255,1)',
                            'text-halo-width': 1,
                            'text-halo-blur': 1,
                          },
                        },
                      ],
                      land: land,
                      ink: ink,
                    )['layers']
                    as List)
                .single
            as Map<String, dynamic>;
    Color color(Map<String, dynamic> layer) {
      final m = RegExp(
        r'rgba\((\d+),(\d+),(\d+),1\)',
      ).firstMatch(layer['paint']['text-color'] as String)!;
      return Color.fromARGB(
        255,
        int.parse(m[1]!),
        int.parse(m[2]!),
        int.parse(m[3]!),
      );
    }

    double contrast(Color a, Color b) {
      final (la, lb) = (a.computeLuminance(), b.computeLuminance());
      return (la > lb ? la + 0.05 : lb + 0.05) /
          (la > lb ? lb + 0.05 : la + 0.05);
    }

    const night = Color(0xFF242428);
    for (final (land, ink) in [(_cream, _slate), (night, _cream)]) {
      final layer = label(land, ink);
      expect(layer['layout']['text-font'], ['IosevkaAile']);
      expect(layer['layout']['text-size'], 14);
      expect(
        (layer['paint'] as Map).keys.where((k) => k.startsWith('text-halo')),
        isEmpty,
      );
      final text = color(layer);
      expect(contrast(text, land), greaterThanOrEqualTo(7));
      // Still the accent's blue: deeper on light land, paler on dark.
      expect(text.b, greaterThan(text.r));
    }
    final onLight = color(label(_cream, _slate));
    final onDark = color(label(night, _cream));
    expect(onLight.computeLuminance(), lessThan(_blue.computeLuminance()));
    expect(onDark.computeLuminance(), greaterThan(_blue.computeLuminance()));
  });

  test('food and drink labels keep a grey off the ramp, not the accent', () {
    final style = _styled([
      {
        'id': 'poi_food',
        'type': 'symbol',
        'layout': {'text-field': '{name:latin}', 'text-size': 10},
        'paint': {'text-color': 'rgba(110,110,110,1)'},
      },
      {
        'id': 'grey',
        'type': 'line',
        'paint': {'line-color': 'rgba(110,110,110,1)'},
      },
    ]);
    final poi = (style['layers'] as List).first as Map<String, dynamic>;
    expect(poi['layout']['text-font'], ['IosevkaAile']);
    expect(poi['layout']['text-size'], 12);
    expect(_paint(style, 0, 'text-color'), _paint(style, 1, 'line-color'));
    // Placed best known first, where they crowd.
    expect(poi['layout']['symbol-sort-key'], ['get', 'rank']);
  });

  test('every label is left out of the tiles, for the map to draw', () {
    final style = _styled([
      {
        'id': 'place_city',
        'type': 'symbol',
        'layout': {'text-field': '{name}', 'text-size': 10},
        'paint': {'text-color': 'rgba(0,0,0,1)'},
      },
      {
        'id': 'road',
        'type': 'line',
        'paint': {'line-color': 'rgba(0,0,0,1)'},
      },
    ]);
    final [label, road] = (style['layers'] as List).cast<Map>();
    expect(label['metadata'], {'overlay': true});
    expect(road['metadata'], isNull);
  });

  test('each palette gets its own style id, so cached tiles never cross', () {
    final light = _styled(const []);
    final dark = _styled(
      const [],
      land: const Color(0xFF242428),
      ink: const Color(0xFFE6E6EA),
    );
    expect(light['id'], isNot(dark['id']));
    expect(light['id'], _styled(const [])['id']);
  });

  test('the bundled style reads into a theme with every layer', () {
    final base =
        jsonDecode(File('assets/rankings_map_style.json').readAsStringSync())
            as Map<String, dynamic>;
    // No key, sprite or glyph endpoint travels in the asset.
    expect(jsonEncode(base), isNot(contains('apiKey')));
    final theme = vtr.ThemeReader().read(
      voyagerMapStyle(
        base,
        land: _cream,
        ink: _slate,
        accent: _blue,
        fontFamily: 'IosevkaAile',
      ),
    );
    expect(theme.layers, hasLength((base['layers'] as List).length));
    expect(theme.tileSources, {'default'});
  });
}
