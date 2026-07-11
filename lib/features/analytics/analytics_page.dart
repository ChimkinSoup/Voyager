import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';
import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/services/analytics_service.dart';
import 'package:voyager/features/analytics/ranking_prompt_banner.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/features/dev/dev_calendar_debug_tile.dart';
import 'package:flutter/services.dart';

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
    final rankingConfigsAsync = ref.watch(rankingConfigsProvider);
    final analytics = ref.watch(analyticsServiceProvider);
    final prompt = ref.watch(periodicPromptServiceProvider);
    final viewMode = ref.watch(_analyticsViewModeProvider);

    return trackersAsync.when(
      data: (trackers) => entriesAsync.when(
        data: (entries) => rankingConfigsAsync.when(
          data: (rankingConfigs) {
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
                  rankingConfigs: rankingConfigs,
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
    required this.rankingConfigs,
    required this.hasTrackers,
    required this.trackers,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.onCreateTracker,
  });

  final int totalEntries;
  final int totalWords;
  final int longestStreak;
  final List<RankingConfig> rankingConfigs;
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
                    if (rankingConfigs.isNotEmpty) ...[
                      Text(
                        'Periodic Rankings',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
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
                            const SizedBox(width: 8),
                            if (selectedTracker?.effectiveTrackingStyle !=
                                TrackerStyle.consecutive) ...[
                              SegmentedButton<_CalendarScale>(
                                showSelectedIcon: false,
                                style: SegmentedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                ),
                                segments: const [
                                  ButtonSegment(
                                    value: _CalendarScale.month,
                                    label: Text('Month'),
                                  ),
                                  ButtonSegment(
                                    value: _CalendarScale.year,
                                    label: Text('Year'),
                                  ),
                                ],
                                selected: {scale},
                                onSelectionChanged: (set) {
                                  if (set.isNotEmpty) {
                                    ref.read(_calendarTimeScaleProvider.notifier).state =
                                        set.first;
                                  }
                                },
                              ),
                              const SizedBox(width: 8),
                            ],
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
            const SizedBox(width: 8),
            _AddRankingButton(),
          ],
        ),
        if (rankingConfigs.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final config in rankingConfigs) _RankingCard(config: config),
        ],
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

// ---------------------------------------------------------------------------
// Add Ranking button (extracted so it can be used in two places)
// ---------------------------------------------------------------------------

class _AddRankingButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton.icon(
      onPressed: () async {
        final config = await showDialog<RankingConfig>(
          context: context,
          builder: (_) => const _RankingDialog(),
        );
        if (config == null) return;
        await ref.read(trackerRepositoryProvider).upsertRankingConfig(config);
        ref.invalidate(rankingConfigsProvider);
      },
      icon: const Icon(PhosphorIconsRegular.plus, size: 16),
      label: const Text('New ranking'),
    );
  }
}

// ---------------------------------------------------------------------------
// Rankings (kept as-is from original)
// ---------------------------------------------------------------------------

class _RankingCard extends ConsumerWidget {
  const _RankingCard({required this.config});

