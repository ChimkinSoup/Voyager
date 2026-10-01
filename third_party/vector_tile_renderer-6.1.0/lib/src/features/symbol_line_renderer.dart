import 'dart:math';
import 'dart:ui';

import '../../vector_tile_renderer.dart';
import '../context.dart';
import '../themes/expression/expression.dart';
import '../themes/style.dart';
import 'extensions.dart';
import 'feature_renderer.dart';
import 'symbol_layout_extension.dart';
import 'symbol_rotation.dart';
import 'text_abbreviator.dart';
import 'text_renderer.dart';

class SymbolLineRenderer extends FeatureRenderer {
  final Logger logger;

  SymbolLineRenderer(this.logger);

  @override
  void render(
    Context context,
    ThemeLayerType layerType,
    Style style,
    TileLayer layer,
    TileFeature feature,
  ) {
    final symbolLayout = style.symbolLayout;
    if (symbolLayout == null) {
      logger.warn(() => 'line symbol does not have a layout');
      return;
    }

    final lines = feature.paths;
    if (lines.isEmpty) {
      return;
    }

    final BoundedPath path = feature.compoundPath;
    if (!context.optimizations.skipInBoundsChecks &&
        !context.tileSpaceMapper.isPathWithinTileClip(path)) {
      return;
    }

    final evaluationContext = EvaluationContext(
      () => feature.properties,
      feature.type,
      logger,
      zoom: context.zoom,
      zoomScaleFactor: context.zoomScaleFactor,
      hasImage: context.hasImage,
    );

    final text = symbolLayout.text?.text.evaluate(evaluationContext);
    final icon = symbolLayout.getIcon(
      context,
      evaluationContext,
      layoutPlacement: LayoutPlacement.line,
    );
    if (text == null) {
      logger.warn(() => 'line with no text');
      return;
    }

    final rotationAlignment = symbolLayout.textRotationAlignment(
      evaluationContext,
      layoutPlacement: LayoutPlacement.line,
    );
    bool rotateWithLine = _shouldRotateWithLine(
      rotationAlignment,
      evaluationContext,
    );
    final textAbbreviation = TextAbbreviator().abbreviate(text);
    if (!context.labelSpace.canAccept(textAbbreviation)) {
      return;
    }

    final textAnchor =
        symbolLayout.text?.anchor.evaluate(evaluationContext) ??
        LayoutAnchor.center;
    final textApproximation = TextApproximation(
      context,
      evaluationContext,
      style,
      [textAbbreviation],
    );

    final metrics = path.pathMetrics;
    final renderBox = _findMiddleMetric(
      context,
      metrics,
      textApproximation,
      rotateWithLine,
    );
    if (renderBox == null || !textApproximation.renderer.canPaint) {
      return;
    }

    context.tileSpaceMapper.drawInPixelSpace(() {
      final tangentPosition = renderBox.tangent.position;
      final tangentAngle = renderBox.tangent.angle;
      final rotateWithLine = (tangentAngle >= 0.01 || tangentAngle <= -0.01);
      final saveState =
          rotateWithLine || rotationAlignment == RotationAlignment.viewport;
      if (saveState) {
        final rotation = rotationAlignment == RotationAlignment.viewport
            ? context.rotation
            : _rightSideUpAngle(tangentAngle);
        context.canvas.save();
        context.canvas.translate(tangentPosition.dx, tangentPosition.dy);
        context.canvas.rotate(-rotation);
        context.canvas.translate(-tangentPosition.dx, -tangentPosition.dy);
      }
      final occupied = icon?.render(
        tangentPosition,
        contentSize: textApproximation.renderer.size,
        withRotation: false,
      );
      var textPosition = tangentPosition;
      if (occupied != null &&
          occupied.overlapsText &&
          textAnchor == LayoutAnchor.center) {
        textPosition = textPosition.translate(
          0,
          (occupied.contentArea.top - occupied.area.top).abs() -
              (occupied.contentArea.bottom - occupied.area.bottom).abs(),
        );
      }
      textApproximation.renderer.render(textPosition);
      if (saveState) {
        context.canvas.restore();
      }
    });
  }

  bool _shouldRotateWithLine(
    RotationAlignment alignment,
    EvaluationContext evaluationContext,
  ) {
    if (alignment == RotationAlignment.viewport) {
      return false;
    }
    return true;
  }

  _RenderBox? _findMiddleMetric(
    Context context,
    List<PathMetric> metrics,
    TextApproximation text,
    bool rotate,
  ) {
    if (metrics.isEmpty) {
      return null;
    }
    final midpoint = metrics.length ~/ 2;
    for (int x = 0; x <= (midpoint + 1); ++x) {
      int lower = midpoint - x;
      if (lower >= 0 && metrics[lower].length > _minPathMetricSize) {
        final renderBox = _occupyLabelSpace(
          context,
          text,
          metrics[lower],
          rotate,
        );
        if (renderBox != null) {
          return renderBox;
        }
      }
      int upper = midpoint + x;
      if (upper != lower &&
          upper < metrics.length &&
          metrics[upper].length > _minPathMetricSize) {
        final renderBox = _occupyLabelSpace(
          context,
          text,
          metrics[upper],
          rotate,
        );
        if (renderBox != null) {
          return renderBox;
        }
      }
    }
    return _occupyLabelSpace(context, text, metrics[midpoint], rotate);
  }

