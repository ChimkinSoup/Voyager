import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/services/weather_forecast_chart.dart';
import 'package:voyager/features/shell/weather_chart_curve.dart';
import 'package:voyager/features/shell/weather_forecast_chart.dart';

/// Typical plot viewport inside the forecast dialog.
const weatherChartWarmupPlotSize = Size(600, 308);

/// Typical full chart size including axis margins.
const weatherChartWarmupChartSize = Size(640, 336);

DayForecastChartSeries weatherChartWarmupSeries({double baseTemp = 14}) {
  return DayForecastChartSeries(
    tempPoints: [
      (hour: 0, tempC: baseTemp),
      (hour: 6, tempC: baseTemp + 3),
      (hour: 12, tempC: baseTemp + 7),
      (hour: 18, tempC: baseTemp + 2),
      (hour: 24, tempC: baseTemp + 1),
    ],
    rainPoints: [
      (hour: 0, rainPercent: 10),
      (hour: 6, rainPercent: 15),
      (hour: 12, rainPercent: 35),
      (hour: 18, rainPercent: 20),
      (hour: 24, rainPercent: 12),
    ],
    minTemp: baseTemp - 2,
    maxTemp: baseTemp + 9,
    isFullDay: true,
  );
}

/// Pre-records and caches a plot Picture for [series] at [plotSize].
///
/// Called outside of frame callbacks (at idle priority) so it never blocks
/// the rasteriser. The first live render will hit the cache instead of
/// recording a new Picture on the hot path.
void warmWeatherChartPlotCache({
  required DayForecastChartSeries series,
  required double gradientStartHour,
  required Color tempColor,
  required Color rainColor,
  required Color degreeGridColor,
  Size plotSize = weatherChartWarmupPlotSize,
}) {
  warmWeatherChartPlotPicture(
    curve: WeatherChartCurve(
      size: plotSize,
      plotPadding: EdgeInsets.zero,
      minX: WeatherForecastChart.minX,
      maxX: WeatherForecastChart.maxX,
      minY: series.minTemp,
      maxY: series.maxTemp,
    ),
    series: series,
    gradientStartHour: gradientStartHour,
    tempFillColor: tempColor.withValues(alpha: 0.4),
    rainFillColor: rainColor.withValues(alpha: 0.4),
    tempLineColor: tempColor,
    degreeGridColor: degreeGridColor,
  );
}

/// Renders the weather transition stack for a few frames after login so GPU
/// shaders compile before the user opens the forecast dialog.
///
/// **Timing contract with [CalendarMorphWarmup]:**
/// The calendar warmup runs its 2 frames immediately at login. To avoid
/// frame-budget competition we delay our start by [_startDelay], ensuring
/// the calendar shaders finish compiling first. Plot cache population is
/// scheduled at [Priority.idle] so it never blocks a frame.
class WeatherChartTransitionWarmup extends ConsumerStatefulWidget {
  const WeatherChartTransitionWarmup({super.key});

  /// How long to wait after login before starting the weather shader warmup.
  /// Long enough for CalendarMorphWarmup's 4 warmup frames to finish.
  static const _startDelay = Duration(milliseconds: 800);

  @override
  ConsumerState<WeatherChartTransitionWarmup> createState() =>
      _WeatherChartTransitionWarmupState();
}

