import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/shell/weather_chart_curve.dart';

void main() {
  test('plot padding matches fl_chart title margins', () {
    const size = Size(400, 200);
    const padding = EdgeInsets.only(left: 40, bottom: 28);
    final curve = WeatherChartCurve(
      size: size,
      plotPadding: padding,
      minX: 0,
      maxX: 24,
      minY: 10,
      maxY: 20,
      curveSmoothness: 0.78,
    );

    expect(curve.plotRect, const Rect.fromLTWH(40, 0, 360, 172));
    expect(curve.pixelX(0), 40);
    expect(curve.pixelX(24), 400);
    expect(curve.hourAtPixelX(40), 0);
    expect(curve.hourAtPixelX(400), 24);
  });
}
