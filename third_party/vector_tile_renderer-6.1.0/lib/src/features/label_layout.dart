import 'dart:math';
import 'dart:ui';

import 'package:flutter/painting.dart';

import '../constants.dart';
import '../context.dart';
import '../extensions.dart';
import '../logger.dart';
import '../model/tile_data_model.dart';
import '../model/tile_model.dart';
import '../optimizations.dart';
import '../symbols/symbols.dart';
import '../symbols/text_painter.dart';
import '../themes/expression/expression.dart';
import '../themes/style.dart';
import '../themes/theme.dart';
import '../themes/theme_layers.dart';
import '../tile_source.dart';
import '../tileset.dart';
import 'feature_renderer.dart';
import 'label_space.dart';
import 'symbol_line_renderer.dart';
import 'symbol_rotation.dart';
import 'text_abbreviator.dart';
import 'text_renderer.dart';
import 'text_wrapper.dart';

/// VOYAGER PATCH: the labels of a whole source tile, placed once for a zoom
/// past the source's last, for every tile cut from it to draw its part of.
///
/// Upstream lays labels out for each drawn tile on its own and drops one that
/// does not fit inside it whole, so a name across a tile's edge is missing,
/// and which names those are changes with the zoom, as the edges move. Tiles
/// cut from one source tile that share its layout agree on every label, so a
/// name is drawn across their edges, each tile painting its side of it. Only
/// a name across the source tile's own edge is still dropped: the tile beyond
/// it is laid out apart.
///
/// A name along a line repeats at the layer's `symbol-spacing`, where
/// upstream drew it once a tile, and only on a stretch long enough to hold
/// it. Icons are not laid out.
///
/// And the labels of a theme layer whose metadata sets `overlay` are placed
/// with the rest but left out of [paint]: they are handed over in [overlaid]
/// for the caller to draw over the tiles itself, which can then leave some
/// out, draw one differently and tell which one a point is on.
class LabelLayout {
  final List<_Label> _labels;

  /// The labels [paint] leaves to the caller, in layout pixels.
  final List<PlacedLabel> overlaid;

  LabelLayout._(this._labels)
    : overlaid = [
        for (final label in _labels)
          if (label.overlaid)
            (
              text: label.text,
              at: label.at,
              painter: label.painter,
              corner: label.at + label.translation,
              bounds: label.bounds,
            ),
      ];

  /// [sources] is the source tile's data by theme source, [zoom] the zoom
  /// drawn at and [scale] how many drawn tiles span the source tile.
  factory LabelLayout({
    required Theme theme,
    required Map<String, TileData> sources,
    required double zoom,
    required double scale,
  }) {
    final layers = theme
        .atZoom(zoom)
        .layers
        .whereType<DefaultLayer>()
        .where(
          (layer) =>
              layer.type == ThemeLayerType.symbol &&
              layer.style.symbolLayout?.text != null,
        )
        .toList(growable: false);
    // Only the layers that carry labels are decoded: the rest of a source
    // tile is most of it.
    final names = layers
        .map((layer) => layer.selector.layerSelector.layerNames())
        .flatSet();
    final tileset = Tileset({
      for (final MapEntry(key: source, value: data) in sources.entries)
        source: TileData(
          layers: data.layers
              .where((layer) => names.contains(layer.name))
              .toList(growable: false),
        ).toTile(),
    });
    final side = tileSize * scale;
    final bounds = Offset.zero & Size.square(side);
    const logger = Logger.noop();
    // For the text helpers, which read a context's scale and its painters.
    // Nothing is drawn through it.
    final context = Context(
      logger: logger,
      canvas: Canvas(PictureRecorder()),
      featureRenderer: FeatureDispatcher(logger),
      tileSource: TileSource(tileset: tileset),
      zoomScaleFactor: 1.0,
      zoom: zoom,
      rotation: 0.0,
      tileSpace: bounds,
      tileClip: bounds,
      optimizations: Optimizations(skipInBoundsChecks: true),
      textPainterProvider: _SharedPainters(),
    );
    final space = LabelSpace(bounds, zoomScaleFactor: 1.0, repeats: true);
    final labels = <_Label>[];

    bool place(
      TextRenderer renderer,
      Offset at,
      double rotation,
      String name,
      bool overlaid,
    ) {
      final quad = SymbolLineRenderer.textSpace(
        at & renderer.size,
        renderer.translation,
        Tangent.fromAngle(at, 0),
        rotation,
        space.margin,
      );
      final text = renderer.symbol.text;
      if (!space.canOccupyQuad(text, quad)) return false;
      space.occupyQuad(text, quad);
      labels.add(
        _Label(
          renderer.painter!,
          at,
          renderer.translation ?? Offset.zero,
          rotation,
          quadBounds(quad),
          name,
          overlaid,
        ),
      );
      return true;
    }

    for (final layer in layers) {
      final style = layer.style;
      final layout = style.symbolLayout!;
      final overlaid = layer.metadata['overlay'] == true;
      // Where each name along a line has been put, to keep its repeats apart
      // across the features a street is split into.
      final placed = <String, List<Offset>>{};
      for (final resolved in tileset.resolver.resolveFeatures(
        layer.selector,
        zoom.truncate(),
      )) {
        final feature = resolved.feature;
        final toPixels = side / resolved.layer.extent;
        final evaluation = EvaluationContext(
          () => feature.properties,
          feature.type,
          logger,
          zoom: zoom,
          zoomScaleFactor: 1.0,
          hasImage: (_) => false,
        );
        final text = layout.text!.text.evaluate(evaluation);
        if (text == null || text.isEmpty) continue;

        if (feature.type == TileFeatureType.point) {
          final renderer = _renderer(
            context,
            evaluation,
            style,
            TextWrapper(layout.text!).wrap(evaluation, text),
          );
          if (renderer == null) continue;
          for (final point in feature.points) {
            place(renderer, point * toPixels, 0.0, text, overlaid);
          }
        } else if (feature.type == TileFeatureType.linestring) {
          final name = TextAbbreviator().abbreviate(text);
          final renderer = _renderer(context, evaluation, style, [name]);
          if (renderer == null) continue;
          final upright =
              layout.textRotationAlignment(
                evaluation,
                layoutPlacement: LayoutPlacement.line,
              ) ==
              RotationAlignment.viewport;
          final spacing = layout.spacing?.evaluate(evaluation) ?? 250.0;
          final others = placed.putIfAbsent(name, () => []);
          for (final path in feature.paths) {
            for (final metric in path.pathMetrics) {
              final length = metric.length * toPixels;
              if (length < renderer.size.width) continue;
              final count = max(1, length ~/ spacing);
              for (var i = 0; i < count; i++) {
                final tangent = metric.getTangentForOffset(
                  metric.length * (i + 0.5) / count,
                );
                if (tangent == null) continue;
                final at = tangent.position * toPixels;
                if (others.any((other) => (other - at).distance < spacing)) {
                  continue;
                }
                final rotation = upright
                    ? 0.0
                    : SymbolLineRenderer.drawnAngle(tangent.angle);
                if (place(renderer, at, rotation, name, overlaid)) {
                  others.add(at);
                }
              }
            }
          }
        }
      }
    }
    return LabelLayout._(labels);
  }

