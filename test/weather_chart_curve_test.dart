import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/shell/weather_chart_curve.dart';

void main() {
  WeatherChartCurve curveFor({
    double width = 240,
    double height = 120,
  }) {
    return WeatherChartCurve(
      size: Size(width, height),
      plotPadding: EdgeInsets.zero,
      minX: 0,
      maxX: 24,
      minY: 0,
      maxY: 30,
    );
  }

  const spots = [
    FlSpot(0, 10),
    FlSpot(6, 16),
    FlSpot(12, 22),
    FlSpot(18, 14),
    FlSpot(24, 11),
  ];

  test('cardinal spline draws smooth curve through knots', () {
    final curve = curveFor();
    final midpoint = curve.pointOnCurveAtX(spots, 9);

    expect(midpoint, isNotNull);
    expect(midpoint!.dx, closeTo(curve.pixelX(9), 0.5));
    expect(midpoint.dy, lessThan(curve.pixelY(16)));
    expect(midpoint.dy, greaterThan(curve.pixelY(22)));
  });

  test('smooth cardinal path is longer than straight chords', () {
    final smooth = curveFor().curvedLinePath(spots);
    final chordPath = Path()
      ..moveTo(curveFor().pixelX(0), curveFor().pixelY(10));
    for (var i = 1; i < spots.length; i++) {
      chordPath.lineTo(
        curveFor().pixelX(spots[i].x),
        curveFor().pixelY(spots[i].y),
      );
    }

    double pathLength(Path path) => path
        .computeMetrics()
        .fold<double>(0, (sum, metric) => sum + metric.length);

    expect(pathLength(smooth), greaterThan(pathLength(chordPath)));
  });

  test('pointOnCurveAtX hits the first and last knots', () {
    final curve = curveFor();

    final start = curve.pointOnCurveAtX(spots, 0);
    final end = curve.pointOnCurveAtX(spots, 24);

    expect(start, isNotNull);
    expect(end, isNotNull);
    expect(start!.dx, closeTo(curve.pixelX(0), 0.5));
    expect(start.dy, closeTo(curve.pixelY(10), 0.5));
    expect(end!.dx, closeTo(curve.pixelX(24), 0.5));
    expect(end.dy, closeTo(curve.pixelY(11), 0.5));
  });
}
