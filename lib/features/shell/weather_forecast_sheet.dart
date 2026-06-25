import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/services/weather_forecast_chart.dart';
import 'package:voyager/features/shell/weather_chart_curve.dart';
import 'package:voyager/features/shell/weather_chart_transition_warmup.dart';
import 'package:voyager/features/shell/weather_forecast_chart.dart';
import 'package:voyager/features/shell/weather_forecast_chart_transition.dart';

Future<void> showWeatherForecastSheet(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _WeatherForecastDialog(),
  );
}

class _WeatherForecastDialog extends ConsumerWidget {
  const _WeatherForecastDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forecastAsync = ref.watch(weatherForecastProvider);
    final cachedForecast = forecastAsync.value;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: forecastAsync.when(
            loading: () {
              if (cachedForecast != null) {
                return _ForecastBody(forecast: cachedForecast);
              }
              return const Center(child: CircularProgressIndicator());
            },
            error: (error, _) {
              if (cachedForecast != null) {
                return _ForecastBody(forecast: cachedForecast);
              }
              return _ForecastError(
                message: _forecastErrorMessage(error),
                onRetry: () => ref.invalidate(weatherForecastProvider),
              );
            },
            data: (forecast) {
              if (forecast == null) {
                return const _ForecastError(
                  message: 'Set a weather location in Settings first.',
                );
              }
              return _ForecastBody(forecast: forecast);
            },
          ),
        ),
      ),
    );
  }
}

String _forecastErrorMessage(Object error) {
  return error.toString().replaceFirst('Exception: ', '');
}

class _ForecastError extends StatelessWidget {
  const _ForecastError({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ],
      ),
    );
  }
}

class _ForecastBody extends ConsumerStatefulWidget {
  const _ForecastBody({required this.forecast});

  final WeatherForecast forecast;

  @override
  ConsumerState<_ForecastBody> createState() => _ForecastBodyState();
}

