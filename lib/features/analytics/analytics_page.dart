import 'dart:async';
import 'dart:math' as math;
import 'package:intl/intl.dart';
import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/core/dev/dev_flags.dart';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/services/analytics_service.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/features/dev/dev_calendar_debug_tile.dart';
import 'package:voyager/features/calendar/calendar_grid.dart'
    show calendarPanelBackgroundColor, MonthTitleHeader;
import 'package:voyager/features/calendar/calendar_day_grid.dart'
    show
        WeekdayHeaderRow,
        MonthDayCellStyle,
        calendarWeekdayLabelStyle,
        calendarAdjacentMonthTextOpacity,
        monthDayGridWeekdayHeaderGap,
        monthGridDates;
import 'package:flutter/services.dart';
import 'dart:ui' show lerpDouble;

// ---------------------------------------------------------------------------
// View mode
// ---------------------------------------------------------------------------

enum _AnalyticsViewMode { grid, calendar }

final _analyticsViewModeProvider =
    StateProvider<_AnalyticsViewMode>((_) => _AnalyticsViewMode.grid);

final _calendarSelectedTrackerProvider =
    StateProvider<String?>((_) => null);

final _calendarTimeScaleProvider =
    StateProvider<_CalendarScale>((_) => _CalendarScale.month);

final _calendarViewMonthProvider = StateProvider<DateTime>((ref) {
  final override = ref.watch(devAnalyticsMonthOverrideProvider);
  if (override == DevAnalyticsMonthOverride.fourRows) {
    return DateTime(2026, 2, 1);
  } else if (override == DevAnalyticsMonthOverride.sixRows) {
    return DateTime(2026, 5, 1);
  } else if (override == DevAnalyticsMonthOverride.fiveRows) {
    return DateTime(2026, 7, 1);
  }
  final now = DateTime.now();
  return DateTime(now.year, now.month, 1);
});

final _calendarViewYearProvider =
    StateProvider<int>((_) => DateTime.now().year);

/// Older (top-row) year of the 2-year window shown by [_MonthGridCalendar].
final _calendarViewMonthlyBaseYearProvider =
    StateProvider<int>((_) => DateTime.now().year - 1);

/// Oldest (leftmost) year of the 10-year window shown by [_YearGridCalendar].
final _calendarViewYearlyBaseYearProvider =
    StateProvider<int>((_) => DateTime.now().year - 9);

enum _CalendarScale { month, year }

// ---------------------------------------------------------------------------
// Root page
// ---------------------------------------------------------------------------

class AnalyticsPage extends ConsumerWidget {
  const AnalyticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(allJournalEntriesProvider);
    final trackersAsync = ref.watch(trackersProvider);
    final analytics = ref.watch(analyticsServiceProvider);
    final prompt = ref.watch(periodicPromptServiceProvider);
    final viewMode = ref.watch(_analyticsViewModeProvider);

    return trackersAsync.when(
      data: (trackers) => entriesAsync.when(
        data: (entries) {
          final words = entries.fold<int>(
            0,
            (sum, e) => sum + analytics.countWords(e.body),
          );
          final streak = prompt.longestJournalStreak(entries);
          return KeepAliveScrollView(
            storageKey: ShellPageStorageKeys.analyticsList,
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            children: [
              // ── Global Stats Header ──────────────────────────────────
              _GlobalStatsHeader(
                totalEntries: analytics.totalJournalEntries(entries),
                totalWords: words,
                longestStreak: streak,
                hasTrackers: trackers.isNotEmpty,
                trackers: trackers,
                viewMode: viewMode,
                onViewModeChanged: (m) =>
                    ref.read(_analyticsViewModeProvider.notifier).state = m,
                onCreateTracker: () => _createTracker(context, ref),
              ),
              const SizedBox(height: 12),
              if (trackers.isEmpty)
                const _EmptyTrackersCard()
              else if (viewMode == _AnalyticsViewMode.grid)
                _GridView(trackers: trackers, analytics: analytics)
              else
                _CalendarView(trackers: trackers, analytics: analytics),
              const SizedBox(height: 32),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
    );
  }

  Future<void> _createTracker(BuildContext context, WidgetRef ref) async {
    final tracker = await showDialog<StatisticTracker>(
      context: context,
      builder: (_) => const _TrackerDialog(),
    );
    if (tracker == null) return;
    await ref.read(trackerRepositoryProvider).upsertTracker(tracker);
    ref.invalidate(trackersProvider);
  }
}

// ---------------------------------------------------------------------------
// Global Stats Header
// ---------------------------------------------------------------------------

class _GlobalStatsHeader extends ConsumerWidget {
  const _GlobalStatsHeader({
    required this.totalEntries,
    required this.totalWords,
    required this.longestStreak,
    required this.hasTrackers,
    required this.trackers,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.onCreateTracker,
  });

  final int totalEntries;
  final int totalWords;
  final int longestStreak;
  final bool hasTrackers;
  final List<StatisticTracker> trackers;
  final _AnalyticsViewMode viewMode;
  final ValueChanged<_AnalyticsViewMode> onViewModeChanged;
  final VoidCallback onCreateTracker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Macro stats row
        IntrinsicHeight(
          child: Row(
            children: [
              _StatChip(
                label: 'Entries',
                value: '$totalEntries',
                icon: PhosphorIconsRegular.notebook,
                accent: accent,
              ),
              const SizedBox(width: 10),
              _StatChip(
                label: 'Words',
                value: _formatNumber(totalWords),
                icon: PhosphorIconsRegular.textAa,
                accent: accent,
              ),
              const SizedBox(width: 10),
              _StatChip(
                label: 'Best Streak',
                value: '$longestStreak days',
                icon: PhosphorIconsRegular.flame,
                accent: accent,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    if (hasTrackers) ...[
                      SegmentedButton<_AnalyticsViewMode>(
                        showSelectedIcon: false,
                        style: SegmentedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: _AnalyticsViewMode.grid,
                            icon: Icon(PhosphorIconsRegular.gridNine, size: 16),
                            label: Text('Grid'),
                          ),
                          ButtonSegment(
                            value: _AnalyticsViewMode.calendar,
                            icon: Icon(PhosphorIconsRegular.calendarBlank, size: 16),
                            label: Text('Calendar'),
                          ),
                        ],
                        selected: {viewMode},
                        onSelectionChanged: (set) {
                          if (set.isNotEmpty) onViewModeChanged(set.first);
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (viewMode == _AnalyticsViewMode.calendar) ...[
                      Builder(builder: (ctx) {
                        final selectedId = ref.watch(_calendarSelectedTrackerProvider);
                        final scale = ref.watch(_calendarTimeScaleProvider);
                        final selectedTracker = trackers.cast<StatisticTracker?>().firstWhere(
                          (t) => t?.id == selectedId,
                          orElse: () => trackers.isNotEmpty ? trackers.first : null,
                        );

                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 220,
                              child: VoyagerDropdownButtonFormField<String>(
                                initialValue: selectedTracker?.id,
                                decoration: const InputDecoration(
                                  labelText: 'Statistic',
                                  isDense: true,
                                ),
                                items: trackers
                                    .map(
                                      (t) => DropdownMenuItem(
                                        value: t.id,
                                        child: Text(
                                          t.name,
                                          style: const TextStyle(fontSize: 13),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (id) => ref
                                    .read(_calendarSelectedTrackerProvider.notifier)
                                    .state = id,
                              ),
                            ),
                            if (selectedTracker != null) ...[
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 16),
                                onPressed: () async {
                                  final updated = await showDialog<StatisticTracker>(
                                    context: ctx,
                                    builder: (_) => _TrackerDialog(tracker: selectedTracker),
                                  );
                                  if (updated == null) return;
                                  await ref.read(trackerRepositoryProvider).upsertTracker(updated);
                                  ref.invalidate(trackersProvider);
                                },
                              ),
                            ],
                            const SizedBox(width: 8),

                          ],
                        );
                      }),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: onCreateTracker,
              icon: const Icon(PhosphorIconsRegular.plus, size: 16),
              label: const Text('New tracker'),
            ),
          ],
        ),
      ],
    );
  }

  String _formatNumber(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
    required this.icon,
    required this.accent,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withValues(alpha: 0.18)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: accent),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyTrackersCard extends StatelessWidget {
  const _EmptyTrackersCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              PhosphorIconsRegular.chartBar,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'No trackers yet. Create one to start logging custom stats.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grid View — Sparkline Stack + Heatmap Grid
// ---------------------------------------------------------------------------

class _GridView extends StatelessWidget {
  const _GridView({required this.trackers, required this.analytics});

  final List<StatisticTracker> trackers;
  final AnalyticsService analytics;

  @override
  Widget build(BuildContext context) {
    final consecutive = trackers
        .where((t) => t.effectiveTrackingStyle == TrackerStyle.consecutive)
        .toList();
    final heatmap = trackers
        .where((t) => t.effectiveTrackingStyle != TrackerStyle.consecutive)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (consecutive.isNotEmpty) ...[
          _SectionLabel(
            icon: PhosphorIconsRegular.chartLineUp,
            label: 'Consecutive',
          ),
          const SizedBox(height: 8),
          _SparklineStack(trackers: consecutive, analytics: analytics),
          if (heatmap.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
          ],
        ],
        if (heatmap.isNotEmpty) ...[
          _SectionLabel(
            icon: PhosphorIconsRegular.squaresFour,
            label: 'Heatmap',
          ),
          const SizedBox(height: 8),
          _HeatmapGrid(trackers: heatmap, analytics: analytics),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon,
            size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 1.0,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sparkline Stack
// ---------------------------------------------------------------------------

class _SparklineStack extends ConsumerWidget {
  const _SparklineStack({required this.trackers, required this.analytics});

  final List<StatisticTracker> trackers;
  final AnalyticsService analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        for (final tracker in trackers)
          _SparklineRow(tracker: tracker, analytics: analytics),
      ],
    );
  }
}

class _SparklineRow extends ConsumerWidget {
  const _SparklineRow({required this.tracker, required this.analytics});

  final StatisticTracker tracker;
  final AnalyticsService analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(trackerValuesProvider(tracker.id));
    final theme = Theme.of(context);
    final color = Color(tracker.colorValue);

    return Container(
      height: 120,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left side: Labels
          SizedBox(
            width: 140,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  tracker.name,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  tracker.cadence.name,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Middle: Chart
          Expanded(
            child: valuesAsync.when(
              data: (values) {
                if (values.isEmpty) {
                  return const Center(
                    child: Text('No data', style: TextStyle(fontSize: 10)),
                  );
                }
                final now = DateTime.now();
                final nowLocal = DateTime(now.year, now.month, now.day);
                final from = switch (tracker.cadence) {
                  TrackerCadence.daily => nowLocal.subtract(const Duration(days: 29)),
                  TrackerCadence.weekly => nowLocal.subtract(const Duration(days: 29 * 7)),
                  TrackerCadence.monthly => DateTime(nowLocal.year, nowLocal.month - 29, 1),
                  TrackerCadence.yearly => DateTime(nowLocal.year - 29, 1, 1),
                };
                final bottomTitleInterval = switch (tracker.cadence) {
                  TrackerCadence.daily => 10.0,
                  TrackerCadence.weekly => 70.0,
                  TrackerCadence.monthly => 300.0,
                  TrackerCadence.yearly => 3650.0,
                };
                final verticalGridInterval = switch (tracker.cadence) {
                  TrackerCadence.daily => 5.0,
                  TrackerCadence.weekly => 35.0,
                  TrackerCadence.monthly => 150.0,
                  TrackerCadence.yearly => 1825.0,
                };
                final spots = analytics.interpolateConsecutive(
                  values: values,
                  from: from,
                  to: now,
                );
                if (spots.isEmpty) {
                  return const Center(
                    child: Text('No data', style: TextStyle(fontSize: 10)),
                  );
                }
                final maxY = spots
                    .map((s) => s.y)
                    .fold<double>(1, (m, y) => y > m ? y : m);
                return LineChart(
                  LineChartData(
                    lineTouchData: LineTouchData(
                      // Large threshold so hovering anywhere between two
                      // interpolated points still resolves to the nearest
                      // spot instead of leaving "dead" gaps with no tooltip.
                      touchSpotThreshold: 10000,
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipColor: (_) => calendarPanelBackgroundColor(context),
                        getTooltipItems: (touchedSpots) => touchedSpots
                            .map(
                              (spot) => LineTooltipItem(
                                spot.y.toStringAsFixed(1),
                                TextStyle(
                                  color: color,
                                  fontWeight: FontWeight.normal,
                                  fontSize: 12,
                                ),
                              ),
                            )
                            .toList(),
                      ),
                      touchCallback: (FlTouchEvent event, LineTouchResponse? response) {
                        if (event is FlTapUpEvent &&
                            response != null &&
                            response.lineBarSpots != null &&
                            response.lineBarSpots!.isNotEmpty) {
                          final spot = response.lineBarSpots!.first;
                          final date = from.add(Duration(days: spot.x.toInt()));
                          final localOffset = event.localPosition;
                          if (localOffset != null) {
                            final box = context.findRenderObject() as RenderBox?;
                            if (box != null) {
                              final globalOffset = box.localToGlobal(localOffset);
                              final rect = globalOffset & const Size(1, 1);
                              final value = values.cast<TrackerValue?>().firstWhere(
                                (v) =>
                                    v != null &&
                                    v.periodStart.year == date.year &&
                                    v.periodStart.month == date.month &&
                                    v.periodStart.day == date.day,
                                orElse: () => null,
                              );
                              _showHeatmapPopover(
                                context: context,
                                tracker: tracker,
                                periodDate: date,
                                anchorRect: rect,
                                initialValue: value,
                                onSaved: () {
                                  ref.invalidate(trackerValuesProvider(tracker.id));
                                },
                              );
                            }
                          }
                        }
                      },
                    ),
                    minY: 0,
                    maxY: maxY <= 0 ? 1 : maxY * 1.15,
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: true,
                      verticalInterval: verticalGridInterval,
                      getDrawingVerticalLine: (_) => FlLine(
                        color: Colors.grey.withValues(alpha: 0.15),
                        strokeWidth: 1,
                      ),
                      getDrawingHorizontalLine: (_) => FlLine(
                        color: theme.colorScheme.outline.withValues(alpha: 0.1),
                        strokeWidth: 1,
                      ),
                    ),
                    titlesData: FlTitlesData(
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 24,
                          getTitlesWidget: (v, _) => Text(
                            v.toInt().toString(),
                            style: theme.textTheme.labelSmall?.copyWith(fontSize: 9),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 18,
                          interval: bottomTitleInterval,
                          getTitlesWidget: (v, _) {
                            final date = from.add(Duration(days: v.toInt()));
                            return Text(
                              DateFormat('MMM d').format(date),
                              style: theme.textTheme.labelSmall?.copyWith(fontSize: 8),
                            );
                          },
                        ),
                      ),
                    ),
                    borderData: FlBorderData(
                      show: true,
                      border: Border(
                        bottom: BorderSide(
                          color: Colors.white.withValues(alpha: 0.15),
                          width: 1,
                        ),
                        left: BorderSide(
                          color: Colors.white.withValues(alpha: 0.15),
                          width: 1,
                        ),
                      ),
                    ),
                    lineBarsData: [
                      LineChartBarData(
                        spots: spots,
                        isCurved: true,
                        preventCurveOverShooting: true,
                        preventCurveOvershootingThreshold: 0,
                        color: color.withValues(alpha: 0.9),
                        barWidth: 1.5,
                        dotData: const FlDotData(show: false),
                        belowBarData: BarAreaData(
                          show: true,
                          color: color.withValues(alpha: 0.15),
                        ),
                      ),
                    ],
                  ),
                );
              },
              loading: () => const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              error: (_, __) => const SizedBox.expand(),
            ),
          ),
          const SizedBox(width: 12),
          // Right: Edit Button
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 16),
              color: theme.colorScheme.onSurfaceVariant,
              onPressed: () async {
                final updated = await showDialog<StatisticTracker>(
                  context: context,
                  builder: (_) => _TrackerDialog(tracker: tracker),
                );
                if (updated == null) return;
                await ref.read(trackerRepositoryProvider).upsertTracker(updated);
                ref.invalidate(trackersProvider);
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Heatmap Grid
// ---------------------------------------------------------------------------

/// Sort comparator for trackers within a single group (starred, or one
/// cadence): manual [StatisticTracker.sortOrder] first, falling back to
/// creation order so freshly-created trackers — which all default to
/// sortOrder 0 — still land in a stable, sensible position.
int _compareTrackerOrder(StatisticTracker a, StatisticTracker b) {
  if (a.sortOrder != b.sortOrder) return a.sortOrder.compareTo(b.sortOrder);
  return a.createdAt.compareTo(b.createdAt);
}

bool _sameTrackerIds(List<StatisticTracker> a, List<StatisticTracker> b) {
  if (a.length != b.length) return false;
  final ids = a.map((t) => t.id).toSet();
  return b.every((t) => ids.contains(t.id));
}

/// Moves [tracker] to the end of its new group (the starred group if newly
/// starred, otherwise back into its cadence group) when its star is toggled.
Future<void> _toggleTrackerStar(
  WidgetRef ref,
  StatisticTracker tracker,
  List<StatisticTracker> allTrackers,
) async {
  final starring = !tracker.starred;
  final siblings = starring
      ? allTrackers.where((t) => t.starred)
      : allTrackers.where(
          (t) => !t.starred && t.cadence == tracker.cadence && t.id != tracker.id,
        );
  var maxOrder = -1;
  for (final t in siblings) {
    if (t.sortOrder > maxOrder) maxOrder = t.sortOrder;
  }
  await ref.read(trackerRepositoryProvider).upsertTracker(
        tracker.copyWith(starred: starring, sortOrder: maxOrder + 1),
      );
  ref.invalidate(trackersProvider);
}

/// A faint horizontal rule separating groups (starred vs. time-period, or
/// between adjacent time periods) in the heatmap grid.
class _HeatmapGroupDivider extends StatelessWidget {
  const _HeatmapGroupDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Container(
        height: 1,
        color: Colors.white.withValues(alpha: 0.12),
      ),
    );
  }
}

class _HeatmapGrid extends ConsumerWidget {
  const _HeatmapGrid({required this.trackers, required this.analytics});

