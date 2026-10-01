import 'dart:ui';

import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../grid/grid_tile_positioner.dart';
import '../grid/slippy_map_translator.dart';
import '../grid/tile_zoom.dart';
import '../style/style.dart';

class TileRenderer {
  final Theme theme;
  final TextPainterProvider textPainterProvider;
  final TileState tileState;
  final TileTranslation translation;
  final Tileset tileset;
  final RasterTileset? rasterTileset;
  final Image? spriteImage;
  final SpriteStyle? sprites;

  /// VOYAGER PATCH: the source tile's label layout and where in it this tile
  /// sits — see [Renderer.render].
  final LabelLayout? labels;
  final Offset labelsOrigin;

  TileRenderer(
      {required this.theme,
      required this.textPainterProvider,
      required this.tileState,
      required this.translation,
      required this.tileset,
      required this.rasterTileset,
      required this.spriteImage,
      required this.sprites,
      this.labels,
      this.labelsOrigin = Offset.zero});

  void render(Canvas canvas, Size size) {
    for (final _ in renderInSteps(canvas, size)) {}
  }

  /// VOYAGER PATCH: [render] a piece at a time — see
  /// [Renderer.renderInSteps].
  Iterable<void> renderInSteps(Canvas canvas, Size size) {
    final tileSizer = GridTileSizer(translation, tileState.zoomScale, size);
    canvas.clipRect(Offset.zero & size);
    tileSizer.apply(canvas);

    final tileClip = tileSizer.tileClip(size, tileSizer.effectiveScale);
    return Renderer(theme: theme, painterProvider: textPainterProvider)
        .renderInSteps(
        canvas,
        TileSource(
            tileset: tileset,
            rasterTileset: (rasterTileset ?? const RasterTileset(tiles: {})),
            spriteAtlas: spriteImage,
            spriteIndex: sprites?.index),
        clip: tileClip,
        zoomScaleFactor: tileSizer.effectiveScale,
        zoom: tileState.zoomDetail,
        rotation: tileState.rotation,
        labels: labels,
        labelsOrigin: labelsOrigin);
  }
}
