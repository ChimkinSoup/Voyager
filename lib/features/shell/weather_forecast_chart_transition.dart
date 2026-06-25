import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/domain/services/weather_forecast_chart.dart';
import 'package:voyager/features/shell/weather_chart_curve.dart';
import 'package:voyager/features/shell/weather_forecast_chart.dart';

/// Slides plot content between days while the axis frame stays fixed and the
/// Y range eases in place so the scale shift is visible.
class WeatherForecastChartTransition extends ConsumerStatefulWidget {
  const WeatherForecastChartTransition({
    super.key,
    required this.fromDayIndex,
    required this.toDayIndex,
    required this.fromSeries,
    required this.toSeries,
    required this.fromGradientStartHour,
    required this.toGradientStartHour,
    this.fromShowCurrentTimeLine = false,
    this.toShowCurrentTimeLine = false,
    this.onTransitionEnd,
  });

  final int? fromDayIndex;
  final int toDayIndex;
  final DayForecastChartSeries? fromSeries;
  final DayForecastChartSeries toSeries;
  final double fromGradientStartHour;
  final double toGradientStartHour;
  final bool fromShowCurrentTimeLine;
  final bool toShowCurrentTimeLine;
  final VoidCallback? onTransitionEnd;

  static const transitionDuration = Duration(milliseconds: 600);

  @override
  ConsumerState<WeatherForecastChartTransition> createState() =>
      _WeatherForecastChartTransitionState();
}