  final List<StatisticTracker> trackers;
  final AnalyticsService analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final starred = trackers.where((t) => t.starred).toList()
      ..sort(_compareTrackerOrder);

    final byCadence = <TrackerCadence, List<StatisticTracker>>{};
    for (final t in trackers.where((t) => !t.starred)) {
      byCadence.putIfAbsent(t.cadence, () => []).add(t);
    }
    for (final group in byCadence.values) {
      group.sort(_compareTrackerOrder);
    }
    final cadenceGroups = TrackerCadence.values
        .where((c) => byCadence.containsKey(c))
        .toList();

    void toggleStar(StatisticTracker tracker) {
      unawaited(_toggleTrackerStar(ref, tracker, trackers));
    }

    final sections = <Widget>[];
    if (starred.isNotEmpty) {
      sections.add(_HeatmapBucket(
        key: const ValueKey('starred'),
        trackers: starred,
        analytics: analytics,
        onToggleStar: toggleStar,
      ));
      if (cadenceGroups.isNotEmpty) {
        sections.add(const _HeatmapGroupDivider());
      }
    }
    for (var gi = 0; gi < cadenceGroups.length; gi++) {
      if (gi > 0) sections.add(const _HeatmapGroupDivider());
      sections.add(_HeatmapBucket(
        key: ValueKey(cadenceGroups[gi].name),
        trackers: byCadence[cadenceGroups[gi]]!,
        analytics: analytics,
        onToggleStar: toggleStar,
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: sections,
    );
  }
}

// ---------------------------------------------------------------------------
// Heatmap Bucket — one freely-reorderable group (starred, or a single
// cadence). Which groups exist and their relative order (starred, then
// daily < weekly < monthly < yearly) is fixed; only the order *within* a
// group is user-draggable. Each group owns its own [ReorderableListView], so
// an item physically cannot be dragged into a different group's list.
// ---------------------------------------------------------------------------

class _HeatmapBucket extends ConsumerStatefulWidget {
  const _HeatmapBucket({
    super.key,
    required this.trackers,
    required this.analytics,
    required this.onToggleStar,
  });

  final List<StatisticTracker> trackers;
  final AnalyticsService analytics;
  final ValueChanged<StatisticTracker> onToggleStar;

  @override
  ConsumerState<_HeatmapBucket> createState() => _HeatmapBucketState();
}

class _HeatmapBucketState extends ConsumerState<_HeatmapBucket> {
  late List<StatisticTracker> _items;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.trackers);
  }

  @override
  void didUpdateWidget(covariant _HeatmapBucket oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameTrackerIds(widget.trackers, _items)) {
      // Membership changed (tracker added/removed, or starred/unstarred
      // elsewhere) — adopt the incoming order outright.
      _items = List.of(widget.trackers);
      return;
    }
    // Same membership: refresh individual tracker objects (e.g. edited
    // name/color) while preserving the current local drag order, so an
    // in-flight reorder's optimistic UI isn't reverted by an unrelated
    // rebuild before persistence finishes.
    final byId = {for (final t in widget.trackers) t.id: t};
    _items = [for (final t in _items) byId[t.id] ?? t];
  }

  void _handleReorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _items.removeAt(oldIndex);
      _items.insert(newIndex, item);
    });
    unawaited(_persist());
  }

  Future<void> _persist() async {
    final repo = ref.read(trackerRepositoryProvider);
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].sortOrder != i) {
        await repo.upsertTracker(_items[i].copyWith(sortOrder: i));
      }
    }
    ref.invalidate(trackersProvider);
  }

  @override
  Widget build(BuildContext context) {
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderItem: _handleReorder,
      proxyDecorator: (child, index, animation) =>
          Material(type: MaterialType.transparency, child: child),
      children: [
        for (var i = 0; i < _items.length; i++)
          ReorderableDragStartListener(
            key: ValueKey(_items[i].id),
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _HeatmapRow(
                tracker: _items[i],
                analytics: widget.analytics,
                onToggleStar: () => widget.onToggleStar(_items[i]),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Single Heatmap Row
// ---------------------------------------------------------------------------

class _HeatmapRow extends ConsumerWidget {
  const _HeatmapRow({
    required this.tracker,
    required this.analytics,
    required this.onToggleStar,
  });

  final StatisticTracker tracker;
  final AnalyticsService analytics;
  final VoidCallback onToggleStar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(trackerValuesProvider(tracker.id));
    final theme = Theme.of(context);
    final color = Color(tracker.colorValue);
    final weekStartsMonday =
        ref.watch(settingsProvider).value?.weekStartsOnMonday ?? true;

    return valuesAsync.when(
      data: (values) {
        // Build the last 30 period dates for this cadence
        final periods = _lastNPeriods(30, weekStartsMonday: weekStartsMonday);

        // Compute rolling max over the exact window being displayed, so
        // normalisation doesn't miss values that fall outside a fixed
        // lookback (e.g. 30 monthly periods span ~2.5 years).
        final windowDays =
            DateTime.now().difference(periods.first).inDays + 1;
        final max = analytics.rollingMax(values, days: windowDays);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Label row
            Row(
              children: [
                CircleAvatar(
                  radius: 5,
                  backgroundColor: color,
                ),
                const SizedBox(width: 6),
                Text(
                  tracker.name,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
                const SizedBox(width: 6),
                Text(
                  '(${_typeLabel(tracker.type)})',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    tracker.starred
                        ? PhosphorIconsFill.star
                        : PhosphorIconsRegular.star,
                    size: 14,
                  ),
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                  color: tracker.starred
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  onPressed: onToggleStar,
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 14),
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                  color: theme.colorScheme.onSurfaceVariant,
                  onPressed: () async {
                    final updated = await showDialog<StatisticTracker>(
                      context: context,
                      builder: (_) => _TrackerDialog(tracker: tracker),
                    );
                    if (updated == null) return;
                    await ref.read(trackerRepositoryProvider).upsertTracker(updated);
                    ref.invalidate(trackersProvider);
                  },
                ),
              ],
            ),
             const SizedBox(height: 4),
            // Squares stretched to fill the row width
            LayoutBuilder(builder: (ctx, constraints) {
              const gap = 4.0;
              final squareSize =
                  ((constraints.maxWidth - gap * periods.length) / periods.length)
                      .clamp(10.0, 40.0);
              return Row(
                children: [
                  for (var i = 0; i < periods.length; i++)
                    Builder(builder: (ctx) {
                      final period = periods[i];
                      final showLabel = (periods.length - 1 - i) % 5 == 0;
                      return Padding(
                        padding: const EdgeInsets.only(right: gap),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _HeatmapSquare(
                              tracker: tracker,
                              values: values,
                              periodDate: period,
                              maxInPeriod: max,
                              analytics: analytics,
                              size: squareSize,
                            ),
                            const SizedBox(height: 4),
                            showLabel
                                ? Text(
                                    _shortDateLabel(period, tracker.cadence),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontSize: 8,
                                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                    ),
                                  )
                                : const Text(
                                    '',
                                    style: TextStyle(fontSize: 8),
                                  ),
                          ],
                        ),
                      );
                    }),
                ],
              );
            }),
          ],
        );
      },
      loading: () => const SizedBox(height: 40, child: LinearProgressIndicator()),
      error: (e, _) => Text('$e'),
    );
  }

  String _shortDateLabel(DateTime date, TrackerCadence cadence) {
    return switch (cadence) {
      TrackerCadence.daily => DateFormat('MMM d').format(date),
      TrackerCadence.weekly => DateFormat('MMM d').format(date),
      TrackerCadence.monthly => DateFormat('MMM yy').format(date),
      TrackerCadence.yearly => DateFormat('yyyy').format(date),
    };
  }

  /// Returns the last [n] period start dates for this tracker's cadence,
  /// oldest first. Weekly periods are anchored to the calendar week start
  /// (matching [_periodStart] and the Calendar view's week grid) rather
  /// than to today's weekday, so a value saved in one view is found by
  /// the other.
  List<DateTime> _lastNPeriods(int n, {required bool weekStartsMonday}) {
    final today = DateTime.now();
    final todayLocal = DateTime(today.year, today.month, today.day);
    final currentWeekStart = todayLocal.subtract(
      Duration(
        days: weekStartsMonday
            ? todayLocal.weekday - DateTime.monday
            : todayLocal.weekday % 7,
      ),
    );
    final periods = <DateTime>[];
    for (var i = n - 1; i >= 0; i--) {
      final candidate = switch (tracker.cadence) {
        TrackerCadence.daily => todayLocal.subtract(Duration(days: i)),
        TrackerCadence.weekly =>
          currentWeekStart.subtract(Duration(days: i * 7)),
        TrackerCadence.monthly =>
          DateTime(todayLocal.year, todayLocal.month - i, 1),
        TrackerCadence.yearly => DateTime(todayLocal.year - i, 1, 1),
      };
      periods.add(candidate);
    }
    return periods;
  }
}

