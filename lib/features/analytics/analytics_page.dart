import 'dart:async';
import 'dart:math' as math;
import 'package:intl/intl.dart';
import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/analytics_service.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/features/analytics/sparkline_touch.dart';
import 'package:voyager/features/analytics/stat_number_format.dart';
import 'package:voyager/features/calendar/calendar_keyboard_shortcuts.dart';
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
// Detail view state
// ---------------------------------------------------------------------------

/// True while a tracker row in the heatmap grid is being drag-reordered.
/// Watched by the hover/tap value popup so it stays hidden for the whole
/// grid during a drag, instead of popping up over whatever square the
/// pointer happens to pass under mid-drag.
final _heatmapDraggingProvider = StateProvider<bool>((_) => false);

final _calendarViewYearProvider = StateProvider<int>(
  (_) => DateTime.now().year,
);

/// Older (top-row) year of the 2-year window shown by [_MonthGridCalendar].
final _calendarViewMonthlyBaseYearProvider = StateProvider<int>(
  (_) => DateTime.now().year - 1,
);

/// Oldest (leftmost) year of the 10-year window shown by [_YearGridCalendar].
final _calendarViewYearlyBaseYearProvider = StateProvider<int>(
  (_) => DateTime.now().year - 9,
);

/// Years spanned by [_MonthGridCalendar] (one row per year), and so also how
/// far one page step moves it — paging by the full window means each step
/// lands on a fresh block instead of overlapping what was just on screen.
/// Shared with [_StatisticDetailPopup._page] so the chevrons and the arrow
/// keys can't drift apart from what's actually rendered.
const _monthGridWindowYears = 2;

