import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:voyager/domain/services/weather_forecast_chart.dart';
import 'package:voyager/features/shell/weather_chart_curve.dart';

/// Cache key for a recorded weather-plot [ui.Picture].
@immutable
class WeatherChartPlotCacheKey {
  const WeatherChartPlotCacheKey({
    required this.generation,
    required this.seriesHash,
    required this.width,
    required this.height,
    required this.plotPaddingLeft,
    required this.plotPaddingBottom,
    required this.minY,
    required this.maxY,
    required this.gradientStartHour,
    required this.tempFillArgb,
    required this.rainFillArgb,
    required this.tempLineArgb,
    required this.degreeGridArgb,
    required this.showDegreeGrid,
    required this.includeCurrentTimeLine,
  });

  /// Bumped when plot recording semantics change (e.g. clipping, padding).
  static const cacheGeneration = 2;

  final int generation;
  final int seriesHash;
  final double width;
  final double height;
  final double plotPaddingLeft;
  final double plotPaddingBottom;
  final double minY;
  final double maxY;
  final double gradientStartHour;
  final int tempFillArgb;
  final int rainFillArgb;
  final int tempLineArgb;
  final int degreeGridArgb;
  final bool showDegreeGrid;
  final bool includeCurrentTimeLine;

  static int hashSeries(DayForecastChartSeries series) {
    return Object.hashAll([
      for (final point in series.tempPoints)
        Object.hash(point.hour, point.tempC),
      for (final point in series.rainPoints)
        Object.hash(point.hour, point.rainPercent),
      series.minTemp,
      series.maxTemp,
    ]);
  }

  factory WeatherChartPlotCacheKey.from({
    required WeatherChartCurve curve,
    required DayForecastChartSeries series,
    required double gradientStartHour,
    required Color tempFillColor,
    required Color rainFillColor,
    required Color tempLineColor,
    required Color degreeGridColor,
    required bool showDegreeGrid,
    double? currentTimeHour,
  }) {
    return WeatherChartPlotCacheKey(
      generation: cacheGeneration,
      seriesHash: hashSeries(series),
      width: curve.size.width,
      height: curve.size.height,
      plotPaddingLeft: curve.plotPadding.left,
      plotPaddingBottom: curve.plotPadding.bottom,
      minY: curve.minY,
      maxY: curve.maxY,
      gradientStartHour: gradientStartHour,
      tempFillArgb: tempFillColor.toARGB32(),
      rainFillArgb: rainFillColor.toARGB32(),
      tempLineArgb: tempLineColor.toARGB32(),
      degreeGridArgb: degreeGridColor.toARGB32(),
      showDegreeGrid: showDegreeGrid,
      includeCurrentTimeLine: currentTimeHour != null,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is WeatherChartPlotCacheKey &&
        other.generation == generation &&
        other.seriesHash == seriesHash &&
        other.width == width &&
        other.height == height &&
        other.plotPaddingLeft == plotPaddingLeft &&
        other.plotPaddingBottom == plotPaddingBottom &&
        other.minY == minY &&
        other.maxY == maxY &&
        other.gradientStartHour == gradientStartHour &&
        other.tempFillArgb == tempFillArgb &&
        other.rainFillArgb == rainFillArgb &&
        other.tempLineArgb == tempLineArgb &&
        other.degreeGridArgb == degreeGridArgb &&
        other.showDegreeGrid == showDegreeGrid &&
        other.includeCurrentTimeLine == includeCurrentTimeLine;
  }

  @override
  int get hashCode => Object.hash(
        generation,
        seriesHash,
        width,
        height,
        plotPaddingLeft,
        plotPaddingBottom,
        minY,
        maxY,
        gradientStartHour,
        tempFillArgb,
        rainFillArgb,
        tempLineArgb,
        degreeGridArgb,
        showDegreeGrid,
        includeCurrentTimeLine,
      );
}

/// LRU cache of rasterised weather plot layers.
class WeatherChartPlotCache {
  WeatherChartPlotCache._();

  static final instance = WeatherChartPlotCache._();
  static const maxEntries = 20;

  final _entries = <WeatherChartPlotCacheKey, ui.Picture>{};
  final _order = <WeatherChartPlotCacheKey>[];

  ui.Picture? lookup(WeatherChartPlotCacheKey key) => _entries[key];

  void store(WeatherChartPlotCacheKey key, ui.Picture picture) {
    final existing = _entries.remove(key);
    existing?.dispose();
    _order.remove(key);

    while (_order.length >= maxEntries) {
      final evict = _order.removeAt(0);
      _entries.remove(evict)?.dispose();
    }

    _entries[key] = picture;
    _order.add(key);
  }

  void clear() {
    for (final picture in _entries.values) {
      picture.dispose();
    }
    _entries.clear();
    _order.clear();
  }
}