// ---------------------------------------------------------------------------
// Hover tooltip helpers (Grid + Calendar cells)
// ---------------------------------------------------------------------------

String _tooltipPeriodLabel(DateTime date, TrackerCadence cadence) {
  return switch (cadence) {
    TrackerCadence.daily => DateFormat('MMM d, yyyy').format(date),
    TrackerCadence.weekly => 'Week of ${DateFormat('MMM d, yyyy').format(date)}',
    TrackerCadence.monthly => DateFormat('MMMM yyyy').format(date),
    TrackerCadence.yearly => DateFormat('yyyy').format(date),
  };
}

/// A text-legible analogue of the heatmap cells' own alpha-based intensity
/// coloring (see e.g. [_HeatmapSquareState.build]): fading a *fill* toward
/// alpha 0 reads as "faint," but doing the same to thin text glyphs makes
/// them unreadable. Desaturating the tracker's color toward grey instead —
/// same hue/lightness, less saturation — gives the same "faint at low
/// values, vivid at high values" read while staying fully opaque.
Color _heatmapValueColor(Color base, double intensity) {
  final hsl = HSLColor.fromColor(base);
  final t = intensity.clamp(0.0, 1.0);
  final saturation = lerpDouble(0.15, hsl.saturation, t)!;
  return hsl.withSaturation(saturation).toColor();
}

String? _tooltipValueLabel(TrackerType type, TrackerValue? value) {
  if (value == null) return null;
  return switch (type) {
    TrackerType.integer => value.intValue?.toString(),
    TrackerType.boolean =>
      value.boolValue == true ? 'Completed' : 'Not completed',
    TrackerType.enumType =>
      (value.enumValue == null || value.enumValue!.isEmpty)
          ? null
          : value.enumValue!,
  };
}

/// The date's compact "tooltip" appearance — same base metrics (font
/// family/height/letterSpacing) as [_editorDateStyle], just a smaller
/// fontSize, rather than an independently-inherited style. Previously this
/// was its own plain `TextStyle(...)` (inheriting whatever ambient
/// font/height/letterSpacing happened to be in scope) while a *second*,
/// separately-defined style was used as the actual starting point for
/// [TextStyle.lerp] in [_MorphPopoverState.build] — the two didn't
/// necessarily agree on anything but fontSize/color, so the date's
/// rendered glyphs visibly changed shape (read as "changing font size")
/// the instant the popover opened, before the lerp had moved at all. Now
/// there's one definition, used for the real hover tooltip's date text,
/// the placeholder that reserves its layout space, and the lerp's t=0
/// endpoint alike, so all three are pixel-identical by construction.
TextStyle _tooltipDateStyle(ThemeData theme) {
  return _editorDateStyle(theme).copyWith(fontSize: 10);
}

TextStyle _editorDateStyle(ThemeData theme) {
  return (theme.textTheme.bodySmall ?? const TextStyle())
      .copyWith(inherit: false, color: theme.colorScheme.onSurfaceVariant);
}

/// The tooltip's date + value content, shared verbatim between the real
/// hover tooltip ([_HoverEditPopoverState._show]) and the morph popover's
/// reconstruction of it ([_MorphPopoverState._buildTooltipBubble]) — the
/// two previously duplicated this structure by hand and had drifted apart
/// (the morph popover wrapped its [dateKey] Text in an extra [Align] the
/// real tooltip didn't have), which showed up as the value text visibly
/// shifting position the instant the popover opened. Building both from
/// this single function instead guarantees they lay out identically; only
/// [dateOpacity] differs (0 in the morph popover, where the date is drawn
/// by a separate floating layer instead).
///
/// Wrapped in its own transparent [Material] (the same
/// `MaterialType.transparency` trick [_MorphPopoverState._buildEditorContent]
/// already uses) rather than relying on an ambient one from a caller: the
/// value [Text] below doesn't set its own `height`/line-height, so it
/// inherits whatever [DefaultTextStyle] happens to be nearest above it — the
/// real tooltip provided one via its own `Material`, but the morph popover's
/// bubble didn't, so the *same* value text resolved a different line-height
/// (and so a different vertical position within its own line box) in the two
/// places even though the text itself was identical. A self-contained
/// `Material` here means both callers get the same ambient style regardless
/// of what surrounds them.
Widget _tooltipDateValueColumn({
  required String periodLabel,
  required String? valueLabel,
  required ThemeData theme,
  Key? dateKey,
  double dateOpacity = 1,
  Color? valueColor,
}) {
  return Material(
    type: MaterialType.transparency,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Opacity(
          opacity: dateOpacity,
          child: Text(
            periodLabel,
            key: dateKey,
            textAlign: TextAlign.right,
            style: _tooltipDateStyle(theme),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          valueLabel ?? '–',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: valueLabel == null
                ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
                : (valueColor ?? theme.colorScheme.onSurface),
            fontWeight: FontWeight.normal,
            fontSize: 14,
          ),
        ),
      ],
    ),
  );
}

/// Wraps [child] with a hover tooltip showing the period label (small, top
/// right) and the value (centered, regular size — a greyed "–" if there's
/// no entry yet). Clicking morphs the same popup in place into the value
/// editor — see [_HoverEditPopover].
Widget _hoverTooltip({
  required BuildContext context,
  required String periodLabel,
  required TrackerType type,
  required TrackerValue? value,
  required StatisticTracker tracker,
  required DateTime periodDate,
  required VoidCallback onSaved,
  required Widget child,
  Color? valueColor,
}) {
  return _HoverEditPopover(
    periodLabel: periodLabel,
    valueLabel: _tooltipValueLabel(type, value),
    valueColor: valueColor,
    tracker: tracker,
    periodDate: periodDate,
    initialValue: value,
    onSaved: onSaved,
    child: child,
  );
}

/// Wraps [child] with a hover tooltip showing the period label (small, top
/// right) and the value (centered, regular size — a greyed "–" if there's
/// no entry yet). This is a plain, transient overlay entry — the same kind
/// Flutter/this app already renders without issue — kept deliberately
/// simple; the editor (heavier, interactive, longer-lived) is opened as a
/// proper route by [_showMorphPopover] instead of folded into this same
/// overlay entry, since that combination is what triggered overlay/element
/// tree corruption in this app's go_router setup.
class _HoverEditPopover extends StatefulWidget {
  const _HoverEditPopover({
    required this.periodLabel,
    required this.valueLabel,
    this.valueColor,
    required this.tracker,
    required this.periodDate,
    required this.initialValue,
    required this.onSaved,
    required this.child,
  });

  final String periodLabel;
  final String? valueLabel;
  final Color? valueColor;
  final StatisticTracker tracker;
  final DateTime periodDate;
  final TrackerValue? initialValue;
  final VoidCallback onSaved;
  final Widget child;

  @override
  State<_HoverEditPopover> createState() => _HoverEditPopoverState();
}

class _HoverEditPopoverState extends State<_HoverEditPopover> {
  final _key = GlobalKey();
  final _tooltipKey = GlobalKey();
  final _tooltipDateKey = GlobalKey();
  OverlayEntry? _entry;

  /// The tooltip bubble's own on-screen rect (not the cell's) — this is
  /// what the edit popover expands out of. Starts as an estimate and is
  /// corrected to the real measured rect once the bubble has laid out.
  Rect? _lastRect;

  Rect? _measure() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Rect? _measureTooltip() {
    final box = _tooltipKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// The date text's own on-screen rect within the tooltip. Passed straight
  /// into [_MorphPopover] as its starting point for the date, so the morph
  /// popover's date-slide layer has a real position from its very first
  /// frame instead of only after its own post-frame remeasurement — which
  /// otherwise left the date invisible for a frame and made it "pop in"
  /// right as the popover opened.
  Rect? _measureTooltipDate() {
    final box =
        _tooltipDateKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _show() {
    if (_entry != null) return;
    final anchor = _measure();
    if (anchor == null) return;
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    const estWidth = 120.0;
    const estHeight = 46.0;
    const margin = 8.0;

    final left = anchor.left
        .clamp(margin, math.max(margin, screen.width - margin - estWidth))
        .toDouble();
    var top = anchor.top - margin - estHeight;
    if (top < margin) top = anchor.bottom + margin;
    _lastRect = Rect.fromLTWH(left, top, estWidth, estHeight);

    _entry = OverlayEntry(
      builder: (ctx) => Positioned(
        left: left,
        top: top,
        child: IgnorePointer(
          child: IntrinsicWidth(
            key: _tooltipKey,
            // No Material of its own here — [_tooltipDateValueColumn]
            // provides one, so the ambient DefaultTextStyle it resolves is
            // the same regardless of what's around it (see that function's
            // doc comment).
            child: Container(
              constraints: const BoxConstraints(minWidth: 64),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: calendarPanelBackgroundColor(context),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: _tooltipDateValueColumn(
                periodLabel: widget.periodLabel,
                valueLabel: widget.valueLabel,
                valueColor: widget.valueColor,
                theme: theme,
                dateKey: _tooltipDateKey,
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final measured = _measureTooltip();
      if (measured != null) _lastRect = measured;
    });
  }

  void _hide() {
    _entry?.remove();
    _entry = null;
  }

  void _handleTap() {
    // Measure the tooltip's actual on-screen rect synchronously rather than
    // trusting [_lastRect] (which starts as an estimate and is only
    // corrected a frame after the tooltip is shown) — otherwise the morph's
    // start rect can be slightly off from what's really on screen, showing
    // up as a small pop/shift right as the animation begins.
    final startRect = _measureTooltip() ?? _lastRect ?? _measure();
    // Measured before [_hide] removes the tooltip's overlay entry (and with
    // it, the render objects being measured).
    final startDateRect = _measureTooltipDate();
    _hide();
    if (startRect != null) {
      _showMorphPopover(
        context: context,
        tracker: widget.tracker,
        periodDate: widget.periodDate,
        anchorRect: startRect,
        anchorDateRect: startDateRect,
        initialValue: widget.initialValue,
        periodLabel: widget.periodLabel,
        valueLabel: widget.valueLabel,
        valueColor: widget.valueColor,
        onSaved: widget.onSaved,
      );
    }
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      key: _key,
      onEnter: (_) => _show(),
      onExit: (_) => _hide(),
      child: GestureDetector(
        onTap: _handleTap,
        child: widget.child,
      ),
    );
  }
}

/// Opens [_MorphPopover] with a custom route transition that expands it out
/// from [anchorRect] (the hover tooltip's own on-screen rect). Opening
/// animates; closing is instant (no reverse transition), per design.
Future<void> _showMorphPopover({
  required BuildContext context,
  required StatisticTracker tracker,
  required DateTime periodDate,
  required Rect anchorRect,
  required Rect? anchorDateRect,
  required TrackerValue? initialValue,
  required String periodLabel,
  required String? valueLabel,
  Color? valueColor,
  required VoidCallback onSaved,
}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      // No built-in route transition — [_MorphPopover] drives its own
      // geometry animation, and only starts moving once it has measured
      // its real end size, so there's never a frame where the route's own
      // clock has run ahead of geometry that isn't known yet.
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (ctx, animation, secondaryAnimation) => _MorphPopover(
        tracker: tracker,
        periodDate: periodDate,
        anchorRect: anchorRect,
        anchorDateRect: anchorDateRect,
        initialValue: initialValue,
        periodLabel: periodLabel,
        valueLabel: valueLabel,
        valueColor: valueColor,
        onSaved: onSaved,
      ),
    ),
  );
}

/// The value editor, opened as a real route (like [_HeatmapPopover]) rather
/// than a raw overlay entry — this app's go_router setup tolerates a simple
/// transient overlay entry (the hover tooltip) and a full interactive route
/// fine individually, but corrupted the element tree when both were merged
/// into one long-lived overlay entry carrying focusable/interactive
/// content.
///
/// The morph itself follows the same technique as the calendar's
/// month↔week transition (see `_MorphLayoutDelegate`/`_MonthWeekMorphLayer`
/// in calendar_page.dart): a single "frame" — just the background, border
/// and shadow, no content — is positioned with [Positioned.fromRect] at
/// `Rect.lerp(tooltipRect, cardRect, t)` every frame, so the *actual shape*
/// on screen moves and resizes continuously from the tooltip's bounds to
/// the card's bounds. It's one shape the whole time, not a static card
/// revealed through a moving clip window. Content (tooltip text vs. the
/// editor form) is a separate cross-fading layer pinned at each end's own
/// position, since unlike the calendar's day cells the two contents aren't
/// similar enough to interpolate directly — but the frame's own continuous
/// motion is what reads as "one popup morphing" rather than two swapping.
class _MorphPopover extends ConsumerStatefulWidget {
  const _MorphPopover({
    required this.tracker,
    required this.periodDate,
    required this.anchorRect,
    required this.anchorDateRect,
    required this.initialValue,
    required this.periodLabel,
    required this.valueLabel,
    this.valueColor,
    required this.onSaved,
  });

  final StatisticTracker tracker;
  final DateTime periodDate;
  final Rect anchorRect;

  /// The date text's on-screen rect within the hover tooltip it's expanding
  /// from, measured synchronously at tap time (see
  /// [_HoverEditPopoverState._measureTooltipDate]). Seeds [_MorphPopoverState.
  /// _tooltipDateRect] immediately, so the date-slide layer has a real start
  /// position from the very first frame instead of only appearing once this
  /// widget's own post-frame remeasurement completes.
  final Rect? anchorDateRect;
  final TrackerValue? initialValue;
  final String periodLabel;
  final String? valueLabel;
  final Color? valueColor;
  final VoidCallback onSaved;

  @override
  ConsumerState<_MorphPopover> createState() => _MorphPopoverState();
}

class _MorphPopoverState extends ConsumerState<_MorphPopover>
    with TickerProviderStateMixin {
  late final TextEditingController _intController;
  bool? _boolValue;
  String? _enumValue;

  /// Key on the editor's content only (no frame/decoration of its own) —
  /// it's laid out at its natural size the whole time regardless of the
  /// frame's current animated size, so it can be measured immediately and
  /// never has to reflow into a partially-grown box.
  final _cardKey = GlobalKey();
  Rect? _cardRect;
  bool _morphStarted = false;

  /// Keys on the date text in each of its two resting spots (tooltip and
  /// editor). Both instances are rendered invisible (opacity 0, kept only
  /// to hold their layout space) — the date itself is drawn by a single
  /// floating layer in [build] that slides between these two measured
  /// rects, so it never disappears/reappears, it just moves.
  final _tooltipDateKey = GlobalKey();
  final _editorDateKey = GlobalKey();
  Rect? _tooltipDateRect;
  Rect? _editorDateRect;

  /// Drives the frame's position+size morph from the tooltip's rect to the
  /// card's rect. Doesn't start until [_cardRect] is known, so there is no
  /// frame where it's animating toward a wrong/placeholder target.
  late final AnimationController _morphController;

  /// Secondary controls (Save/Delete/Cancel) fade in only once the morph
  /// has finished, per design.
  late final AnimationController _controlsController;

  int get _slowMo => DevFlags.slowHeatmapPopoverAnimation ? 10 : 1;

  @override
  void initState() {
    super.initState();
    _intController = TextEditingController(
      text: widget.initialValue?.intValue?.toString() ?? '',
    );
    _intController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _intController.text.length,
    );
    _boolValue = widget.initialValue?.boolValue ?? widget.tracker.defaultBool;
    _enumValue = widget.initialValue?.enumValue ??
        widget.tracker.defaultEnumOption;
    // Seed from the tooltip's own already-measured date rect (see
    // [_MorphPopover.anchorDateRect]) so the date-slide layer in [build] can
    // render from frame one instead of waiting for [_measure]'s post-frame
    // remeasurement — otherwise the date is invisible for a frame and then
    // pops in right as the popover opens.
    _tooltipDateRect = widget.anchorDateRect;

    _morphController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 240 * _slowMo),
    );
    _controlsController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 150 * _slowMo),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void dispose() {
    _morphController.dispose();
    _controlsController.dispose();
    _intController.dispose();
    super.dispose();
  }

