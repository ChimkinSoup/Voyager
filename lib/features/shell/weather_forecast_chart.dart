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
import 'package:voyager/features/shell/weather_chart_plot_cache.dart';

const _defaultRainColor = 0xFFFF9800;
const _defaultAccentColor = 0xFF7C9EFF;

({Color temp, Color rain}) weatherChartColors(WidgetRef ref) {
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
    this.chartFrameOnly = false,
    this.plotContentOnly = false,
    this.showDegreeGrid,
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

  /// Axes and border only — no curves or fills (used during day transitions).
  final bool chartFrameOnly;

  /// Curves and fills only — no axes or border; parent must size to the plot rect.
  final bool plotContentOnly;

  /// When null, degree grid shows on full and plot-only charts, not frame-only.
  final bool? showDegreeGrid;

  static const minX = 0.0;
  static const maxX = 24.0;
  static const leftAxisWidth = 40.0;
  static const bottomAxisHeight = 28.0;

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
    final colors = weatherChartColors(ref);
    final tempColor = colors.temp;
    final rainColor = colors.rain;
    final tempFillColor = tempColor.withValues(alpha: 0.4);
    final rainFillColor = rainColor.withValues(alpha: 0.4);
    final degreeGridColor = colorScheme.outlineVariant.withValues(alpha: 0.15);
    final tempSpots = [
      for (final point in widget.series.tempPoints)
        FlSpot(point.hour, point.tempC),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showLegend && !widget.plotContentOnly) ...[
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
              final showFrame = !widget.plotContentOnly;
              final showPlot = !widget.chartFrameOnly;
              final plotPadding = widget.plotContentOnly
                  ? EdgeInsets.zero
                  : EdgeInsets.only(
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
              );

              final hoveredBucket = showPlot && _hoveredHour != null
                  ? _bucketForHour(widget.series, _hoveredHour!)
                  : null;
              final currentTimeHour =
                  showPlot && widget.showCurrentTimeLine ? _currentTimeHour() : null;

              // On the sliding plot layers during day transitions; omitted from the
              // fixed axis frame so lines move with the graph instead of clipping.
              final showDegreeGrid =
                  widget.showDegreeGrid ?? !widget.chartFrameOnly;

              final lineChart = LineChart(
                duration: widget.axisMinY != null || widget.axisMaxY != null
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
                        showTitles: showFrame,
                        reservedSize: WeatherForecastChart.leftAxisWidth,
                        interval: _tempAxisInterval,
                        getTitlesWidget: (value, meta) {
                          if (!showFrame ||
                              value <= meta.min ||
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
                        showTitles: showFrame,
                        reservedSize: WeatherForecastChart.bottomAxisHeight,
                        interval: 6,
                        getTitlesWidget: (value, meta) {
                          if (!showFrame) return const SizedBox.shrink();
                          final hour = value.round();
                          if (![6, 12, 18].contains(hour)) {
                            return const SizedBox.shrink();
                          }
                          return Text(
                            _formatHourLabel(hour),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(
                    show: showFrame,
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(
                        alpha: 0.4,
                      ),
                    ),
                  ),
                  lineTouchData: const LineTouchData(enabled: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: showPlot && tempSpots.isNotEmpty
                          ? tempSpots
                          : [
                              FlSpot(
                                WeatherForecastChart.minX,
                                widget.chartMinY,
                              ),
                              FlSpot(
                                WeatherForecastChart.maxX,
                                widget.chartMinY,
                              ),
                            ],
                      isCurved: false,
                      color: Colors.transparent,
                      barWidth: 0,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(show: false),
                    ),
                  ],
                ),
              );

              final plotStack = Stack(
                children: [
                  if (showPlot && tempSpots.isNotEmpty)
                    Positioned.fill(
                      child: CustomPaint(
                        isComplex: widget.plotContentOnly,
                        willChange: widget.plotContentOnly,
                        painter: _WeatherPlotPainter(
                          series: widget.series,
                          curve: curve,
                          spots: tempSpots,
                          gradientStartHour: widget.gradientStartHour,
                          tempFillColor: tempFillColor,
                          rainFillColor: rainFillColor,
                          tempLineColor: tempColor,
                          degreeGridColor: degreeGridColor,
                          showDegreeGrid: showDegreeGrid,
                          currentTimeHour: currentTimeHour,
                          hoveredBucket: hoveredBucket,
                          allowVerticalOverflow: widget.allowOverflow,
                        ),
                      ),
                    ),
                  if (showFrame)
                    Positioned.fill(child: lineChart),
                ],
              );

              if (widget.plotContentOnly) {
                return plotStack;
              }

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
                      child: plotStack,
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

  static const _tempAxisInterval = 5.0;

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
    final colors = weatherChartColors(ref);

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

/// Records a plot layer into the cache and returns the picture.
ui.Picture warmWeatherChartPlotPicture({
  required WeatherChartCurve curve,
  required DayForecastChartSeries series,
  required double gradientStartHour,
  required Color tempFillColor,
  required Color rainFillColor,
  required Color tempLineColor,
  required Color degreeGridColor,
  bool showDegreeGrid = true,
  double? currentTimeHour,
}) {
  final key = WeatherChartPlotCacheKey.from(
    curve: curve,
    series: series,
    gradientStartHour: gradientStartHour,
    tempFillColor: tempFillColor,
    rainFillColor: rainFillColor,
    tempLineColor: tempLineColor,
    degreeGridColor: degreeGridColor,
    showDegreeGrid: showDegreeGrid,
    currentTimeHour: currentTimeHour,
  );

  final cached = WeatherChartPlotCache.instance.lookup(key);
  if (cached != null) return cached;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final spots = [
    for (final point in series.tempPoints) FlSpot(point.hour, point.tempC),
  ];
  _paintWeatherPlot(
    canvas: canvas,
    series: series,
    curve: curve,
    spots: spots,
    gradientStartHour: gradientStartHour,
    tempFillColor: tempFillColor,
    rainFillColor: rainFillColor,
    tempLineColor: tempLineColor,
    degreeGridColor: degreeGridColor,
    showDegreeGrid: showDegreeGrid,
    currentTimeHour: currentTimeHour,
  );
  final picture = recorder.endRecording();
  WeatherChartPlotCache.instance.store(key, picture);
  return picture;
}

/// Returns true when a cached picture was drawn.
bool paintWeatherChartPlotCached({
  required Canvas canvas,
  required WeatherChartCurve curve,
  required DayForecastChartSeries series,
  required double gradientStartHour,
  required Color tempFillColor,
  required Color rainFillColor,
  required Color tempLineColor,
  required Color degreeGridColor,
  bool showDegreeGrid = true,
  double? currentTimeHour,
}) {
  final key = WeatherChartPlotCacheKey.from(
    curve: curve,
    series: series,
    gradientStartHour: gradientStartHour,
    tempFillColor: tempFillColor,
    rainFillColor: rainFillColor,
    tempLineColor: tempLineColor,
    degreeGridColor: degreeGridColor,
    showDegreeGrid: showDegreeGrid,
    currentTimeHour: currentTimeHour,
  );

  final cached = WeatherChartPlotCache.instance.lookup(key);
  if (cached != null) {
    canvas.drawPicture(cached);
    return true;
  }

  final recorder = ui.PictureRecorder();
  final recordingCanvas = Canvas(recorder);
  final spots = [
    for (final point in series.tempPoints) FlSpot(point.hour, point.tempC),
  ];
  _paintWeatherPlot(
    canvas: recordingCanvas,
    series: series,
    curve: curve,
    spots: spots,
    gradientStartHour: gradientStartHour,
    tempFillColor: tempFillColor,
    rainFillColor: rainFillColor,
    tempLineColor: tempLineColor,
    degreeGridColor: degreeGridColor,
    showDegreeGrid: showDegreeGrid,
    currentTimeHour: currentTimeHour,
  );
  final picture = recorder.endRecording();
  WeatherChartPlotCache.instance.store(key, picture);
  canvas.drawPicture(picture);
  return true;
}

/// Single-pass plot renderer for transitions (both days in one paint).
class WeatherForecastPlotStrip extends StatelessWidget {
  const WeatherForecastPlotStrip({
    super.key,
    required this.viewportSize,
    required this.stripOffsetPx,
    required this.earlierSeries,
    required this.laterSeries,
    required this.earlierGradientStartHour,
    required this.laterGradientStartHour,
    required this.axisMinY,
    required this.axisMaxY,
    required this.tempColor,
    required this.rainColor,
    required this.degreeGridColor,
    this.earlierCurrentTimeHour,
    this.laterCurrentTimeHour,
  });

  final Size viewportSize;
  final double stripOffsetPx;
  final DayForecastChartSeries earlierSeries;
  final DayForecastChartSeries laterSeries;
  final double earlierGradientStartHour;
  final double laterGradientStartHour;
  final double axisMinY;
  final double axisMaxY;
  final Color tempColor;
  final Color rainColor;
  final Color degreeGridColor;
  final double? earlierCurrentTimeHour;
  final double? laterCurrentTimeHour;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: viewportSize,
      isComplex: true,
      willChange: true,
      painter: _WeatherFilmStripPainter(
        stripOffsetPx: stripOffsetPx,
        earlierSeries: earlierSeries,
        laterSeries: laterSeries,
        earlierGradientStartHour: earlierGradientStartHour,
        laterGradientStartHour: laterGradientStartHour,
        axisMinY: axisMinY,
        axisMaxY: axisMaxY,
        tempFillColor: tempColor.withValues(alpha: 0.4),
        rainFillColor: rainColor.withValues(alpha: 0.4),
        tempLineColor: tempColor,
        degreeGridColor: degreeGridColor,
        earlierCurrentTimeHour: earlierCurrentTimeHour,
        laterCurrentTimeHour: laterCurrentTimeHour,
      ),
    );
  }
}

class _WeatherPlotPainter extends CustomPainter {
  _WeatherPlotPainter({
    required this.series,
    required this.curve,
    required this.spots,
    required this.gradientStartHour,
    required this.tempFillColor,
    required this.rainFillColor,
    required this.tempLineColor,
    required this.degreeGridColor,
    required this.showDegreeGrid,
    this.currentTimeHour,
    this.hoveredBucket,
    this.allowVerticalOverflow = false,
  });

  final DayForecastChartSeries series;
  final WeatherChartCurve curve;
  final List<FlSpot> spots;
  final double gradientStartHour;
  final Color tempFillColor;
  final Color rainFillColor;
  final Color tempLineColor;
  final Color degreeGridColor;
  final bool showDegreeGrid;
  final double? currentTimeHour;
  final _WeatherBucket? hoveredBucket;
  final bool allowVerticalOverflow;

  @override
  void paint(Canvas canvas, Size size) {
    if (hoveredBucket == null &&
        paintWeatherChartPlotCached(
          canvas: canvas,
          curve: curve,
          series: series,
          gradientStartHour: gradientStartHour,
          tempFillColor: tempFillColor,
          rainFillColor: rainFillColor,
          tempLineColor: tempLineColor,
          degreeGridColor: degreeGridColor,
          showDegreeGrid: showDegreeGrid,
          currentTimeHour: currentTimeHour,
        )) {
      return;
    }

    _paintWeatherPlot(
        canvas: canvas,
        series: series,
        curve: curve,
        spots: spots,
        gradientStartHour: gradientStartHour,
        tempFillColor: tempFillColor,
        rainFillColor: rainFillColor,
        tempLineColor: tempLineColor,
        degreeGridColor: degreeGridColor,
        showDegreeGrid: showDegreeGrid,
      currentTimeHour: currentTimeHour,
      hoveredBucket: hoveredBucket,
      allowVerticalOverflow: allowVerticalOverflow,
    );
  }

  @override
  bool shouldRepaint(covariant _WeatherPlotPainter oldDelegate) {
    return oldDelegate.series != series ||
        !oldDelegate.curve.matchesScale(curve) ||
        oldDelegate.spots != spots ||
        oldDelegate.gradientStartHour != gradientStartHour ||
        oldDelegate.tempFillColor != tempFillColor ||
        oldDelegate.rainFillColor != rainFillColor ||
        oldDelegate.tempLineColor != tempLineColor ||
        oldDelegate.degreeGridColor != degreeGridColor ||
        oldDelegate.showDegreeGrid != showDegreeGrid ||
        oldDelegate.currentTimeHour != currentTimeHour ||
        oldDelegate.hoveredBucket?.hour != hoveredBucket?.hour ||
        oldDelegate.allowVerticalOverflow != allowVerticalOverflow;
  }
}

class _WeatherFilmStripPainter extends CustomPainter {
  _WeatherFilmStripPainter({
    required this.stripOffsetPx,
    required this.earlierSeries,
    required this.laterSeries,
    required this.earlierGradientStartHour,
    required this.laterGradientStartHour,
    required this.axisMinY,
    required this.axisMaxY,
    required this.tempFillColor,
    required this.rainFillColor,
    required this.tempLineColor,
    required this.degreeGridColor,
    this.earlierCurrentTimeHour,
    this.laterCurrentTimeHour,
  });

  final double stripOffsetPx;
  final DayForecastChartSeries earlierSeries;
  final DayForecastChartSeries laterSeries;
  final double earlierGradientStartHour;
  final double laterGradientStartHour;
  final double axisMinY;
  final double axisMaxY;
  final Color tempFillColor;
  final Color rainFillColor;
  final Color tempLineColor;
  final Color degreeGridColor;
  final double? earlierCurrentTimeHour;
  final double? laterCurrentTimeHour;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final plotWidth = size.width;
    final plotSize = Size(plotWidth, size.height);

    canvas.save();
    canvas.translate(stripOffsetPx, 0);

    _paintDayPanel(
      canvas: canvas,
      plotSize: plotSize,
      offsetX: 0,
      series: earlierSeries,
      gradientStartHour: earlierGradientStartHour,
      currentTimeHour: earlierCurrentTimeHour,
    );
    _paintDayPanel(
      canvas: canvas,
      plotSize: plotSize,
      offsetX: plotWidth,
      series: laterSeries,
      gradientStartHour: laterGradientStartHour,
      currentTimeHour: laterCurrentTimeHour,
    );

    canvas.restore();
  }

  void _paintDayPanel({
    required Canvas canvas,
    required Size plotSize,
    required double offsetX,
    required DayForecastChartSeries series,
    required double gradientStartHour,
    double? currentTimeHour,
  }) {
    if (series.tempPoints.isEmpty) return;

    canvas.save();
    canvas.translate(offsetX, 0);

    final curve = WeatherChartCurve(
      size: plotSize,
      plotPadding: EdgeInsets.zero,
      minX: WeatherForecastChart.minX,
      maxX: WeatherForecastChart.maxX,
      minY: axisMinY,
      maxY: axisMaxY,
    );

    if (!paintWeatherChartPlotCached(
      canvas: canvas,
      curve: curve,
      series: series,
      gradientStartHour: gradientStartHour,
      tempFillColor: tempFillColor,
      rainFillColor: rainFillColor,
      tempLineColor: tempLineColor,
      degreeGridColor: degreeGridColor,
      showDegreeGrid: true,
      currentTimeHour: currentTimeHour,
    )) {
      final spots = [
        for (final point in series.tempPoints)
          FlSpot(point.hour, point.tempC),
      ];
      _paintWeatherPlot(
        canvas: canvas,
        series: series,
        curve: curve,
        spots: spots,
        gradientStartHour: gradientStartHour,
        tempFillColor: tempFillColor,
        rainFillColor: rainFillColor,
        tempLineColor: tempLineColor,
        degreeGridColor: degreeGridColor,
        showDegreeGrid: true,
        currentTimeHour: currentTimeHour,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WeatherFilmStripPainter oldDelegate) {
    return oldDelegate.stripOffsetPx != stripOffsetPx ||
        oldDelegate.earlierSeries != earlierSeries ||
        oldDelegate.laterSeries != laterSeries ||
        oldDelegate.earlierGradientStartHour != earlierGradientStartHour ||
        oldDelegate.laterGradientStartHour != laterGradientStartHour ||
        oldDelegate.axisMinY != axisMinY ||
        oldDelegate.axisMaxY != axisMaxY ||
        oldDelegate.tempFillColor != tempFillColor ||
        oldDelegate.rainFillColor != rainFillColor ||
        oldDelegate.tempLineColor != tempLineColor ||
        oldDelegate.degreeGridColor != degreeGridColor ||
        oldDelegate.earlierCurrentTimeHour != earlierCurrentTimeHour ||
        oldDelegate.laterCurrentTimeHour != laterCurrentTimeHour;
  }
}

void _paintWeatherPlot({
  required Canvas canvas,
  required DayForecastChartSeries series,
  required WeatherChartCurve curve,
  required List<FlSpot> spots,
  required double gradientStartHour,
  required Color tempFillColor,
  required Color rainFillColor,
  required Color tempLineColor,
  required Color degreeGridColor,
  required bool showDegreeGrid,
  double? currentTimeHour,
  _WeatherBucket? hoveredBucket,
  bool allowVerticalOverflow = false,
}) {
  if (spots.isEmpty) return;

  final plotRect = curve.plotRect;
  if (plotRect.width <= 0 || plotRect.height <= 0) return;

  canvas.save();
  if (allowVerticalOverflow) {
    final overshoot = plotRect.height * 4;
    canvas.clipRect(
      Rect.fromLTRB(
        plotRect.left,
        plotRect.top - overshoot,
        plotRect.right,
        plotRect.bottom + overshoot,
      ),
    );
  } else {
    canvas.clipRect(plotRect);
  }

  final belowPath = curve.belowCurvePath(spots);
  final linePath = curve.curvedLinePath(spots);

  _paintWeatherFill(
    canvas: canvas,
    series: series,
    curve: curve,
    belowPath: belowPath,
    gradientStartHour: gradientStartHour,
    tempFillColor: tempFillColor,
    rainFillColor: rainFillColor,
    hoveredBucket: hoveredBucket,
  );

  if (showDegreeGrid) {
    _paintDegreeGrid(
      canvas: canvas,
      curve: curve,
      belowPath: belowPath,
      degreeGridColor: degreeGridColor,
    );
  }

  canvas.drawPath(
    linePath,
    Paint()
      ..color = tempLineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round,
  );

  if (currentTimeHour != null) {
    _paintCurrentTimeLine(
      canvas: canvas,
      curve: curve,
      spots: spots,
      currentTimeHour: currentTimeHour,
    );
  }

  canvas.restore();
}

void _paintWeatherFill({
  required Canvas canvas,
  required DayForecastChartSeries series,
  required WeatherChartCurve curve,
  required Path belowPath,
  required double gradientStartHour,
  required Color tempFillColor,
  required Color rainFillColor,
  _WeatherBucket? hoveredBucket,
}) {
  if (series.tempPoints.isEmpty) return;

  canvas.save();
  canvas.clipPath(belowPath);

  final fillStartHour = series.tempPoints.first.hour;
  final fillEndHour = series.tempPoints.last.hour;
  final startPx = curve.pixelX(fillStartHour).ceil();
  final endPx = curve.pixelX(fillEndHour).floor();
  final plotRect = curve.plotRect;

  final hoverStartPx = hoveredBucket == null
      ? null
      : curve.pixelX(hoveredBucket.startHour).round();
  final hoverEndPx = hoveredBucket == null
      ? null
      : curve.pixelX(hoveredBucket.endHour).round();

  const hoverLighten = 0.22;
  var runStart = startPx.toDouble();
  Color? runColor;

  void flushRun(double runEnd) {
    final color = runColor;
    if (color == null || runEnd <= runStart) return;
    canvas.drawRect(
      Rect.fromLTRB(runStart, plotRect.top, runEnd, plotRect.bottom),
      Paint()..color = color,
    );
  }

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
      fillColor = Color.lerp(fillColor, Colors.white, hoverLighten)!;
    }

    if (runColor == null) {
      runColor = fillColor;
      runStart = px.toDouble();
      continue;
    }

    if (fillColor != runColor) {
      flushRun(px.toDouble());
      runColor = fillColor;
      runStart = px.toDouble();
    }
  }

  flushRun(endPx + 1.0);
  canvas.restore();
}