  final RankingConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(rankingValuesProvider(config.id));
    final weekStartsMonday =
        ref.watch(settingsProvider).value?.weekStartsOnMonday ?? true;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: valuesAsync.when(
          data: (values) {
            final sorted = [...values]
              ..sort((a, b) => a.periodStart.compareTo(b.periodStart));
            final lastCompleted =
                sorted.isEmpty ? null : sorted.last.periodStart;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        config.name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      '${config.cadence.name} / 1-${config.maxValue}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                RankingPromptBanner(
                  cadence: config.cadence,
                  maxValue: config.maxValue,
                  lastCompleted: lastCompleted,
                  weekStartsMonday: weekStartsMonday,
                  onSubmit: (value) =>
                      _saveRanking(ref, value, weekStartsMonday),
                ),
                if (sorted.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 80,
                    child: LineChart(
                      LineChartData(
                        minY: 1,
                        maxY: config.maxValue.toDouble(),
                        gridData: const FlGridData(show: false),
                        titlesData: const FlTitlesData(show: false),
                        borderData: FlBorderData(show: false),
                        lineBarsData: [
                          LineChartBarData(
                            spots: [
                              for (var i = 0; i < sorted.length; i++)
                                FlSpot(i.toDouble(), sorted[i].value.toDouble()),
                            ],
                            isCurved: true,
                            preventCurveOverShooting: true,
                            preventCurveOvershootingThreshold: 0,
                            color: Color(config.colorStart),
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: Color(config.colorStart).withValues(alpha: 0.1),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('$e'),
        ),
      ),
    );
  }

  Future<void> _saveRanking(
    WidgetRef ref,
    int value,
    bool weekStartsMonday,
  ) async {
    final periodStart = _periodStart(
      DateTime.now(),
      config.cadence,
      weekStartsMonday: weekStartsMonday,
    );
    final now = utcNow();
    await ref.read(trackerRepositoryProvider).upsertRankingValue(
          RankingValue(
            id: '${config.id}_${periodStart.millisecondsSinceEpoch}',
            configId: config.id,
            periodStart: periodStart,
            value: value,
            createdAt: now,
            updatedAt: now,
          ),
        );
    ref.invalidate(rankingValuesProvider(config.id));
  }
}

// ---------------------------------------------------------------------------
// Ranking Dialog (kept as-is)
// ---------------------------------------------------------------------------

class _RankingDialog extends ConsumerStatefulWidget {
  const _RankingDialog();

  @override
  ConsumerState<_RankingDialog> createState() => _RankingDialogState();
}

class _RankingDialogState extends ConsumerState<_RankingDialog> {
  final _nameController = TextEditingController(text: 'Weekly review');
  final _maxController = TextEditingController(text: '10');
  var _cadence = TrackerCadence.weekly;
  late int _colorStart;
  late int _colorEnd;
  var _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final palette = ref.read(colorPaletteProvider);
    _colorStart =
        palette.contains(0xFF4CAF50) ? 0xFF4CAF50 : palette.first;
    _colorEnd = palette.contains(0xFFF44336) ? 0xFFF44336 : palette.last;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _maxController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New periodic ranking'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            VoyagerTextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            VoyagerDropdownButtonFormField<TrackerCadence>(
              initialValue: _cadence,
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
            VoyagerTextField(
              controller: _maxController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Max value'),
            ),
            const SizedBox(height: 12),
            ColorPickerField(
              label: 'Low score color',
              value: _colorStart,
              onChanged: (value) => setState(() => _colorStart = value),
            ),
            const SizedBox(height: 12),
            ColorPickerField(
              label: 'High score color',
              value: _colorEnd,
              onChanged: (value) => setState(() => _colorEnd = value),
            ),
          ],
        ),
      ),
    ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    final maxValue = int.tryParse(_maxController.text.trim()) ?? 10;
    if (name.isEmpty || maxValue < 2) return;
    final now = utcNow();
    Navigator.pop(
      context,
      RankingConfig(
        id: newId(),
        name: name,
        cadence: _cadence,
        maxValue: maxValue,
        colorStart: _colorStart,
        colorEnd: _colorEnd,
        createdAt: now,
        updatedAt: now,
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
      height: 64,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            // Chart fills entire row
            valuesAsync.when(
              data: (values) {
                if (values.isEmpty) {
                  return const SizedBox.expand();
                }
                final now = DateTime.now();
                final from = now.subtract(const Duration(days: 89));
                final spots = analytics.interpolateConsecutive(
                  values: values,
                  from: from,
                  to: now,
                );
                if (spots.isEmpty) return const SizedBox.expand();
                final maxY = spots
                    .map((s) => s.y)
                    .fold<double>(1, (m, y) => y > m ? y : m);
                return LineChart(
                  LineChartData(
                    minY: 0,
                    maxY: maxY <= 0 ? 1 : maxY * 1.15,
                    gridData: const FlGridData(show: false),
                    titlesData: const FlTitlesData(show: false),
                    borderData: FlBorderData(show: false),
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
              loading: () => const SizedBox.expand(),
              error: (_, __) => const SizedBox.expand(),
            ),
            // Label overlay
            Positioned(
              left: 10,
              top: 0,
              bottom: 0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    tracker.name,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      shadows: [
                        const Shadow(
                          blurRadius: 6,
                          color: Colors.black38,
                        ),
                      ],
                    ),
                  ),
                  Text(
                    tracker.cadence.name,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Heatmap Grid
// ---------------------------------------------------------------------------

class _HeatmapGrid extends StatelessWidget {
  const _HeatmapGrid({required this.trackers, required this.analytics});

  final List<StatisticTracker> trackers;
  final AnalyticsService analytics;

  @override
  Widget build(BuildContext context) {
    // Group by cadence with dividers between groups
    final byGroup = <TrackerCadence, List<StatisticTracker>>{};
    for (final t in trackers) {
      byGroup.putIfAbsent(t.cadence, () => []).add(t);
    }
    final groups = TrackerCadence.values
        .where((c) => byGroup.containsKey(c))
        .toList();

    final rows = <Widget>[];
    for (var gi = 0; gi < groups.length; gi++) {
      if (gi > 0) {
        rows.add(const Divider(
          height: 24,
          thickness: 0.5,
          indent: 0,
          endIndent: 0,
        ));
      }
      final groupTrackers = byGroup[groups[gi]]!;
      for (final tracker in groupTrackers) {
        rows.add(_HeatmapRow(tracker: tracker, analytics: analytics));
        rows.add(const SizedBox(height: 6));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

// ---------------------------------------------------------------------------
// Single Heatmap Row
// ---------------------------------------------------------------------------

class _HeatmapRow extends ConsumerWidget {
  const _HeatmapRow({required this.tracker, required this.analytics});

  final StatisticTracker tracker;
  final AnalyticsService analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(trackerValuesProvider(tracker.id));
    final theme = Theme.of(context);
    final color = Color(tracker.colorValue);

    return valuesAsync.when(
      data: (values) {
        // Compute rolling max for intensity normalisation
        final max = analytics.rollingMax(values);

        // Build the last 30 period dates for this cadence
        final periods = _lastNPeriods(30);

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
              ],
            ),
            const SizedBox(height: 4),
            // Scrollable squares
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final period in periods)
                    _HeatmapSquare(
                      tracker: tracker,
                      values: values,
                      periodDate: period,
                      maxInPeriod: max,
                      analytics: analytics,
                    ),
                ],
              ),
            ),
          ],
        );
      },
      loading: () => const SizedBox(height: 40, child: LinearProgressIndicator()),
      error: (e, _) => Text('$e'),
    );
  }

  /// Returns the last [n] period start dates for this tracker's cadence,
  /// oldest first.
  List<DateTime> _lastNPeriods(int n) {
    final today = DateTime.now();
    final todayLocal = DateTime(today.year, today.month, today.day);
    final periods = <DateTime>[];
    for (var i = n - 1; i >= 0; i--) {
      final candidate = switch (tracker.cadence) {
        TrackerCadence.daily => todayLocal.subtract(Duration(days: i)),
        TrackerCadence.weekly => todayLocal.subtract(Duration(days: i * 7)),
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
// Single Heatmap Square
// ---------------------------------------------------------------------------

class _HeatmapSquare extends ConsumerStatefulWidget {
  const _HeatmapSquare({
    required this.tracker,
    required this.values,
    required this.periodDate,
    required this.maxInPeriod,
    required this.analytics,
  });

  final StatisticTracker tracker;
  final List<TrackerValue> values;
  final DateTime periodDate;
  final int maxInPeriod;
  final AnalyticsService analytics;

  @override
  ConsumerState<_HeatmapSquare> createState() => _HeatmapSquareState();
}

class _HeatmapSquareState extends ConsumerState<_HeatmapSquare> {
  final _key = GlobalKey();

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

    return GestureDetector(
      key: _key,
      onTap: _openPopover,
      child: Container(
        width: 28,
        height: 28,
        margin: const EdgeInsets.only(right: 4),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(5),
        ),
      ),
    );
  }

  void _openPopover() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final offset = box.localToGlobal(Offset.zero);
    final rect = offset & box.size;

    showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => _HeatmapPopover(
        tracker: widget.tracker,
        periodDate: widget.periodDate,
        anchorRect: rect,
        initialValue: _findValue(),
        onSaved: () {
          ref.invalidate(trackerValuesProvider(widget.tracker.id));
          ref.invalidate(pendingStatEntriesProvider);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Heatmap square popover
// ---------------------------------------------------------------------------

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

class _HeatmapPopoverState extends ConsumerState<_HeatmapPopover> {
  late final TextEditingController _intController;
  bool? _boolValue;
  String? _enumValue;

  @override
  void initState() {
    super.initState();
    _intController = TextEditingController(
      text:
          (widget.initialValue?.intValue ?? widget.tracker.defaultInt).toString(),
    );
    _boolValue = widget.initialValue?.boolValue ?? widget.tracker.defaultBool;
    _enumValue = widget.initialValue?.enumValue ??
        widget.tracker.defaultEnumOption;
  }

  @override
  void dispose() {
    _intController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        // Dismiss tapping outside
        Positioned.fill(
          child: GestureDetector(
            onTap: Navigator.of(context).pop,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),
        // Popover card, positioned near the square
        Positioned(
          left: widget.anchorRect.left.clamp(0, double.infinity),
          top: widget.anchorRect.bottom + 6,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            color: theme.colorScheme.surface,
            child: SizedBox(
              width: 280,
              child: Padding(
                padding: const EdgeInsets.all(14),
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
                    _valueEditor(theme),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (widget.initialValue != null) ...[
                          TextButton(
                            onPressed: _delete,
                            style: TextButton.styleFrom(
                              foregroundColor: theme.colorScheme.error,
                            ),
                            child: const Text('Delete'),
                          ),
                          const Spacer(),
                        ],
                        TextButton(
                          onPressed: Navigator.of(context).pop,
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _save,
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _valueEditor(ThemeData theme) {
    switch (widget.tracker.type) {
      case TrackerType.integer:
        final cap = widget.tracker.integerCap;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cap != null) ...[
              Slider(
                min: 0,
                max: cap.toDouble(),
                divisions: cap == 0 ? null : cap,
                value: (int.tryParse(_intController.text) ?? 0)
                    .clamp(0, cap)
                    .toDouble(),
                onChanged: (v) =>
                    setState(() => _intController.text = v.round().toString()),
              ),
            ],
            VoyagerTextField(
              controller: _intController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Value',
                helperText: cap == null ? null : '0–$cap',
                isDense: true,
              ),
            ),
          ],
        );
      case TrackerType.boolean:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Completed'),
          value: _boolValue ?? false,
          onChanged: (v) => setState(() => _boolValue = v),
        );
      case TrackerType.enumType:
        final options = widget.tracker.enumOptions;
        return VoyagerDropdownButtonFormField<String>(
          initialValue: options.contains(_enumValue) ? _enumValue : null,
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

  String _formatDate(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
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
        else if (scale == _CalendarScale.month)
          _MonthHeatmapCalendar(
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

    showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => _HeatmapPopover(
        tracker: widget.tracker!,
        periodDate: widget.periodDate!,
        anchorRect: rect,
        initialValue: widget.value,
        onSaved: () {
          ref.invalidate(trackerValuesProvider(widget.tracker!.id));
          ref.invalidate(pendingStatEntriesProvider);
        },
      ),
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
                      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5),
                      width: 1,
                    ),
                  ),
                )
              : GestureDetector(
                  key: _key,
                  onTap: _openPopover,
                  child: Container(
                    decoration: BoxDecoration(
                      color: widget.intensity == 0
                          ? widget.color.withValues(alpha: 0.10)
                          : widget.color.withValues(alpha: 0.15 + 0.85 * widget.intensity),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: widget.color.withValues(alpha: 0.3),
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
    final color = Color(tracker.colorValue);

    return valuesAsync.when(
      data: (values) {
        final now = DateTime.now();
        final max = analytics.rollingMax(values, days: 366);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${now.year}', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            // 52 weeks × 7 days grid
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(53, (weekIdx) {
                  return Column(
                    children: List.generate(7, (dayOfWeek) {
                      final date = DateTime(now.year, 1, 1)
                          .add(Duration(days: weekIdx * 7 + dayOfWeek));
                      if (date.year != now.year) {
                        return const SizedBox(width: 14, height: 14);
                      }
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
                      return Container(
                        width: 12,
                        height: 12,
                        margin: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          color: intensity == 0
                              ? color.withValues(alpha: 0.08)
                              : color.withValues(
                                  alpha: 0.15 + 0.85 * intensity),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      );
                    }),
                  );
                }),
              ),
            ),
          ],
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
// Tracker creation dialog (updated with trackingStyle)
// ---------------------------------------------------------------------------

class _TrackerDialog extends ConsumerStatefulWidget {
  const _TrackerDialog();

  @override
  ConsumerState<_TrackerDialog> createState() => _TrackerDialogState();
}

class _TrackerDialogState extends ConsumerState<_TrackerDialog> {
  final _nameController = TextEditingController();
  final _defaultIntController = TextEditingController(text: '0');
  final _capController = TextEditingController(text: '10');
  final _optionsController = TextEditingController();
  var _type = TrackerType.integer;
  var _cadence = TrackerCadence.daily;
  var _trackingStyle = TrackerStyle.independent;
  late int _colorValue;
  var _initialized = false;
  var _showOnCalendar = false;
  var _hasCap = false;
  var _defaultBool = false;
  String? _defaultEnumOption;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final palette = ref.read(colorPaletteProvider);
    _colorValue =
        palette.isNotEmpty ? palette.first : defaultColorPalette.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _defaultIntController.dispose();
    _capController.dispose();
    _optionsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enumOptions = _enumOptions;
    return AlertDialog(
      title: const Text('New statistic tracker'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              VoyagerTextField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              VoyagerDropdownButtonFormField<TrackerType>(
                initialValue: _type,
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
              ColorPickerField(
                label: 'Tracker color',
                value: _colorValue,
                onChanged: (value) =>
                    setState(() => _colorValue = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show on calendar'),
                value: _showOnCalendar,
                onChanged: (value) =>
                    setState(() => _showOnCalendar = value),
              ),
              if (_type == TrackerType.integer) ...[
                VoyagerTextField(
                  controller: _defaultIntController,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Default value'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use cap'),
                  value: _hasCap,
                  onChanged: (value) =>
                      setState(() => _hasCap = value),
                ),
                if (_hasCap)
                  VoyagerTextField(
                    controller: _capController,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Cap'),
                  ),
              ],
              if (_type == TrackerType.boolean)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Default checked'),
                  value: _defaultBool,
                  onChanged: (value) =>
                      setState(() => _defaultBool = value),
                ),
              if (_type == TrackerType.enumType) ...[
                VoyagerTextField(
                  controller: _optionsController,
                  decoration: const InputDecoration(
                    labelText: 'Options',
                    helperText: 'Comma-separated, e.g. Gym A, Gym B',
                  ),
                  onChanged: (_) => setState(() {
                    if (!enumOptions.contains(_defaultEnumOption)) {
                      _defaultEnumOption = null;
                    }
                  }),
                ),
                const SizedBox(height: 12),
                VoyagerDropdownButtonFormField<String>(
                  initialValue: enumOptions.contains(_defaultEnumOption)
                      ? _defaultEnumOption
                      : null,
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
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }

  List<String> get _enumOptions => _optionsController.text
      .split(',')
      .map((option) => option.trim())
      .where((option) => option.isNotEmpty)
      .toSet()
      .toList();

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final enumOptions = _enumOptions;
    if (_type == TrackerType.enumType && enumOptions.isEmpty) return;
    final now = utcNow();
    Navigator.pop(
      context,
      StatisticTracker(
        id: newId(),
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
        createdAt: now,
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

DateTime _periodStart(
  DateTime date,
  TrackerCadence cadence, {
  required bool weekStartsMonday,
}) {
  final local = DateTime(date.year, date.month, date.day);
  return switch (cadence) {
    TrackerCadence.daily => local,
    TrackerCadence.weekly => local.subtract(
        Duration(
          days: weekStartsMonday
              ? local.weekday - DateTime.monday
              : local.weekday % 7,
        ),
      ),
    TrackerCadence.monthly => DateTime(local.year, local.month),
    TrackerCadence.yearly => DateTime(local.year),
  };
}