  /// Paints the labels that reach into [area] of the layout, on a canvas
  /// whose origin is [area]'s corner and which is clipped to it.
  void paint(Canvas canvas, Rect area) {
    canvas.save();
    canvas.translate(-area.left, -area.top);
    for (final label in _labels) {
      if (label.overlaid || !label.bounds.overlaps(area)) continue;
      canvas.save();
      if (label.rotation != 0.0) {
        canvas.translate(label.at.dx, label.at.dy);
        canvas.rotate(-label.rotation);
        canvas.translate(-label.at.dx, -label.at.dy);
      }
      label.painter.paint(canvas, label.at + label.translation);
      canvas.restore();
    }
    canvas.restore();
  }
}

/// A label of a [LabelLayout]: its [text] on one line, the point it is
/// anchored [at] and the box it was given, margin included, as [bounds].
/// [painter] painted at [corner] draws it, for a label that is not turned.
typedef PlacedLabel = ({
  String text,
  Offset at,
  TextPainter painter,
  Offset corner,
  Rect bounds,
});

/// The source layers [theme]'s labels are read from, at any zoom: all of a
/// source tile that a [LabelLayout] needs.
Set<String> labelSourceLayers(Theme theme) => theme.layers
    .whereType<DefaultLayer>()
    .where(
      (layer) =>
          layer.type == ThemeLayerType.symbol &&
          layer.style.symbolLayout?.text != null,
    )
    .map((layer) => layer.selector.layerSelector.layerNames())
    .flatSet();

TextRenderer? _renderer(
  Context context,
  EvaluationContext evaluation,
  Style style,
  List<String> lines,
) {
  final text = TextApproximation(context, evaluation, style, lines);
  if (text.styledSymbol == null) return null;
  return text.renderer.canPaint ? text.renderer : null;
}

/// One painter for each distinct text: a street's name is laid out once
/// however often it repeats.
class _SharedPainters extends TextPainterProvider {
  final _painters = <StyledSymbol, TextPainter>{};

  @override
  TextPainter provide(StyledSymbol symbol) => _painters.putIfAbsent(
    symbol,
    () => const DefaultTextPainterProvider().provide(symbol),
  );
}

class _Label {
  final TextPainter painter;

  /// The point the label is anchored to and turned about, in layout pixels.
  final Offset at;

  /// From [at] to the text's corner, before turning.
  final Offset translation;
  final double rotation;

  /// What the label covers, margin included.
  final Rect bounds;

  /// The text unwrapped.
  final String text;

  /// Whether it is left to the caller to draw — see [LabelLayout.overlaid].
  final bool overlaid;

  _Label(
    this.painter,
    this.at,
    this.translation,
    this.rotation,
    this.bounds,
    this.text,
    this.overlaid,
  );
}