class _WeatherChartTransitionWarmupState
    extends ConsumerState<WeatherChartTransitionWarmup> {
  bool _done = false;
  int _frame = 0;
  double _stripOffsetPx = 0;
  Timer? _startTimer;

  @override
  void initState() {
    super.initState();
    // Delay so CalendarMorphWarmup gets its four warmup frames uncontested.
    _startTimer = Timer(
      WeatherChartTransitionWarmup._startDelay,
      () {
        if (!mounted) return;
        WidgetsBinding.instance.addPostFrameCallback(_advance);
      },
    );
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    super.dispose();
  }

  void _advance(Duration _) {
    if (!mounted) return;

    // Do NOT call _populatePlotCache() here — that would record ui.Pictures
    // synchronously during a frame callback, blocking the rasteriser.
    // The widget render below triggers paintWeatherChartPlotCached which
    // populates the cache naturally on cache miss (one frame, invisible).
    // Real-data cache population is scheduled at idle priority below.

    _frame++;
    if (_frame >= 3) {
      setState(() => _done = true);
      // Schedule real forecast data cache population at idle priority so it
      // runs between frames and never contends with visible animations.
      SchedulerBinding.instance.scheduleTask<void>(
        _populatePlotCacheIdle,
        Priority.idle,
      );
      return;
    }

    _stripOffsetPx = switch (_frame) {
      0 => 0,
      1 => -weatherChartWarmupPlotSize.width * 0.5,
      _ => -weatherChartWarmupPlotSize.width,
    };
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback(_advance);
  }

  void _populatePlotCacheIdle() {
    if (!mounted) return;

    final colors = weatherChartColors(ref);
    final degreeGridColor = Theme.of(context)
        .colorScheme
        .outlineVariant
        .withValues(alpha: 0.15);

    final forecast = ref.read(weatherForecastProvider).valueOrNull;
    if (forecast != null) {
      final now = DateTime.now();
      final days = visibleForecastDays(forecast.dailySummaries, now);
      for (var i = 0; i < days.length && i < forecastVisibleDayCount; i++) {
        final series = buildDayForecastChartSeries(
          forecast.periods,
          days[i].date,
          now: now,
        );
        if (series.isEmpty) continue;
        warmWeatherChartPlotCache(
          series: series,
          gradientStartHour: forecastRainGradientStartHour(
            days[i].date,
            forecast.fetchedAt,
          ),
          tempColor: colors.temp,
          rainColor: colors.rain,
          degreeGridColor: degreeGridColor,
        );
      }
      return;
    }

    // No forecast yet — warm with synthetic series so shaders are compiled.
    warmWeatherChartPlotCache(
      series: weatherChartWarmupSeries(baseTemp: 14),
      gradientStartHour: 0,
      tempColor: colors.temp,
      rainColor: colors.rain,
      degreeGridColor: degreeGridColor,
    );
    warmWeatherChartPlotCache(
      series: weatherChartWarmupSeries(baseTemp: 18),
      gradientStartHour: 0,
      tempColor: colors.temp,
      rainColor: colors.rain,
      degreeGridColor: degreeGridColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return const SizedBox.shrink();

    final colors = weatherChartColors(ref);
    final degreeGridColor = Theme.of(context)
        .colorScheme
        .outlineVariant
        .withValues(alpha: 0.15);
    final earlier = weatherChartWarmupSeries(baseTemp: 14);
    final later = weatherChartWarmupSeries(baseTemp: 18);

    return SizedBox.shrink(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        maxWidth: weatherChartWarmupChartSize.width,
        maxHeight: weatherChartWarmupChartSize.height,
        child: Opacity(
          opacity: 1 / 255,
          child: SizedBox(
            width: weatherChartWarmupChartSize.width,
            height: weatherChartWarmupChartSize.height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                WeatherForecastChart(
                  series: later,
                  gradientStartHour: 0,
                  axisMinY: later.minTemp,
                  axisMaxY: later.maxTemp,
                  chartFrameOnly: true,
                  showLegend: false,
                ),
                Positioned(
                  left: WeatherForecastChart.leftAxisWidth,
                  top: 0,
                  right: 0,
                  bottom: WeatherForecastChart.bottomAxisHeight,
                  child: WeatherForecastPlotStrip(
                    viewportSize: weatherChartWarmupPlotSize,
                    stripOffsetPx: _stripOffsetPx,
                    earlierSeries: earlier,
                    laterSeries: later,
                    earlierGradientStartHour: 0,
                    laterGradientStartHour: 0,
                    axisMinY: earlier.minTemp,
                    axisMaxY: later.maxTemp,
                    tempColor: colors.temp,
                    rainColor: colors.rain,
                    degreeGridColor: degreeGridColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
