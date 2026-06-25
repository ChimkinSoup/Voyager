import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Cardinal tension spline through forecast points (tension fixed at 0).
class WeatherChartCurve {
  WeatherChartCurve({
    required this.size,
    required this.plotPadding,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });

  final Size size;
  final EdgeInsets plotPadding;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  static const _tension = 0.0;

  double get _tangentScale => 1 - _tension;

  /// Plot area inside [size] after fl_chart title margins.
  Rect get plotRect => Rect.fromLTWH(
        plotPadding.left,
        plotPadding.top,
        math.max(0, size.width - plotPadding.horizontal),
        math.max(0, size.height - plotPadding.vertical),
      );

  double pixelX(double x) {
    final rect = plotRect;
    final deltaX = maxX - minX;
    if (deltaX == 0) return rect.left;
    return rect.left + ((x - minX) / deltaX) * rect.width;
  }

  double pixelY(double y) {
    final rect = plotRect;
    final deltaY = maxY - minY;
    if (deltaY == 0) return rect.bottom;
    return rect.bottom - (((y - minY) / deltaY) * rect.height);
  }

  double hourAtPixelX(double px) {
    final rect = plotRect;
    if (rect.width <= 0) return minX;
    final t = ((px - rect.left) / rect.width).clamp(0.0, 1.0);
    return minX + t * (maxX - minX);
  }

  /// Point on the curved temperature line at chart [x] (hour).
  Offset? pointOnCurveAtX(List<FlSpot> spots, double x) {
    if (spots.isEmpty) return null;
    if (spots.length == 1) {
      return Offset(pixelX(spots.first.x), pixelY(spots.first.y));
    }

    final targetPx = pixelX(x);
    final path = curvedLinePath(spots);
    for (final metric in path.computeMetrics()) {
      final length = metric.length;
      if (length <= 0) continue;

      var low = 0.0;
      var high = length;
      Offset? best;

      for (var i = 0; i < 64; i++) {
        final mid = (low + high) / 2;
        final tangent = metric.getTangentForOffset(mid);
        if (tangent == null) break;
        best = tangent.position;
        if (tangent.position.dx < targetPx) {
          low = mid;
        } else {
          high = mid;
        }
      }

      if (best != null) return best;
    }

    return null;
  }

  Offset _spotPixel(List<FlSpot> spots, int index) {
    return Offset(pixelX(spots[index].x), pixelY(spots[index].y));
  }

  Offset _tangentAt(List<FlSpot> spots, int index) {
    final count = spots.length;
    final scale = _tangentScale;
    if (count <= 1 || scale <= 0) return Offset.zero;

    if (index == 0) {
      return (_spotPixel(spots, 1) - _spotPixel(spots, 0)) * scale;
    }
    if (index == count - 1) {
      return (_spotPixel(spots, count - 1) - _spotPixel(spots, count - 2)) *
          scale;
    }

    return (_spotPixel(spots, index + 1) - _spotPixel(spots, index - 1)) /
        2 *
        scale;
  }

  Path curvedLinePath(List<FlSpot> spots) {
    final path = Path();
    if (spots.isEmpty) return path;

    final count = spots.length;
    final first = _spotPixel(spots, 0);
    path.moveTo(first.dx, first.dy);
    if (count == 1) return path;

    for (var i = 0; i < count - 1; i++) {
      final p0 = _spotPixel(spots, i);
      final p1 = _spotPixel(spots, i + 1);
      final m0 = _tangentAt(spots, i);
      final m1 = _tangentAt(spots, i + 1);
      final control1 = p0 + m0 / 3;
      final control2 = p1 - m1 / 3;
      path.cubicTo(
        control1.dx,
        control1.dy,
        control2.dx,
        control2.dy,
        p1.dx,
        p1.dy,
      );
    }

    return path;
  }

  Path belowCurvePath(List<FlSpot> spots) {
    final linePath = curvedLinePath(spots);
    if (spots.isEmpty) return Path();

    final belowPath = Path.from(linePath);
    final bottom = plotRect.bottom;
    var x = pixelX(spots.last.x);
    belowPath.lineTo(x, bottom);

    x = pixelX(spots.first.x);
    belowPath.lineTo(x, bottom);

    x = pixelX(spots.first.x);
    final y = pixelY(spots.first.y);
    belowPath
      ..lineTo(x, y)
      ..close();

    return belowPath;
  }

  bool matchesScale(WeatherChartCurve other) {
    return size == other.size &&
        plotPadding == other.plotPadding &&
        minX == other.minX &&
        maxX == other.maxX &&
        minY == other.minY &&
        maxY == other.maxY;
  }
}