  /// Measures the editor content's natural size — it's never constrained
  /// by the frame's current animated size (see [_buildEditorContent]), so
  /// this is accurate from the very first frame. Computes the card's
  /// resting position the same way the old hover tooltip positioned
  /// itself (prefer above the anchor, flip below only if there's no room),
  /// then starts the morph exactly once.
  void _measure() {
    if (!mounted) return;
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
      return;
    }
    final size = box.size;
    final screen = MediaQuery.sizeOf(context);
    const margin = 8.0;

    var left = widget.anchorRect.left;
    left = left.clamp(margin, math.max(margin, screen.width - margin - size.width));

    // Share a corner with the tooltip rather than floating some distance
    // from it: growing upward, the card's bottom-left lines up with the
    // tooltip's bottom-left; flipped below, its top-left lines up with the
    // tooltip's top-left. Either way the frame's start and end rects touch
    // at that corner, so the morph reads as one shape expanding outward
    // from it instead of leaving a gap.
    var top = widget.anchorRect.bottom - size.height;
    if (top < margin) {
      final below = widget.anchorRect.top;
      top = below + size.height <= screen.height - margin
          ? below
          : screen.height - margin - size.height;
    }
    top = top.clamp(margin, math.max(margin, screen.height - margin - size.height));

    final rect = Offset(left, top) & size;

    // The tooltip content layer is pinned at a constant position
    // (widget.anchorRect), so its date's global rect can be read directly.
    final tooltipDateBox =
        _tooltipDateKey.currentContext?.findRenderObject() as RenderBox?;
    if (tooltipDateBox != null && tooltipDateBox.hasSize) {
      _tooltipDateRect =
          tooltipDateBox.localToGlobal(Offset.zero) & tooltipDateBox.size;
    }

    // The editor content layer is still pinned at widget.anchorRect on this
    // first successful measurement (nothing has set _cardRect yet), so its
    // date's current global position minus that origin gives its offset
    // *within* the card. Re-anchor that offset to the card's real resting
    // position (`rect`) so the target is correct even though the card
    // hasn't actually moved there yet.
    final editorDateBox =
        _editorDateKey.currentContext?.findRenderObject() as RenderBox?;
    if (editorDateBox != null && editorDateBox.hasSize) {
      final localOffset =
          editorDateBox.localToGlobal(Offset.zero) - widget.anchorRect.topLeft;
      _editorDateRect = (rect.topLeft + localOffset) & editorDateBox.size;
    }