class _WeatherForecastChartTransitionState
    extends ConsumerState<WeatherForecastChartTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  bool _isTransitioning = false;
  DayForecastChartSeries? _outgoingSeries;
  int? _outgoingDayIndex;
  double _fromGradientStartHour = 0;
  double _fromMinY = 0;
  double _fromMaxY = 1;
  double _targetMinY = 0;
  double _targetMaxY = 1;
  bool _transitionCacheWarmed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: WeatherForecastChartTransition.transitionDuration,
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutCubic,
    );
    _controller.addStatusListener(_onTransitionStatus);

    if (widget.fromDayIndex != null && widget.fromSeries != null) {
      _beginTransition(
        fromDayIndex: widget.fromDayIndex!,
        outgoing: widget.fromSeries!,
      );
    }
  }

  @override
  void didUpdateWidget(covariant WeatherForecastChartTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.toDayIndex != oldWidget.toDayIndex &&
        widget.fromSeries != null) {
      _controller.stop();
      _beginTransition(
        fromDayIndex: widget.fromDayIndex ?? oldWidget.toDayIndex,
        outgoing: widget.fromSeries!,
      );
    }
  }

  void _beginTransition({
    required int fromDayIndex,
    required DayForecastChartSeries outgoing,
  }) {
    _outgoingSeries = outgoing;
    _outgoingDayIndex = fromDayIndex;
    _fromGradientStartHour = widget.fromGradientStartHour;
    _fromMinY = outgoing.minTemp;
    _fromMaxY = outgoing.maxTemp;
    _targetMinY = widget.toSeries.minTemp;
    _targetMaxY = widget.toSeries.maxTemp;
    _isTransitioning = true;
    _transitionCacheWarmed = false;
    _controller.forward(from: 0);
  }

  void _warmTransitionPlotCache(
    DayForecastChartSeries outgoing, {
    required Size plotSize,
  }) {
    final colors = weatherChartColors(ref);
    final degreeGridColor = Theme.of(context)
        .colorScheme
        .outlineVariant
        .withValues(alpha: 0.15);
    final tempFill = colors.temp.withValues(alpha: 0.4);
    final rainFill = colors.rain.withValues(alpha: 0.4);

    warmWeatherChartPlotPicture(
      curve: WeatherChartCurve(
        size: plotSize,
        plotPadding: EdgeInsets.zero,
        minX: WeatherForecastChart.minX,
        maxX: WeatherForecastChart.maxX,
        minY: _fromMinY,
        maxY: _fromMaxY,
      ),
      series: outgoing,
      gradientStartHour: _fromGradientStartHour,
      tempFillColor: tempFill,
      rainFillColor: rainFill,
      tempLineColor: colors.temp,
      degreeGridColor: degreeGridColor,
    );
    warmWeatherChartPlotPicture(
      curve: WeatherChartCurve(
        size: plotSize,
        plotPadding: EdgeInsets.zero,
        minX: WeatherForecastChart.minX,
        maxX: WeatherForecastChart.maxX,
        minY: _targetMinY,
        maxY: _targetMaxY,
      ),
      series: widget.toSeries,
      gradientStartHour: widget.toGradientStartHour,
      tempFillColor: tempFill,
      rainFillColor: rainFill,
      tempLineColor: colors.temp,
      degreeGridColor: degreeGridColor,
    );
  }

  void _onTransitionStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _isTransitioning) {
      _finishTransition();
    }
  }

  void _finishTransition() {
    if (!_isTransitioning) return;
    setState(() {
      _isTransitioning = false;
      _outgoingSeries = null;
      _outgoingDayIndex = null;
    });
    widget.onTransitionEnd?.call();
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onTransitionStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.toSeries.isEmpty) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        if (!_isTransitioning) {
          return WeatherForecastChart(
            series: widget.toSeries,
            gradientStartHour: widget.toGradientStartHour,
            showCurrentTimeLine: widget.toShowCurrentTimeLine,
          );
        }

        final outgoing = _outgoingSeries;
        if (outgoing == null || _outgoingDayIndex == null) {
          return WeatherForecastChart(
            series: widget.toSeries,
            gradientStartHour: widget.toGradientStartHour,
            showCurrentTimeLine: widget.toShowCurrentTimeLine,
          );
        }

        final t = _animation.value;
        final axisMinY = ui.lerpDouble(_fromMinY, _targetMinY, t)!;
        final axisMaxY = ui.lerpDouble(_fromMaxY, _targetMaxY, t)!;

        final forward = widget.toDayIndex > _outgoingDayIndex!;
        final earlierSeries = forward ? outgoing : widget.toSeries;
        final laterSeries = forward ? widget.toSeries : outgoing;
        final earlierGradient = forward
            ? _fromGradientStartHour
            : widget.toGradientStartHour;
        final laterGradient = forward
            ? widget.toGradientStartHour
            : _fromGradientStartHour;
        final earlierShowNow = forward
            ? widget.fromShowCurrentTimeLine
            : widget.toShowCurrentTimeLine;
        final laterShowNow = forward
            ? widget.toShowCurrentTimeLine
            : widget.fromShowCurrentTimeLine;
        final stripOffset = forward ? -t : -(1 - t);

        final colors = weatherChartColors(ref);
        final degreeGridColor = Theme.of(context)
            .colorScheme
            .outlineVariant
            .withValues(alpha: 0.15);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const WeatherChartLegendRow(),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final plotWidth =
                      constraints.maxWidth -
                      WeatherForecastChart.leftAxisWidth;
                  final plotHeight =
                      constraints.maxHeight -
                      WeatherForecastChart.bottomAxisHeight;
                  final viewportSize = Size(plotWidth, plotHeight);
                  final stripOffsetPx = stripOffset * plotWidth;

                  if (!_transitionCacheWarmed) {
                    _transitionCacheWarmed = true;
                    final size = viewportSize;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted || !_isTransitioning) return;
                      _warmTransitionPlotCache(outgoing, plotSize: size);
                    });
                  }

                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      RepaintBoundary(
                        child: WeatherForecastChart(
                          series: widget.toSeries,
                          gradientStartHour: widget.toGradientStartHour,
                          axisMinY: axisMinY,
                          axisMaxY: axisMaxY,
                          chartFrameOnly: true,
                          showLegend: false,
                        ),
                      ),
                      Positioned(
                        left: WeatherForecastChart.leftAxisWidth,
                        top: 0,
                        right: 0,
                        bottom: WeatherForecastChart.bottomAxisHeight,
                        child: ClipRect(
                          child: WeatherForecastPlotStrip(
                            viewportSize: viewportSize,
                            stripOffsetPx: stripOffsetPx,
                            earlierSeries: earlierSeries,
                            laterSeries: laterSeries,
                            earlierGradientStartHour: earlierGradient,
                            laterGradientStartHour: laterGradient,
                            axisMinY: axisMinY,
                            axisMaxY: axisMaxY,
                            tempColor: colors.temp,
                            rainColor: colors.rain,
                            degreeGridColor: degreeGridColor,
                            earlierCurrentTimeHour: earlierShowNow
                                ? _currentTimeHour(earlierSeries)
                                : null,
                            laterCurrentTimeHour:
                                laterShowNow ? _currentTimeHour(laterSeries) : null,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  double? _currentTimeHour(DayForecastChartSeries series) {
    if (series.tempPoints.isEmpty) return null;
    final now = DateTime.now();
    final hour = currentTimeChartHour(now);
    final first = series.tempPoints.first.hour;
    final last = series.tempPoints.last.hour;
    if (hour < first || hour > last) return null;
    return hour;
  }
}
