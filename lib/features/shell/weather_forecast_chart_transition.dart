import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:voyager/domain/services/weather_forecast_chart.dart';
import 'package:voyager/features/shell/weather_forecast_chart.dart';

enum _TransitionPhase { idle, sliding, settlingY }

/// Slides between daily forecast charts, then eases the Y-axis to the new day.
class WeatherForecastChartTransition extends StatefulWidget {
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

  static const slideDuration = Duration(milliseconds: 160);
  static const yAxisDuration = Duration(milliseconds: 210);

  @override
  State<WeatherForecastChartTransition> createState() =>
      _WeatherForecastChartTransitionState();
}

class _WeatherForecastChartTransitionState
    extends State<WeatherForecastChartTransition>
    with TickerProviderStateMixin {
  late final AnimationController _slideController;
  late final Animation<double> _slideAnimation;
  late final AnimationController _yAxisController;
  late final Animation<double> _yAxisAnimation;

  _TransitionPhase _phase = _TransitionPhase.idle;
  DayForecastChartSeries? _outgoingSeries;
  int? _outgoingDayIndex;
  double _fromGradientStartHour = 0;
  double _slideFromMinY = 0;
  double _slideFromMaxY = 1;
  double _targetMinY = 0;
  double _targetMaxY = 1;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: WeatherForecastChartTransition.slideDuration,
    );
    _slideAnimation = CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeInOutCubic,
    );
    _yAxisController = AnimationController(
      vsync: this,
      duration: WeatherForecastChartTransition.yAxisDuration,
    );
    _yAxisAnimation = CurvedAnimation(
      parent: _yAxisController,
      curve: Curves.easeInOutCubic,
    );

    _slideController.addStatusListener(_onSlideStatus);
    _yAxisController.addStatusListener(_onYAxisStatus);

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
      _slideController.stop();
      _yAxisController.stop();
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
    _slideFromMinY = outgoing.minTemp;
    _slideFromMaxY = outgoing.maxTemp;
    _targetMinY = widget.toSeries.minTemp;
    _targetMaxY = widget.toSeries.maxTemp;
    _phase = _TransitionPhase.sliding;
    _yAxisController.reset();
    _slideController.forward(from: 0);
  }

  void _onSlideStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed ||
        _phase != _TransitionPhase.sliding) {
      return;
    }
    if (_yRangesDiffer) {
      setState(() => _phase = _TransitionPhase.settlingY);
      _yAxisController.forward(from: 0);
    } else {
      _finishTransition();
    }
  }

  void _onYAxisStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed &&
        _phase == _TransitionPhase.settlingY) {
      _finishTransition();
    }
  }

  void _finishTransition() {
    if (_phase == _TransitionPhase.idle) return;
    setState(() {
      _phase = _TransitionPhase.idle;
      _outgoingSeries = null;
      _outgoingDayIndex = null;
    });
    widget.onTransitionEnd?.call();
  }

  bool get _yRangesDiffer =>
      (_slideFromMinY - _targetMinY).abs() > 0.05 ||
      (_slideFromMaxY - _targetMaxY).abs() > 0.05;

  bool get _isBusy =>
      _phase != _TransitionPhase.idle ||
      _slideController.isAnimating ||
      _yAxisController.isAnimating;

  @override
  void dispose() {
    _slideController.removeStatusListener(_onSlideStatus);
    _yAxisController.removeStatusListener(_onYAxisStatus);
    _slideController.dispose();
    _yAxisController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.toSeries.isEmpty) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: Listenable.merge([_slideAnimation, _yAxisAnimation]),
      builder: (context, _) {
        if (!_isBusy) {
          return WeatherForecastChart(
            series: widget.toSeries,
            gradientStartHour: widget.toGradientStartHour,
            showCurrentTimeLine: widget.toShowCurrentTimeLine,
          );
        }

        if (_phase == _TransitionPhase.settlingY) {
          final yT = _yAxisAnimation.value;
          return WeatherForecastChart(
            series: widget.toSeries,
            gradientStartHour: widget.toGradientStartHour,
            axisMinY: ui.lerpDouble(_slideFromMinY, _targetMinY, yT)!,
            axisMaxY: ui.lerpDouble(_slideFromMaxY, _targetMaxY, yT)!,
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

        final consecutive =
            (widget.toDayIndex - _outgoingDayIndex!).abs() == 1;
        final forward = widget.toDayIndex > _outgoingDayIndex!;
        final direction = forward ? 1.0 : -1.0;
        final t = _slideAnimation.value;

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final plotWidth = width - WeatherForecastChart.leftAxisWidth;
            final slideDistance = consecutive ? plotWidth : width;
            final fromOffset = -direction * t * slideDistance;
            final toOffset = direction * (1 - t) * slideDistance;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const WeatherChartLegendRow(),
                const SizedBox(height: 8),
                Expanded(
                  child: ClipRect(
                    child: Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        Positioned.fill(
                          child: Transform.translate(
                            offset: Offset(fromOffset, 0),
                            child: WeatherForecastChart(
                              series: outgoing,
                              gradientStartHour: _fromGradientStartHour,
                              axisMinY: _slideFromMinY,
                              axisMaxY: _slideFromMaxY,
                              showLegend: false,
                              showCurrentTimeLine: widget.fromShowCurrentTimeLine,
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: Transform.translate(
                            offset: Offset(toOffset, 0),
                            child: WeatherForecastChart(
                              series: widget.toSeries,
                              gradientStartHour: widget.toGradientStartHour,
                              axisMinY: _slideFromMinY,
                              axisMaxY: _slideFromMaxY,
                              allowOverflow: true,
                              showLegend: false,
                              showCurrentTimeLine: widget.toShowCurrentTimeLine,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
