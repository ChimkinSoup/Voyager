import 'dart:ui';

import 'constants.dart';
import 'context.dart';
import 'features/feature_renderer.dart';
import 'features/label_layout.dart';
import 'logger.dart';
import 'optimizations.dart';
import 'profiling.dart';
import 'symbols/text_painter.dart';
import 'themes/theme.dart';
import 'tile_source.dart';

class Renderer {
  final Theme theme;
  final Logger logger;
  final FeatureDispatcher featureRenderer;
  final TextPainterProvider painterProvider;
  Renderer({
    required this.theme,
    this.painterProvider = const DefaultTextPainterProvider(),
    Logger? logger,
  }) : logger = logger ?? const Logger.noop(),
       featureRenderer = FeatureDispatcher(logger ?? const Logger.noop());

  /// renders the given tile to the canvas
  ///
  /// [zoomScaleFactor] the 1-dimensional scale at which the tile is being
  ///        rendered. If the tile is being rendered at twice it's normal size
  ///        along the x-axis, the zoomScaleFactor would be 2. 1.0 indicates that
  ///        no scaling is being applied.
  /// [zoom] the current zoom level, which is used to filter theme layers
  ///        via `minzoom` and `maxzoom`. Value must be >= 0 and <= 24
  /// [tile] the tile to render
  /// [clip] the optional clip to constrain tile rendering, used to limit drawing
  ///        so that a portion of a tile can be rendered to a canvas
  /// [labels] VOYAGER PATCH: the layout of the source tile this tile is cut
  ///        from. With it the theme's symbol layers are not laid out for this
  ///        tile; its part of [labels], the tile-sized square at
  ///        [labelsOrigin], is painted over the other layers instead.
  void render(
    Canvas canvas,
    TileSource tile, {
    Rect? clip,
    required double zoomScaleFactor,
    required double zoom,
    required double rotation,
    LabelLayout? labels,
    Offset labelsOrigin = Offset.zero,
  }) {
    profileSync('Render', () {
      for (final _ in renderInSteps(
        canvas,
        tile,
        clip: clip,
        zoomScaleFactor: zoomScaleFactor,
        zoom: zoom,
        rotation: rotation,
        labels: labels,
        labelsOrigin: labelsOrigin,
      )) {}
    });
  }

  /// VOYAGER PATCH: [render] a piece at a time. Nothing is drawn until the
  /// result is iterated, and each step of it draws a few hundred features
  /// more, so a caller can stop between steps and go on in a later frame: a
  /// whole tile at the source's own zoom is tens of milliseconds of drawing.
  Iterable<void> renderInSteps(
    Canvas canvas,
    TileSource tile, {
    Rect? clip,
    required double zoomScaleFactor,
    required double zoom,
    required double rotation,
    LabelLayout? labels,
    Offset labelsOrigin = Offset.zero,
  }) sync* {
    final tileSpace = Rect.fromLTWH(
      0,
      0,
      tileSize.toDouble(),
      tileSize.toDouble(),
    );
    canvas.save();
    canvas.clipRect(tileSpace);
    final tileClip = clip ?? tileSpace;
    final optimizations = Optimizations(
      skipInBoundsChecks:
          clip == null ||
          (tileClip.width - tileSpace.width).abs() < (tileSpace.width / 2),
    );
    final context = Context(
      logger: logger,
      canvas: canvas,
      featureRenderer: featureRenderer,
      tileSource: tile,
      zoomScaleFactor: zoomScaleFactor,
      zoom: zoom,
      rotation: rotation,
      tileSpace: tileSpace,
      tileClip: tileClip,
      optimizations: optimizations,
      textPainterProvider: painterProvider,
    );
    final effectiveTheme = theme.atZoom(zoom);
    for (final themeLayer in effectiveTheme.layers) {
      if (labels != null && themeLayer.type == ThemeLayerType.symbol) {
        continue;
      }
      logger.log(() => 'rendering theme layer ${themeLayer.id}');
      yield* themeLayer.renderInSteps(context);
    }
    labels?.paint(canvas, labelsOrigin & tileSpace.size);
    canvas.restore();
  }
}
