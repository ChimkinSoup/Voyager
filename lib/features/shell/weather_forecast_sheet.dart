import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/services/weather_forecast_chart.dart';
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

  int get _dayIndex {
    _selectedDayIndex ??= resolveForecastDayIndex(
      widget.forecast.dailySummaries,
      ref.read(weatherForecastLastDayProvider),
    );
    return _selectedDayIndex!;
  }

  void _selectDay(int index) {
    if (index == _dayIndex) return;
    ref.read(weatherForecastLastDayProvider.notifier).state =
        widget.forecast.dailySummaries[index].date;
    setState(() {
      _transitionFromIndex = _dayIndex;
      _selectedDayIndex = index;
    });
  }

  void _onChartTransitionEnd() {
    if (mounted) setState(() => _transitionFromIndex = null);
  }

  DayForecastChartSeries _seriesForDay(int index) {
    return buildDayForecastChartSeries(
      widget.forecast.periods,
      widget.forecast.dailySummaries[index].date,
      now: DateTime.now(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dayFormat = DateFormat('EEE d MMM');
    final updated = DateFormat('d MMM, HH:mm').format(
      widget.forecast.fetchedAt.toLocal(),
    );
    final days = widget.forecast.dailySummaries;
    final selectedDay = days[_dayIndex];
    final chartSeries = _seriesForDay(_dayIndex);
    final now = DateTime.now();
    final showCurrentTimeLine =
        isTodayForecastDay(selectedDay.date, now);
    final fromShowCurrentTimeLine = _transitionFromIndex == null
        ? false
        : isTodayForecastDay(
            days[_transitionFromIndex!].date,
            now,
          );
    final fromSeries = _transitionFromIndex == null
        ? null
        : _seriesForDay(_transitionFromIndex!);

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
                      selected: i == _dayIndex,
                      onTap: () => _selectDay(i),
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
                  toDayIndex: _dayIndex,
                  fromSeries: fromSeries,
                  toSeries: chartSeries,
                  fromGradientStartHour: _transitionFromIndex == null
                      ? 0
                      : forecastRainGradientStartHour(
                          days[_transitionFromIndex!].date,
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