    if (rect != _cardRect) {
      setState(() => _cardRect = rect);
    }
    if (!_morphStarted) {
      _morphStarted = true;
      _morphController.forward().whenComplete(() {
        if (mounted) _controlsController.forward();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Color(widget.tracker.colorValue);
    final cardRect = _cardRect ?? widget.anchorRect;

    return Stack(
      children: [
        // Dismiss tapping outside
        Positioned.fill(
          child: GestureDetector(
            onTap: _handleOutsideTap,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),
        // The frame: the one shape that actually moves and resizes from
        // the tooltip's rect to the card's rect, every frame — this is
        // what makes it read as a single popup morphing, not two
        // separate popups shrinking/growing independently.
        AnimatedBuilder(
          animation: _morphController,
          builder: (context, _) {
            final t = Curves.easeInOutCubic.transform(_morphController.value);
            final rect = Rect.lerp(widget.anchorRect, cardRect, t)!;
            return Positioned.fromRect(
              rect: rect,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color.lerp(
                    calendarPanelBackgroundColor(context),
                    theme.colorScheme.surface,
                    t,
                  ),
                  borderRadius: BorderRadius.lerp(
                    BorderRadius.circular(8),
                    BorderRadius.circular(12),
                    t,
                  ),
                  border: Border.lerp(
                    Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    Border.all(color: accent, width: 3),
                    t,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: popupGlowAlpha * t),
                      blurRadius: 12 * t,
                      spreadRadius: 2 * t,
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35 * t),
                      blurRadius: 10 * t,
                      offset: Offset(0, 4 * t),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        // Tooltip content — pinned at the tooltip's own rect, fades out
        // early in the morph.
        Positioned(
          left: widget.anchorRect.left,
          top: widget.anchorRect.top,
          child: IgnorePointer(
            child: FadeTransition(
              opacity: Tween<double>(begin: 1, end: 0).animate(
                CurvedAnimation(
                  parent: _morphController,
                  curve: const Interval(0.0, 0.3),
                ),
              ),
              child: _buildTooltipBubble(theme),
            ),
          ),
        ),
        // Editor content — pinned at the card's resting position. Stays
        // fully hidden until the frame has completely finished expanding,
        // then fades in via the same controller/timing as the Save/Delete/
        // Cancel row — otherwise its fixed, full size content would appear
        // partway through the expand and overflow the still-growing frame.
        Positioned(
          left: cardRect.left,
          top: cardRect.top,
          child: FadeTransition(
            opacity: _controlsController,
            child: _buildEditorContent(theme, accent),
          ),
        ),
        // The date text — the one piece of content that's continuously
        // visible throughout: instead of fading out of the tooltip and
        // back in on the editor, it slides from its measured resting spot
        // in the tooltip to its measured resting spot in the editor, in
        // lockstep with the frame's own morph.
        // Renders as soon as [_tooltipDateRect] is known (seeded
        // synchronously from [widget.anchorDateRect], so that's frame one)
        // rather than waiting on [_editorDateRect] too — the morph hasn't
        // started at that point anyway (t is still 0), so lerping toward
        // the tooltip's own rect as a placeholder end target is a no-op
        // until [_measure] fills in the real editor-side rect.
        if (_tooltipDateRect != null)
          AnimatedBuilder(
            animation: _morphController,
            builder: (context, _) {
              final t = Curves.easeInOutCubic.transform(_morphController.value);
              final origin = Offset.lerp(
                _tooltipDateRect!.topLeft,
                (_editorDateRect ?? _tooltipDateRect!).topLeft,
                t,
              )!;
              return Positioned(
                left: origin.dx,
                top: origin.dy,
                child: IgnorePointer(
                  child: Text(
                    widget.periodLabel,
                    style: TextStyle.lerp(
                      _tooltipDateStyle(theme),
                      _editorDateStyle(theme),
                      t,
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildTooltipBubble(ThemeData theme) {
    return IntrinsicWidth(
      // constraints outside padding, padding accounting for the frame's own
      // 1px resting border — matches exactly how the real hover tooltip's
      // Container (constraints > decoration [which folds in the border's
      // own inset] > padding) sizes itself, so this reconstruction lines
      // up with it pixel-for-pixel instead of drifting by a couple of px.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 7, 11, 7),
          // Shared with the real hover tooltip's own content (see
          // [_tooltipDateValueColumn]) — only the date's opacity differs,
          // since it's drawn here purely to reserve layout space while the
          // visible date text is drawn by the sliding layer in [build].
          child: _tooltipDateValueColumn(
            periodLabel: widget.periodLabel,
            valueLabel: widget.valueLabel,
            valueColor: widget.valueColor,
            theme: theme,
            dateKey: _tooltipDateKey,
            dateOpacity: 0,
          ),
        ),
      ),
    );
  }

  /// Just the editor's content (title row, value editor, buttons) — no
  /// background/border/shadow of its own, since the frame layer in
  /// [build] owns that. Always laid out at its natural width (310) so
  /// [_measure] gets an accurate size regardless of the frame's current
  /// animated size.
  Widget _buildEditorContent(ThemeData theme, Color accent) {
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        key: _cardKey,
        width: 310,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    widget.tracker.name,
                    style: theme.textTheme.titleSmall,
                  ),
                  const Spacer(),
                  // Invisible — only here to reserve layout space. The
                  // visible date text is drawn by the sliding layer in
                  // [build].
                  Opacity(
                    opacity: 0,
                    child: Text(
                      key: _editorDateKey,
                      widget.periodLabel,
                      style: _editorDateStyle(theme),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _valueEditor(theme, accent),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (widget.initialValue != null)
                    TextButton(
                      onPressed: _delete,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      child: const Text('Delete'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
                          ? Colors.white
                          : Colors.black,
                    ),
                    child: const Text('Save'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: Navigator.of(context).pop,
                    style: TextButton.styleFrom(
                      foregroundColor: accent,
                    ),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _valueEditor(ThemeData theme, Color accent) {
    switch (widget.tracker.type) {
      case TrackerType.integer:
        final cap = widget.tracker.integerCap;
        final minVal = widget.tracker.defaultInt;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cap != null) ...[
              Slider(
                min: minVal.toDouble(),
                max: cap.toDouble(),
                divisions: (cap - minVal) <= 0 ? null : (cap - minVal),
                activeColor: accent,
                inactiveColor: accent.withValues(alpha: 0.24),
                value: (int.tryParse(_intController.text) ?? minVal)
                    .clamp(minVal, cap)
                    .toDouble(),
                onChanged: (v) =>
                    setState(() => _intController.text = v.round().toString()),
              ),
            ],
            VoyagerTextField(
              controller: _intController,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              accentColor: accent,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(
                labelText: 'Value',
                isDense: true,
                contentPadding: EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 12),
              ),
            ),
            if (cap != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(
                  '$minVal–$cap',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ],
        );
      case TrackerType.boolean:
        return SwitchListTile(
          contentPadding: const EdgeInsets.only(left: 6, right: 0),
          dense: true,
          title: const Text('Completed'),
          value: _boolValue ?? false,
          activeColor: accent,
          onChanged: (v) => setState(() => _boolValue = v),
        );
      case TrackerType.enumType:
        final options = widget.tracker.enumOptions;
        return VoyagerDropdownButtonFormField<String>(
          initialValue: options.contains(_enumValue) ? _enumValue : null,
          accentColor: accent,
          decoration: const InputDecoration(
            labelText: 'Value',
            isDense: true,
          ),
          items: options
              .map((o) => DropdownMenuItem(value: o, child: Text(o)))
              .toList(),
          onChanged: (v) => setState(() => _enumValue = v),
        );
    }
  }

  Future<void> _delete() async {
    final current = widget.initialValue;
    if (current != null) {
      await ref.read(trackerRepositoryProvider).softDeleteValue(current.id);
      widget.onSaved();
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _save() async {
    final now = utcNow();
    final current = widget.initialValue;
    int? intVal;
    bool? boolVal;
    String? enumVal;

    switch (widget.tracker.type) {
      case TrackerType.integer:
        final text = _intController.text.trim();
        if (text.isEmpty) {
          if (current != null) {
            await ref.read(trackerRepositoryProvider).softDeleteValue(current.id);
            widget.onSaved();
          }
          if (mounted) Navigator.of(context).pop();
          return;
        }
        final raw = int.tryParse(text);
        if (raw == null) {
          Navigator.of(context).pop();
          return;
        }
        final cap = widget.tracker.integerCap;
        intVal = cap == null ? raw : raw.clamp(0, cap);
      case TrackerType.boolean:
        boolVal = _boolValue;
      case TrackerType.enumType:
        enumVal = _enumValue;
    }

    await ref.read(trackerRepositoryProvider).upsertValue(
          TrackerValue(
            id: current?.id ??
                '${widget.tracker.id}_${widget.periodDate.millisecondsSinceEpoch}',
            trackerId: widget.tracker.id,
            periodStart: widget.periodDate,
            intValue: intVal,
            boolValue: boolVal,
            enumValue: enumVal,
            createdAt: current?.createdAt ?? now,
            updatedAt: now,
          ),
        );

    widget.onSaved();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _handleOutsideTap() async {
    await _save();
  }

}

// ---------------------------------------------------------------------------
// Single Heatmap Square
// ---------------------------------------------------------------------------

class _HeatmapSquare extends ConsumerStatefulWidget {
  const _HeatmapSquare({
    required this.tracker,
    required this.values,
    required this.periodDate,
    required this.maxInPeriod,
    required this.analytics,
    required this.size,
  });

  final StatisticTracker tracker;
  final List<TrackerValue> values;
  final DateTime periodDate;
  final int maxInPeriod;
  final AnalyticsService analytics;
  final double size;

  @override
  ConsumerState<_HeatmapSquare> createState() => _HeatmapSquareState();
}

class _HeatmapSquareState extends ConsumerState<_HeatmapSquare> {
  TrackerValue? _findValue() {
    return widget.values.cast<TrackerValue?>().firstWhere(
      (v) =>
          v != null &&
          v.periodStart.year == widget.periodDate.year &&
          v.periodStart.month == widget.periodDate.month &&
          v.periodStart.day == widget.periodDate.day,
      orElse: () => null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = _findValue();
    final intensity = widget.analytics.heatmapIntensity(
      type: widget.tracker.type,
      value: value,
      tracker: widget.tracker,
      maxInPeriod:
          widget.maxInPeriod == 0 ? 1 : widget.maxInPeriod,
      allValues: widget.values,
    );
    final color = Color(widget.tracker.colorValue);
    final bgColor = intensity == 0
        ? color.withValues(alpha: 0.10)
        : color.withValues(alpha: 0.15 + 0.85 * intensity);

    return _hoverTooltip(
      context: context,
      periodLabel: _tooltipPeriodLabel(widget.periodDate, widget.tracker.cadence),
      type: widget.tracker.type,
      value: value,
      tracker: widget.tracker,
      periodDate: widget.periodDate,
      valueColor: value == null ? null : _heatmapValueColor(color, intensity),
      onSaved: () {
        ref.invalidate(trackerValuesProvider(widget.tracker.id));
        ref.invalidate(pendingStatEntriesProvider);
      },
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Heatmap square popover
// ---------------------------------------------------------------------------

/// Opens [_HeatmapPopover] with a custom route transition that expands it
/// out from [anchorRect] (the hovered tooltip's own on-screen rect, or the
/// cell's rect as a fallback). Opening animates; closing is instant (no
/// reverse transition), per design.
Future<void> _showHeatmapPopover({
  required BuildContext context,
  required StatisticTracker tracker,
  required DateTime periodDate,
  required Rect anchorRect,
  required TrackerValue? initialValue,
  required VoidCallback onSaved,
}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      // No built-in route transition — [_HeatmapPopover] drives its own
      // expand animation (like [_MorphPopover]) and only starts it once it
      // has measured its real size/position, so there's never a frame
      // where the route's own clock has run ahead of geometry that isn't
      // known yet.
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      transitionsBuilder: (ctx, animation, secondaryAnimation, child) => child,
      pageBuilder: (ctx, animation, secondaryAnimation) => _HeatmapPopover(
        tracker: tracker,
        periodDate: periodDate,
        anchorRect: anchorRect,
        initialValue: initialValue,
        onSaved: onSaved,
      ),
    ),
  );
}

/// Clips to a fixed [rect] each frame — used to reveal the popover card
/// growing out of the hover tooltip's original bounds without reflowing
/// the (already full-size, naturally laid out) card underneath.
class _RevealClipper extends CustomClipper<Rect> {
  const _RevealClipper(this.rect);

  final Rect rect;

  @override
  Rect getClip(Size size) => rect;

  @override
  bool shouldReclip(covariant _RevealClipper oldClipper) => oldClipper.rect != rect;
}

class _HeatmapPopover extends ConsumerStatefulWidget {
  const _HeatmapPopover({
    required this.tracker,
    required this.periodDate,
    required this.anchorRect,
    required this.initialValue,
    required this.onSaved,
  });

  final StatisticTracker tracker;
  final DateTime periodDate;
  final Rect anchorRect;
  final TrackerValue? initialValue;
  final VoidCallback onSaved;

  @override
  ConsumerState<_HeatmapPopover> createState() => _HeatmapPopoverState();
}

class _HeatmapPopoverState extends ConsumerState<_HeatmapPopover>
    with TickerProviderStateMixin {
  late final TextEditingController _intController;
  bool? _boolValue;
  String? _enumValue;
  final _cardKey = GlobalKey();
  Offset? _position;
  Size? _cardSize;
  bool _expandStarted = false;

  /// Drives the expand-from-the-hovered-cell entrance animation. Doesn't
  /// start until [_cardSize]/[_position] are known, so there is never a
  /// frame where it's animating toward a wrong/placeholder target — the
  /// same fix as [_MorphPopoverState._morphController].
  late final AnimationController _expandController;

  /// Secondary controls (Save/Delete/Cancel) fade in only once the main
  /// expand animation has finished, per design.
  late final AnimationController _controlsController;

  int get _slowMo => DevFlags.slowHeatmapPopoverAnimation ? 10 : 1;

  @override
  void initState() {
    super.initState();
    _intController = TextEditingController(
      text: widget.initialValue?.intValue?.toString() ?? '',
    );
    _intController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _intController.text.length,
    );
    _boolValue = widget.initialValue?.boolValue ?? widget.tracker.defaultBool;
    _enumValue = widget.initialValue?.enumValue ??
        widget.tracker.defaultEnumOption;

    _expandController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 220 * _slowMo),
    );
    _controlsController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 150 * _slowMo),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _reposition());
  }

  @override
  void dispose() {
    _expandController.dispose();
    _controlsController.dispose();
    _intController.dispose();
    super.dispose();
  }

  /// Measures the popover's actual rendered size and clamps it to stay
  /// within the screen. Prefers appearing above the anchor — same as the
  /// hover tooltip it expands from — flipping below only if there isn't
  /// enough room above, so the expand animation doesn't jump sides.
  void _reposition() {
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !mounted) return;
    final size = box.size;
    final screen = MediaQuery.sizeOf(context);
    const margin = 8.0;

    var left = widget.anchorRect.left;
    left = left.clamp(margin, math.max(margin, screen.width - margin - size.width));

    var top = widget.anchorRect.top - 6 - size.height;
    if (top < margin) {
      final below = widget.anchorRect.bottom + 6;
      top = below + size.height <= screen.height - margin
          ? below
          : screen.height - margin - size.height;
    }
    top = top.clamp(margin, math.max(margin, screen.height - margin - size.height));

    final next = Offset(left, top);
    if (next != _position || size != _cardSize) {
      setState(() {
        _position = next;
        _cardSize = size;
      });
    }
    if (!_expandStarted) {
      _expandStarted = true;
      _expandController.forward().whenComplete(() {
        if (mounted) _controlsController.forward();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Color(widget.tracker.colorValue);
    final expand = CurvedAnimation(
      parent: _expandController,
      curve: Curves.easeOutCubic,
    );

    // The card is positioned at its final, measured location (`origin`)
    // and rendered at its natural size the whole time — nothing reflows.
    // What animates is a clip window, computed in the card's own local
    // coordinate space, that grows from exactly where the hover tooltip
    // was (`startLocalRect`) to the card's full bounds. Because
    // startLocalRect is always `anchorRect` shifted by `-origin`, the
    // window's on-screen position at t=0 is always `anchorRect` itself,
    // regardless of when `_reposition()` corrects `origin` — so there's
    // no visible jump once the real position/size are measured.
    final origin = _position ??
        Offset(
          widget.anchorRect.left.clamp(0, double.infinity),
          widget.anchorRect.top.clamp(0, double.infinity),
        );
    final startLocalRect = widget.anchorRect.shift(-origin);
    final endLocalRect = _cardSize == null ? startLocalRect : Offset.zero & _cardSize!;

    return Stack(
      children: [
        // Dismiss tapping outside
        Positioned.fill(
          child: GestureDetector(
            onTap: _handleOutsideTap,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),
        // Popover card, positioned near the square
        Positioned(
          left: origin.dx,
          top: origin.dy,
          child: AnimatedBuilder(
            animation: expand,
            builder: (context, child) => ClipRect(
              clipper: _RevealClipper(
                Rect.lerp(startLocalRect, endLocalRect, expand.value)!,
              ),
              child: child,
            ),
            child: FadeTransition(
              opacity: CurvedAnimation(
                parent: _expandController,
                curve: const Interval(0.0, 0.5),
              ),
              child: Container(
                key: _cardKey,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: popupGlowAlpha),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Material(
                  elevation: 8,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: accent, width: 3),
                  ),
                  color: theme.colorScheme.surface,
                  child: SizedBox(
                    width: 310,
                    child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              widget.tracker.name,
                              style: theme.textTheme.titleSmall,
                            ),
                            const Spacer(),
                            Text(
                              _formatDate(widget.periodDate),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _valueEditor(theme, accent),
                        const SizedBox(height: 10),
                        FadeTransition(
                          opacity: _controlsController,
                          child: Row(
                            children: [
                              if (widget.initialValue != null)
                                TextButton(
                                  onPressed: _delete,
                                  style: TextButton.styleFrom(
                                    foregroundColor: theme.colorScheme.error,
                                  ),
                                  child: const Text('Delete'),
                                ),
                              const Spacer(),
                              FilledButton(
                                onPressed: _save,
                                style: FilledButton.styleFrom(
                                  backgroundColor: accent,
                                  foregroundColor: ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
                                      ? Colors.white
                                      : Colors.black,
                                ),
                                child: const Text('Save'),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: Navigator.of(context).pop,
                                style: TextButton.styleFrom(
                                  foregroundColor: accent,
                                ),
                                child: const Text('Cancel'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _valueEditor(ThemeData theme, Color accent) {
    switch (widget.tracker.type) {
      case TrackerType.integer:
        final cap = widget.tracker.integerCap;
        final minVal = widget.tracker.defaultInt;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cap != null) ...[
              Slider(
                min: minVal.toDouble(),
                max: cap.toDouble(),
                divisions: (cap - minVal) <= 0 ? null : (cap - minVal),
                activeColor: accent,
                inactiveColor: accent.withValues(alpha: 0.24),
                value: (int.tryParse(_intController.text) ?? minVal)
                    .clamp(minVal, cap)
                    .toDouble(),
                onChanged: (v) =>
                    setState(() => _intController.text = v.round().toString()),
              ),
            ],
            VoyagerTextField(
              controller: _intController,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              accentColor: accent,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(
                labelText: 'Value',
                isDense: true,
                contentPadding: EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 12),
              ),
            ),
            if (cap != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(
                  '$minVal–$cap',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ],
        );
      case TrackerType.boolean:
        return SwitchListTile(
          contentPadding: const EdgeInsets.only(left: 6, right: 0),
          dense: true,
          title: const Text('Completed'),
          value: _boolValue ?? false,
          activeColor: accent,
          onChanged: (v) => setState(() => _boolValue = v),
        );
      case TrackerType.enumType:
        final options = widget.tracker.enumOptions;
        return VoyagerDropdownButtonFormField<String>(
          initialValue: options.contains(_enumValue) ? _enumValue : null,
          accentColor: accent,
          decoration: const InputDecoration(
            labelText: 'Value',
            isDense: true,
          ),
          items: options
              .map((o) => DropdownMenuItem(value: o, child: Text(o)))
              .toList(),
          onChanged: (v) => setState(() => _enumValue = v),
        );
    }
  }

  Future<void> _delete() async {
    final current = widget.initialValue;
    if (current != null) {
      await ref.read(trackerRepositoryProvider).softDeleteValue(current.id);
      widget.onSaved();
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _save() async {
    final now = utcNow();
    final current = widget.initialValue;
    int? intVal;
    bool? boolVal;
    String? enumVal;

    switch (widget.tracker.type) {
      case TrackerType.integer:
        final text = _intController.text.trim();
        if (text.isEmpty) {
          if (current != null) {
            await ref.read(trackerRepositoryProvider).softDeleteValue(current.id);
            widget.onSaved();
          }
          if (mounted) Navigator.of(context).pop();
          return;
        }
        final raw = int.tryParse(text);
        if (raw == null) {
          Navigator.of(context).pop();
          return;
        }
        final cap = widget.tracker.integerCap;
        intVal = cap == null ? raw : raw.clamp(0, cap);
      case TrackerType.boolean:
        boolVal = _boolValue;
      case TrackerType.enumType:
        enumVal = _enumValue;
    }

    await ref.read(trackerRepositoryProvider).upsertValue(
          TrackerValue(
            id: current?.id ??
                '${widget.tracker.id}_${widget.periodDate.millisecondsSinceEpoch}',
            trackerId: widget.tracker.id,
            periodStart: widget.periodDate,
            intValue: intVal,
            boolValue: boolVal,
            enumValue: enumVal,
            createdAt: current?.createdAt ?? now,
            updatedAt: now,
          ),
        );

    widget.onSaved();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _handleOutsideTap() async {
    await _save();
  }

  String _formatDate(DateTime d) {
    return DateFormat('MMMM d, yyyy').format(d);
  }
}

// ---------------------------------------------------------------------------
// Calendar View
// ---------------------------------------------------------------------------

class _CalendarView extends ConsumerWidget {
  const _CalendarView({required this.trackers, required this.analytics});

  final List<StatisticTracker> trackers;
  final AnalyticsService analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(_calendarSelectedTrackerProvider);
    final scale = ref.watch(_calendarTimeScaleProvider);

    final selectedTracker = trackers.cast<StatisticTracker?>().firstWhere(
      (t) => t?.id == selectedId,
      orElse: () => trackers.isNotEmpty ? trackers.first : null,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selectedTracker == null)
          const SizedBox.shrink()
        else if (selectedTracker.effectiveTrackingStyle ==
            TrackerStyle.consecutive)
          _ConsecutiveCalendarChart(
            tracker: selectedTracker,
            analytics: analytics,
          )
        else if (selectedTracker.cadence == TrackerCadence.monthly)
          _MonthGridCalendar(
            tracker: selectedTracker,
            analytics: analytics,
          )
        else if (selectedTracker.cadence == TrackerCadence.yearly)
          _YearGridCalendar(
            tracker: selectedTracker,
            analytics: analytics,
          )
        else
          _YearHeatmapCalendar(
            tracker: selectedTracker,
            analytics: analytics,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Consecutive full-screen line chart (Calendar mode)
// ---------------------------------------------------------------------------

class _ConsecutiveCalendarChart extends ConsumerWidget {
  const _ConsecutiveCalendarChart({
    required this.tracker,
    required this.analytics,
  });

  final StatisticTracker tracker;
  final AnalyticsService analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(trackerValuesProvider(tracker.id));
    final color = Color(tracker.colorValue);

    return valuesAsync.when(
      data: (values) {
        final now = DateTime.now();
        final from = DateTime(now.year, now.month, 1);
        final to = now;
        final spots = analytics.interpolateConsecutive(
          values: values,
          from: from,
          to: to,
        );
        if (spots.isEmpty) {
          return SizedBox(
            height: 280,
            child: Center(
              child: Text(
                'No data for this month',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }
        final maxY = spots.map((s) => s.y).fold<double>(1, math.max);
        return SizedBox(
          height: 280,
          child: LineChart(
            LineChartData(
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => calendarPanelBackgroundColor(context),
                  getTooltipItems: (touchedSpots) => touchedSpots
                      .map(
                        (spot) => LineTooltipItem(
                          spot.y.toStringAsFixed(1),
                          TextStyle(
                            color: color,
                            fontWeight: FontWeight.normal,
                            fontSize: 12,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              minY: 0,
              maxY: maxY * 1.2,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: Theme.of(context)
                      .colorScheme
                      .outline
                      .withValues(alpha: 0.15),
                  strokeWidth: 1,
                ),
              ),
              titlesData: FlTitlesData(
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    getTitlesWidget: (v, _) => Text(
                      v.toInt().toString(),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 22,
                    interval: 5,
                    getTitlesWidget: (v, _) {
                      final day = from.add(Duration(days: v.toInt()));
                      return Text(
                        '${day.day}',
                        style: Theme.of(context).textTheme.labelSmall,
                      );
                    },
                  ),
                ),
              ),
              borderData: FlBorderData(show: false),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  preventCurveOverShooting: true,
                  preventCurveOvershootingThreshold: 0,
                  color: color,
                  barWidth: 2,
                  dotData: FlDotData(show: spots.length <= 15),
                  belowBarData: BarAreaData(
                    show: true,
                    color: color.withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      loading: () => const SizedBox(
        height: 280,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Text('$e'),
    );
  }
}

// ---------------------------------------------------------------------------
// Monthly heatmap calendar
// ---------------------------------------------------------------------------

class _MonthHeatmapCalendar extends ConsumerWidget {
  const _MonthHeatmapCalendar({
    required this.tracker,
    required this.analytics,
  });

  final StatisticTracker tracker;
  final AnalyticsService analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(trackerValuesProvider(tracker.id));
    final theme = Theme.of(context);
    final color = Color(tracker.colorValue);
    final currentMonth = ref.watch(_calendarViewMonthProvider);

    return valuesAsync.when(
      data: (values) {
        final firstDay = DateTime(currentMonth.year, currentMonth.month, 1);
        final daysInMonth =
            DateTime(currentMonth.year, currentMonth.month + 1, 0).day;
        final startWeekday = firstDay.weekday % 7; // 0=Sun
        final max = analytics.rollingMax(values);

        void previousMonth() {
          ref.read(_calendarViewMonthProvider.notifier).update((state) =>
              DateTime(state.year, state.month - 1, 1));
        }

        void nextMonth() {
          ref.read(_calendarViewMonthProvider.notifier).update((state) =>
              DateTime(state.year, state.month + 1, 1));
        }

        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                previousMonth();
                return KeyEventResult.handled;
              } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                nextMonth();
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: previousMonth,
                  ),
                  Text(
                    '${_monthName(currentMonth.month)} ${currentMonth.year}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: nextMonth,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Day-of-week headers
              Row(
                children: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
                    .map(
                      (d) => Expanded(
                        child: Center(
                          child: Text(
                            d,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 4),
              Wrap(
                children: [
                  // Offset leading blanks
                  for (var i = 0; i < startWeekday; i++)
                    const _CalendarCell(
                      day: null,
                      color: Colors.transparent,
                      intensity: 0,
                      value: null,
                      showValue: false,
                    ),
                  // Actual days
                  for (var day = 1; day <= daysInMonth; day++)
                    Builder(builder: (ctx) {
                      final date = DateTime(currentMonth.year, currentMonth.month, day);
                      final v = values.cast<TrackerValue?>().firstWhere(
                        (v) =>
                            v != null &&
                            v.periodStart.year == date.year &&
                            v.periodStart.month == date.month &&
                            v.periodStart.day == date.day,
                        orElse: () => null,
                      );
                      final intensity = analytics.heatmapIntensity(
                        type: tracker.type,
                        value: v,
                        tracker: tracker,
                        maxInPeriod: max == 0 ? 1 : max,
                        allValues: values,
                      );
                      return _CalendarCell(
                        day: day,
                        color: color,
                        intensity: intensity,
                        value: v,
                        showValue: true,
                        tracker: tracker,
                        periodDate: date,
                      );
                  }),
                // Trailing blanks
                for (var i = (startWeekday + daysInMonth) % 7; i > 0 && i < 7; i++)
                  const _CalendarCell(
                    day: null,
                    color: Colors.transparent,
                    intensity: 0,
                    value: null,
                    showValue: false,
                  ),
              ],
            ),
          ],
        ),
      );
    },
      loading: () => const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Text('$e'),
    );
  }

  String _monthName(int m) => [
        '', 'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
      ][m];
}

class _CalendarCell extends ConsumerStatefulWidget {
  const _CalendarCell({
    required this.day,
    required this.color,
    required this.intensity,
    required this.value,
    required this.showValue,
    this.tracker,
    this.periodDate,
  });

  final int? day;
  final Color color;
  final double intensity;
  final TrackerValue? value;
  final bool showValue;
  final StatisticTracker? tracker;
  final DateTime? periodDate;

  @override
  ConsumerState<_CalendarCell> createState() => _CalendarCellState();
}

class _CalendarCellState extends ConsumerState<_CalendarCell> {
  final _key = GlobalKey();

  void _openPopover() {
    if (widget.tracker == null || widget.periodDate == null) return;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final offset = box.localToGlobal(Offset.zero);
    final rect = offset & box.size;

    _showHeatmapPopover(
      context: context,
      tracker: widget.tracker!,
      periodDate: widget.periodDate!,
      anchorRect: rect,
      initialValue: widget.value,
      onSaved: () {
        ref.invalidate(trackerValuesProvider(widget.tracker!.id));
        ref.invalidate(pendingStatEntriesProvider);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final fraction = 1 / 7;
    return FractionallySizedBox(
      widthFactor: fraction,
      child: AspectRatio(
        aspectRatio: 8 / 5,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: widget.day == null
              ? Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                      width: 1,
                    ),
                  ),
                )
              : GestureDetector(
                  key: _key,
                  onTap: _openPopover,
                  child: Container(
                    decoration: BoxDecoration(
                      color: widget.value == null
                          ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05)
                          : widget.intensity == 0
                              ? widget.color.withValues(alpha: 0.10)
                              : widget.color.withValues(alpha: 0.15 + 0.85 * widget.intensity),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.1),
                        width: 1,
                      ),
                    ),
                    child: Stack(
                      children: [
                        Positioned(
                          top: 2,
                          left: 4,
                          child: Text(
                            '${widget.day}',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (widget.showValue && widget.value?.intValue != null)
                          Center(
                            child: FittedBox(
                              child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: Text(
                                  '${widget.value!.intValue}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: widget.intensity > 0.5
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.onSurface,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Yearly heatmap calendar
// ---------------------------------------------------------------------------

class _YearHeatmapCalendar extends ConsumerWidget {
  const _YearHeatmapCalendar({
    required this.tracker,
    required this.analytics,
  });

  final StatisticTracker tracker;
  final AnalyticsService analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(trackerValuesProvider(tracker.id));
    final theme = Theme.of(context);
    final year = ref.watch(_calendarViewYearProvider);
    final weekStartsMonday =
        ref.watch(settingsProvider).value?.weekStartsOnMonday ?? true;

    void previousYear() {
      ref.read(_calendarViewYearProvider.notifier).update((y) => y - 1);
    }

    void nextYear() {
      ref.read(_calendarViewYearProvider.notifier).update((y) => y + 1);
    }

    return valuesAsync.when(
      data: (values) {
        final max = analytics.rollingMax(values, days: 366);

        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                previousYear();
                return KeyEventResult.handled;
              } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                nextYear();
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: previousYear,
                  ),
                  Text(
                    '$year',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: nextYear,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (var row = 0; row < 4; row++) ...[
                if (row > 0) const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var col = 0; col < 3; col++) ...[
                      if (col > 0) const SizedBox(width: 8),
                      Expanded(
                        child: _HeatmapMonthTile(
                          month: DateTime(year, row * 3 + col + 1),
                          tracker: tracker,
                          values: values,
                          maxInPeriod: max,
                          analytics: analytics,
                          weekStartsMonday: weekStartsMonday,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        );
      },
      loading: () => const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Text('$e'),
    );
  }
}

// ---------------------------------------------------------------------------
// Yearly heatmap: single month tile (mirrors the Calendar page's year tiles)
// ---------------------------------------------------------------------------

class _HeatmapMonthTile extends StatelessWidget {
  const _HeatmapMonthTile({
    required this.month,
    required this.tracker,
    required this.values,
    required this.maxInPeriod,
    required this.analytics,
    required this.weekStartsMonday,
  });

  final DateTime month;
  final StatisticTracker tracker;
  final List<TrackerValue> values;
  final int maxInPeriod;
  final AnalyticsService analytics;
  final bool weekStartsMonday;

  static const _monthNames = [
    '', 'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  @override
  Widget build(BuildContext context) {
    final cells = monthGridDates(month, weekStartsMonday: weekStartsMonday);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: calendarPanelBackgroundColor(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: LayoutBuilder(builder: (context, constraints) {
          final daySize = constraints.maxWidth / 7;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _monthNames[month.month],
                style: MonthTitleHeader.yearTileMonthNameStyle(context),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textHeightBehavior: MonthTitleHeader.titleTextHeightBehavior,
              ),
              const SizedBox(height: MonthTitleHeader.titleGap),
              WeekdayHeaderRow(
                weekStartsMonday: weekStartsMonday,
                useSingleLetterLabels: false,
                labelStyle: calendarWeekdayLabelStyle(
                  context,
                  fontSize: MonthDayCellStyle.compact.fontSize,
                ),
              ),
              const SizedBox(height: monthDayGridWeekdayHeaderGap),
              for (var row = 0; row < 6; row++)
                Row(
                  children: tracker.cadence == TrackerCadence.weekly
                      ? _weeklyRowCells(row: row, cells: cells, daySize: daySize)
                      : [
                          for (var col = 0; col < 7; col++)
                            SizedBox(
                              width: daySize,
                              height: daySize,
                              child: _HeatmapDayCell(
                                tracker: tracker,
                                date: cells[row * 7 + col],
                                month: month,
                                values: values,
                                maxInPeriod: maxInPeriod,
                                analytics: analytics,
                              ),
                            ),
                        ],
                ),
            ],
          );
        }),
      ),
    );
  }

  /// Builds one week-row of cells for a weekly-cadence tracker: the full
  /// row is always rendered as a single continuous block (one value per
  /// calendar week), with the days that spill into an adjacent month
  /// rendered as greyed-out segments within that same block rather than
  /// breaking off into separate cells.
  List<Widget> _weeklyRowCells({
    required int row,
    required List<DateTime> cells,
    required double daySize,
  }) {
    final rowCells = cells.sublist(row * 7, row * 7 + 7);
    return [
      SizedBox(
        width: daySize * 7,
        height: daySize,
        child: _HeatmapWeekBlock(
          tracker: tracker,
          rowCells: rowCells,
          month: month,
          values: values,
          maxInPeriod: maxInPeriod,
          analytics: analytics,
        ),
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// Yearly heatmap: single day cell (heat fill instead of events)
// ---------------------------------------------------------------------------

class _HeatmapDayCell extends ConsumerStatefulWidget {
  const _HeatmapDayCell({
    required this.tracker,
    required this.date,
    required this.month,
    required this.values,
    required this.maxInPeriod,
    required this.analytics,
  });

  final StatisticTracker tracker;
  final DateTime date;
  final DateTime month;
  final List<TrackerValue> values;
  final int maxInPeriod;
  final AnalyticsService analytics;

  @override
  ConsumerState<_HeatmapDayCell> createState() => _HeatmapDayCellState();
}

class _HeatmapDayCellState extends ConsumerState<_HeatmapDayCell> {
  TrackerValue? _findValue() {
    return widget.values.cast<TrackerValue?>().firstWhere(
      (v) =>
          v != null &&
          v.periodStart.year == widget.date.year &&
          v.periodStart.month == widget.date.month &&
          v.periodStart.day == widget.date.day,
      orElse: () => null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final inMonth =
        widget.date.month == widget.month.month &&
        widget.date.year == widget.month.year;
    final value = _findValue();
    final intensity = widget.analytics.heatmapIntensity(
      type: widget.tracker.type,
      value: value,
      tracker: widget.tracker,
      maxInPeriod: widget.maxInPeriod == 0 ? 1 : widget.maxInPeriod,
      allValues: widget.values,
    );
    final color = Color(widget.tracker.colorValue);
    final fade = inMonth ? 1.0 : 0.4;
    final bgColor = value == null
        ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05 * fade)
        : intensity == 0
            ? color.withValues(alpha: 0.10 * fade)
            : color.withValues(alpha: (0.15 + 0.85 * intensity) * fade);

    return _hoverTooltip(
      context: context,
      periodLabel: _tooltipPeriodLabel(widget.date, TrackerCadence.daily),
      type: widget.tracker.type,
      value: value,
      tracker: widget.tracker,
      periodDate: widget.date,
      valueColor: value == null ? null : _heatmapValueColor(color, intensity),
      onSaved: () {
        ref.invalidate(trackerValuesProvider(widget.tracker.id));
        ref.invalidate(pendingStatEntriesProvider);
      },
      child: Container(
        margin: const EdgeInsets.all(1),
        padding: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(MonthDayCellStyle.compact.borderRadius),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: Text(
            '${widget.date.day}',
            style: TextStyle(
              fontSize: MonthDayCellStyle.compact.fontSize,
              fontWeight: FontWeight.w500,
              color: inMonth
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: calendarAdjacentMonthTextOpacity),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Weekly heatmap: one merged block per calendar week. Days that spill into
// an adjacent month are rendered as greyed-out segments within the same
// continuous block instead of breaking off into separate cells.
// ---------------------------------------------------------------------------

class _HeatmapWeekBlock extends ConsumerStatefulWidget {
  const _HeatmapWeekBlock({
    required this.tracker,
    required this.rowCells,
    required this.month,
    required this.values,
    required this.maxInPeriod,
    required this.analytics,
  });

  final StatisticTracker tracker;
  final List<DateTime> rowCells;
  final DateTime month;
  final List<TrackerValue> values;
  final int maxInPeriod;
  final AnalyticsService analytics;

  @override
  ConsumerState<_HeatmapWeekBlock> createState() => _HeatmapWeekBlockState();
}

class _HeatmapWeekBlockState extends ConsumerState<_HeatmapWeekBlock> {
  DateTime get _weekStart => widget.rowCells.first;

  TrackerValue? _findValue() {
    return widget.values.cast<TrackerValue?>().firstWhere(
      (v) =>
          v != null &&
          v.periodStart.year == _weekStart.year &&
          v.periodStart.month == _weekStart.month &&
          v.periodStart.day == _weekStart.day,
      orElse: () => null,
    );
  }

  bool _inMonth(DateTime d) =>
      d.year == widget.month.year && d.month == widget.month.month;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = _findValue();
    final intensity = widget.analytics.heatmapIntensity(
      type: widget.tracker.type,
      value: value,
      tracker: widget.tracker,
      maxInPeriod: widget.maxInPeriod == 0 ? 1 : widget.maxInPeriod,
      allValues: widget.values,
    );
    final color = Color(widget.tracker.colorValue);
    final baseAlpha = value == null
        ? 0.05
        : intensity == 0
            ? 0.10
            : 0.15 + 0.85 * intensity;
    final baseColor = value == null ? theme.colorScheme.onSurface : color;

    return _hoverTooltip(
      context: context,
      periodLabel: _tooltipPeriodLabel(_weekStart, TrackerCadence.weekly),
      type: widget.tracker.type,
      value: value,
      tracker: widget.tracker,
      periodDate: _weekStart,
      valueColor: value == null ? null : _heatmapValueColor(color, intensity),
      onSaved: () {
        ref.invalidate(trackerValuesProvider(widget.tracker.id));
        ref.invalidate(pendingStatEntriesProvider);
      },
      child: Container(
        margin: const EdgeInsets.all(1),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(MonthDayCellStyle.compact.borderRadius),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final d in widget.rowCells)
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(1),
                  color: baseColor.withValues(
                    alpha: baseAlpha * (_inMonth(d) ? 1.0 : 0.4),
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      '${d.day}',
                      style: TextStyle(
                        fontSize: MonthDayCellStyle.compact.fontSize,
                        fontWeight: FontWeight.w500,
                        color: _inMonth(d)
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: calendarAdjacentMonthTextOpacity),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Monthly calendar: 24 boxes (2 rows of 12 months, one row per year)
// ---------------------------------------------------------------------------

class _MonthGridCalendar extends ConsumerWidget {
  const _MonthGridCalendar({required this.tracker, required this.analytics});

  final StatisticTracker tracker;
  final AnalyticsService analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(trackerValuesProvider(tracker.id));
    final theme = Theme.of(context);
    final baseYear = ref.watch(_calendarViewMonthlyBaseYearProvider);

    void previousWindow() {
      ref.read(_calendarViewMonthlyBaseYearProvider.notifier).update((y) => y - 2);
    }

    void nextWindow() {
      ref.read(_calendarViewMonthlyBaseYearProvider.notifier).update((y) => y + 2);
    }

    return valuesAsync.when(
      data: (values) {
        final max = analytics.rollingMax(values, days: 731);

        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                previousWindow();
                return KeyEventResult.handled;
              } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                nextWindow();
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: previousWindow,
                  ),
                  Text(
                    '$baseYear – ${baseYear + 1}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: nextWindow,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              for (var row = 0; row < 2; row++) ...[
                if (row > 0) const SizedBox(height: 20),
                Text(
                  '${baseYear + row}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (var m = 0; m < 12; m++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(right: m < 11 ? 6 : 0),
                          child: _MonthGridBox(
                            tracker: tracker,
                            periodDate: DateTime(baseYear + row, m + 1, 1),
                            values: values,
                            maxInPeriod: max,
                            analytics: analytics,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
      loading: () => const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Text('$e'),
    );
  }
}

class _MonthGridBox extends ConsumerStatefulWidget {
  const _MonthGridBox({
    required this.tracker,
    required this.periodDate,
    required this.values,
    required this.maxInPeriod,
    required this.analytics,
  });

  final StatisticTracker tracker;
  final DateTime periodDate;
  final List<TrackerValue> values;
  final int maxInPeriod;
  final AnalyticsService analytics;

  @override
  ConsumerState<_MonthGridBox> createState() => _MonthGridBoxState();
}

class _MonthGridBoxState extends ConsumerState<_MonthGridBox> {
  TrackerValue? _findValue() {
    return widget.values.cast<TrackerValue?>().firstWhere(
      (v) =>
          v != null &&
          v.periodStart.year == widget.periodDate.year &&
          v.periodStart.month == widget.periodDate.month,
      orElse: () => null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = _findValue();
    final intensity = widget.analytics.heatmapIntensity(
      type: widget.tracker.type,
      value: value,
      tracker: widget.tracker,
      maxInPeriod: widget.maxInPeriod == 0 ? 1 : widget.maxInPeriod,
      allValues: widget.values,
    );
    final color = Color(widget.tracker.colorValue);
    final bgColor = value == null
        ? theme.colorScheme.onSurface.withValues(alpha: 0.05)
        : intensity == 0
            ? color.withValues(alpha: 0.10)
            : color.withValues(alpha: 0.15 + 0.85 * intensity);

    return Column(
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: _hoverTooltip(
            context: context,
            periodLabel: _tooltipPeriodLabel(widget.periodDate, TrackerCadence.monthly),
            type: widget.tracker.type,
            value: value,
            tracker: widget.tracker,
            periodDate: widget.periodDate,
            valueColor: value == null ? null : _heatmapValueColor(color, intensity),
            onSaved: () {
              ref.invalidate(trackerValuesProvider(widget.tracker.id));
              ref.invalidate(pendingStatEntriesProvider);
            },
            child: Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          DateFormat('MMM').format(widget.periodDate),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Yearly calendar: 10 boxes in a single row, one per year
// ---------------------------------------------------------------------------

class _YearGridCalendar extends ConsumerWidget {
  const _YearGridCalendar({required this.tracker, required this.analytics});

  final StatisticTracker tracker;
  final AnalyticsService analytics;

  static const _yearCount = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(trackerValuesProvider(tracker.id));
    final theme = Theme.of(context);
    final baseYear = ref.watch(_calendarViewYearlyBaseYearProvider);

    void previousWindow() {
      ref.read(_calendarViewYearlyBaseYearProvider.notifier).update((y) => y - _yearCount);
    }

    void nextWindow() {
      ref.read(_calendarViewYearlyBaseYearProvider.notifier).update((y) => y + _yearCount);
    }

    return valuesAsync.when(
      data: (values) {
        final max = analytics.rollingMax(values, days: 365 * _yearCount);

        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                previousWindow();
                return KeyEventResult.handled;
              } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                nextWindow();
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: previousWindow,
                  ),
                  Text(
                    '$baseYear – ${baseYear + _yearCount - 1}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: nextWindow,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  for (var i = 0; i < _yearCount; i++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: i < _yearCount - 1 ? 6 : 0),
                        child: _YearGridBox(
                          tracker: tracker,
                          periodDate: DateTime(baseYear + i),
                          values: values,
                          maxInPeriod: max,
                          analytics: analytics,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Text('$e'),
    );
  }
}

class _YearGridBox extends ConsumerStatefulWidget {
  const _YearGridBox({
    required this.tracker,
    required this.periodDate,
    required this.values,
    required this.maxInPeriod,
    required this.analytics,
  });

  final StatisticTracker tracker;
  final DateTime periodDate;
  final List<TrackerValue> values;
  final int maxInPeriod;
  final AnalyticsService analytics;

  @override
  ConsumerState<_YearGridBox> createState() => _YearGridBoxState();
}

class _YearGridBoxState extends ConsumerState<_YearGridBox> {
  TrackerValue? _findValue() {
    return widget.values.cast<TrackerValue?>().firstWhere(
      (v) => v != null && v.periodStart.year == widget.periodDate.year,
      orElse: () => null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = _findValue();
    final intensity = widget.analytics.heatmapIntensity(
      type: widget.tracker.type,
      value: value,
      tracker: widget.tracker,
      maxInPeriod: widget.maxInPeriod == 0 ? 1 : widget.maxInPeriod,
      allValues: widget.values,
    );
    final color = Color(widget.tracker.colorValue);
    final bgColor = value == null
        ? theme.colorScheme.onSurface.withValues(alpha: 0.05)
        : intensity == 0
            ? color.withValues(alpha: 0.10)
            : color.withValues(alpha: 0.15 + 0.85 * intensity);

    return Column(
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: _hoverTooltip(
            context: context,
            periodLabel: _tooltipPeriodLabel(widget.periodDate, TrackerCadence.yearly),
            type: widget.tracker.type,
            value: value,
            tracker: widget.tracker,
            periodDate: widget.periodDate,
            valueColor: value == null ? null : _heatmapValueColor(color, intensity),
            onSaved: () {
              ref.invalidate(trackerValuesProvider(widget.tracker.id));
              ref.invalidate(pendingStatEntriesProvider);
            },
            child: Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${widget.periodDate.year}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tracker creation dialog (updated with trackingStyle)
// ---------------------------------------------------------------------------

class _TrackerDialog extends ConsumerStatefulWidget {
  const _TrackerDialog({this.tracker});

  final StatisticTracker? tracker;

  @override
  ConsumerState<_TrackerDialog> createState() => _TrackerDialogState();
}

class _TrackerDialogState extends ConsumerState<_TrackerDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _defaultIntController;
  late final TextEditingController _capController;
  final _lowerFocusNode = FocusNode();
  final _upperFocusNode = FocusNode();
  final List<TextEditingController> _optionControllers = [];
  final List<FocusNode> _optionFocusNodes = [];
  final _newOptionController = TextEditingController();
  final _newOptionFocusNode = FocusNode();
  String? _optionError;
  late TrackerType _type;
  late TrackerCadence _cadence;
  late TrackerStyle _trackingStyle;
  late int _colorValue;
  var _initialized = false;
  late bool _showOnCalendar;
  late bool _hasCap;
  late bool _defaultBool;
  String? _defaultEnumOption;

  @override
  void initState() {
    super.initState();
    final t = widget.tracker;
    _nameController = TextEditingController(text: t?.name ?? '');
    _defaultIntController =
        TextEditingController(text: t?.defaultInt.toString() ?? '0');
    _capController =
        TextEditingController(text: t?.integerCap?.toString() ?? '10');
    _type = t?.type ?? TrackerType.integer;
    _cadence = t?.cadence ?? TrackerCadence.daily;
    _trackingStyle = t?.effectiveTrackingStyle ?? TrackerStyle.independent;
    _colorValue = t?.colorValue ?? 0xFF7C9EFF;
    _showOnCalendar = t?.showOnCalendar ?? false;
    _hasCap = t?.integerCap != null;
    _defaultBool = t?.defaultBool ?? false;
    _defaultEnumOption = t?.defaultEnumOption;
    if (t != null && t.type == TrackerType.enumType) {
      for (final option in t.enumOptions) {
        _optionControllers.add(TextEditingController(text: option));
        _optionFocusNodes.add(FocusNode());
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    if (widget.tracker == null) {
      _colorValue = Theme.of(context).colorScheme.primary.toARGB32();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _defaultIntController.dispose();
    _capController.dispose();
    _lowerFocusNode.dispose();
    _upperFocusNode.dispose();
    for (final controller in _optionControllers) {
      controller.dispose();
    }
    for (final focusNode in _optionFocusNodes) {
      focusNode.dispose();
    }
    _newOptionController.dispose();
    _newOptionFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enumOptions = _enumOptions;
    final accent = Color(_colorValue);
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: accent, width: 3),
      ),
      shadowColor: accent.withValues(alpha: popupGlowAlpha),
      elevation: 24,
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      title: Text(widget.tracker != null ? 'Edit statistic tracker' : 'New statistic tracker'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              VoyagerTextField(
                controller: _nameController,
                autofocus: true,
                accentColor: accent,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  isDense: true,
                  contentPadding: EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 12),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              VoyagerDropdownButtonFormField<TrackerType>(
                initialValue: _type,
                accentColor: accent,
                decoration: const InputDecoration(labelText: 'Type'),
                items: TrackerType.values
                    .map(
                      (type) => DropdownMenuItem(
                        value: type,
                        child: Text(_typeLabel(type)),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setState(() => _type = value ?? _type),
              ),
              // TrackingStyle only for integers
              if (_type == TrackerType.integer) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Display style',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                const SizedBox(height: 6),
                SegmentedButton<TrackerStyle>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    selectedForegroundColor: Colors.white,
                    selectedBackgroundColor: accent,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: TrackerStyle.independent,
                      icon: Icon(PhosphorIconsRegular.squaresFour, size: 16),
                      label: Text('Heatmap'),
                    ),
                    ButtonSegment(
                      value: TrackerStyle.consecutive,
                      icon: Icon(PhosphorIconsRegular.chartLineUp, size: 16),
                      label: Text('Sparkline'),
                    ),
                  ],
                  selected: {_trackingStyle},
                  onSelectionChanged: (set) {
                    if (set.isNotEmpty) {
                      setState(() => _trackingStyle = set.first);
                    }
                  },
                ),
              ],
              const SizedBox(height: 12),
              VoyagerDropdownButtonFormField<TrackerCadence>(
                initialValue: _cadence,
                accentColor: accent,
                decoration: const InputDecoration(labelText: 'Cadence'),
                items: TrackerCadence.values
                    .map(
                      (cadence) => DropdownMenuItem(
                        value: cadence,
                        child: Text(cadence.name),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setState(() => _cadence = value ?? _cadence),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show on calendar'),
                value: _showOnCalendar,
                activeColor: accent,
                onChanged: (value) =>
                    setState(() => _showOnCalendar = value),
              ),
              if (_type == TrackerType.integer) ...[
                if (!_hasCap) ...[
                  VoyagerTextField(
                    controller: _defaultIntController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    accentColor: accent,
                    decoration: const InputDecoration(
                      labelText: 'Default value',
                      isDense: true,
                      contentPadding: EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 12),
                    ),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use limit'),
                  value: _hasCap,
                  activeColor: accent,
                  onChanged: (value) {
                    setState(() => _hasCap = value);
                    if (value) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _upperFocusNode.requestFocus();
                      });
                    }
                  },
                ),
                if (_hasCap) ...[
                  Row(
                    children: [
                      Expanded(
                        child: VoyagerTextField(
                          controller: _defaultIntController,
                          focusNode: _lowerFocusNode,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          accentColor: accent,
                          decoration: const InputDecoration(
                            labelText: 'Lower limit',
                            isDense: true,
                            contentPadding: EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 12),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          '-',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(color: accent),
                        ),
                      ),
                      Expanded(
                        child: VoyagerTextField(
                          controller: _capController,
                          focusNode: _upperFocusNode,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          accentColor: accent,
                          decoration: const InputDecoration(
                            labelText: 'Upper limit',
                            isDense: true,
                            contentPadding: EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
              if (_type == TrackerType.boolean)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Default checked'),
                  value: _defaultBool,
                  activeColor: accent,
                  onChanged: (value) =>
                      setState(() => _defaultBool = value),
                ),
              if (_type == TrackerType.enumType) ...[
                if (_optionControllers.isNotEmpty) ...[
                  ReorderableListView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    onReorderItem: _reorderOptions,
                    children: [
                      for (var i = 0; i < _optionControllers.length; i++)
                        Padding(
                          key: ValueKey(_optionControllers[i]),
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              ReorderableDragStartListener(
                                index: i,
                                child: Icon(
                                  Icons.drag_handle,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: VoyagerTextField(
                                  controller: _optionControllers[i],
                                  focusNode: _optionFocusNodes[i],
                                  accentColor: accent,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    contentPadding: EdgeInsets.only(
                                      left: 16,
                                      right: 16,
                                      top: 0,
                                      bottom: 12,
                                    ),
                                  ),
                                  onChanged: (_) => setState(() {
                                    _optionError = null;
                                    if (!_enumOptions.contains(_defaultEnumOption)) {
                                      _defaultEnumOption = null;
                                    }
                                  }),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(PhosphorIconsRegular.trash),
                                onPressed: () => _removeOption(i),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
                VoyagerTextField(
                  key: const ValueKey('new-option-field'),
                  controller: _newOptionController,
                  focusNode: _newOptionFocusNode,
                  accentColor: accent,
                  decoration: const InputDecoration(
                    labelText: 'Add option',
                    isDense: true,
                    contentPadding: EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 12),
                  ),
                  onChanged: (_) {
                    if (_optionError != null) setState(() => _optionError = null);
                  },
                  onSubmitted: (_) => _addOption(),
                ),
                if (_optionError != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 16, top: 4),
                    child: Text(
                      _optionError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (enumOptions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  VoyagerDropdownButtonFormField<String>(
                    initialValue: enumOptions.contains(_defaultEnumOption)
                        ? _defaultEnumOption
                        : null,
                    accentColor: accent,
                    decoration: const InputDecoration(
                      labelText: 'Default option',
                    ),
                    items: enumOptions
                        .map(
                          (option) => DropdownMenuItem(
                            value: option,
                            child: Text(option),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _defaultEnumOption = value),
                  ),
                ],
              ],
              const SizedBox(height: 12),
              ColorPickerField(
                label: 'Tracker color',
                value: _colorValue,
                maxHeight: paletteViewportHeight(18, visibleRows: 3, clipPartialNextRow: true) - 4,
                onChanged: (value) =>
                    setState(() => _colorValue = value),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(
            foregroundColor: accent,
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: accent,
          ),
          child: Text(widget.tracker != null ? 'Save' : 'Create'),
        ),
      ],
    );
  }

  List<String> get _enumOptions => _optionControllers
      .map((controller) => controller.text.trim())
      .where((option) => option.isNotEmpty)
      .toList();

  void _addOption() {
    final text = _newOptionController.text.trim();
    if (text.isEmpty) return;
    if (_enumOptions.contains(text)) {
      setState(() => _optionError = 'This option already exists');
      return;
    }
    setState(() {
      _optionControllers.add(TextEditingController(text: text));
      _optionFocusNodes.add(FocusNode());
      _newOptionController.clear();
      _optionError = null;
    });
    _newOptionFocusNode.requestFocus();
  }

  void _removeOption(int index) {
    setState(() {
      _optionControllers.removeAt(index).dispose();
      _optionFocusNodes.removeAt(index).dispose();
      _optionError = null;
      if (!_enumOptions.contains(_defaultEnumOption)) {
        _defaultEnumOption = null;
      }
    });
  }

  void _reorderOptions(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    setState(() {
      final controller = _optionControllers.removeAt(oldIndex);
      final focusNode = _optionFocusNodes.removeAt(oldIndex);
      _optionControllers.insert(newIndex, controller);
      _optionFocusNodes.insert(newIndex, focusNode);
    });
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    if (_type == TrackerType.enumType) {
      final pending = _newOptionController.text.trim();
      if (pending.isNotEmpty) {
        if (_enumOptions.contains(pending)) {
          setState(() => _optionError = 'This option already exists');
          _newOptionFocusNode.requestFocus();
          return;
        }
        setState(() {
          _optionControllers.add(TextEditingController(text: pending));
          _optionFocusNodes.add(FocusNode());
          _newOptionController.clear();
        });
      }
    }

    final enumOptions = _enumOptions;
    if (_type == TrackerType.enumType) {
      if (enumOptions.isEmpty) return;
      if (enumOptions.toSet().length != enumOptions.length) {
        setState(() => _optionError = 'Options must be unique');
        return;
      }
    }
    final now = utcNow();
    Navigator.pop(
      context,
      StatisticTracker(
        id: widget.tracker?.id ?? newId(),
        name: name,
        type: _type,
        cadence: _cadence,
        colorValue: _colorValue,
        showOnCalendar: _showOnCalendar,
        integerCap: _type == TrackerType.integer && _hasCap
            ? int.tryParse(_capController.text.trim())
            : null,
        defaultInt: int.tryParse(_defaultIntController.text.trim()) ?? 0,
        defaultBool: _defaultBool,
        enumOptions: enumOptions,
        defaultEnumOption: _defaultEnumOption,
        // Only set trackingStyle for integer type; null for others
        trackingStyle:
            _type == TrackerType.integer ? _trackingStyle : null,
        starred: widget.tracker?.starred ?? false,
        sortOrder: widget.tracker?.sortOrder ?? 0,
        createdAt: widget.tracker?.createdAt ?? now,
        updatedAt: now,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

String _typeLabel(TrackerType type) {
  return switch (type) {
    TrackerType.integer => 'Integer',
    TrackerType.boolean => 'Boolean',
    TrackerType.enumType => 'Dropdown',
  };
}