class _ForecastBodyState extends ConsumerState<_ForecastBody> {
  int? _selectedDayIndex;
  int? _transitionFromIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _warmVisibleDayPlots());
  }

  void _warmVisibleDayPlots() {
    if (!mounted) return;

    final colors = weatherChartColors(ref);
    final degreeGridColor = Theme.of(context)
        .colorScheme
        .outlineVariant
        .withValues(alpha: 0.15);
    final now = DateTime.now();
    final days = _visibleDays(now);

    for (var i = 0; i < days.length; i++) {
      final series = _seriesForDay(days, i, now);
      if (series.isEmpty) continue;
      final gradientStartHour = forecastRainGradientStartHour(
        days[i].date,
        widget.forecast.fetchedAt,
      );
      warmWeatherChartPlotCache(
        series: series,
        gradientStartHour: gradientStartHour,
        tempColor: colors.temp,
        rainColor: colors.rain,
        degreeGridColor: degreeGridColor,
      );
      warmWeatherChartPlotPicture(
        curve: WeatherChartCurve(
          size: weatherChartWarmupChartSize,
          plotPadding: const EdgeInsets.only(
            left: WeatherForecastChart.leftAxisWidth,
            bottom: WeatherForecastChart.bottomAxisHeight,
          ),
          minX: WeatherForecastChart.minX,
          maxX: WeatherForecastChart.maxX,
          minY: series.minTemp,
          maxY: series.maxTemp,
        ),
        series: series,
        gradientStartHour: gradientStartHour,
        tempFillColor: colors.temp.withValues(alpha: 0.4),
        rainFillColor: colors.rain.withValues(alpha: 0.4),
        tempLineColor: colors.temp,
        degreeGridColor: degreeGridColor,
      );
    }
  }

  List<DailyForecastSummary> _visibleDays(DateTime now) =>
      visibleForecastDays(widget.forecast.dailySummaries, now);

  int _resolveDayIndex(List<DailyForecastSummary> days, DateTime now) {
    return resolveForecastDayIndex(
      days,
      ref.read(weatherForecastLastDayProvider),
      now: now,
    );
  }

  void _selectDay(int index, List<DailyForecastSummary> days) {
    if (index == _selectedDayIndex) return;
    ref.read(weatherForecastLastDayProvider.notifier).state =
        days[index].date;
    setState(() {
      _transitionFromIndex = _selectedDayIndex;
      _selectedDayIndex = index;
    });
  }

  void _onChartTransitionEnd() {
    if (mounted) setState(() => _transitionFromIndex = null);
  }

  DayForecastChartSeries _seriesForDay(
    List<DailyForecastSummary> days,
    int index,
    DateTime now,
  ) {
    return buildDayForecastChartSeries(
      widget.forecast.periods,
      days[index].date,
      now: now,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dayFormat = DateFormat('EEE d MMM');
    final updated =
        '${DateFormat('d MMM').format(widget.forecast.fetchedAt.toLocal())}, ${formatTime12Hour(widget.forecast.fetchedAt)}';
    final now = DateTime.now();
    final days = _visibleDays(now);
    if (days.isEmpty) {
      return const Center(child: Text('No forecast data available.'));
    }

    _selectedDayIndex ??= _resolveDayIndex(days, now);
    final dayIndex = _selectedDayIndex!.clamp(0, days.length - 1);
    if (dayIndex != _selectedDayIndex) {
      _selectedDayIndex = dayIndex;
    }

    final selectedDay = days[dayIndex];
    final chartSeries = _seriesForDay(days, dayIndex, now);
    final showCurrentTimeLine =
        isTodayForecastDay(selectedDay.date, now);
    final fromShowCurrentTimeLine = _transitionFromIndex == null
        ? false
        : isTodayForecastDay(
            days[_transitionFromIndex!.clamp(0, days.length - 1)].date,
            now,
          );
    final fromSeries = _transitionFromIndex == null
        ? null
        : _seriesForDay(
            days,
            _transitionFromIndex!.clamp(0, days.length - 1),
            now,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.forecast.locationLabel != null)
                    Text(
                      widget.forecast.locationLabel!,
                      style: theme.textTheme.titleMedium,
                    ),
                  Text(
                    'Updated $updated',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(PhosphorIconsRegular.x),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Daily', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(
          height: 116,
          child: Row(
            children: [
              for (var i = 0; i < days.length; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: i < days.length - 1 ? 8 : 0),
                    child: _DailyCard(
                      day: days[i],
                      dayFormat: dayFormat,
                      selected: i == dayIndex,
                      onTap: () => _selectDay(i, days),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: chartSeries.isEmpty
              ? Center(
                  child: Text(
                    'No hourly data for ${dayFormat.format(selectedDay.date)}.',
                    textAlign: TextAlign.center,
                  ),
                )
              : WeatherForecastChartTransition(
                  fromDayIndex: _transitionFromIndex,
                  toDayIndex: dayIndex,
                  fromSeries: fromSeries,
                  toSeries: chartSeries,
                  fromGradientStartHour: _transitionFromIndex == null
                      ? 0
                      : forecastRainGradientStartHour(
                          days[_transitionFromIndex!.clamp(0, days.length - 1)]
                              .date,
                          widget.forecast.fetchedAt,
                        ),
                  toGradientStartHour: forecastRainGradientStartHour(
                    selectedDay.date,
                    widget.forecast.fetchedAt,
                  ),
                  fromShowCurrentTimeLine: fromShowCurrentTimeLine,
                  toShowCurrentTimeLine: showCurrentTimeLine,
                  onTransitionEnd: _onChartTransitionEnd,
                ),
        ),
      ],
    );
  }
}

class _DailyCard extends StatelessWidget {
  const _DailyCard({
    required this.day,
    required this.dayFormat,
    required this.selected,
    required this.onTap,
  });

  final DailyForecastSummary day;
  final DateFormat dayFormat;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          height: 116,
          decoration: BoxDecoration(
            color: selected
                ? colorScheme.primaryContainer.withValues(alpha: 0.45)
                : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? colorScheme.primary
                  : colorScheme.outlineVariant.withValues(alpha: 0.5),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  dayFormat.format(day.date),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                ),
                const SizedBox(height: 4),
                Icon(weatherIconData(day.icon), size: 22),
                const SizedBox(height: 4),
                Text(
                  '${day.highC.round()}° / ${day.lowC.round()}°',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  '${day.maxRainChancePercent}%',
                  maxLines: 1,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
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