void _paintDegreeGrid({
  required Canvas canvas,
  required WeatherChartCurve curve,
  required Path belowPath,
  required Color degreeGridColor,
}) {
  final rect = curve.plotRect;
  if (rect.width <= 0 || rect.height <= 0) return;

  final paint = Paint()
    ..color = degreeGridColor
    ..strokeWidth = 0.5;

  final firstDeg = curve.minY.ceil();
  final lastDeg = curve.maxY.floor();
  if (firstDeg > lastDeg) return;

  canvas.save();
  canvas.clipPath(belowPath);

  for (var deg = firstDeg; deg <= lastDeg; deg++) {
    if (deg <= curve.minY || deg >= curve.maxY) continue;
    final y = curve.pixelY(deg.toDouble());
    canvas.drawLine(
      Offset(rect.left, y),
      Offset(rect.right, y),
      paint,
    );
  }

  canvas.restore();
}

void _paintCurrentTimeLine({
  required Canvas canvas,
  required WeatherChartCurve curve,
  required List<FlSpot> spots,
  required double currentTimeHour,
}) {
  final curvePoint = curve.pointOnCurveAtX(spots, currentTimeHour);
  if (curvePoint == null) return;

  final bottom = curve.plotRect.bottom;
  final paint = Paint()
    ..color = Colors.white
    ..strokeWidth = 1.25
    ..strokeCap = StrokeCap.round;

  const dashLength = 3.0;
  const gapLength = 3.0;
  final start = Offset(curvePoint.dx, bottom);
  final end = curvePoint;
  final dx = end.dx - start.dx;
  final dy = end.dy - start.dy;
  final distance = math.sqrt(dx * dx + dy * dy);
  if (distance <= 0) return;

  final unit = Offset(dx / distance, dy / distance);
  var travelled = 0.0;
  var drawing = true;

  while (travelled < distance) {
    final segment = drawing ? dashLength : gapLength;
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