/// Years spanned by [_YearGridCalendar] (one box per year); same paging rule
/// as [_monthGridWindowYears].
const _yearGridWindowYears = 10;

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

    return trackersAsync.when(
      data: (trackers) => entriesAsync.when(
        data: (entries) {
          final words = entries.fold<int>(
            0,
            (sum, e) => sum + analytics.countWords(e.body),
          );
          final streak = prompt.longestJournalStreak(entries);
          // Prepend built-in default trackers (e.g. Journal Entries) when the
          // per-view setting is on. These are virtual — see
          // [buildJournalEntriesTracker] — and each view has its own toggle.
          final settings = ref.watch(settingsProvider).valueOrNull;
          final showDefaultsInGrid =
              settings?.showDefaultTrackersInGrid ?? true;
          final accent = Theme.of(context).colorScheme.primary.toARGB32();
          final defaultTracker = buildJournalEntriesTracker(colorValue: accent);
          final gridTrackers = <StatisticTracker>[
            if (showDefaultsInGrid) defaultTracker,
            ...trackers,
          ];
          return KeepAliveScrollView(
            storageKey: ShellPageStorageKeys.analyticsList,
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            children: [
              // ── Macro Stats Row ───────────────────────────────────────
              // Each chip opens the same detail popup a tracker tile does,
              // backed by a virtual tracker derived from journal entries.
              _MacroStatsRow(
                totalEntries: analytics.totalJournalEntries(entries),
                totalWords: words,
                longestStreak: streak,
                analytics: analytics,
                entriesTracker: defaultTracker,
                streakTracker: buildStreakTracker(colorValue: accent),
                wordCountTracker: buildWordCountTracker(colorValue: accent),
              ),
              const SizedBox(height: 12),
              // ── Toolbar + tracker grid ────────────────────────────────
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _AnalyticsToolbar(
                    onCreateTracker: () => _createTracker(context, ref),
                  ),
                  const SizedBox(height: 12),
                  if (gridTrackers.isEmpty)
                    const _EmptyTrackersCard()
                  else
                    _GridView(trackers: gridTrackers, analytics: analytics),
                ],
              ),
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
// Macro Stats Row
// ---------------------------------------------------------------------------

class _MacroStatsRow extends StatelessWidget {
  const _MacroStatsRow({
    required this.totalEntries,
    required this.totalWords,
    required this.longestStreak,
    required this.analytics,
    required this.entriesTracker,
    required this.streakTracker,
    required this.wordCountTracker,
  });

  final int totalEntries;
  final int totalWords;
  final int longestStreak;
  final AnalyticsService analytics;

  /// The virtual trackers each chip drills into. Built by the caller so the
  /// chips and the popup agree on colour and identity.
  final StatisticTracker entriesTracker;
  final StatisticTracker streakTracker;
  final StatisticTracker wordCountTracker;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return IntrinsicHeight(
      child: Row(
        children: [
          _StatChip(
            label: 'Entries',
            value: compactNumberLabel(totalEntries),
            icon: PhosphorIconsRegular.notebook,
            accent: accent,
            onTap: () => _showStatisticDetail(
              context: context,
              tracker: entriesTracker,
              analytics: analytics,
            ),
          ),
          const SizedBox(width: 10),
          _StatChip(
            label: 'Words',
            value: compactNumberLabel(totalWords),
            icon: PhosphorIconsRegular.textAa,
            accent: accent,
            onTap: () => _showStatisticDetail(
              context: context,
              tracker: wordCountTracker,
              analytics: analytics,
            ),
          ),
          const SizedBox(width: 10),
          _StatChip(
            label: 'Best Streak',
            value: '${compactNumberLabel(longestStreak)} days',
            icon: PhosphorIconsRegular.flame,
            accent: accent,
            onTap: () => _showStatisticDetail(
              context: context,
              tracker: streakTracker,
              analytics: analytics,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Analytics Toolbar — view mode toggle, tracker selector, new tracker button
// ---------------------------------------------------------------------------

class _AnalyticsToolbar extends StatelessWidget {
  const _AnalyticsToolbar({required this.onCreateTracker});

  final VoidCallback onCreateTracker;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        FilledButton.icon(
          onPressed: onCreateTracker,
          icon: const Icon(PhosphorIconsRegular.plus, size: 16),
          label: const Text('New tracker'),
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
    required this.icon,
    required this.accent,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Material(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accent.withValues(alpha: 0.18)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 18, color: accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
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
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
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

/// Makes a whole grid tile — the full bar out to the right edge, not just its
/// label — both the hover target and the tap target for opening [tracker]'s
/// detail popup.
///
/// The tap target sits *behind* the tile's content. The chart and the heatmap
/// squares handle their own taps (which mean "edit this period's value"), so
/// only taps landing in the surrounding chrome fall through to here — one
/// gesture can't mean two things.
///
/// [dragIndex], when set, also makes that same chrome the drag handle for
/// reordering the row at that index: press and hold the chrome to drag, press
/// and release it to open the detail popup. Both gestures hang off the
/// *behind* layer deliberately, so the split follows the hit test rather than
/// a timer — anything the content above claims (the sparkline, a heatmap
/// square) never reaches this layer at all and so can neither drag the row nor
/// open the detail popup. That's what leaves a press on the sparkline itself
/// free to mean "edit this period", however long it's held: fl_chart registers
/// its own tap *and* long-press recognizers, so it wins the pointer over the
/// plot either way.
///
/// Hover is the opposite: its [MouseRegion] sits above everything and doesn't
/// absorb events, because a highlight driven from behind the content would
/// blink out every time the pointer crossed the chart or a square.
///
/// The tile's fill and border come in through [decoration] and are painted by
/// *this* widget, in a layer of their own below the gestures, rather than by
/// the content [builder] returns. That split isn't cosmetic: a decoration is
/// opaque to hit testing wherever its shape covers
/// ([RenderDecoratedBox.hitTestSelf] asks [BoxDecoration.hitTest], which
/// answers for the shape and ignores how transparent the paint is). A
/// decorated `Container` in the content layer therefore swallowed every
/// pointer that landed on chrome before it could reach the layer beneath —
/// which is the whole tile except the chart and the squares, i.e. exactly the
/// region that is supposed to open the popup and start a drag. Neither
/// gesture fired anywhere.
class _StatTile extends StatefulWidget {
  const _StatTile({
    required this.tracker,
    required this.analytics,
    required this.decoration,
    required this.builder,
    this.dragIndex,
  });

  final StatisticTracker tracker;
  final AnalyticsService analytics;

  /// The tile's fill and border for the current hover state. Painted behind
  /// the gesture layer — see the note on hit testing above.
  final BoxDecoration Function(bool hovered) decoration;

  /// The tile's content, *without* a decoration of its own.
  final Widget Function(BuildContext context, bool hovered) builder;

  /// This row's position in its reorderable list, or null when the row isn't
  /// reorderable (or reorders from its own handle elsewhere).
  final int? dragIndex;

  @override
  State<_StatTile> createState() => _StatTileState();
}

class _StatTileState extends State<_StatTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    Widget tapTarget = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showStatisticDetail(
        context: context,
        tracker: widget.tracker,
        analytics: widget.analytics,
      ),
    );
    final dragIndex = widget.dragIndex;
    if (dragIndex != null) {
      tapTarget = _QuickDelayedDragStartListener(
        index: dragIndex,
        child: tapTarget,
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        children: [
          // Bottom of the stack: the tile's fill and border, held clear of
          // hit testing so they can't intercept the gestures below them.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(decoration: widget.decoration(_hovered)),
            ),
          ),
          // Hit-tested only where the content above doesn't claim the pointer.
          Positioned.fill(child: tapTarget),
          widget.builder(context, _hovered),
        ],
      ),
    );
  }
}

/// Like [ReorderableDelayedDragStartListener], but lifts into a drag after a
/// shorter hold. The framework default ([ReorderableDelayedDragStartListener],
/// via [DelayedMultiDragGestureRecognizer]) is [kLongPressTimeout] = 500 ms;
/// stat rows drag from a 200 ms hold so reordering feels quicker without
/// colliding with the plain tap that opens the detail popup.
class _QuickDelayedDragStartListener extends ReorderableDragStartListener {
  const _QuickDelayedDragStartListener({
    required super.child,
    required super.index,
  });

  static const _delay = Duration(milliseconds: 200);

  @override
  MultiDragGestureRecognizer createRecognizer() {
    return DelayedMultiDragGestureRecognizer(delay: _delay, debugOwner: this);
  }
}

// ---------------------------------------------------------------------------
// Sparkline Stack
// ---------------------------------------------------------------------------

/// The consecutive section's rows, as one flat freely-reorderable list.
///
/// Unlike the heatmap — which splits into starred and per-cadence buckets —
/// consecutive trackers reorder as a single group, so a row can be dragged
/// anywhere in the section regardless of its cadence.
///
/// Dragging starts on a *long press anywhere* on the row rather than from a
/// handle. A row is almost entirely chart, and the chart already claims plain
/// hover (tooltip) and plain tap (edit that period); requiring the press to be
/// held is what keeps those three gestures distinguishable on one surface.
class _SparklineStack extends ConsumerStatefulWidget {
  const _SparklineStack({required this.trackers, required this.analytics});

  final List<StatisticTracker> trackers;
  final AnalyticsService analytics;

  @override
  ConsumerState<_SparklineStack> createState() => _SparklineStackState();
}

class _SparklineStackState extends ConsumerState<_SparklineStack> {
  late List<StatisticTracker> _items;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.trackers)..sort(_compareTrackerOrder);
  }

  @override
  void didUpdateWidget(covariant _SparklineStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameTrackerIds(widget.trackers, _items)) {
      // Membership changed (tracker added, removed, or switched tracking
      // style) — adopt the incoming set outright.
      _items = List.of(widget.trackers)..sort(_compareTrackerOrder);
      return;
    }
    // Same membership: refresh the tracker objects (an edited name or colour)
    // while preserving the current local order, so an in-flight reorder's
    // optimistic UI isn't reverted by an unrelated rebuild before the write
    // finishes.
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
      onReorderStart: (_) =>
          ref.read(_heatmapDraggingProvider.notifier).state = true,
      onReorderEnd: (_) =>
          ref.read(_heatmapDraggingProvider.notifier).state = false,
      proxyDecorator: (child, index, animation) =>
          Material(type: MaterialType.transparency, child: child),
      children: [
        for (var i = 0; i < _items.length; i++)
          _SparklineRow(
            key: ValueKey(_items[i].id),
            tracker: _items[i],
            analytics: widget.analytics,
            // The drag handle is the row's chrome, not the whole row — see
            // [_StatTile]. Wrapping the row itself would have made a hold on
            // the sparkline drag it, stealing the press that means "edit this
            // period".
            dragIndex: i,
          ),
      ],
    );
  }
}

class _SparklineRow extends ConsumerWidget {
  const _SparklineRow({
    super.key,
    required this.tracker,
    required this.analytics,
    this.dragIndex,
  });

  final StatisticTracker tracker;
  final AnalyticsService analytics;
  final int? dragIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(trackerValuesProvider(tracker.id));
    final theme = Theme.of(context);
    final color = Color(tracker.colorValue);
    final promptService = ref.watch(periodicPromptServiceProvider);
    final weekStartsMonday =
        ref.watch(settingsProvider).value?.weekStartsOnMonday ?? true;

    // The gap between rows lives outside the tile, so the tile's own
    // decoration and gesture layers ([_StatTile]) line up exactly with each
    // other and stop at the visible edge rather than running into the gap.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _StatTile(
        tracker: tracker,
        analytics: analytics,
        // Around the sparkline: short press opens the detail popup, hold drags
        // the row. On the sparkline itself both gestures belong to the chart
        // and mean "edit this period".
        dragIndex: dragIndex,
        decoration: (hovered) => BoxDecoration(
          color: color.withValues(alpha: hovered ? 0.12 : 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: color.withValues(alpha: hovered ? 0.35 : 0.15),
          ),
        ),
        builder: (context, hovered) => Container(
          height: 120,
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left side: labels. Opening the detail popup is handled by the
              // whole-tile hitbox in [_StatTile], so nothing here needs its own
              // tap target — and [IgnorePointer] is what lets that hitbox see
              // the press at all, since a [Text] hit-tests as opaque
              // ([RenderParagraph.hitTestSelf] is unconditionally true) and
              // would otherwise make the entire label column a dead zone.
              IgnorePointer(
                child: SizedBox(
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
              ),
              const SizedBox(width: 12),
              // Middle: Chart
              Expanded(
                child: valuesAsync.when(
                  data: (values) {
                    final now = DateTime.now();
                    final nowLocal = DateTime(now.year, now.month, now.day);
                    // Calendar days throughout, so the window starts on local
                    // midnight of a real date rather than 23:00 the evening
                    // before — everything below measures x as an offset from
                    // it. See [addCalendarDays].
                    final from = switch (tracker.cadence) {
                      TrackerCadence.daily => addCalendarDays(nowLocal, -29),
                      TrackerCadence.weekly => addCalendarDays(
                        nowLocal,
                        -29 * 7,
                      ),
                      TrackerCadence.monthly => DateTime(
                        nowLocal.year,
                        nowLocal.month - 29,
                        1,
                      ),
                      TrackerCadence.yearly => DateTime(
                        nowLocal.year - 29,
                        1,
                        1,
                      ),
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
                      // Cover the whole window, not just the default first 365
                      // days — otherwise the longer monthly/yearly spans draw only
                      // their first year of data, squished onto the left edge.
                      maxDays: calendarDaysBetween(from, now),
                      upperBound: tracker.integerCap,
                    );
                    // Period-start anchors across the window, drawn as an
                    // invisible zero-height line. fl_chart only hit-tests near a
                    // bar's spots, so these let the user tap the sparkline to enter
                    // data even when it has no values yet — the chart renders (axes
                    // + gridlines) instead of a dead "No data" label.
                    final todayPeriod = promptService.periodStartFor(
                      now,
                      tracker.cadence,
                      weekStartsMonday: weekStartsMonday,
                    );
                    final anchors = <FlSpot>[];
                    for (var i = 0; ; i++) {
                      final periodStart = switch (tracker.cadence) {
                        TrackerCadence.daily => addCalendarDays(
                          todayPeriod,
                          -i,
                        ),
                        TrackerCadence.weekly => addCalendarDays(
                          todayPeriod,
                          -i * 7,
                        ),
                        TrackerCadence.monthly => DateTime(
                          todayPeriod.year,
                          todayPeriod.month - i,
                          1,
                        ),
                        TrackerCadence.yearly => DateTime(
                          todayPeriod.year - i,
                          1,
                          1,
                        ),
                      };
                      final x = calendarDaysBetween(from, periodStart);
                      if (x < 0) break;
                      anchors.add(FlSpot(x.toDouble(), 0));
                    }
                    final anchorSpots = anchors.reversed.toList();
                    DateTime periodStartOf(DateTime date) =>
                        promptService.periodStartFor(
                          date,
                          tracker.cadence,
                          weekStartsMonday: weekStartsMonday,
                        );
                    final dataMax = spots
                        .map((s) => s.y)
                        .fold<double>(1, (m, y) => y > m ? y : m);
                    // Round the axis out to whole steps so the compact tile shows
                    // three evenly spaced, round gridlines instead of an arbitrary
                    // 15% headroom above the peak.
                    final yStep = niceAxisStep(dataMax, _sparklineGridLines);
                    final maxY = yStep * (_sparklineGridLines - 1);
                    // fl_chart lays the axis titles out *around* the plot
                    // (`FlTitlesData.allSidesPadding`), so the plot area is this
                    // widget's box inset by whatever each axis reserves — top and
                    // right show no titles and so reserve nothing. Hoisted here
                    // because the hover bubble maps the touched spot back to a
                    // pixel position and has to do it with the very numbers the
                    // chart drew with.
                    final leftReserved = axisReservedSize(maxY, 9, 8);
                    const bottomReserved = 26.0;
                    // Pinned rather than left to fl_chart to infer from the data,
                    // for the same reason: an inferred domain the bubble had to
                    // guess at is one the bubble could guess wrong.
                    final xs = [
                      for (final s in spots) s.x,
                      for (final s in anchorSpots) s.x,
                    ];
                    final minX = xs.isEmpty ? 0.0 : xs.reduce(math.min);
                    final maxX = xs.isEmpty ? 1.0 : xs.reduce(math.max);
                    return _SparklineTouchScope(
                      builder: (context, touch, onTouchChanged, bubbleKeys) {
                        final touchedIndex = touchedSpotIndex(spots, touch?.x);
                        // Hoisted so the touched-spot indicator below can
                        // reference the very same bar instance it's drawn
                        // against.
                        final dataBar = LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          color: color.withValues(alpha: 0.9),
                          barWidth: 1.5,
                          dotData: const FlDotData(show: false),
                          belowBarData: _sparklineFill(color),
                          showingIndicators: touchedIndex < 0
                              ? const []
                              : [touchedIndex],
                        );
                        final chart = LineChart(
                          LineChartData(
                            // fl_chart's own tooltip stays off: the bubble is
                            // drawn by [_sparklineHoverBubble] instead, so it
                            // is literally the heatmap's. The indicator line
                            // on the touched spot is a separate setting
                            // ([LineChartBarData.showingIndicators]) and is
                            // still on.
                            showingTooltipIndicators: const [],
                            lineTouchData: LineTouchData(
                              handleBuiltInTouches: false,
                              // Large threshold so hovering anywhere between two
                              // interpolated points still resolves to the nearest
                              // spot instead of leaving "dead" gaps with no tooltip.
                              touchSpotThreshold: 10000,
                              touchCallback:
                                  (
                                    FlTouchEvent event,
                                    LineTouchResponse? response,
                                  ) {
                                    _recordSparklineTouch(
                                      event,
                                      response,
                                      onTouchChanged,
                                    );
                                    _openSparklinePeriodEditor(
                                      event: event,
                                      response: response,
                                      context: context,
                                      tracker: tracker,
                                      from: from,
                                      values: values,
                                      periodStartOf: periodStartOf,
                                      bubbleKeys: bubbleKeys,
                                      color: color,
                                      onTouchChanged: onTouchChanged,
                                      onSaved: () => ref.invalidate(
                                        trackerValuesProvider(tracker.id),
                                      ),
                                    );
                                  },
                            ),
                            minX: minX,
                            maxX: maxX,
                            minY: 0,
                            maxY: maxY,
                            gridData: FlGridData(
                              show: true,
                              drawVerticalLine: true,
                              verticalInterval: verticalGridInterval,
                              horizontalInterval: yStep,
                              getDrawingVerticalLine: (_) => FlLine(
                                color: Colors.grey.withValues(alpha: 0.15),
                                strokeWidth: 1,
                              ),
                              getDrawingHorizontalLine: (_) => FlLine(
                                color: theme.colorScheme.outline.withValues(
                                  alpha: 0.1,
                                ),
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
                              // Both axes hold their labels off the plot with
                              // [SideTitleWidget.space]. Without it the "0" on the Y
                              // axis and the first date on the X axis butt up against
                              // the corner and read as one run-together number.
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: leftReserved,
                                  interval: yStep,
                                  getTitlesWidget: (v, meta) => SideTitleWidget(
                                    meta: meta,
                                    space: 8,
                                    child: Text(
                                      compactNumberLabel(v),
                                      maxLines: 1,
                                      softWrap: false,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(fontSize: 9),
                                    ),
                                  ),
                                ),
                              ),
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: bottomReserved,
                                  interval: bottomTitleInterval,
                                  getTitlesWidget: (v, meta) {
                                    final date = addCalendarDays(
                                      from,
                                      v.toInt(),
                                    );
                                    return SideTitleWidget(
                                      meta: meta,
                                      space: 8,
                                      child: Text(
                                        DateFormat('MMM d').format(date),
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(fontSize: 8),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            borderData: FlBorderData(
                              show: true,
                              border: Border(
                                bottom: BorderSide(
                                  color: VoyagerColors.of(context).strongHairline,
                                  width: 1,
                                ),
                                left: BorderSide(
                                  color: VoyagerColors.of(context).strongHairline,
                                  width: 1,
                                ),
                              ),
                            ),
                            lineBarsData: [
                              // barIndex 0 — invisible hit-test anchors.
                              LineChartBarData(
                                spots: anchorSpots,
                                color: Colors.transparent,
                                barWidth: 0,
                                dotData: const FlDotData(show: false),
                              ),
                              // barIndex 1 — the real data curve.
                              dataBar,
                            ],
                          ),
                        );
                        return _sparklineHoverBubble(
                          chart: chart,
                          touch: touch,
                          spots: spots,
                          minX: minX,
                          maxX: maxX,
                          maxY: maxY,
                          leftReserved: leftReserved,
                          bottomReserved: bottomReserved,
                          from: from,
                          values: values,
                          tracker: tracker,
                          periodStartOf: periodStartOf,
                          color: color,
                          keys: bubbleKeys,
                        );
                      },
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
                    await ref
                        .read(trackerRepositoryProvider)
                        .upsertTracker(updated);
                    ref.invalidate(trackersProvider);
                  },
                ),
              ),
            ],
          ),
        ),
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
          (t) =>
              !t.starred && t.cadence == tracker.cadence && t.id != tracker.id,
        );
  var maxOrder = -1;
  for (final t in siblings) {
    if (t.sortOrder > maxOrder) maxOrder = t.sortOrder;
  }
  await ref
      .read(trackerRepositoryProvider)
      .upsertTracker(
        tracker.copyWith(starred: starring, sortOrder: maxOrder + 1),
      );
  ref.invalidate(trackersProvider);
}

String _cadenceLabel(TrackerCadence cadence) {
  final name = cadence.name;
  return name[0].toUpperCase() + name.substring(1);
}

/// A faint horizontal rule separating groups (starred vs. time-period, or
/// between adjacent time periods) in the heatmap grid. When [label] is set
/// (the name of the section that follows), the rule is cut in the middle
/// to make room for it instead of running underneath the text.
class _HeatmapGroupDivider extends StatelessWidget {
  const _HeatmapGroupDivider({this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineColor = VoyagerColors.of(context).chartGrid;
    if (label == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Container(height: 1, color: lineColor),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: lineColor)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(child: Container(height: 1, color: lineColor)),
        ],
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
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    // Built-in default trackers (e.g. Journal Entries) are virtual and
    // read-only: they can't be starred or reordered, so they're rendered as
    // pinned rows above the reorderable buckets rather than inside one.
    final defaults = trackers.where((t) => t.isDefault).toList();
    final userTrackers = trackers.where((t) => !t.isDefault).toList();

    final starred = userTrackers.where((t) => t.starred).toList()
      ..sort(_compareTrackerOrder);

    final byCadence = <TrackerCadence, List<StatisticTracker>>{};
    for (final t in userTrackers.where((t) => !t.starred)) {
      byCadence.putIfAbsent(t.cadence, () => []).add(t);
    }
    for (final group in byCadence.values) {
      group.sort(_compareTrackerOrder);
    }
    final cadenceGroups = TrackerCadence.values
        .where((c) => byCadence.containsKey(c))
        .toList();

    void toggleStar(StatisticTracker tracker) {
      unawaited(_toggleTrackerStar(ref, tracker, userTrackers));
    }

    final sections = <Widget>[];
    for (final tracker in defaults) {
      sections.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _HeatmapRow(
            key: ValueKey(tracker.id),
            tracker: tracker,
            analytics: analytics,
            onToggleStar: () {},
          ),
        ),
      );
    }
    if (defaults.isNotEmpty &&
        (starred.isNotEmpty || cadenceGroups.isNotEmpty)) {
      sections.add(const _HeatmapGroupDivider());
    }
    if (starred.isNotEmpty) {
      sections.add(
        Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 2),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: accent.withValues(alpha: 0.6)),
          ),
          child: _HeatmapBucket(
            key: const ValueKey('starred'),
            trackers: starred,
            analytics: analytics,
            onToggleStar: toggleStar,
          ),
        ),
      );
      if (cadenceGroups.isNotEmpty) {
        sections.add(
          _HeatmapGroupDivider(label: _cadenceLabel(cadenceGroups.first)),
        );
      }
    }
    for (var gi = 0; gi < cadenceGroups.length; gi++) {
      if (gi > 0) {
        sections.add(
          _HeatmapGroupDivider(label: _cadenceLabel(cadenceGroups[gi])),
        );
      }
      sections.add(
        _HeatmapBucket(
          key: ValueKey(cadenceGroups[gi].name),
          trackers: byCadence[cadenceGroups[gi]]!,
          analytics: analytics,
          onToggleStar: toggleStar,
        ),
      );
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
    // Keyed on this bucket's *membership* (not order), so a star toggle —
    // which moves a tracker into or out of this bucket — tears down and
    // remounts the list fresh with no residual animation state to carry
    // over, while a plain in-bucket drag reorder (membership unchanged)
    // keeps the same key and so keeps Flutter's native drag animation.
    final membershipKey = (_items.map((t) => t.id).toList()..sort()).join('|');
    return ReorderableListView(
      key: ValueKey(membershipKey),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderItem: _handleReorder,
      onReorderStart: (_) =>
          ref.read(_heatmapDraggingProvider.notifier).state = true,
      onReorderEnd: (_) =>
          ref.read(_heatmapDraggingProvider.notifier).state = false,
      proxyDecorator: (child, index, animation) =>
          Material(type: MaterialType.transparency, child: child),
      children: [
        for (var i = 0; i < _items.length; i++)
          // The drag handle is the row's chrome, not the row itself — see
          // [_StatTile]. Wrapping the whole row in a
          // [ReorderableDragStartListener] claimed the pointer on *down*,
          // before the tap that opens the detail popup could ever complete,
          // and did so over the heatmap squares too — where a press already
          // means "edit this period".
          Padding(
            key: ValueKey(_items[i].id),
            padding: const EdgeInsets.only(bottom: 6),
            child: _HeatmapRow(
              tracker: _items[i],
              analytics: widget.analytics,
              onToggleStar: () => widget.onToggleStar(_items[i]),
              dragIndex: i,
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
    super.key,
    required this.tracker,
    required this.analytics,
    required this.onToggleStar,
    this.dragIndex,
  });

  final StatisticTracker tracker;
  final AnalyticsService analytics;
  final VoidCallback onToggleStar;

  /// This row's position in its bucket's reorderable list. Handed to
  /// [_StatTile], which makes the row's chrome both the tap target and the
  /// hold-to-drag handle.
  final int? dragIndex;

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
            calendarDaysBetween(periods.first, DateTime.now()) + 1;
        final max = analytics.rollingMax(values, days: windowDays);

        // Hoisted out of [_HeatmapSquare] so each of the (up to 30) squares
        // in this row does an O(1) map lookup instead of its own O(n) scan
        // over the full value history, and so the "only one value ever
        // recorded" check inside [AnalyticsService.heatmapIntensity] runs
        // once per row instead of once per square.
        final valuesByDay = <DateTime, TrackerValue>{
          for (final v in values)
            DateTime(
              v.periodStart.year,
              v.periodStart.month,
              v.periodStart.day,
            ): v,
        };
        final hasSingleIntValue =
            values.where((v) => v.intValue != null).length == 1;

        return _StatTile(
          tracker: tracker,
          analytics: analytics,
          dragIndex: dragIndex,
          // The tile has no fill of its own at rest — it only lights up on
          // hover, so the hitbox reads as spanning the whole bar out to the
          // right edge rather than just the label.
          decoration: (hovered) => BoxDecoration(
            color: hovered ? color.withValues(alpha: 0.08) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: hovered
                  ? color.withValues(alpha: 0.25)
                  : Colors.transparent,
            ),
          ),
          builder: (context, hovered) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Label row.
                Row(
                  children: [
                    CircleAvatar(radius: 5, backgroundColor: color),
                    const SizedBox(width: 6),
                    // Inert, and so held clear of the pointer so the tile's
                    // own hitbox ([_StatTile]) gets the press — a [Text]
                    // hit-tests as opaque and would be a dead zone otherwise.
                    IgnorePointer(
                      child: Text(
                        tracker.name,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IgnorePointer(
                      child: Text(
                        '(${_typeLabel(tracker.type)})',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    // Default trackers (e.g. Journal Entries) are virtual and
                    // read-only: no star, edit or reorder affordances.
                    if (!tracker.isDefault) ...[
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
                            ? color
                            : theme.colorScheme.onSurfaceVariant,
                        onPressed: onToggleStar,
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(
                          PhosphorIconsRegular.pencilSimple,
                          size: 14,
                        ),
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                        color: theme.colorScheme.onSurfaceVariant,
                        onPressed: () async {
                          final updated = await showDialog<StatisticTracker>(
                            context: context,
                            builder: (_) => _TrackerDialog(tracker: tracker),
                          );
                          if (updated == null) return;
                          await ref
                              .read(trackerRepositoryProvider)
                              .upsertTracker(updated);
                          ref.invalidate(trackersProvider);
                        },
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                // Squares stretched to fill the row width
                LayoutBuilder(
                  builder: (ctx, constraints) {
                    const gap = 4.0;
                    final squareSize =
                        ((constraints.maxWidth - gap * periods.length) /
                                periods.length)
                            .clamp(10.0, 40.0);
                    return Row(
                      children: [
                        for (var i = 0; i < periods.length; i++)
                          Builder(
                            builder: (ctx) {
                              final period = periods[i];
                              final showLabel =
                                  (periods.length - 1 - i) % 5 == 0;
                              return Padding(
                                padding: const EdgeInsets.only(right: gap),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _HeatmapSquare(
                                      tracker: tracker,
                                      valuesByDay: valuesByDay,
                                      hasSingleIntValue: hasSingleIntValue,
                                      periodDate: period,
                                      maxInPeriod: max,
                                      analytics: analytics,
                                      size: squareSize,
                                    ),
                                    const SizedBox(height: 4),
                                    // Under the square, not on it: inert, and
                                    // so kept out of the pointer's way for the
                                    // tile's hitbox (see [_StatTile]).
                                    IgnorePointer(
                                      child: showLabel
                                          ? Text(
                                              _shortDateLabel(
                                                period,
                                                tracker.cadence,
                                              ),
                                              style: theme.textTheme.labelSmall
                                                  ?.copyWith(
                                                    fontSize: 8,
                                                    color: theme
                                                        .colorScheme
                                                        .onSurfaceVariant
                                                        .withValues(alpha: 0.7),
                                                  ),
                                            )
                                          : const Text(
                                              '',
                                              style: TextStyle(fontSize: 8),
                                            ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
      loading: () =>
          const SizedBox(height: 40, child: LinearProgressIndicator()),
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
    final currentWeekStart = addCalendarDays(
      todayLocal,
      -(weekStartsMonday
          ? todayLocal.weekday - DateTime.monday
          : todayLocal.weekday % 7),
    );
    final periods = <DateTime>[];
    for (var i = n - 1; i >= 0; i--) {
      final candidate = switch (tracker.cadence) {
        TrackerCadence.daily => addCalendarDays(todayLocal, -i),
        TrackerCadence.weekly => addCalendarDays(currentWeekStart, -i * 7),
        TrackerCadence.monthly => DateTime(
          todayLocal.year,
          todayLocal.month - i,
          1,
        ),
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

/// Formats a sparkline hover value to at most one decimal place, dropping a
/// trailing `.0` so a whole number reads as `1` rather than `1.0` (while
/// `1.5` stays `1.5`). The plotted line itself keeps full precision — only
/// the label a user hovers is rounded.
///
/// Past [_sparkLabelDigitBudget] whole digits the decimal is dropped
/// altogether and the value is rounded: fl_chart sizes the hover bubble to
/// its text, so `123456.5` makes a bubble wide enough to spill outside the
/// chart. A tenth is noise at that magnitude anyway, so spending the width on
/// it isn't worth it — `123457` reads the same and fits.
/// Opens the single-period editor when [event] is a press *completing* on the
/// sparkline, and does nothing otherwise.
///
/// Both a plain tap and a long press count. A press held over the plot is
/// claimed by fl_chart's own long-press recognizer rather than by the row's
/// drag handle, so without [FlLongPressEnd] here a slow or deliberate press on
/// the chart would land on nothing at all — it can't fall through to the drag,
/// and it wouldn't have opened the editor either.
///
/// The period and its current value come from [resolveSparklinePeriod], the
/// same lookup the hover bubble reads, so the editor always opens on the number
/// the bubble was showing.
///
/// It opens [_MorphPopover] — the very same editor, and the very same
/// animation, a heatmap square uses ([_HoverEditPopoverState._handleTap]),
/// handed the hover bubble's own measured rect. Sharing one implementation is
/// deliberate: the sparkline previously had a lookalike of its own that
/// revealed a static card through a growing clip window, and it drifted out of
/// step with the heatmap's morph until the two no longer matched.
///
/// Anchoring it to the pointer instead — which is what a 1×1 rect at
/// [FlTouchEvent.localPosition] amounts to — meant the editor grew out of
/// wherever the cursor happened to be rather than out of the bubble the user
/// was looking at, and so started somewhere different on every click.
void _openSparklinePeriodEditor({
  required FlTouchEvent event,
  required LineTouchResponse? response,
  required BuildContext context,
  required StatisticTracker tracker,
  required DateTime from,
  required List<TrackerValue> values,
  required DateTime Function(DateTime) periodStartOf,
  required _SparklineBubbleKeys bubbleKeys,
  required Color color,
  required ValueChanged<_SparklineTouch?> onTouchChanged,
  required VoidCallback onSaved,
}) {
  if (event is! FlTapUpEvent && event is! FlLongPressEnd) return;
  final spots = response?.lineBarSpots;
  if (spots == null || spots.isEmpty) return;
  // Both measured before the bubble is dismissed below — [_hide]'s
  // counterpart here, and for the same reason: once it's gone there's nothing
  // left to measure.
  final anchorRect = bubbleKeys.bubbleRect;
  if (anchorRect == null) return;
  final anchorDateRect = bubbleKeys.dateRect;
  // The data curve's hit, not `spots.first` — see [_sparklineDataBarSpot].
  final dataSpot = _sparklineDataBarSpot(spots);
  final resolved = resolveSparklinePeriod(
    x: (dataSpot ?? spots.first).x,
    from: from,
    values: values,
    periodStartOf: periodStartOf,
  );
  // Rebuilt here rather than plumbed down from the bubble: the bubble is a
  // pure function of the resolved period, so recomputing from the same
  // [resolveSparklinePeriod] result reproduces exactly the strings on screen,
  // which is what lets the morph's content layer cross-fade out of the very
  // text the user was reading.
  final reading = _sparklineValueReading(
    tracker: tracker,
    value: resolved.value,
    interpolatedY: dataSpot?.y,
  );
  final valueLabel = reading.label;
  // The bubble stands down as the editor takes over, rather than the two
  // overlapping for as long as the editor is up.
  onTouchChanged(null);
  _showMorphPopover(
    context: context,
    tracker: tracker,
    periodDate: resolved.periodStart,
    anchorRect: anchorRect,
    anchorDateRect: anchorDateRect,
    initialValue: resolved.value,
    periodLabel: _tooltipPeriodLabel(resolved.periodStart, tracker.cadence),
    valueLabel: valueLabel,
    valueColor: _sparklineValueColor(
      label: valueLabel,
      isEstimate: reading.isEstimate,
      color: color,
      theme: Theme.of(context),
    ),
    onSaved: onSaved,
  );
}

/// A sparkline's hover bubble, stacked over [chart] and anchored to the
/// pointer at [pointer] (null hides it).
///
/// This is the heatmap's bubble, not a lookalike: same [Container] chrome and
/// the same [_tooltipDateValueColumn] content, so the two surfaces stay
/// identical by construction rather than by two sets of matching constants.
/// That's also why fl_chart's own tooltip is switched off at the call sites —
/// it can only paint [TextSpan]s, so it could never render the real column
/// (whose two lines carry different alignments and their own spacing), and
/// matching it by eye would have meant duplicating the styling a third time.
/// The touched-spot indicator line is a separate fl_chart setting and stays on.
///
/// The number comes from [_sparklineValueReading]: the stored record via
/// [resolveSparklinePeriod] when the period was logged, and the touched spot's
/// interpolated `y` when it wasn't. An interpolated reading is greyed out, in
/// the same shade as the dash below — which is what lets the bubble show the
/// curve's own value on a gap while the editor still opens on the empty record
/// underneath it. Periods with nothing to interpolate from
/// (boolean and enum trackers) keep the greyed dash a never-logged heatmap
/// square shows.
Widget _sparklineHoverBubble({
  required Widget chart,
  required _SparklineTouch? touch,
  required List<FlSpot> spots,
  required double minX,
  required double maxX,
  required double maxY,
  required double leftReserved,
  required double bottomReserved,
  required DateTime from,
  required List<TrackerValue> values,
  required StatisticTracker tracker,
  required DateTime Function(DateTime) periodStartOf,
  required Color color,
  required _SparklineBubbleKeys keys,
}) {
  return Builder(
    builder: (context) {
      final theme = Theme.of(context);
      return LayoutBuilder(
        builder: (context, constraints) {
          if (touch == null) return chart;
          final index = touchedSpotIndex(spots, touch.x);
          if (index < 0) return chart;
          final spot = spots[index];
          final resolved = resolveSparklinePeriod(
            x: touch.x,
            from: from,
            values: values,
            periodStartOf: periodStartOf,
          );
          // `spot.y` is the curve's own value at the touched day, which is the
          // recorded number on a logged day and the interpolated one between
          // logged days — exactly the fallback [_sparklineValueReading] wants.
          final reading = _sparklineValueReading(
            tracker: tracker,
            value: resolved.value,
            interpolatedY: spot.y,
          );
          final valueLabel = reading.label;
          // Anchored to the *touched point on the curve*, never to the
          // pointer. Both identify the same period, but only the spot holds
          // still while the cursor wanders up and down within the tile — and
          // a bubble that slides with the cursor gave the editor a different
          // starting rect on every click, which is what made the morph
          // ([_showMorphPopover]) open from a different place each time.
          final plotWidth = math.max(0.0, constraints.maxWidth - leftReserved);
          final plotHeight = math.max(
            0.0,
            constraints.maxHeight - bottomReserved,
          );
          final spanX = maxX - minX;
          final spotDx =
              leftReserved +
              (spanX == 0 ? 0.0 : (spot.x - minX) / spanX * plotWidth);
          final spotDy =
              plotHeight - (maxY == 0 ? 0.0 : spot.y / maxY * plotHeight);
          // The bubble always sits above the point, never below.
          //
          // It used to flip below whenever there wasn't room above, which on a
          // compact tile meant almost always: the tile leaves only ~70px of
          // plot and the bubble needs 54px of clearance, so any point in the
          // upper part of the band flipped. The side it landed on therefore
          // tracked the *value* being hovered, and the bubble jumped from one
          // side of the curve to the other as the pointer moved along it.
          //
          // Pinning it above costs an overflow instead: with the point near
          // the top of the plot the bubble extends past the tile and paints
          // over the row above it. That's fine here — the [Stack] below is
          // [Clip.none] and nothing between it and the list clips, and this
          // tile paints after (over) the one above it. Only the topmost row in
          // the viewport can have it cropped, by the scroll view's own edge.
          return Stack(
            clipBehavior: Clip.none,
            children: [
              chart,
              // Placed by [_SparklineBubbleLayout] rather than a [Positioned]
              // with precomputed offsets, because centring the bubble on the
              // point requires half its width — and the bubble is an
              // [IntrinsicWidth] whose width isn't known until it's laid out.
              // A layout delegate is the one place that width is available.
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomSingleChildLayout(
                    delegate: _SparklineBubbleLayout(
                      anchor: Offset(spotDx, spotDy),
                    ),
                    child: IntrinsicWidth(
                      key: keys.bubble,
                      // No Material of its own here —
                      // [_tooltipDateValueColumn] provides one (see that
                      // function's doc comment).
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 64),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: calendarPanelBackgroundColor(context),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: VoyagerColors.of(context).hairline,
                          ),
                        ),
                        child: _tooltipDateValueColumn(
                          periodLabel: _tooltipPeriodLabel(
                            resolved.periodStart,
                            tracker.cadence,
                          ),
                          valueLabel: valueLabel,
                          valueColor: _sparklineValueColor(
                            label: valueLabel,
                            isEstimate: reading.isEstimate,
                            color: color,
                            theme: theme,
                          ),
                          theme: theme,
                          dateKey: keys.date,
                        ),
                      ),
                    ),
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

/// Centres the sparkline hover bubble on the datapoint it describes, sitting
/// it [_gap] above the point.
///
/// Both offsets need the bubble's real size, which is why this is a layout
/// delegate rather than arithmetic at the call site. The bubble is an
/// [IntrinsicWidth] sized to its own text, so its width varies with the date
/// and value it happens to be showing. The previous code guessed at a fixed
/// 120×46 instead, which was wrong twice over: it centred by half the *guess*
/// rather than half the bubble, leaving it visibly off-centre by however much
/// the guess missed by; and it clamped the right edge to `maxWidth - 120`, so
/// the bubble stopped tracking the curve well before the last datapoint —
/// worst exactly where the sparkline ends.
///
/// Nothing clamps the result to the plot. A bubble centred on a point near
/// either end overhangs the plot's edge by up to half its width, and near the
/// top it overhangs upward; the [Stack] holding it is [Clip.none] and neither
/// [CustomSingleChildLayout] nor anything between here and the list clips, so
/// it paints. Staying glued to the point is worth the overhang — clamping is
/// what produced the drift being fixed here.
class _SparklineBubbleLayout extends SingleChildLayoutDelegate {
  const _SparklineBubbleLayout({required this.anchor});

  /// The datapoint, in the enclosing [Stack]'s coordinates.
  final Offset anchor;

  static const double _gap = 8;

  /// Unbounded, so the bubble keeps sizing to its content exactly as it did
  /// under a [Positioned] with only `left`/`top` set. Passing the parent's
  /// constraints down instead would cap it at the plot's width and let a long
  /// value wrap.
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      const BoxConstraints();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    anchor.dx - childSize.width / 2,
    anchor.dy - _gap - childSize.height,
  );

  @override
  bool shouldRelayout(_SparklineBubbleLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}

/// Holds which period a sparkline's pointer is resting on, as an x coordinate
/// rather than as a captured spot.
///
/// This exists to keep the hover bubble live across an edit. fl_chart's own
/// touch handling (`handleBuiltInTouches`) snapshots the touched [LineBarSpot]
/// *by value* and only replaces it on the next touch event — so saving from
/// the keyboard, where the pointer never moves and no event is produced,
/// leaves both the bubble's text and its anchor position showing pre-edit
/// data until the user jiggles the mouse. Storing only the x and re-resolving
/// it against the freshly built series every frame keeps both live.
///
/// The chart therefore opts out of built-in touch handling and supplies
/// `showingTooltipIndicators` itself; [touchedSpotIndex] does the resolving.
/// Where a sparkline's pointer is: the series x it resolves to, plus its raw
/// position in the chart's own coordinates. The x identifies the period; the
/// position is what the hover bubble anchors itself to.
class _SparklineTouch {
  const _SparklineTouch(this.x, this.position);

  final double x;
  final Offset position;

  @override
  bool operator ==(Object other) =>
      other is _SparklineTouch && other.x == x && other.position == position;

  @override
  int get hashCode => Object.hash(x, position);
}

/// A handle onto the live hover bubble, so a tap can measure the very rect
/// that's on screen and hand it to the editor as its starting point — the same
/// thing [_HoverEditPopoverState._handleTap] does for a heatmap square, and
/// for the same reason: an estimated rect shows up as a small pop the instant
/// the editor opens.
class _SparklineBubbleKeys {
  final GlobalKey bubble = GlobalKey();

  /// The date line inside the bubble. [_MorphPopover] slides the date from
  /// here to its position in the editor, so it needs the text's own rect and
  /// not just the bubble's — the same thing
  /// [_HoverEditPopoverState._measureTooltipDate] provides for a heatmap
  /// square.
  final GlobalKey date = GlobalKey();

  Rect? get bubbleRect => _rectOf(bubble);

  Rect? get dateRect => _rectOf(date);

  static Rect? _rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

class _SparklineTouchScope extends StatefulWidget {
  const _SparklineTouchScope({required this.builder});

  final Widget Function(
    BuildContext context,
    _SparklineTouch? touch,
    ValueChanged<_SparklineTouch?> onTouchChanged,
    _SparklineBubbleKeys keys,
  )
  builder;

  @override
  State<_SparklineTouchScope> createState() => _SparklineTouchScopeState();
}

class _SparklineTouchScopeState extends State<_SparklineTouchScope> {
  _SparklineTouch? _touch;
  final _keys = _SparklineBubbleKeys();

  void _setTouch(_SparklineTouch? touch) {
    if (_touch == touch) return;
    setState(() => _touch = touch);
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _touch, _setTouch, _keys);
}

/// Records the pointer's position from a sparkline touch event, mirroring the
/// show/hide rule fl_chart applies internally: anything that isn't a live
/// interaction (pointer exit, pan end, tap cancel) clears the tooltip.
///
/// Only the real data bar counts. Sparklines also carry an invisible anchor
/// bar (barIndex 0) purely so empty regions stay tappable, and its spots sit
/// at period starts that need not line up with the interpolated curve — so
/// tracking its x would resolve to nothing on the series.
void _recordSparklineTouch(
  FlTouchEvent event,
  LineTouchResponse? response,
  ValueChanged<_SparklineTouch?> onTouchChanged,
) {
  final hits = response?.lineBarSpots;
  final position = event.localPosition;
  // No pointer position means there's nothing to anchor the bubble to — the
  // same non-interactive events that clear the tooltip below.
  if (!event.isInterestedForInteractions ||
      position == null ||
      hits == null ||
      hits.isEmpty) {
    onTouchChanged(null);
    return;
  }
  for (final hit in hits) {
    if (hit.barIndex == _sparklineDataBarIndex) {
      onTouchChanged(_SparklineTouch(hit.x, position));
      return;
    }
  }
  onTouchChanged(null);
}

/// Index of the real data curve in a sparkline's `lineBarsData`; index 0 is
/// the invisible hit-test anchor line.
const _sparklineDataBarIndex = 1;

/// Horizontal gridlines (including the zero baseline) drawn on a sparkline in
/// the compact grid tile, versus in the large detail popup. The tile is only
/// ~96px of plot height, so more than three lines reads as noise; the popup
/// has the room to be read as a real chart.
const _sparklineGridLines = 3;
const _sparklineDetailGridLines = 6;

/// The gradient wash under a sparkline: the tracker's colour at 30% where it
/// meets the line, fading to fully transparent at the baseline, so the series
/// carries visual weight without competing with the line itself.
BarAreaData _sparklineFill(Color color) {
  return BarAreaData(
    show: true,
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [color.withValues(alpha: 0.30), color.withValues(alpha: 0.0)],
    ),
  );
}

String _tooltipPeriodLabel(DateTime date, TrackerCadence cadence) {
  return switch (cadence) {
    TrackerCadence.daily => DateFormat('MMM d, yyyy').format(date),
    TrackerCadence.weekly =>
      'Week of ${DateFormat('MMM d, yyyy').format(date)}',
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

/// Intensity at which a heatmap cell starts to glow.
const _heatmapGlowThreshold = 0.65;

/// A soft [BoxShadow] in the cell's own colour, so a capped or highly active
/// period reads as an LED lit against the dark geometric background rather
/// than just a slightly-less-transparent square.
///
/// Only cells above [_heatmapGlowThreshold] glow, ramping in from there: if
/// every cell glowed, the bloom would blur the grid into a smear and none of
/// them would stand out.
List<BoxShadow> _heatmapGlow(Color base, double intensity) {
  final t = intensity.clamp(0.0, 1.0);
  if (t < _heatmapGlowThreshold) return const [];
  final ramp = (t - _heatmapGlowThreshold) / (1 - _heatmapGlowThreshold);
  return [
    BoxShadow(
      color: base.withValues(alpha: 0.18 + 0.30 * ramp),
      blurRadius: 5 + 7 * ramp,
      spreadRadius: ramp,
    ),
  ];
}

/// The value line of a hover bubble, for heatmap squares and sparklines alike.
///
/// Shared so the two surfaces can't word the same record differently — null
/// means "nothing logged", which [_tooltipDateValueColumn] renders as the
/// greyed dash.
String? _hoverValueLabel({
  required StatisticTracker tracker,
  required TrackerType type,
  required TrackerValue? value,
}) {
  // The virtual "Journal Entries" tracker is read-only (no tap-to-edit) and
  // reads as journaled / not journaled rather than completed / not completed.
  if (tracker.id == kJournalEntriesTrackerId) {
    return value?.boolValue == true ? 'Journaled' : 'Not journaled';
  }
  return _tooltipValueLabel(type, value);
}

/// A sparkline bubble's value line: what to print, and whether it's read off
/// the curve rather than out of the database.
///
/// A logged period reads as its stored number. A period *between* two logged
/// ones has no record — but the curve still draws a Hermite-interpolated point
/// for it ([AnalyticsService.interpolateConsecutive]) — so the bubble reports
/// that interpolated number instead of the greyed dash it used to show.
///
/// This is the whole point of the sparkline for non-daily cadences. Every day
/// between two recorded period starts is an interpolated point on the curve,
/// and the bubble used to snap each of them back to its period start and print
/// *that period's* stored value — so dragging across a gap showed the
/// left-hand number sitting flat under a curve that was visibly climbing.
///
/// An estimate is marked by colour alone — [_tooltipMutedValueColor], the same
/// grey a never-logged period's dash uses. That's the same signal the editor
/// gives when you click through: it opens on the *stored* value, so an
/// interpolated period gets an empty field. Grey text and an empty box say the
/// one thing, which is why the number needs no marker of its own.
///
/// The colour rides in on the existing `valueColor` argument, so
/// [_MorphPopover]'s reconstruction of the bubble reproduces it without any
/// extra plumbing.
///
/// Only integer trackers interpolate — [AnalyticsService.interpolateConsecutive]
/// reads `intValue` and emits nothing without it — so boolean and enum
/// sparklines have no curve to read and keep the dash.
({String? label, bool isEstimate}) _sparklineValueReading({
  required StatisticTracker tracker,
  required TrackerValue? value,
  required double? interpolatedY,
}) {
  return sparklineValueReading(
    storedLabel: _hoverValueLabel(
      tracker: tracker,
      type: tracker.type,
      value: value,
    ),
    interpolates: tracker.type == TrackerType.integer,
    interpolatedY: interpolatedY,
  );
}

/// The greyed-out shade a tooltip's value line takes when it isn't showing
/// something the user recorded — the "–" of a never-logged period, and the
/// interpolated reading of a period between two logged ones.
///
/// One function so the two can't drift: they mean the same thing to the
/// reader ("this isn't your data"), so they have to look the same.
Color _tooltipMutedValueColor(ThemeData theme) =>
    theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);

/// The colour a sparkline bubble's value line takes for a given reading: the
/// tracker's own [color] for a record, and the muted grey for an interpolated
/// estimate.
///
/// The grey is the only thing distinguishing an estimate from a record, which
/// is deliberate — it's the same grey the dash uses, and it matches the empty
/// field the editor opens with on a period that was never logged.
Color? _sparklineValueColor({
  required String? label,
  required bool isEstimate,
  required Color color,
  required ThemeData theme,
}) {
  if (label == null) return null;
  return isEstimate ? _tooltipMutedValueColor(theme) : color;
}

/// The touched point on a sparkline's real data curve, or null when the touch
/// only landed on the invisible anchor line.
///
/// [LineTouchResponse.lineBarSpots] can lead with a hit on the anchor bar
/// (barIndex 0), whose spots all sit at `y == 0`. Reading a curve value off
/// `spots.first` would therefore report a flat zero rather than the
/// interpolated number.
LineBarSpot? _sparklineDataBarSpot(List<LineBarSpot>? hits) {
  if (hits == null) return null;
  for (final hit in hits) {
    if (hit.barIndex == _sparklineDataBarIndex) return hit;
  }
  return null;
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
  return (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
    inherit: false,
    color: theme.colorScheme.onSurfaceVariant,
  );
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
/// by a separate floating layer instead). (The date does carry an [Align]
/// now — but from here, so both callers get it. See the note on it below
/// for what it's for.)
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
        // Both lines are held to a single line: the bubble sizes itself with
        // [IntrinsicWidth], so letting them wrap would break a long value
        // ("12000", or a wordy enum option) across two lines mid-number
        // instead of widening the bubble to fit it.
        // Centred, and shrink-wrapped by the [Align] rather than stretched to
        // the column's width.
        //
        // Both matter for short labels — a yearly tracker's "2026", or
        // anything narrower than the bubble's 64px minimum. Stretched, the
        // date's box spans the full width and its glyphs sat at the right
        // edge while the value below them sat centred, so the two lines
        // visibly disagreed. Longer labels are the widest line in the bubble
        // and so fill it either way, which is why this only ever showed up on
        // yearly.
        //
        // Shrink-wrapping also keeps [dateKey]'s measured rect on the glyphs
        // instead of on the full-width box. The morph popover positions its
        // sliding date layer from that rect's topLeft
        // ([_MorphPopoverState.build]) and draws the text unaligned, so a
        // stretched box handed it a start position to the left of where the
        // glyphs actually were — the same short labels would jump sideways
        // the instant the editor opened.
        Opacity(
          opacity: dateOpacity,
          child: Align(
            child: Text(
              periodLabel,
              key: dateKey,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: _tooltipDateStyle(theme),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          valueLabel ?? '–',
          textAlign: TextAlign.center,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: valueLabel == null
                ? _tooltipMutedValueColor(theme)
                : (valueColor ?? theme.colorScheme.onSurface),
            fontWeight: FontWeight.normal,
            fontSize: 14,
          ),
        ),
      ],
    ),
  );
}

/// Wraps [child] with a hover tooltip showing the period label (small,
/// centered) and the value (centered, regular size — a greyed "–" if there's
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
  final valueLabel = _hoverValueLabel(
    tracker: tracker,
    type: type,
    value: value,
  );
  return _HoverEditPopover(
    periodLabel: periodLabel,
    valueLabel: valueLabel,
    valueColor: valueColor,
    tracker: tracker,
    periodDate: periodDate,
    initialValue: value,
    onSaved: onSaved,
    readOnly: tracker.isDefault,
    child: child,
  );
}

/// Wraps [child] with a hover tooltip showing the period label (small,
/// centered) and the value (centered, regular size — a greyed "–" if there's
/// no entry yet). This is a plain, transient overlay entry — the same kind
/// Flutter/this app already renders without issue — kept deliberately
/// simple; the editor (heavier, interactive, longer-lived) is opened as a
/// proper route by [_showMorphPopover] instead of folded into this same
/// overlay entry, since that combination is what triggered overlay/element
/// tree corruption in this app's go_router setup.
class _HoverEditPopover extends ConsumerStatefulWidget {
  const _HoverEditPopover({
    required this.periodLabel,
    required this.valueLabel,
    this.valueColor,
    required this.tracker,
    required this.periodDate,
    required this.initialValue,
    required this.onSaved,
    this.readOnly = false,
    required this.child,
  });

  final String periodLabel;
  final String? valueLabel;
  final Color? valueColor;
  final StatisticTracker tracker;
  final DateTime periodDate;
  final TrackerValue? initialValue;
  final VoidCallback onSaved;

  /// When true the hover tooltip still shows, but tapping does nothing (the
  /// value can't be edited). Used by virtual default trackers.
  final bool readOnly;
  final Widget child;

  @override
  ConsumerState<_HoverEditPopover> createState() => _HoverEditPopoverState();
}

class _HoverEditPopoverState extends ConsumerState<_HoverEditPopover> {
  final _key = GlobalKey();
  final _tooltipKey = GlobalKey();
  final _tooltipDateKey = GlobalKey();
  OverlayEntry? _entry;

  /// Links the bubble (in the root overlay) to this cell, so it follows the
  /// cell's live on-screen position. The overlay sits outside the page's
  /// scroll view, so a bubble positioned by absolute coordinates would stay
  /// put while the grid scrolled out from under it, drifting off-centre
  /// until the pointer left the cell and re-entered it.
  final _link = LayerLink();

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
    // Suppressed for the whole heatmap grid while any row is being
    // drag-reordered, so the pointer passing over other squares mid-drag
    // doesn't pop up a stray value tooltip.
    if (ref.read(_heatmapDraggingProvider)) return;
    final anchor = _measure();
    if (anchor == null) return;
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    const estWidth = 120.0;
    const estHeight = 46.0;
    const margin = 8.0;

    // Horizontal placement is resolved once here, as a delta from the cell's
    // own left edge: the grid only ever scrolls vertically, so the cell's x
    // can't move while the bubble is up and this stays correct for the whole
    // hover.
    final left = anchor.left
        .clamp(margin, math.max(margin, screen.width - margin - estWidth))
        .toDouble();
    final dx = left - anchor.left;
    // Above the cell when there's room for it, else below. Also decided once:
    // a hovered cell can only drift by its own height before the pointer
    // falls off it, which hides the bubble and re-runs this on re-entry.
    final showAbove = anchor.top - margin - estHeight >= margin;
    _lastRect = Rect.fromLTWH(
      left,
      showAbove ? anchor.top - margin - estHeight : anchor.bottom + margin,
      estWidth,
      estHeight,
    );

    _entry = OverlayEntry(
      // Pinned at the overlay's origin so the follower below contributes no
      // offset of its own, and left unsized so the bubble keeps sizing to its
      // own content.
      builder: (ctx) => Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: _link,
          // Vertical placement rides the cell's transform, re-resolved every
          // frame at paint time — that's what keeps the bubble glued to the
          // cell mid-scroll. Anchoring by the bubble's own edge means its real
          // measured height places it; estHeight above only picks the side.
          targetAnchor: showAbove ? Alignment.topLeft : Alignment.bottomLeft,
          followerAnchor: showAbove ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(dx, showAbove ? -margin : margin),
          showWhenUnlinked: false,
          child: IgnorePointer(
            child: IntrinsicWidth(
              key: _tooltipKey,
              // No Material of its own here — [_tooltipDateValueColumn]
              // provides one, so the ambient DefaultTextStyle it resolves is
              // the same regardless of what's around it (see that function's
              // doc comment).
              child: Container(
                constraints: const BoxConstraints(minWidth: 64),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: calendarPanelBackgroundColor(context),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: VoyagerColors.of(context).hairline,
                  ),
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
    // Read-only trackers (e.g. the virtual Journal Entries tracker) show the
    // hover tooltip but can't be edited.
    if (widget.readOnly) return;
    if (ref.read(_heatmapDraggingProvider)) return;
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

  /// An [OverlayEntry] doesn't rebuild just because the widget that inserted
  /// it did, so a bubble that's already up keeps painting the build it was
  /// inserted with. That goes stale after an edit: saving invalidates the
  /// values provider and *then* pops the editor, which drops the pointer back
  /// onto the cell and re-runs [_show] before the refetch has landed — so the
  /// re-shown bubble captures the pre-edit value, and the rebuild that carries
  /// the new one arrives here, a frame or more later, with no effect on the
  /// entry. Marking it dirty on content change is what lets that rebuild
  /// through.
  ///
  /// Deferred to a post-frame callback rather than done inline: this runs
  /// during the parent's build — and the heatmap builds under a
  /// [LayoutBuilder], so it's a build inside a layout pass — while the entry
  /// lives in the root overlay, a subtree of its own. Marking a widget dirty
  /// mid-build is only legal for a descendant of whatever is currently
  /// building, which the overlay never is, so doing it here throws
  /// "markNeedsBuild() called during build". Waiting for the frame to finish
  /// costs the bubble one frame of staleness, which is invisible.
  @override
  void didUpdateWidget(_HoverEditPopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_entry == null) return;
    if (widget.periodLabel == oldWidget.periodLabel &&
        widget.valueLabel == oldWidget.valueLabel &&
        widget.valueColor == oldWidget.valueColor) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry == null) return;
      _entry!.markNeedsBuild();
      // Re-measured only once the rebuilt bubble has laid out — a different
      // value can change its width ([IntrinsicWidth]), and [_lastRect] is the
      // fallback start rect for the morph animation.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _entry == null) return;
        final measured = _measureTooltip();
        if (measured != null) _lastRect = measured;
      });
    });
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Dismiss an already-open tooltip the instant a drag starts anywhere
    // in the grid (not just on this row), matching the [_show] guard above.
    ref.listen(_heatmapDraggingProvider, (_, dragging) {
      if (dragging) _hide();
    });
    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        key: _key,
        onEnter: (_) => _show(),
        onExit: (_) => _hide(),
        child: GestureDetector(onTap: _handleTap, child: widget.child),
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

/// The value editor for a single period, shared by heatmap squares and
/// sparklines alike — both open it out of their own hover bubble, so the two
/// surfaces animate identically by construction rather than by two
/// implementations kept in sync by hand.
///
/// Opened as a real route rather than a raw overlay entry: this app's
/// go_router setup tolerates a simple
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
    _enumValue =
        widget.initialValue?.enumValue ?? widget.tracker.defaultEnumOption;
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
    left = left.clamp(
      margin,
      math.max(margin, screen.width - margin - size.width),
    );

    // Share the bottom-left corner with the tooltip rather than floating some
    // distance from it: the card's bottom border lands exactly on the
    // tooltip's bottom border, so the frame's start and end rects touch there
    // and the morph reads as one shape growing upward out of the tooltip
    // instead of leaving a gap.
    //
    // There's deliberately no flip to the tooltip's *top* edge when the card
    // won't fit above. That flip aligned the two top borders instead of the
    // bottom ones, which is a different animation, not a nudged version of the
    // same one — and it fired constantly on sparklines, whose bubble sits
    // above its datapoint and so leaves a card's height of headroom far less
    // often than a heatmap tooltip does. Clamping keeps the bottom borders
    // together for every case that fits and degrades by the smallest possible
    // offset for the few that don't.
    final top = (widget.anchorRect.bottom - size.height)
        .clamp(margin, math.max(margin, screen.height - margin - size.height))
        .toDouble();

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
              // The blurred/spread box shadows below are re-rasterized every
              // tick since their radii are animating — isolating them in
              // their own compositing layer keeps that repaint from also
              // repainting the sibling tooltip/editor/date layers in this
              // Stack, which don't otherwise share a layer with this one.
              child: RepaintBoundary(
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
                      Border.all(color: VoyagerColors.of(context).hairline),
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
                        color: VoyagerColors.of(context).shadow.withValues(
                          alpha: VoyagerColors.of(context).strongShadowAlpha * t,
                        ),
                        blurRadius:
                            10 * t * VoyagerColors.of(context).shadowBlurScale,
                        offset: Offset(0, 4 * t),
                      ),
                    ],
                  ),
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
                  // Ellipsised, and the only flexible child in the row: the
                  // card is a fixed 310 wide, so a long tracker name beside a
                  // long period label has nowhere to go and overflowed the
                  // row. The date keeps its natural width because the sliding
                  // layer in [build] animates the real date text onto this
                  // one's measured rect — truncating it would land the slide
                  // on a different string than the one it started from.
                  Expanded(
                    child: Text(
                      widget.tracker.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Invisible — only here to reserve layout space. The
                  // visible date text is drawn by the sliding layer in
                  // [build].
                  Opacity(
                    opacity: 0,
                    child: Text(
                      key: _editorDateKey,
                      widget.periodLabel,
                      style: _editorDateStyle(theme),
                      maxLines: 1,
                      softWrap: false,
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
                      foregroundColor: VoyagerColors.of(context).onAccent,
                    ),
                    child: const Text('Save'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: Navigator.of(context).pop,
                    style: TextButton.styleFrom(foregroundColor: accent),
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
                contentPadding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 0,
                  bottom: 12,
                ),
              ),
            ),
            if (cap != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(
                  '$minVal–$cap',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.6,
                    ),
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
          decoration: const InputDecoration(labelText: 'Value', isDense: true),
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
            await ref
                .read(trackerRepositoryProvider)
                .softDeleteValue(current.id);
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

    await ref
        .read(trackerRepositoryProvider)
        .upsertValue(
          TrackerValue(
            id:
                current?.id ??
                trackerValueId(widget.tracker.id, widget.periodDate),
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
    required this.valuesByDay,
    required this.hasSingleIntValue,
    required this.periodDate,
    required this.maxInPeriod,
    required this.analytics,
    required this.size,
  });

  final StatisticTracker tracker;

  /// This tracker's values keyed by calendar day (see [_HeatmapRow.build]) —
  /// an O(1) lookup for this square's [periodDate] instead of each square
  /// independently scanning the full value history.
  final Map<DateTime, TrackerValue> valuesByDay;

  /// Whether this tracker has ever recorded exactly one value, precomputed
  /// once per row (see [_HeatmapRow.build]) instead of re-scanned by
  /// [AnalyticsService.heatmapIntensity] for every square in the row.
  final bool hasSingleIntValue;
  final DateTime periodDate;
  final int maxInPeriod;
  final AnalyticsService analytics;
  final double size;

  @override
  ConsumerState<_HeatmapSquare> createState() => _HeatmapSquareState();
}

class _HeatmapSquareState extends ConsumerState<_HeatmapSquare> {
  TrackerValue? _findValue() {
    return widget.valuesByDay[DateTime(
      widget.periodDate.year,
      widget.periodDate.month,
      widget.periodDate.day,
    )];
  }

  @override
  Widget build(BuildContext context) {
    final value = _findValue();
    final intensity = widget.analytics.heatmapIntensity(
      type: widget.tracker.type,
      value: value,
      tracker: widget.tracker,
      maxInPeriod: widget.maxInPeriod == 0 ? 1 : widget.maxInPeriod,
      hasSingleIntValue: widget.hasSingleIntValue,
    );
    final color = Color(widget.tracker.colorValue);
    final bgColor = intensity == 0
        ? color.withValues(alpha: 0.10)
        : color.withValues(alpha: 0.15 + 0.85 * intensity);

    return _hoverTooltip(
      context: context,
      periodLabel: _tooltipPeriodLabel(
        widget.periodDate,
        widget.tracker.cadence,
      ),
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
          border: Border.all(
            color: VoyagerColors.of(context).hairline,
            width: 1,
          ),
          boxShadow: _heatmapGlow(color, intensity),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Calendar View
// ---------------------------------------------------------------------------

/// Opens [_StatisticDetailPopup] for [tracker] — the large overlay that
/// replaced the old Calendar view mode. Dismissed by tapping the scrim, the
/// close button, or Escape.
Future<void> _showStatisticDetail({
  required BuildContext context,
  required StatisticTracker tracker,
  required AnalyticsService analytics,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: VoyagerColors.of(context).scrim,
    builder: (_) =>
        _StatisticDetailPopup(tracker: tracker, analytics: analytics),
  );
}

class _StatisticDetailPopup extends ConsumerWidget {
  const _StatisticDetailPopup({required this.tracker, required this.analytics});

  final StatisticTracker tracker;
  final AnalyticsService analytics;

  /// Steps the visible window by [delta] pages (-1 left/earlier, 1
  /// right/later), matching whichever calendar [build] is showing for
  /// [tracker]. The consecutive style renders a line chart with no windowed
  /// range, so there's nothing to page there.
  void _page(WidgetRef ref, StatisticTracker? tracker, int delta) {
    if (tracker == null) return;
    if (tracker.effectiveTrackingStyle == TrackerStyle.consecutive) return;
    if (tracker.cadence == TrackerCadence.monthly) {
      ref
          .read(_calendarViewMonthlyBaseYearProvider.notifier)
          .update((y) => y + _monthGridWindowYears * delta);
    } else if (tracker.cadence == TrackerCadence.yearly) {
      ref
          .read(_calendarViewYearlyBaseYearProvider.notifier)
          .update((y) => y + _yearGridWindowYears * delta);
    } else {
      ref.read(_calendarViewYearProvider.notifier).update((y) => y + delta);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final color = Color(tracker.colorValue);

    // The same widget the Calendar page uses for its own period navigation, so
    // the arrows (and the configurable letter keys) behave identically in both
    // places. It listens on [HardwareKeyboard] rather than a [Focus] node,
    // so it works the moment the popup opens without anything having to take
    // focus first.
    return CalendarKeyboardShortcuts(
      navigateLeftKey: settings.calendarNavigateLeftKey,
      navigateRightKey: settings.calendarNavigateRightKey,
      onNavigate: (delta) => _page(ref, tracker, delta),
      child: Dialog(
        // Fully opaque, unlike the calendar's own translucent panels: this
        // sits directly over the grid it was opened from, and letting the
        // tiles show through would leave the chart competing with a heatmap
        // behind it.
        backgroundColor: theme.colorScheme.surface.withValues(alpha: 1),
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: color.withValues(alpha: 0.25)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ────────────────────────────────────────────
                Row(
                  children: [
                    CircleAvatar(radius: 6, backgroundColor: color),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tracker.name,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${tracker.cadence.name} · '
                            '${_typeLabel(tracker.type)}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Built-in trackers are derived, not stored — nothing
                    // about them is editable.
                    if (!tracker.isDefault)
                      IconButton(
                        icon: const Icon(
                          PhosphorIconsRegular.pencilSimple,
                          size: 18,
                        ),
                        tooltip: 'Edit tracker',
                        onPressed: () async {
                          final updated = await showDialog<StatisticTracker>(
                            context: context,
                            builder: (_) => _TrackerDialog(tracker: tracker),
                          );
                          if (updated == null) return;
                          await ref
                              .read(trackerRepositoryProvider)
                              .upsertTracker(updated);
                          ref.invalidate(trackersProvider);
                        },
                      ),
                    IconButton(
                      icon: const Icon(PhosphorIconsRegular.x, size: 18),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // ── Body ──────────────────────────────────────────────
                Flexible(
                  child: SingleChildScrollView(
                    child: _StatisticDetailBody(
                      tracker: tracker,
                      analytics: analytics,
                    ),
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

/// Picks the right calendar body for [tracker] — the same dispatch the old
/// Calendar view mode used.
class _StatisticDetailBody extends StatelessWidget {
  const _StatisticDetailBody({required this.tracker, required this.analytics});

  final StatisticTracker tracker;
  final AnalyticsService analytics;

  @override
  Widget build(BuildContext context) {
    if (tracker.effectiveTrackingStyle == TrackerStyle.consecutive) {
      return _ConsecutiveCalendarChart(tracker: tracker, analytics: analytics);
    }
    return switch (tracker.cadence) {
      TrackerCadence.monthly => _MonthGridCalendar(
        tracker: tracker,
        analytics: analytics,
      ),
      TrackerCadence.yearly => _YearGridCalendar(
        tracker: tracker,
        analytics: analytics,
      ),
      _ => _YearHeatmapCalendar(tracker: tracker, analytics: analytics),
    };
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
    final theme = Theme.of(context);
    final color = Color(tracker.colorValue);
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final weekStartsMonday = settings.weekStartsOnMonday;
    final promptService = ref.watch(periodicPromptServiceProvider);

    // The chart spans a fixed number of periods per cadence — roughly 180
    // days / 50 weeks / 24 months / 15 years. The window is sized so the day
    // count is an exact multiple of the tick spacing, which is what keeps
    // every bottom-axis label evenly spaced *and* lands the current period
    // squarely on the final tick (instead of a stray, closer "today" label at
    // the right edge — the old 1, 6, 11, 16, 17 problem).
    final now = DateTime.now();
    final todayPeriod = promptService.periodStartFor(
      now,
      tracker.cadence,
      weekStartsMonday: weekStartsMonday,
    );
    final (
      int totalDays,
      double tickInterval,
      String dateFmt,
    ) = switch (tracker.cadence) {
      TrackerCadence.daily => (180, 30.0, 'MMM d'),
      TrackerCadence.weekly => (343, 49.0, 'MMM d'),
      TrackerCadence.monthly => (720, 120.0, 'MMM yy'),
      TrackerCadence.yearly => (5475, 1095.0, 'yyyy'),
    };
    final from = addCalendarDays(todayPeriod, -totalDays);

    return valuesAsync.when(
      data: (values) {
        final spots = analytics.interpolateConsecutive(
          values: values,
          from: from,
          to: todayPeriod,
          maxDays: totalDays,
          upperBound: tracker.integerCap,
        );

        // One anchor per period start across the whole window, rendered as an
        // invisible zero-height line. fl_chart only reports touches near a
        // bar's spots, so these give a tap *anywhere* a nearest period to
        // resolve to — letting the user click the chart to enter data even
        // when it's otherwise empty ("just axes"), without drawing a baseline.
        final anchors = <FlSpot>[];
        for (var i = 0; ; i++) {
          final periodStart = switch (tracker.cadence) {
            TrackerCadence.daily => addCalendarDays(todayPeriod, -i),
            TrackerCadence.weekly => addCalendarDays(todayPeriod, -i * 7),
            TrackerCadence.monthly => DateTime(
              todayPeriod.year,
              todayPeriod.month - i,
              1,
            ),
            TrackerCadence.yearly => DateTime(todayPeriod.year - i, 1, 1),
          };
          final x = calendarDaysBetween(from, periodStart);
          if (x < 0) break;
          anchors.add(FlSpot(x.toDouble(), 0));
        }
        final anchorSpots = anchors.reversed.toList();

        DateTime periodStartOf(DateTime date) => promptService.periodStartFor(
          date,
          tracker.cadence,
          weekStartsMonday: weekStartsMonday,
        );

        final dataMax = spots.isEmpty
            ? 1.0
            : spots.map((s) => s.y).fold<double>(1, math.max);
        // The popup has the height to carry a full six-line scale.
        final yStep = niceAxisStep(dataMax, _sparklineDetailGridLines);
        final maxY = yStep * (_sparklineDetailGridLines - 1);
        // See the matching note on the grid sparkline: the plot area is the
        // chart's box inset by what the axis titles reserve, and the hover
        // bubble maps spots to pixels with these same numbers.
        final leftReserved = axisReservedSize(maxY, 12, 10);
        const bottomReserved = 32.0;

        return SizedBox(
          height: 380,
          child: _SparklineTouchScope(
            builder: (context, touch, onTouchChanged, bubbleKeys) {
              final touchedIndex = touchedSpotIndex(spots, touch?.x);
              // Hoisted so the touched-spot indicator below can reference the
              // very same bar instance it's drawn against.
              final dataBar = LineChartBarData(
                spots: spots,
                isCurved: true,
                color: color,
                barWidth: 2,
                dotData: FlDotData(show: spots.length <= 15),
                belowBarData: _sparklineFill(color),
                showingIndicators: touchedIndex < 0 ? const [] : [touchedIndex],
              );
              final chart = LineChart(
                LineChartData(
                  // fl_chart's own tooltip stays off: the bubble is drawn
                  // by [_sparklineHoverBubble] instead, so it is literally
                  // the heatmap's. The indicator line on the touched spot
                  // is a separate setting
                  // ([LineChartBarData.showingIndicators]) and is still on.
                  showingTooltipIndicators: const [],
                  lineTouchData: LineTouchData(
                    handleBuiltInTouches: false,
                    // Large threshold so a tap anywhere resolves to the nearest
                    // period anchor rather than leaving dead zones.
                    touchSpotThreshold: 100000,
                    touchCallback:
                        (FlTouchEvent event, LineTouchResponse? response) {
                          _recordSparklineTouch(
                            event,
                            response,
                            onTouchChanged,
                          );
                          _openSparklinePeriodEditor(
                            event: event,
                            response: response,
                            context: context,
                            tracker: tracker,
                            from: from,
                            values: values,
                            periodStartOf: periodStartOf,
                            bubbleKeys: bubbleKeys,
                            color: color,
                            onTouchChanged: onTouchChanged,
                            onSaved: () => ref.invalidate(
                              trackerValuesProvider(tracker.id),
                            ),
                          );
                        },
                  ),
                  minX: 0,
                  maxX: totalDays.toDouble(),
                  minY: 0,
                  maxY: maxY,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: yStep,
                    getDrawingHorizontalLine: (_) => FlLine(
                      color: theme.colorScheme.outline.withValues(alpha: 0.15),
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
                    // See the matching note on the grid sparkline: the axes
                    // hold their labels clear of the plot so the Y origin and
                    // the first date label don't collide in the corner.
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: leftReserved,
                        interval: yStep,
                        getTitlesWidget: (v, meta) => SideTitleWidget(
                          meta: meta,
                          space: 10,
                          child: Text(
                            compactNumberLabel(v),
                            maxLines: 1,
                            softWrap: false,
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: bottomReserved,
                        interval: tickInterval,
                        getTitlesWidget: (v, meta) {
                          final date = addCalendarDays(from, v.round());
                          return SideTitleWidget(
                            meta: meta,
                            space: 10,
                            child: Text(
                              DateFormat(dateFmt).format(date),
                              style: theme.textTheme.labelSmall,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    // barIndex 0 — invisible hit-test anchors.
                    LineChartBarData(
                      spots: anchorSpots,
                      color: Colors.transparent,
                      barWidth: 0,
                      dotData: const FlDotData(show: false),
                    ),
                    // barIndex 1 — the real data curve.
                    dataBar,
                  ],
                ),
              );
              return _sparklineHoverBubble(
                chart: chart,
                touch: touch,
                spots: spots,
                minX: 0,
                maxX: totalDays.toDouble(),
                maxY: maxY,
                leftReserved: leftReserved,
                bottomReserved: bottomReserved,
                from: from,
                values: values,
                tracker: tracker,
                periodStartOf: periodStartOf,
                color: color,
                keys: bubbleKeys,
              );
            },
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
// Yearly heatmap calendar
// ---------------------------------------------------------------------------

class _YearHeatmapCalendar extends ConsumerWidget {
  const _YearHeatmapCalendar({required this.tracker, required this.analytics});

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

        // Arrow-key paging is handled once for every calendar by
        // [_CalendarView] above — see [_CalendarView._page].
        return Column(
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
    '',
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
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
        child: LayoutBuilder(
          builder: (context, constraints) {
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
                        ? _weeklyRowCells(
                            row: row,
                            cells: cells,
                            daySize: daySize,
                          )
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
          },
        ),
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
    // Days spilling in from an adjacent month never take the tracker's colour
    // fill — they render as neutral (faded) cells so only the days that
    // actually belong to this month light up. Their own value shows when that
    // month is in view.
    final bgColor = (!inMonth || value == null)
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
          borderRadius: BorderRadius.circular(
            MonthDayCellStyle.compact.borderRadius,
          ),
          // Spill-in days from an adjacent month render neutral, so they
          // never glow either.
          boxShadow: (!inMonth || value == null)
              ? const []
              : _heatmapGlow(color, intensity),
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
                  : Theme.of(context).colorScheme.onSurfaceVariant.withValues(
                      alpha: calendarAdjacentMonthTextOpacity,
                    ),
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
          borderRadius: BorderRadius.circular(
            MonthDayCellStyle.compact.borderRadius,
          ),
          // The week reads as one block, so the glow goes on the block rather
          // than on each of its day segments.
          boxShadow: value == null ? const [] : _heatmapGlow(color, intensity),
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
                            : theme.colorScheme.onSurfaceVariant.withValues(
                                alpha: calendarAdjacentMonthTextOpacity,
                              ),
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
      ref
          .read(_calendarViewMonthlyBaseYearProvider.notifier)
          .update((y) => y - _monthGridWindowYears);
    }

    void nextWindow() {
      ref
          .read(_calendarViewMonthlyBaseYearProvider.notifier)
          .update((y) => y + _monthGridWindowYears);
    }

    return valuesAsync.when(
      data: (values) {
        final max = analytics.rollingMax(values, days: 731);

        // Arrow-key paging is handled once for every calendar by
        // [_CalendarView] above — see [_CalendarView._page].
        return Column(
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
                  '$baseYear – ${baseYear + _monthGridWindowYears - 1}',
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
            for (var row = 0; row < _monthGridWindowYears; row++) ...[
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
    // Match the canonical month period-start exactly (the 1st). Matching
    // year+month alone would also pick up any daily row recorded in that
    // month, so a tracker toggled from daily to monthly would surface an
    // arbitrary daily value as the month's — and overwrite it on edit.
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
            periodLabel: _tooltipPeriodLabel(
              widget.periodDate,
              TrackerCadence.monthly,
            ),
            type: widget.tracker.type,
            value: value,
            tracker: widget.tracker,
            periodDate: widget.periodDate,
            valueColor: value == null
                ? null
                : _heatmapValueColor(color, intensity),
            onSaved: () {
              ref.invalidate(trackerValuesProvider(widget.tracker.id));
              ref.invalidate(pendingStatEntriesProvider);
            },
            child: Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: VoyagerColors.of(context).hairline),
                boxShadow: value == null
                    ? const []
                    : _heatmapGlow(color, intensity),
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(trackerValuesProvider(tracker.id));
    final theme = Theme.of(context);
    final baseYear = ref.watch(_calendarViewYearlyBaseYearProvider);

    void previousWindow() {
      ref
          .read(_calendarViewYearlyBaseYearProvider.notifier)
          .update((y) => y - _yearGridWindowYears);
    }

    void nextWindow() {
      ref
          .read(_calendarViewYearlyBaseYearProvider.notifier)
          .update((y) => y + _yearGridWindowYears);
    }

    return valuesAsync.when(
      data: (values) {
        final max = analytics.rollingMax(
          values,
          days: 365 * _yearGridWindowYears,
        );

        // Arrow-key paging is handled once for every calendar by
        // [_CalendarView] above — see [_CalendarView._page].
        return Column(
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
                  '$baseYear – ${baseYear + _yearGridWindowYears - 1}',
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
                for (var i = 0; i < _yearGridWindowYears; i++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: i < _yearGridWindowYears - 1 ? 6 : 0,
                      ),
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
    // Match the canonical year period-start exactly (Jan 1). Matching the
    // year alone would also pick up any daily/monthly row in that year, so a
    // tracker toggled to yearly would surface an unrelated value as the
    // year's — and overwrite it on edit.
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
            periodLabel: _tooltipPeriodLabel(
              widget.periodDate,
              TrackerCadence.yearly,
            ),
            type: widget.tracker.type,
            value: value,
            tracker: widget.tracker,
            periodDate: widget.periodDate,
            valueColor: value == null
                ? null
                : _heatmapValueColor(color, intensity),
            onSaved: () {
              ref.invalidate(trackerValuesProvider(widget.tracker.id));
              ref.invalidate(pendingStatEntriesProvider);
            },
            child: Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: VoyagerColors.of(context).hairline),
                boxShadow: value == null
                    ? const []
                    : _heatmapGlow(color, intensity),
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
    _defaultIntController = TextEditingController(
      text: t?.defaultInt.toString() ?? '0',
    );
    _capController = TextEditingController(
      text: t?.integerCap?.toString() ?? '10',
    );
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
      title: Text(
        widget.tracker != null
            ? 'Edit statistic tracker'
            : 'New statistic tracker',
      ),
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
                  contentPadding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 0,
                    bottom: 12,
                  ),
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
                onChanged: (value) => setState(() => _type = value ?? _type),
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
                    selectedForegroundColor: VoyagerColors.of(context).onAccent,
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
                onChanged: (value) => setState(() => _showOnCalendar = value),
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
                      contentPadding: EdgeInsets.only(
                        left: 16,
                        right: 16,
                        top: 0,
                        bottom: 12,
                      ),
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
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          accentColor: accent,
                          decoration: const InputDecoration(
                            labelText: 'Lower limit',
                            isDense: true,
                            contentPadding: EdgeInsets.only(
                              left: 16,
                              right: 16,
                              top: 0,
                              bottom: 12,
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          '-',
                          style: Theme.of(
                            context,
                          ).textTheme.titleLarge?.copyWith(color: accent),
                        ),
                      ),
                      Expanded(
                        child: VoyagerTextField(
                          controller: _capController,
                          focusNode: _upperFocusNode,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          accentColor: accent,
                          decoration: const InputDecoration(
                            labelText: 'Upper limit',
                            isDense: true,
                            contentPadding: EdgeInsets.only(
                              left: 16,
                              right: 16,
                              top: 0,
                              bottom: 12,
                            ),
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
                  onChanged: (value) => setState(() => _defaultBool = value),
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
                                  color: Theme.of(context).colorScheme.onSurface
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
                                    if (!_enumOptions.contains(
                                      _defaultEnumOption,
                                    )) {
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
                    contentPadding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 0,
                      bottom: 12,
                    ),
                  ),
                  onChanged: (_) {
                    if (_optionError != null)
                      setState(() => _optionError = null);
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
                maxHeight:
                    paletteViewportHeight(
                      18,
                      visibleRows: 3,
                      clipPartialNextRow: true,
                    ) -
                    4,
                onChanged: (value) => setState(() => _colorValue = value),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: accent),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: accent),
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
        trackingStyle: _type == TrackerType.integer ? _trackingStyle : null,
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
