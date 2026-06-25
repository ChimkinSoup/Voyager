import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';
import 'package:voyager/domain/services/weather_forecast_chart.dart';
import 'package:voyager/features/shell/weather_chart_curve.dart';

const _defaultRainColor = 0xFFFF9800;
const _defaultAccentColor = 0xFF7C9EFF;

({Color temp, Color rain}) _chartColors(WidgetRef ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  final cached = ref.watch(weatherChartColorsProvider);
  return (
    temp: Color(
      cached.temp ??
          settings?.weatherChartTempColor ??
          settings?.accentColor ??
          _defaultAccentColor,
    ),
    rain: Color(
      cached.rain ?? settings?.weatherChartRainColor ?? _defaultRainColor,
    ),
  );
}

class WeatherForecastChart extends ConsumerStatefulWidget {
  const WeatherForecastChart({
    super.key,
    required this.series,
    required this.gradientStartHour,
    this.showLegend = true,
    this.axisMinY,
    this.axisMaxY,
    this.allowOverflow = false,
    this.showCurrentTimeLine = false,
  });

  final DayForecastChartSeries series;
  final double gradientStartHour;
  final bool showLegend;
  final double? axisMinY;
  final double? axisMaxY;

  /// When true, vertical dotted line shows the current local time (today only).
  final bool showCurrentTimeLine;

  /// When true, vertical plot clipping is disabled so data can exceed the axis.
  final bool allowOverflow;

  static const minX = 0.0;
  static const maxX = 24.0;
  static const leftAxisWidth = 40.0;
  static const bottomAxisHeight = 28.0;
  static const curveSmoothness = 0.78;

  double get chartMinY => axisMinY ?? series.minTemp;
  double get chartMaxY => axisMaxY ?? series.maxTemp;

  @override
  ConsumerState<WeatherForecastChart> createState() =>
      _WeatherForecastChartState();
}

class _WeatherForecastChartState extends ConsumerState<WeatherForecastChart> {
  double? _hoveredHour;
  Offset? _hoverPosition;
  Timer? _nowTimer;

  @override
  void initState() {
    super.initState();
    _syncNowTimer();
  }