  _RenderBox? _occupyLabelSpace(
    Context context,
    TextApproximation text,
    PathMetric metric,
    bool rotate,
  ) {
    Tangent? getTangentForOffsetInPixels(double distance) {
      final tangent = metric.getTangentForOffset(distance);
      if (tangent != null) {
        final angle = rotate ? -tangent.angle : 0.0;
        return Tangent.fromAngle(
          context.tileSpaceMapper.pointFromTileToPixels(tangent.position),
          angle,
        );
      }
      return null;
    }

    Tangent? tangent = getTangentForOffsetInPixels(metric.length / 2);
    _RenderBox? renderBox;
    if (tangent != null) {
      renderBox = _occupyLabelSpaceAtTangent(context, text, tangent, rotate);
      if (renderBox == null) {
        tangent = getTangentForOffsetInPixels(metric.length / 4);
        if (tangent != null) {
          renderBox = _occupyLabelSpaceAtTangent(
            context,
            text,
            tangent,
            rotate,
          );
          if (renderBox == null) {
            tangent = getTangentForOffsetInPixels(metric.length * 3 / 4);
            if (tangent != null) {
              renderBox = _occupyLabelSpaceAtTangent(
                context,
                text,
                tangent,
                rotate,
              );
            }
          }
        }
      }
    }
    return renderBox;
  }

  _RenderBox? _occupyLabelSpaceAtTangent(
    Context context,
    TextApproximation text,
    Tangent tangent,
    bool rotate,
  ) {
    final box = text.labelBox(tangent.position, translated: false);
    if (box != null) {
      final angle = rotate ? drawnAngle(tangent.angle) : context.rotation;
      final textSpace = SymbolLineRenderer.textSpace(
        box,
        text.translation,
        tangent,
        angle,
        context.labelSpace.margin,
      );
      if (context.labelSpace.canOccupyQuad(text.text, textSpace) &&
          text.styledSymbol != null) {
        return _preciselyOccupyLabelSpaceAtTangent(
          context,
          text,
          textSpace,
          tangent,
          angle,
        );
      }
    }
    return null;
  }

  // VOYAGER PATCH: as the point renderer does — with no precise box yet, the
  // approximate one is occupied; a precise box that collides rejects the
  // label. Upstream fell back to the approximate box in both cases without
  // occupying it, so a label that collided was drawn anyway.
  _RenderBox? _preciselyOccupyLabelSpaceAtTangent(
    Context context,
    TextApproximation text,
    List<Offset> approximateSpace,
    Tangent tangent,
    double angle,
  ) {
    final renderer = text.renderer;
    final box = renderer.labelBox(tangent.position, translated: false);
    if (box == null) {
      context.labelSpace.occupyQuad(text.text, approximateSpace);
      return _RenderBox(tangent);
    }
    final textSpace = SymbolLineRenderer.textSpace(
      box,
      renderer.translation,
      tangent,
      angle,
      context.labelSpace.margin,
    );
    if (context.labelSpace.canOccupyQuad(renderer.symbol.text, textSpace)) {
      context.labelSpace.occupyQuad(renderer.symbol.text, textSpace);
      return _RenderBox(tangent);
    }
    return null;
  }

  /// The angle [render] turns the canvas by for a label along a line whose
  /// tangent is at [tangentAngle].
  static double drawnAngle(double tangentAngle) =>
      (tangentAngle >= 0.01 || tangentAngle <= -0.01)
      ? _rightSideUpAngle(tangentAngle)
      : 0.0;

  static double _rightSideUpAngle(double radians) {
    if (radians > _rotationShiftUpper || radians < _rotationShiftLower) {
      return radians + _rotationShift;
    }
    return radians;
  }

  // VOYAGER PATCH: the space a label takes is the box it is drawn in —
  // [box]'s size at [translation] from the tangent's point, with a margin,
  // turned about that point the way [render] turns the canvas. Upstream took
  // the upright bounds of that box, offset from it, so a name along a road
  // at an angle blocked the block beside it and missed part of its own text.
  static List<Offset> textSpace(
    Rect box,
    Offset? translation,
    Tangent tangent,
    double angle,
    double margin,
  ) {
    final local = Rect.fromLTWH(
      translation?.dx ?? 0,
      translation?.dy ?? 0,
      box.width,
      box.height,
    ).inflate(margin);
    final c = cos(-angle);
    final s = sin(-angle);
    return [
      for (final corner in [
        local.topLeft,
        local.topRight,
        local.bottomRight,
        local.bottomLeft,
      ])
        tangent.position +
            Offset(
              corner.dx * c - corner.dy * s,
              corner.dx * s + corner.dy * c,
            ),
    ];
  }
}

class _RenderBox {
  final Tangent tangent;

  _RenderBox(this.tangent);
}

const _minPathMetricSize = 100.0;

const _degToRad = pi / 180.0;
const _rotationOvershot = 3;
const _rotationShiftUpper = (90 + _rotationOvershot) * _degToRad;
const _rotationShiftLower = -(90 + _rotationOvershot) * _degToRad;
const _rotationShift = (180 * _degToRad);
