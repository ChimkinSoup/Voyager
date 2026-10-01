// The vendored vector_tile_renderer lays the labels of an overzoomed source
// tile out once, for every tile cut from it to draw its part of (VOYAGER
// PATCH in label_layout.dart). These pin that a name across the edge between
// two such tiles is drawn whole by the pair, that one across the source
// tile's own edge is dropped, and that a street's name repeats along it.

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:vector_tile_renderer/src/model/geometry_model.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

// Four drawn tiles span the source tile: 1024 layout pixels to 4096 units.
const _scale = 4.0;
const _zoom = 16.0;

final _theme = ThemeReader().read({
  'version': 8,
  'id': 'test',
  'sources': {
    'default': {'type': 'vector'},
  },
  'layers': [
    for (final (id, layer, layout) in [
      ('streets', 'street', {'symbol-placement': 'line', 'symbol-spacing': 350}),
      ('food', 'poi', <String, Object>{}),
    ])
      {
        'id': id,
        'type': 'symbol',
        'source': 'default',
        'source-layer': layer,
        'layout': {'text-field': '{name}', 'text-size': 10, ...layout},
        'paint': {'text-color': 'rgba(0,0,0,1)'},
      },
  ],
});

/// A layout of one feature named `Name` — 40 x 10 in the test font: a point
/// at [point], or a line through [line], in layout pixels.
LabelLayout _layout({Offset? point, List<Offset>? line}) {
  Point<double> units(Offset pixels) => Point(pixels.dx * 4, pixels.dy * 4);
  return LabelLayout(
    theme: _theme,
    zoom: _zoom,
    scale: _scale,
    sources: {
      'default': TileData(
        layers: [
          TileDataLayer(
            name: point != null ? 'poi' : 'street',
            extent: 4096,
            features: [
              TileDataFeature(
                type: point != null
                    ? TileFeatureType.point
                    : TileFeatureType.linestring,
                properties: {'name': 'Name'},
                geometry: null,
                points: point == null ? null : [units(point)],
                lines: line == null
                    ? null
                    : [TileLine(line.map(units).toList())],
              ),
            ],
          ),
        ],
      ),
    },
  );
}

/// The top row of the layout, 1024 x 256, as the four tiles cut from it draw
/// it, side by side.
Future<ByteData> _tiles(LabelLayout layout, {double top = 0}) =>
    _pixels((canvas) {
      for (var column = 0; column < 4; column++) {
        canvas.save();
        canvas.translate(column * 256, 0);
        Renderer(theme: _theme).render(
          canvas,
          TileSource(tileset: Tileset({})),
          zoomScaleFactor: 1,
          zoom: _zoom,
          rotation: 0,
          labels: layout,
          labelsOrigin: Offset(column * 256, top),
        );
        canvas.restore();
      }
    });

/// The same row drawn in one piece.
Future<ByteData> _whole(LabelLayout layout, {double top = 0}) => _pixels(
  (canvas) => layout.paint(canvas, Rect.fromLTWH(0, top, 1024, 256)),
);

Future<ByteData> _pixels(void Function(Canvas canvas) draw) async {
  final recorder = PictureRecorder();
  draw(Canvas(recorder));
  final image = await recorder.endRecording().toImage(1024, 256);
  return (await image.toByteData())!;
}

bool _inked(ByteData pixels, int x, int y) =>
    pixels.getUint8((y * 1024 + x) * 4 + 3) > 0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a name across the edge between two tiles is drawn by both', () async {
    // Centred on the edge between the first tile and the second.
    final layout = _layout(point: const Offset(256, 100));
    final tiles = await _tiles(layout);

    expect(_inked(tiles, 246, 100), isTrue);
    expect(_inked(tiles, 266, 100), isTrue);
    expect(
      tiles.buffer.asUint8List(),
      (await _whole(layout)).buffer.asUint8List(),
    );
  });

  test('a name across the source tile\'s own edge is dropped', () async {
    final tiles = await _tiles(_layout(point: const Offset(1010, 100)));

    expect(tiles.buffer.asUint8List().every((byte) => byte == 0), isTrue);
  });

  test('a street\'s name repeats along it, across tile edges', () async {
    // 1024 long at a spacing of 350: twice, at 256 and 768 — each on an edge.
    final layout = _layout(line: const [Offset(0, 356), Offset(1024, 356)]);
    final tiles = await _tiles(layout, top: 256);

    for (final x in [246, 266, 758, 778]) {
      expect(_inked(tiles, x, 100), isTrue, reason: 'at $x');
    }
    expect(_inked(tiles, 512, 100), isFalse);
    expect(
      tiles.buffer.asUint8List(),
      (await _whole(layout, top: 256)).buffer.asUint8List(),
    );
  });

  test('a layer marked overlay is placed but handed over, not drawn', () async {
    final theme = ThemeReader().read({
      'version': 8,
      'id': 'overlay',
      'sources': {
        'default': {'type': 'vector'},
      },
      'layers': [
        {
          'id': 'food',
          'type': 'symbol',
          'source': 'default',
          'source-layer': 'poi',
          'metadata': {'overlay': true},
          'layout': {'text-field': '{name}', 'text-size': 10},
          'paint': {'text-color': 'rgba(0,0,0,1)'},
        },
      ],
    });
    final layout = LabelLayout(
      theme: theme,
      zoom: _zoom,
      scale: _scale,
      sources: {
        'default': TileData(
          layers: [
            TileDataLayer(
              name: 'poi',
              extent: 4096,
              features: [
                TileDataFeature(
                  type: TileFeatureType.point,
                  properties: {'name': 'Name'},
                  geometry: null,
                  points: [const Point(1200, 400)],
                  lines: null,
                ),
              ],
            ),
          ],
        ),
      },
    );

    final label = layout.overlaid.single;
    expect(label.text, 'Name');
    expect(label.at, const Offset(300, 100));
    expect(label.bounds.contains(const Offset(315, 102)), isTrue);
    expect(label.bounds.contains(const Offset(300, 130)), isFalse);
    expect(
      (await _whole(layout)).buffer.asUint8List().every((byte) => byte == 0),
      isTrue,
    );
    expect(_layout(point: const Offset(300, 100)).overlaid, isEmpty);
  });
}
