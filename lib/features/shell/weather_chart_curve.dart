import 'dart:math' as math;
import 'dart:ui';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Matches [fl_chart] curved line geometry so custom fills align with the line.
class WeatherChartCurve {
  WeatherChartCurve({
    required this.size,
    required this.plotPadding,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.curveSmoothness,
    this.preventCurveOverShooting = true,
    this.preventCurveOvershootingThreshold = 0,
  });

  final Size size;
  final EdgeInsets plotPadding;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;
  final double curveSmoothness;
  final bool preventCurveOverShooting;
  final double preventCurveOvershootingThreshold;

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

  Path curvedLinePath(List<FlSpot> spots) {
    final path = Path();
    if (spots.isEmpty) return path;

    final count = spots.length;
    path.moveTo(pixelX(spots[0].x), pixelY(spots[0].y));
    if (count == 1) {
      path.lineTo(pixelX(spots[0].x), pixelY(spots[0].y));
      return path;
    }

    var temp = Offset.zero;
    for (var i = 1; i < count; i++) {
      final current = Offset(pixelX(spots[i].x), pixelY(spots[i].y));
      final previous = Offset(pixelX(spots[i - 1].x), pixelY(spots[i - 1].y));
      final next = Offset(
        pixelX(spots[i + 1 < count ? i + 1 : i].x),
        pixelY(spots[i + 1 < count ? i + 1 : i].y),
      );

      final controlPoint1 = previous + temp;
      final smoothness = curveSmoothness;
      temp = ((next - previous) / 2) * smoothness;

      if (preventCurveOverShooting) {
        if ((next - current).dy <= preventCurveOvershootingThreshold ||
            (current - previous).dy <= preventCurveOvershootingThreshold) {
          temp = Offset(temp.dx, 0);
        }
        if ((next - current).dx <= preventCurveOvershootingThreshold ||
            (current - previous).dx <= preventCurveOvershootingThreshold) {
          temp = Offset(0, temp.dy);
        }
      }

      final controlPoint2 = current - temp;
      path.cubicTo(
        controlPoint1.dx,
        controlPoint1.dy,
        controlPoint2.dx,
        controlPoint2.dy,
        current.dx,
        current.dy,
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
}