  @override
  void didUpdateWidget(covariant WeatherForecastChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showCurrentTimeLine != widget.showCurrentTimeLine) {
      _syncNowTimer();
    }
  }

  @override
  void dispose() {
    _nowTimer?.cancel();
    super.dispose();
  }

  void _syncNowTimer() {
    _nowTimer?.cancel();
    _nowTimer = null;
    if (!widget.showCurrentTimeLine) return;
    _nowTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  double? _currentTimeHour() {
    if (!widget.showCurrentTimeLine || widget.series.tempPoints.isEmpty) {
      return null;
    }
    final now = DateTime.now();
    final hour = currentTimeChartHour(now);
    final first = widget.series.tempPoints.first.hour;
    final last = widget.series.tempPoints.last.hour;
    if (hour < first || hour > last) return null;
    return hour;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final colors = _chartColors(ref);
    final tempColor = colors.temp;
    final rainColor = colors.rain;
    final tempFillColor = tempColor.withValues(alpha: 0.4);
    final rainFillColor = rainColor.withValues(alpha: 0.4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showLegend) ...[
          const WeatherChartLegendRow(),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final chartSize = Size(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              final plotPadding = EdgeInsets.only(
                left: WeatherForecastChart.leftAxisWidth,
                bottom: WeatherForecastChart.bottomAxisHeight,
              );
              final curve = WeatherChartCurve(
                size: chartSize,
                plotPadding: plotPadding,
                minX: WeatherForecastChart.minX,
                maxX: WeatherForecastChart.maxX,
                minY: widget.chartMinY,
                maxY: widget.chartMaxY,
                curveSmoothness: WeatherForecastChart.curveSmoothness,
              );

              final hoveredBucket = _hoveredHour == null
                  ? null
                  : _bucketForHour(widget.series, _hoveredHour!);
              final currentTimeHour = _currentTimeHour();

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: MouseRegion(
                      onHover: (event) {
                        final hour = curve.hourAtPixelX(event.localPosition.dx);
                        setState(() {
                          _hoveredHour = hour;
                          _hoverPosition = event.localPosition;
                        });
                      },
                      onExit: (_) => setState(() {
                        _hoveredHour = null;
                        _hoverPosition = null;
                      }),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _WeatherFillPainter(
                                series: widget.series,
                                curve: curve,
                                gradientStartHour: widget.gradientStartHour,
                                tempFillColor: tempFillColor,
                                rainFillColor: rainFillColor,
                                hoveredBucket: hoveredBucket,
                              ),
                            ),
                          ),
                          LineChart(
                            duration: widget.axisMinY != null ||
                                    widget.axisMaxY != null
                                ? Duration.zero
                                : const Duration(milliseconds: 150),
                            LineChartData(
                              minX: WeatherForecastChart.minX,
                              maxX: WeatherForecastChart.maxX,
                              minY: widget.chartMinY,
                              maxY: widget.chartMaxY,
                              clipData: widget.allowOverflow
                                  ? const FlClipData.horizontal()
                                  : const FlClipData.all(),
                              gridData: const FlGridData(show: false),
                              titlesData: FlTitlesData(
                                topTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                rightTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                leftTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    reservedSize:
                                        WeatherForecastChart.leftAxisWidth,
                                    interval: _niceTempInterval(
                                      widget.chartMinY,
                                      widget.chartMaxY,
                                    ),
                                    getTitlesWidget: (value, meta) {
                                      if (value <= meta.min ||
                                          value >= meta.max) {
                                        return const SizedBox.shrink();
                                      }
                                      return Text(
                                        '${value.round()}°',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(color: tempColor),
                                      );
                                    },
                                  ),
                                ),
                                bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    reservedSize:
                                        WeatherForecastChart.bottomAxisHeight,
                                    interval: 6,
                                    getTitlesWidget: (value, meta) {
                                      final hour = value.round();
                                      if (![6, 12, 18].contains(hour)) {
                                        return const SizedBox.shrink();
                                      }
                                      return Text(
                                        _formatHourLabel(hour),
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              borderData: FlBorderData(
                                show: true,
                                border: Border.all(
                                  color: colorScheme.outlineVariant.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                              ),
                              lineTouchData: const LineTouchData(
                                enabled: false,
                              ),
                              lineBarsData: [
                                LineChartBarData(
                                  spots: [
                                    for (final point in widget.series.tempPoints)
                                      FlSpot(point.hour, point.tempC),
                                  ],
                                  isCurved: true,
                                  curveSmoothness:
                                      WeatherForecastChart.curveSmoothness,
                                  preventCurveOverShooting: true,
                                  preventCurveOvershootingThreshold: 0,
                                  color: tempColor,
                                  barWidth: 2.5,
                                  dotData: const FlDotData(show: false),
                                  belowBarData: BarAreaData(show: false),
                                ),
                              ],
                            ),
                          ),
                          if (currentTimeHour != null)
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _CurrentTimeLinePainter(
                                  series: widget.series,
                                  curve: curve,
                                  currentTimeHour: currentTimeHour,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (hoveredBucket != null && _hoverPosition != null)
                    _HoverTooltip(
                      bucket: hoveredBucket,
                      position: _hoverPosition!,
                      chartSize: chartSize,
                      tempColor: tempColor,
                      theme: theme,
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  static double _niceTempInterval(double minY, double maxY) {
    final span = maxY - minY;
    if (span <= 4) return 1;
    if (span <= 10) return 2;
    return 5;
  }

  static String _formatHourLabel(int hour) {
    if (hour == 0 || hour == 24) return '12 AM';
    if (hour == 12) return '12 PM';
    if (hour < 12) return '$hour AM';
    return '${hour - 12} PM';
  }
}

Future<void> pickWeatherChartColor(
  BuildContext context,
  WidgetRef ref, {
  required bool isTemp,
}) async {
  final repo = ref.read(settingsRepositoryProvider);
  final settings = await repo.getSettings();
  final palette = ref.read(colorPaletteProvider);
  var selected = normalizeColorValue(
    isTemp
        ? settings.weatherChartTempColor ?? settings.accentColor
        : settings.weatherChartRainColor ?? _defaultRainColor,
  );
  if (!paletteContains(palette, selected)) {
    selected = palette.first;
  }

  if (!context.mounted) return;
  final result = await pickColorFromPalette(
    context,
    palette: palette,
    current: selected,
    title: isTemp ? 'Temperature color' : 'Rain color',
  );

  if (result == null) return;
  await repo.saveSettings(
    settings.copyWith(
      weatherChartTempColor: isTemp ? result : settings.weatherChartTempColor,
      weatherChartRainColor: isTemp ? settings.weatherChartRainColor : result,
    ),
  );
  ref.read(weatherChartColorsProvider.notifier).state = (
    temp: isTemp ? result : settings.weatherChartTempColor,
    rain: isTemp ? settings.weatherChartRainColor : result,
  );
  ref.invalidate(settingsProvider);
}

class WeatherChartLegendRow extends ConsumerWidget {
  const WeatherChartLegendRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = _chartColors(ref);

    return Row(
      children: [
        _LegendChip(
          color: colors.temp,
          label: 'Temperature',
          onPickColor: () => pickWeatherChartColor(context, ref, isTemp: true),
        ),
        const SizedBox(width: 16),
        _LegendChip(
          color: colors.rain,
          label: 'Rain',
          onPickColor: () => pickWeatherChartColor(context, ref, isTemp: false),
        ),
      ],
    );
  }
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({
    required this.color,
    required this.label,
    required this.onPickColor,
  });

  final Color color;
  final String label;
  final VoidCallback onPickColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPickColor,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

class _WeatherBucket {
  const _WeatherBucket({
    required this.hour,
    required this.startHour,
    required this.endHour,
    required this.tempC,
    required this.rainPercent,
  });

  final double hour;
  final double startHour;
  final double endHour;
  final double tempC;
  final double rainPercent;
}

_WeatherBucket? _bucketForHour(
  DayForecastChartSeries series,
  double hour,
) {
  for (final temp in series.tempPoints) {
    final range = chartBucketRangeCenteredOn(temp.hour);
    if (hour >= range.start && hour < range.end) {
      final rainPercent = series.rainPoints
              .where((point) => point.hour == temp.hour)
              .map((point) => point.rainPercent)
              .firstOrNull ??
          0;
      return _WeatherBucket(
        hour: temp.hour,
        startHour: range.start,
        endHour: range.end,
        tempC: temp.tempC,
        rainPercent: rainPercent,
      );
    }
  }
  return null;
}

double _rainAtHour(
  List<({double hour, double rainPercent})> points,
  double hour,
) {
  if (points.isEmpty) return 0;
  if (hour <= points.first.hour) return points.first.rainPercent;
  if (hour >= points.last.hour) return points.last.rainPercent;

  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    if (hour >= a.hour && hour <= b.hour) {
      final t = (hour - a.hour) / (b.hour - a.hour);
      return ui.lerpDouble(a.rainPercent, b.rainPercent, t)!;
    }
  }
  return points.last.rainPercent;
}

class _CurrentTimeLinePainter extends CustomPainter {
  _CurrentTimeLinePainter({
    required this.series,
    required this.curve,
    required this.currentTimeHour,
  });

  final DayForecastChartSeries series;
  final WeatherChartCurve curve;
  final double currentTimeHour;

  static const _dashLength = 3.0;
  static const _gapLength = 3.0;

  List<FlSpot> get _spots => [
        for (final point in series.tempPoints)
          FlSpot(point.hour, point.tempC),
      ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final curvePoint = curve.pointOnCurveAtX(_spots, currentTimeHour);
    if (curvePoint == null) return;

    final bottom = curve.plotRect.bottom;
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round;

    _drawDottedLine(
      canvas,
      Offset(curvePoint.dx, bottom),
      curvePoint,
      paint,
    );
  }

  void _drawDottedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final distance = math.sqrt(dx * dx + dy * dy);
    if (distance <= 0) return;

    final unit = Offset(dx / distance, dy / distance);
    var travelled = 0.0;
    var drawing = true;

    while (travelled < distance) {
      final segment = drawing ? _dashLength : _gapLength;
      final next = math.min(travelled + segment, distance);
      if (drawing) {
        canvas.drawLine(
          start + unit * travelled,
          start + unit * next,
          paint,
        );
      }
      travelled = next;
      drawing = !drawing;
    }
  }

  @override
  bool shouldRepaint(covariant _CurrentTimeLinePainter oldDelegate) {
    return oldDelegate.series != series ||
        oldDelegate.curve.size != curve.size ||
        oldDelegate.currentTimeHour != currentTimeHour;
  }
}

class _WeatherFillPainter extends CustomPainter {
  _WeatherFillPainter({
    required this.series,
    required this.curve,
    required this.gradientStartHour,
    required this.tempFillColor,
    required this.rainFillColor,
    required this.hoveredBucket,
  });

  final DayForecastChartSeries series;
  final WeatherChartCurve curve;
  final double gradientStartHour;
  final Color tempFillColor;
  final Color rainFillColor;
  final _WeatherBucket? hoveredBucket;

  static const _hoverLighten = 0.22;

  List<FlSpot> get _spots => [
        for (final point in series.tempPoints)
          FlSpot(point.hour, point.tempC),
      ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    if (series.tempPoints.isEmpty) return;

    final fillPath = curve.belowCurvePath(_spots);
    canvas.save();
    canvas.clipPath(fillPath);

    final fillStartHour = series.tempPoints.first.hour;
    final fillEndHour = series.tempPoints.last.hour;
    final startPx = curve.pixelX(fillStartHour).ceil();
    final endPx = curve.pixelX(fillEndHour).floor();

    final hoverStartPx = hoveredBucket == null
        ? null
        : curve.pixelX(hoveredBucket!.startHour).round();
    final hoverEndPx = hoveredBucket == null
        ? null
        : curve.pixelX(hoveredBucket!.endHour).round();
    final plotRect = curve.plotRect;

    for (var px = startPx; px <= endPx; px++) {
      final hour = curve.hourAtPixelX(px.toDouble());
      final rain = _rainAtHour(series.rainPoints, hour).clamp(0, 100);
      final rainWeight = rainFillBlendFactor(hour, gradientStartHour);
      var fillColor = Color.lerp(
        tempFillColor,
        rainFillColor,
        (rain / 100) * rainWeight,
      )!;

      final inHover = hoverStartPx != null &&
          hoverEndPx != null &&
          px >= hoverStartPx &&
          px < hoverEndPx;
      if (inHover) {
        fillColor = Color.lerp(fillColor, Colors.white, _hoverLighten)!;
      }

      canvas.drawLine(
        Offset(px.toDouble(), plotRect.top),
        Offset(px.toDouble(), plotRect.bottom),
        Paint()
          ..color = fillColor
          ..strokeWidth = 1,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WeatherFillPainter oldDelegate) {
    return oldDelegate.series != series ||
        oldDelegate.curve.size != curve.size ||
        oldDelegate.gradientStartHour != gradientStartHour ||
        oldDelegate.tempFillColor != tempFillColor ||
        oldDelegate.rainFillColor != rainFillColor ||
        oldDelegate.hoveredBucket?.hour != hoveredBucket?.hour;
  }
}

class _HoverTooltip extends StatelessWidget {
  const _HoverTooltip({
    required this.bucket,
    required this.position,
    required this.chartSize,
    required this.tempColor,
    required this.theme,
  });

  final _WeatherBucket bucket;
  final Offset position;
  final Size chartSize;
  final Color tempColor;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final colorScheme = theme.colorScheme;
    final left = (position.dx + 12).clamp(0.0, chartSize.width - 120);
    final top = 8.0.clamp(0.0, chartSize.height - 56);

    return Positioned(
      left: left,
      top: top,
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(8),
        color: colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatBucketTime(bucket.hour),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${bucket.tempC.round()}°C',
                style: theme.textTheme.titleSmall?.copyWith(color: tempColor),
              ),
              Text(
                '${bucket.rainPercent.round()}% rain',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatBucketTime(double hour) {
    final h = hour.round();
    if (h == 0 || h == 24) return '12:00 AM';
    if (h == 12) return '12:00 PM';
    if (h < 12) return '$h:00 AM';
    return '${h - 12}:00 PM';
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}
