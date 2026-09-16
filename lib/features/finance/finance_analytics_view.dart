import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/widgets/chart_hover_bubble.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/scope_switcher.dart';
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/features/finance/finance_asset_modal.dart';
import 'package:voyager/features/finance/finance_category_modal.dart';
import 'package:voyager/features/finance/finance_contribution_room_modal.dart';
import 'package:voyager/features/finance/finance_room_bar.dart';
import 'package:voyager/features/finance/finance_room_event_modal.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart'
    show kIncomeGreen;
import 'package:voyager/features/finance/finance_ui_prefs.dart';

/// Which bucket of the spending breakdown is being drilled into.
///
/// In memory only, and deliberately so: a focus is a question being asked
/// right now ("what is inside food this month"), not a setting. Coming back to
/// the tab in the same session keeps the answer on screen; relaunching the app
/// into a chart quietly showing one slice of one bucket would not be a
/// feature, it would be a chart that lies about what it is showing.
sealed class BreakdownFocus {
  const BreakdownFocus();
}

class BreakdownFocusNone extends BreakdownFocus {
  const BreakdownFocusNone();
}

/// Drilled into the expenses whose *primary* tag is [tag].
class BreakdownFocusTag extends BreakdownFocus {
  const BreakdownFocusTag(this.tag);

  final String tag;

  @override
  bool operator ==(Object other) =>
      other is BreakdownFocusTag && other.tag == tag;

  @override
  int get hashCode => Object.hash('tag', tag);
}

/// Drilled into a category-grouped slice: a category name, or one of
/// [kUncategorizedLabel] / [kUntaggedLabel].
class BreakdownFocusCategory extends BreakdownFocus {
  const BreakdownFocusCategory(this.label);

  final String label;

  @override
  bool operator ==(Object other) =>
      other is BreakdownFocusCategory && other.label == label;

  @override
  int get hashCode => Object.hash('category', label);
}

final _breakdownFocusProvider = StateProvider<BreakdownFocus>(
  (_) => const BreakdownFocusNone(),
);

/// How many buckets the cash-flow dashboard shows, at every granularity.
///
/// The same count for all three on purpose. fl_chart animates between two
/// `BarChartData`s by lerping their group lists pairwise, and when the two
/// lists are *different lengths* it can't: the shorter one's groups morph
/// while the extra groups snap straight to their final values, all while the
/// y-axis is still rescaling underneath. Yearly used to show five buckets
/// against the others' twelve, which is why the heave was only ever visible
/// crossing into or out of the yearly view. Equal lengths make every
/// transition a true one-to-one morph.
const int _kCashFlowPeriods = 12;

/// The macro analytics suite: income vs. expense, spending breakdown, and the
/// net-worth tracker.
class FinanceAnalyticsView extends StatelessWidget {
  const FinanceAnalyticsView({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Side by side, each card gets under half the width. The breakdown
        // card's month row — "September 2026" beside the Category/Tag/Store
        // switch — needs ~410px inside the card, which 880 did not leave.
        final wide = constraints.maxWidth >= 960;
        final padding = EdgeInsets.fromLTRB(wide ? 20 : 16, 4, wide ? 20 : 16, 96);

        if (!wide) {
          return ListView(
            padding: padding,
            children: const [
              _CashFlowCard(),
              SizedBox(height: 12),
              _BreakdownCard(),
              SizedBox(height: 12),
              _NetWorthCard(),
            ],
          );
        }
        return ListView(
          padding: padding,
          children: const [
            _CashFlowCard(),
            SizedBox(height: 12),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _BreakdownCard()),
                  SizedBox(width: 12),
                  Expanded(child: _NetWorthCard()),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Shared card shell
// ---------------------------------------------------------------------------

class _AnalyticsCard extends StatelessWidget {
  const _AnalyticsCard({
    required this.icon,
    this.title = '',
    this.titleWidget,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;

  /// Replaces [title] when the title does more than name the card — the
  /// breakdown card's chart dropdown. It carries its own 8px of tap padding,
  /// so the gap after the icon is left to it.
  final Widget? titleWidget;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
              if (titleWidget case final titleWidget?)
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: titleWidget,
                  ),
                )
              else ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// Compact money label for chart axes (e.g. `$1.2k`).
String _compactMoney(double dollars) {
  final abs = dollars.abs();
  final sign = dollars < 0 ? '-' : '';
  if (abs >= 1000000) return '$sign\$${(abs / 1000000).toStringAsFixed(1)}M';
  if (abs >= 1000) return '$sign\$${(abs / 1000).toStringAsFixed(1)}k';
  return '$sign\$${abs.toStringAsFixed(0)}';
}

// ---------------------------------------------------------------------------
// Income vs. Expense dashboard
// ---------------------------------------------------------------------------

class _CashFlowCard extends ConsumerWidget {
  const _CashFlowCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final granularity = ref.watch(
      financeUiPrefsProvider.select((prefs) => prefs.cashFlowGranularity),
    );
    final transactions = settledTransactions(
      ref.watch(transactionsProvider).valueOrNull ?? const [],
      DateTime.now(),
    );
    final weekStartsMonday =
        ref.watch(settingsProvider).valueOrNull?.weekStartsOnMonday ?? true;

    final series = cashFlowSeries(
      transactions,
      granularity: granularity,
      periods: _kCashFlowPeriods,
      weekStartsMonday: weekStartsMonday,
    );

    final totalIncome = series.fold<int>(0, (s, p) => s + p.incomeCents);
    final totalExpense = series.fold<int>(0, (s, p) => s + p.expenseCents);
    final maxCents = series.fold<int>(
      0,
      (m, p) => [m, p.incomeCents, p.expenseCents].reduce((a, b) => a > b ? a : b),
    );
    final maxY = maxCents == 0 ? 1.0 : (maxCents / 100) * 1.2;

    return _AnalyticsCard(
      icon: PhosphorIconsRegular.chartBar,
      title: 'Income vs. Expense',
      trailing: SegmentedButton<CashFlowGranularity>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          textStyle: const TextStyle(fontSize: 11),
        ),
        segments: const [
          ButtonSegment(
            value: CashFlowGranularity.weekly,
            label: Text('W'),
            tooltip: 'Weekly',
          ),
          ButtonSegment(
            value: CashFlowGranularity.monthly,
            label: Text('M'),
            tooltip: 'Monthly',
          ),
          ButtonSegment(
            value: CashFlowGranularity.yearly,
            label: Text('Y'),
            tooltip: 'Yearly',
          ),
        ],
        selected: {granularity},
        onSelectionChanged: (set) {
          if (set.isNotEmpty) {
            ref
                .read(financeUiPrefsProvider.notifier)
                .setCashFlowGranularity(set.first);
          }
        },
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _LegendDot(color: kIncomeGreen, label: 'In'),
              const SizedBox(width: 6),
              Text(
                formatCents(totalIncome),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(width: 16),
              _LegendDot(color: accent, label: 'Out'),
              const SizedBox(width: 6),
              Text(
                formatCents(totalExpense),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const Spacer(),
              Text(
                'Net ${formatCents(totalIncome - totalExpense, signed: true)}',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: totalIncome - totalExpense >= 0
                      ? kIncomeGreen
                      : theme.colorScheme.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 180,
            child: maxCents == 0
                ? Center(
                    child: Text(
                      'No activity in this period yet.',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : _CashFlowChart(
                    series: series,
                    granularity: granularity,
                    maxY: maxY,
                    accent: accent,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Axis tick label for a cash-flow bucket — short, because a dozen of them
/// share one axis.
String _periodTickLabel(DateTime start, CashFlowGranularity granularity) {
  switch (granularity) {
    case CashFlowGranularity.weekly:
      return DateFormat('MMM d').format(start);
    case CashFlowGranularity.monthly:
      return DateFormat('MMM').format(start);
    case CashFlowGranularity.yearly:
      return DateFormat('yyyy').format(start);
  }
}

/// The same bucket spelled out for a hover bubble, which has one line to
/// itself and should leave no doubt which week or year is being read. Matches
/// the analytics page's tooltip wording.
String _periodBubbleLabel(DateTime start, CashFlowGranularity granularity) {
  switch (granularity) {
    case CashFlowGranularity.weekly:
      return 'Week of ${DateFormat('MMM d, yyyy').format(start)}';
    case CashFlowGranularity.monthly:
      return DateFormat('MMMM yyyy').format(start);
    case CashFlowGranularity.yearly:
      return DateFormat('yyyy').format(start);
  }
}

/// Income vs. expense bars, sized to the card they're in and reporting through
/// the app's shared hover bubble.
class _CashFlowChart extends StatefulWidget {
  const _CashFlowChart({
    required this.series,
    required this.granularity,
    required this.maxY,
    required this.accent,
  });

  final List<CashFlowPoint> series;
  final CashFlowGranularity granularity;
  final double maxY;
  final Color accent;

  @override
  State<_CashFlowChart> createState() => _CashFlowChartState();
}

class _CashFlowChartState extends State<_CashFlowChart> {
  static const double _leftReserved = 42;
  static const double _bottomReserved = 22;
  static const double _barsSpace = 2;

  /// Share of each bucket's slot the two rods together are allowed to fill.
  /// The remainder is the gutter that keeps one bucket legible from the next.
  static const double _slotFill = 0.72;

  static const double _minRodWidth = 5;
  static const double _maxRodWidth = 26;

  ({int group, int rod})? _touched;

  void _handleTouch(FlTouchEvent event, BarTouchResponse? response) {
    final spot = response?.spot;
    final next = !event.isInterestedForInteractions || spot == null
        ? null
        : (group: spot.touchedBarGroupIndex, rod: spot.touchedRodDataIndex);
    // A bucket with no income (or no spending) draws no rod at all, but
    // fl_chart still reports a hit on the zero-height one when the pointer
    // crosses where it would have been. Reading out "$0.00" from a bar that
    // isn't on screen is a reading of nothing, so it doesn't get a bubble.
    if (next != null && _centsAt(next.group, next.rod) == 0) {
      if (_touched == null) return;
      setState(() => _touched = null);
      return;
    }
    if (next == _touched) return;
    setState(() => _touched = next);
  }

  /// Value of one rod, or 0 when [group]/[rod] isn't a rod in this chart.
  int _centsAt(int group, int rod) {
    if (group < 0 || group >= widget.series.length) return 0;
    final point = widget.series[group];
    return switch (rod) {
      0 => point.incomeCents,
      1 => point.expenseCents,
      _ => 0,
    };
  }

  /// Width of one rod, so the pair fills [_slotFill] of the bucket's share of
  /// the plot.
  ///
  /// Sized from the plot rather than fixed at a handful of pixels: a dozen
  /// 5px rods left a wide card looking like a chart of hairlines with most of
  /// its width spent on empty gutter.
  double _rodWidth(double plotWidth, int count) {
    if (count == 0) return _minRodWidth;
    final slot = plotWidth / count;
    return (((slot * _slotFill) - _barsSpace) / 2).clamp(
      _minRodWidth,
      _maxRodWidth,
    );
  }

  /// Centre of bucket [index]'s group, in plot coordinates.
  ///
  /// Mirrors what [BarChartAlignment.spaceAround] does inside fl_chart: the
  /// leftover width is split into one gutter on each side of every group, so a
  /// group sits half a gutter in from where an evenly-spaced one would.
  double _groupCentre(
    int index,
    double plotWidth,
    double groupWidth,
    int count,
  ) {
    final gutter = (plotWidth - count * groupWidth) / (count * 2);
    return (2 * index + 1) * gutter + (index + 0.5) * groupWidth;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final series = widget.series;
    final accent = widget.accent;
    final maxY = widget.maxY;

    return LayoutBuilder(
      builder: (context, constraints) {
        final plotWidth = math.max(0.0, constraints.maxWidth - _leftReserved);
        final plotHeight = math.max(
          0.0,
          constraints.maxHeight - _bottomReserved,
        );
        final rodWidth = _rodWidth(plotWidth, series.length);
        final groupWidth = rodWidth * 2 + _barsSpace;

        final touched = _touched;
        final valid =
            touched != null &&
            touched.group >= 0 &&
            touched.group < series.length &&
            (touched.rod == 0 || touched.rod == 1);

        final chart = BarChart(
          BarChartData(
            maxY: maxY,
            alignment: BarChartAlignment.spaceAround,
            barTouchData: BarTouchData(
              // fl_chart's own tooltip stays off — the bubble below is the
              // analytics page's, so the two surfaces read identically.
              handleBuiltInTouches: false,
              touchCallback: _handleTouch,
            ),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              getDrawingHorizontalLine: (_) => FlLine(
                color: theme.colorScheme.outline.withValues(alpha: 0.10),
                strokeWidth: 1,
              ),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: _leftReserved,
                  getTitlesWidget: (value, _) => Text(
                    _compactMoney(value),
                    style: theme.textTheme.labelSmall?.copyWith(fontSize: 9),
                  ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: _bottomReserved,
                  getTitlesWidget: (value, _) {
                    final i = value.toInt();
                    if (i < 0 || i >= series.length) {
                      return const SizedBox.shrink();
                    }
                    // Thin out labels so they never collide, counting back
                    // from the right-hand end rather than forward from the
                    // left. With an even number of buckets and every other
                    // one labelled, one of the two ends goes unlabelled — and
                    // the one that matters is the newest bucket, which is the
                    // period the user is currently in.
                    final step = (series.length / 6).ceil();
                    if ((series.length - 1 - i) % step != 0) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _periodTickLabel(
                          series[i].periodStart,
                          widget.granularity,
                        ),
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 9,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < series.length; i++)
                BarChartGroupData(
                  x: i,
                  barsSpace: _barsSpace,
                  barRods: [
                    BarChartRodData(
                      toY: series[i].incomeCents / 100,
                      color: kIncomeGreen,
                      width: rodWidth,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(2),
                      ),
                    ),
                    BarChartRodData(
                      toY: series[i].expenseCents / 100,
                      color: accent,
                      width: rodWidth,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(2),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );

        final point = valid ? series[touched.group] : null;
        final isIncome = valid && touched.rod == 0;
        final cents = point == null
            ? 0
            : (isIncome ? point.incomeCents : point.expenseCents);
        final rodCentre = point == null
            ? 0.0
            : _groupCentre(
                    touched!.group,
                    plotWidth,
                    groupWidth,
                    series.length,
                  ) -
                  groupWidth / 2 +
                  (isIncome
                      ? rodWidth / 2
                      : rodWidth + _barsSpace + rodWidth / 2);

        // The chart stays the Stack's first child whether or not anything is
        // hovered: dropping back to a bare chart between hovers would rebuild
        // its element and restart the bar animation every time the pointer
        // left the plot.
        return Stack(
          clipBehavior: Clip.none,
          children: [
            chart,
            if (point != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomSingleChildLayout(
                    delegate: _ChartBubbleLayout(
                      anchor: Offset(
                        _leftReserved + rodCentre,
                        maxY == 0
                            ? plotHeight
                            : plotHeight * (1 - (cents / 100) / maxY),
                      ),
                    ),
                    child: ChartHoverBubble(
                      periodLabel: _periodBubbleLabel(
                        point.periodStart,
                        widget.granularity,
                      ),
                      valueLabel: formatCents(cents),
                      valueColor: isIncome ? kIncomeGreen : accent,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Spending breakdown
// ---------------------------------------------------------------------------

class _BreakdownCard extends ConsumerWidget {
  const _BreakdownCard();

  /// How many legend rows the chart lists.
  ///
  /// Twelve while focused rather than six: a drill-down is the one view where
  /// the long tail is the point — "what else was in here" — and the focused
  /// set is bounded by one bucket's worth of tags, not by the whole month's.
  static const _legendRows = 6;
  static const _focusedLegendRows = 12;

  /// The month row's height in both charts: the compact Category/Tag/Store
  /// control's. Income has no control there, and a row only as tall as its
  /// label pulled the pie 16px up on every switch between the two.
  static const _monthRowHeight = 32.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final chart = ref.watch(
      financeUiPrefsProvider.select((prefs) => prefs.breakdownChart),
    );
    final switcher = ScopeSwitcher<FinanceBreakdownChart>(
      items: const [
        ScopeSwitcherItem(
          value: FinanceBreakdownChart.spending,
          label: 'Spending Breakdown',
        ),
        ScopeSwitcherItem(
          value: FinanceBreakdownChart.income,
          label: 'Income by Source',
        ),
      ],
      selectedValue: chart,
      accent: theme.colorScheme.onSurface,
      popoverWidth: 200,
      onSelected: (value) {
        // A drill-down is a question about spending; it shouldn't be waiting
        // behind the income chart to reappear on the way back.
        _clearFocus(ref);
        ref.read(financeUiPrefsProvider.notifier).setBreakdownChart(value);
      },
    );
    if (chart == FinanceBreakdownChart.income) {
      return _AnalyticsCard(
        icon: PhosphorIconsRegular.chartPieSlice,
        titleWidget: switcher,
        child: _incomeSourceChart(context, ref),
      );
    }

    final mode = ref.watch(
      financeUiPrefsProvider.select((prefs) => prefs.breakdownMode),
    );
    final focus = ref.watch(_breakdownFocusProvider);
    final now = DateTime.now();
    final transactions = settledTransactions(
      ref.watch(transactionsProvider).valueOrNull ?? const [],
      now,
    );
    final categories =
        ref.watch(financeCategoriesProvider).valueOrNull ?? const [];
    final tagColors = ref.watch(tagColorsProvider).valueOrNull ?? const {};

    final from = DateTime(now.year, now.month, 1);
    final to = DateTime(now.year, now.month + 1, 1);

    final List<BreakdownSlice> slices;
    // What the donut's centre reads. Only in the unfocused and tag-focused
    // charts is it the sum of the slices: a category drill-down counts a
    // multi-tag expense under each of its tags, so its children can add up to
    // more than the category cost. The exclusive parent total is the honest
    // answer to "what did this bucket cost", so that is what the centre keeps.
    final int total;
    switch (focus) {
      case BreakdownFocusNone() when mode == FinanceBreakdownMode.store:
        slices = originBreakdown(
          transactions,
          from: from,
          to: to,
          type: TransactionType.expense,
          colorFor: colorForTag,
        );
        total = slices.fold<int>(0, (s, x) => s + x.amountCents);
      case BreakdownFocusNone():
        slices = spendingBreakdown(
          transactions,
          from: from,
          to: to,
          categories: categories,
          tagColors: tagColors,
          groupByCategory: mode == FinanceBreakdownMode.category,
        );
        total = slices.fold<int>(0, (s, x) => s + x.amountCents);
      case BreakdownFocusTag(:final tag):
        final result = spendingBreakdownFocusedByTag(
          transactions,
          from: from,
          to: to,
          tag: tag,
          tagColors: tagColors,
        );
        slices = result.slices;
        total = result.parentCents;
      case BreakdownFocusCategory(:final label):
        final result = spendingBreakdownFocusedByCategory(
          transactions,
          from: from,
          to: to,
          categories: categories,
          label: label,
          tagColors: tagColors,
        );
        slices = result.slices;
        total = result.parentCents;
    }

    final focused = focus is! BreakdownFocusNone;
    final legendRows = focused ? _focusedLegendRows : _legendRows;
    final legend = slices.take(legendRows);
    // The tail the legend has no room for. It is still drawn in the pie and
    // still names itself on hover, so the line is a pointer at it rather than
    // an Other slice: folding the tail into one wedge would leave the chart
    // with a segment that means nothing to click.
    final tail = slices.skip(legendRows);
    final tailCents = tail.fold<int>(0, (s, x) => s + x.amountCents);

    return _AnalyticsCard(
      icon: PhosphorIconsRegular.chartPieSlice,
      titleWidget: switcher,
      trailing: GlassButton(
        icon: const Icon(PhosphorIconsRegular.folderSimple, size: 16),
        dense: true,
        tooltip: 'Manage categories',
        onPressed: () => _showCategoryManager(context, ref),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: _monthRowHeight,
            child: Row(
              children: [
                Text(
                  DateFormat.yMMMM().format(now),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                // In the month row rather than a line of its own: a line
                // between here and the pie pushed the pie down on every
                // focus and pulled it back up on every clear.
                if (focused)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _BreakdownFilterText(
                          label: _focusLabel(focus),
                          onClear: () => _clearFocus(ref),
                        ),
                      ),
                    ),
                  )
                else
                  const Spacer(),
                SegmentedButton<FinanceBreakdownMode>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: FinanceBreakdownMode.category,
                      label: Text('Category'),
                    ),
                    ButtonSegment(
                      value: FinanceBreakdownMode.tag,
                      label: Text('Tag'),
                    ),
                    ButtonSegment(
                      value: FinanceBreakdownMode.store,
                      label: Text('Store'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (set) {
                    if (set.isEmpty) return;
                    // The focus belongs to the grouping it was taken from — a
                    // category name means nothing to the tag chart — so the
                    // switch drops it rather than carrying over a filter that
                    // would match nothing.
                    _clearFocus(ref);
                    ref
                        .read(financeUiPrefsProvider.notifier)
                        .setBreakdownMode(set.first);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (slices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Text(
                // The unfocused wording would be a lie under a focus: the
                // month may be full of spending, just none of it in here.
                //
                // Prose rather than the HLD's "$0.00 ring": now that a tag
                // focus takes every expense carrying the tag, the only way
                // into an empty bucket is one whose transactions went away
                // under the focus — and an empty ring reading $0.00 says
                // less about that than a sentence does.
                focused
                    ? 'Nothing left in this bucket.'
                    : 'No spending recorded this month.',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else ...[
            SizedBox(
              height: 150,
              child: _BreakdownPie(
                slices: slices,
                total: total,
                // Store slices don't drill down (v1).
                onSliceTap: mode == FinanceBreakdownMode.store
                    ? null
                    : (index) => _focusSlice(ref, focus, mode, slices[index]),
              ),
            ),
            const SizedBox(height: 12),
            for (final slice in legend)
              _BreakdownLegendRow(
                slice: slice,
                total: total,
                onTap: mode == FinanceBreakdownMode.store
                    ? null
                    : () => _focusSlice(ref, focus, mode, slice),
              ),
            if (tail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 18),
                child: Text(
                  '+${tail.length} more  ·  ${formatCents(tailCents)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _focusLabel(BreakdownFocus focus) => switch (focus) {
    BreakdownFocusTag(:final tag) => tag,
    BreakdownFocusCategory(:final label) => label,
    BreakdownFocusNone() => '',
  };

  void _clearFocus(WidgetRef ref) =>
      ref.read(_breakdownFocusProvider.notifier).state =
          const BreakdownFocusNone();

  static const _incomeLegendRows = 6;

  /// This month's deposits split by source — the income-side twin of the
  /// spending breakdown's Store mode, picked from the breakdown card's title
  /// dropdown rather than a fourth segment, so the Category/Tag/Store control
  /// only ever speaks about expenses. No drill-down (v1).
  ///
  /// A method returning the same Column as the spending chart rather than a
  /// widget of its own: a separate widget type would rebuild the pie on every
  /// switch, and the slices would jump instead of morphing like they do
  /// between Category, Tag and Store.
  Widget _incomeSourceChart(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final transactions = settledTransactions(
      ref.watch(transactionsProvider).valueOrNull ?? const [],
      now,
    );

    final slices = originBreakdown(
      transactions,
      from: DateTime(now.year, now.month, 1),
      to: DateTime(now.year, now.month + 1, 1),
      type: TransactionType.deposit,
      colorFor: colorForTag,
    );
    final total = slices.fold<int>(0, (s, x) => s + x.amountCents);
    final legend = slices.take(_incomeLegendRows);
    final tail = slices.skip(_incomeLegendRows);
    final tailCents = tail.fold<int>(0, (s, x) => s + x.amountCents);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: _monthRowHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              DateFormat.yMMMM().format(now),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (slices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              'No income recorded this month.',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else ...[
          SizedBox(
            height: 150,
            child: _BreakdownPie(slices: slices, total: total),
          ),
          const SizedBox(height: 12),
          for (final slice in legend)
            _BreakdownLegendRow(slice: slice, total: total, onTap: null),
          if (tail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 18),
              child: Text(
                '+${tail.length} more  ·  ${formatCents(tailCents)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// Re-roots the chart on the bucket that was clicked.
  void _focusSlice(
    WidgetRef ref,
    BreakdownFocus focus,
    FinanceBreakdownMode mode,
    BreakdownSlice slice,
  ) {
    final notifier = ref.read(_breakdownFocusProvider.notifier);
    // Untagged has no tags to subdivide by, in either grouping, so it always
    // resolves through the category path — which knows to draw it as one
    // solid slice rather than looking for a tag by that name.
    if (slice.label == kUntaggedLabel) {
      notifier.state = const BreakdownFocusCategory(kUntaggedLabel);
      return;
    }
    switch (focus) {
      case BreakdownFocusNone():
        notifier.state = mode == FinanceBreakdownMode.category
            ? BreakdownFocusCategory(slice.label)
            : BreakdownFocusTag(slice.label);
      case BreakdownFocusTag():
        // A co-tag slice: re-root onto it, the same as focusing it from the
        // unfocused tag chart. One level at a time, no breadcrumb.
        notifier.state = BreakdownFocusTag(slice.label);
      case BreakdownFocusCategory():
        // The children of a category are tags, and a tag is a thing the Tag
        // chart knows how to draw — so the click moves the grouping with it
        // rather than leaving the segmented control disagreeing with the pie.
        ref
            .read(financeUiPrefsProvider.notifier)
            .setBreakdownMode(FinanceBreakdownMode.tag);
        notifier.state = BreakdownFocusTag(slice.label);
    }
  }

  Future<void> _showCategoryManager(BuildContext context, WidgetRef ref) async {
    await showVoyagerSheet<void>(
      context: context,
      enableDrag: false,
      builder: (ctx) => ProviderScope(
        parent: ProviderScope.containerOf(context),
        child: const _CategoryManager(),
      ),
    );
  }
}

/// The "you are looking at one bucket" notice, and the way back out of it.
///
/// The whole line is the clear target — no separate ✕. It is the only chrome
/// the focused chart adds, and a filter you can't see how to leave is worse
/// than no filter at all.
class _BreakdownFilterText extends StatelessWidget {
  const _BreakdownFilterText({required this.label, required this.onClear});

  final String label;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onClear,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Text(
            // No leading `#` on a tag, matching the legend below it.
            'Filtering: $label',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: accent),
          ),
        ),
      ),
    );
  }
}

/// One legend row: dot, label, amount, and share of the chart's centre total.
class _BreakdownLegendRow extends StatelessWidget {
  const _BreakdownLegendRow({
    required this.slice,
    required this.total,
    required this.onTap,
  });

  final BreakdownSlice slice;
  final int total;

  /// Null for a chart whose slices don't drill down.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: paletteColor(slice.colorValue, context),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // No leading `#`, on a tag or a category alike. In a legend the
              // marker is doing no work — nothing here is a tag *reference*
              // the way it is in prose — and it made the two groupings of the
              // same chart look like two different kinds of thing.
              slice.label,
              style: theme.textTheme.labelMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            formatCents(slice.amountCents),
            style: theme.textTheme.labelMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 34,
            child: Text(
              // Against the centre total, so every row reads as a share of
              // the bucket named there. Under a category focus these do not
              // add to 100% — a two-tag expense is counted in both rows — but
              // each row on its own is still a true share of the parent.
              total == 0
                  ? '—'
                  : '${((slice.amountCents / total) * 100).round()}%',
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: row,
      ),
    );
  }
}

/// The donut, its running total, and the hover bubble that names whichever
/// slice the pointer is on.
///
/// The total in the middle is the chart's resting state; it stays put while a
/// slice is hovered rather than being swapped out, so the share the bubble
/// quotes can be read against the whole it is a share *of*.
class _BreakdownPie extends StatefulWidget {
  const _BreakdownPie({
    required this.slices,
    required this.total,
    this.onSliceTap,
  });

  final List<BreakdownSlice> slices;
  final int total;

  /// Called with the index of the slice a click landed on.
  final ValueChanged<int>? onSliceTap;

  @override
  State<_BreakdownPie> createState() => _BreakdownPieState();
}

class _BreakdownPieState extends State<_BreakdownPie> {
  static const double _centerRadius = 44;
  static const double _sliceRadius = 18;

  int? _touchedIndex;

  /// A drill-down replaces the slice list under a State that is kept — the
  /// filter line is already on screen, so the children line up and the
  /// element is reused — and an index taken against the old list then points
  /// at the wrong slice, or past the end of the new one.
  @override
  void didUpdateWidget(covariant _BreakdownPie oldWidget) {
    super.didUpdateWidget(oldWidget);
    final touched = _touchedIndex;
    if (touched == null) return;
    if (touched >= widget.slices.length ||
        widget.slices[touched].label != oldWidget.slices[touched].label) {
      _touchedIndex = null;
    }
  }

  void _handleTouch(FlTouchEvent event, PieTouchResponse? response) {
    final index = response?.touchedSection?.touchedSectionIndex;
    final onSlice = index != null && index >= 0 && index < widget.slices.length;

    // A click, not the hover that precedes it: the callback fires for every
    // pointer event the chart sees, and drilling in on hover would make the
    // chart impossible to merely read.
    //
    // Resolved from the raw response rather than from the highlight below,
    // because the two disagree off desktop: fl_chart calls a tap-up
    // "uninteresting" everywhere except desktop and web, so reading the tap
    // out of the highlight left slice clicks doing nothing at all on a phone.
    if (event is FlTapUpEvent && onSlice) {
      widget.onSliceTap?.call(index);
    }

    final resolved = onSlice && event.isInterestedForInteractions ? index : null;
    if (resolved == _touchedIndex) return;
    setState(() => _touchedIndex = resolved);
  }

  /// Midpoint of slice [index]'s arc, relative to the donut's centre.
  ///
  /// fl_chart lays sections out clockwise from three o'clock, so walking the
  /// preceding slices' sweeps and stopping halfway into this one gives the
  /// point on the ring the bubble should sit above.
  Offset _arcMidpoint(int index) {
    final total = widget.slices.fold<int>(0, (s, x) => s + x.amountCents);
    if (total <= 0) return Offset.zero;
    var sweptRadians = 0.0;
    for (var i = 0; i < index; i++) {
      sweptRadians += 2 * math.pi * widget.slices[i].amountCents / total;
    }
    final mid =
        sweptRadians +
        math.pi * widget.slices[index].amountCents / total;
    const radius = _centerRadius + _sliceRadius / 2;
    return Offset(math.cos(mid) * radius, math.sin(mid) * radius);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slices = widget.slices;
    final total = widget.total;
    final touched = _touchedIndex;
    // A bucket that cost nothing still gets a ring: fl_chart draws no sections
    // at all when every value is zero, and an empty square under a "$0.00"
    // reads as a chart that failed rather than as an answer.
    final allZero = !slices.any((s) => s.amountCents > 0);

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        PieChart(
          PieChartData(
            sectionsSpace: 2,
            centerSpaceRadius: _centerRadius,
            pieTouchData: PieTouchData(touchCallback: _handleTouch),
            sections: [
              for (var i = 0; i < slices.length; i++)
                PieChartSectionData(
                  value: allZero ? 1 : slices[i].amountCents.toDouble(),
                  color: paletteColor(slices[i].colorValue, context),
                  // The hovered slice thickens outward a little, so the bubble
                  // and the wedge it describes are tied together without a
                  // second colour or a border to read.
                  radius: i == touched ? _sliceRadius + 4 : _sliceRadius,
                  showTitle: false,
                ),
            ],
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatCents(total),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              'spent',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (touched != null)
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final centre = Offset(
                    constraints.maxWidth / 2,
                    constraints.maxHeight / 2,
                  );
                  final share = total == 0
                      ? 0
                      : ((slices[touched].amountCents / total) * 100).round();
                  return CustomSingleChildLayout(
                    delegate: _ChartBubbleLayout(
                      anchor: centre + _arcMidpoint(touched),
                    ),
                    child: ChartHoverBubble(
                      periodLabel: slices[touched].label,
                      valueLabel:
                          '${formatCents(slices[touched].amountCents)}  ·  $share%',
                      valueColor: paletteColor(
                        slices[touched].colorValue,
                        context,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// Lists existing categories with an entry point to create or edit one.
class _CategoryManager extends ConsumerWidget {
  const _CategoryManager();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final categories =
        ref.watch(financeCategoriesProvider).valueOrNull ?? const [];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Categories', style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(
                onPressed: Navigator.of(context).pop,
                icon: const Icon(PhosphorIconsRegular.x, size: 18),
                tooltip: 'Close',
                padding: EdgeInsets.zero,
                constraints: kMinTouchTarget,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (categories.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'No categories yet. Group related tags — like #mcdonalds and '
                '#burger_king under "Eating out" — to roll them up in the '
                'breakdown.',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final category in categories)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  radius: 8,
                  backgroundColor: paletteColor(category.colorValue, context),
                ),
                title: Text(category.name,
                    style: theme.textTheme.bodyMedium),
                subtitle: Text(
                  category.tags.isEmpty
                      ? 'No tags yet'
                      : category.tags.map((t) => '#$t').join('  '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(
                  PhosphorIconsRegular.pencilSimple,
                  size: 14,
                ),
                onTap: () => showCategoryModal(context, ref,
                    existing: category),
              ),
          const SizedBox(height: 12),
          GlassButton(
            onPressed: () => showCategoryModal(context, ref),
            icon: const Icon(PhosphorIconsRegular.plus, size: 16),
            label: 'New category',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Net worth tracker
// ---------------------------------------------------------------------------

class _NetWorthCard extends ConsumerWidget {
  const _NetWorthCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final transactions = settledTransactions(
      ref.watch(transactionsProvider).valueOrNull ?? const [],
      DateTime.now(),
    );
    final assets = ref.watch(assetsProvider).valueOrNull ?? const [];
    final valuations =
        ref.watch(assetValuationsProvider).valueOrNull ?? const [];
    final rooms = ref.watch(contributionRoomsProvider).valueOrNull ?? const [];
    final roomEvents =
        ref.watch(assetRoomEventsProvider).valueOrNull ?? const [];
    final now = DateTime.now();
    // One summary per room, shared by every asset in it.
    final roomSummaries = {
      for (final room in rooms)
        room.id: roomYearSummary(room, roomEvents, now: now),
    };

    final series = netWorthSeries(
      transactions,
      assets,
      valuations,
      months: 12,
    );
    final current = series.isEmpty ? null : series.last;
    final hasData = transactions.isNotEmpty || assets.isNotEmpty;

    return _AnalyticsCard(
      icon: PhosphorIconsRegular.trendUp,
      title: 'Net Worth',
      trailing: GlassButton(
        icon: const Icon(PhosphorIconsRegular.plus, size: 16),
        dense: true,
        tooltip: 'Add asset',
        onPressed: () => showAssetModal(context, ref),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (current != null) ...[
            Text(
              formatNetCents(current.totalCents),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: current.totalCents >= 0
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${formatNetCents(current.cashCents)} ledger · '
              '${formatNetCents(current.assetCents)} assets',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            height: 110,
            child: !hasData
                ? Center(
                    child: Text(
                      'Log transactions or add an asset to chart your wealth.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : _NetWorthChart(
                    series: series,
                    color: accent,
                    negativeColor: theme.colorScheme.error,
                  ),
          ),
          if (assets.isNotEmpty) ...[
            const SizedBox(height: 12),
            Divider(
              height: 1,
              color: theme.colorScheme.outline.withValues(alpha: 0.12),
            ),
            const SizedBox(height: 8),
            for (final asset in assets)
              _AssetRow(
                asset: asset,
                valuation: latestValuation(valuations, asset.id),
                roomSummary: roomSummaries[asset.contributionRoomId],
                roomMemberCount: asset.contributionRoomId == null
                    ? 0
                    : roomMembers(assets, asset.contributionRoomId!).length,
              ),
          ],
        ],
      ),
    );
  }
}

/// Height reserved below the net-worth curve for its month labels.
const double _kNetWorthBottomReserved = 18;

class _NetWorthChart extends StatefulWidget {
  const _NetWorthChart({
    required this.series,
    required this.color,
    required this.negativeColor,
  });

  final List<NetWorthPoint> series;
  final Color color;
  final Color negativeColor;

  @override
  State<_NetWorthChart> createState() => _NetWorthChartState();
}

class _NetWorthChartState extends State<_NetWorthChart> {
  /// Index into the series the pointer is currently reading, or null.
  int? _touchedIndex;

  void _handleTouch(FlTouchEvent event, LineTouchResponse? response) {
    final hits = response?.lineBarSpots;
    final next = !event.isInterestedForInteractions || hits == null || hits.isEmpty
        ? null
        : hits.first.spotIndex;
    if (next == _touchedIndex) return;
    setState(() => _touchedIndex = next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final series = widget.series;
    final latestNegative =
        series.isNotEmpty && series.last.totalCents < 0;
    final color = latestNegative ? widget.negativeColor : widget.color;
    final spots = [
      for (var i = 0; i < series.length; i++)
        FlSpot(i.toDouble(), series[i].totalCents / 100),
    ];
    final values = spots.map((s) => s.y).toList();
    var minValue = values.reduce((a, b) => a < b ? a : b);
    var maxValue = values.reduce((a, b) => a > b ? a : b);
    // The lowest month the series actually contains, kept before the flat-
    // series nudge below invents a range around it. This is where the hover
    // indicator line stops — see `getTouchLineStart`.
    final floor = minValue;
    if (minValue == maxValue) {
      minValue -= 1;
      maxValue += 1;
    }
    final pad = (maxValue - minValue) * 0.15;
    var minY = minValue - pad;
    var maxY = maxValue + pad;

    // Zero is the wealth floor readers expect. Show it whenever the series
    // touches or dips below it, and stretch the plot so an all-negative
    // series still has room to draw that baseline above the curve.
    final showZeroLine = floor <= 0;
    if (showZeroLine) {
      if (maxY < 0) maxY = 0;
      if (minY > 0) minY = 0;
    }

    final touched =
        _touchedIndex != null && _touchedIndex! >= 0 && _touchedIndex! < series.length
        ? _touchedIndex
        : null;
    final touchedPoint = touched == null ? null : series[touched];
    final touchedNegative =
        touchedPoint != null && touchedPoint.totalCents < 0;

    final chart = LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        lineTouchData: LineTouchData(
          // The bubble below is drawn by this widget, not by fl_chart, so its
          // own tooltip stays off; the indicator line on the touched spot is a
          // separate setting (LineChartBarData.showingIndicators) and stays on.
          handleBuiltInTouches: false,
          // A threshold big enough that the pointer is always inside *some*
          // spot's zone. At the default 10px the reading zones are islands
          // with dead water between them, so drifting between two months —
          // most of the chart's width — showed nothing at all.
          touchSpotThreshold: 10000,
          touchCallback: _handleTouch,
          // The indicator line hangs from the hovered point down to this y.
          // fl_chart's default is the bottom of the *plot*, which sits a
          // 15%-of-range pad below the lowest month in the series — so the
          // lowest point on the curve, the one most likely to be $0, still
          // trailed a stub of line below itself with nothing under it to
          // point at. Ending on the series' own floor makes that stub exactly
          // zero-length while every higher point keeps a line to read down.
          getTouchLineStart: (_, _) => floor,
        ),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            if (showZeroLine)
              HorizontalLine(
                y: 0,
                color: theme.colorScheme.outline.withValues(alpha: 0.35),
                // Same width as the series stroke so a flat-$0 run shares one
                // vertical band with the dotted axis instead of sitting under it.
                strokeWidth: 2,
                dashArray: const [4, 4],
              ),
          ],
        ),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: _kNetWorthBottomReserved,
              interval: 1,
              getTitlesWidget: (value, _) {
                final i = value.toInt();
                if (i < 0 || i >= series.length) {
                  return const SizedBox.shrink();
                }
                final step = (series.length / 4).ceil();
                if (i % step != 0) return const SizedBox.shrink();
                return Text(
                  DateFormat('MMM').format(series[i].date),
                  style: theme.textTheme.labelSmall?.copyWith(fontSize: 9),
                );
              },
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.25,
            // A cubic through the points is free to bulge past them between
            // two of them, which on a series that steps sharply drew the line
            // below the lowest month it contains — a net worth that visibly
            // dips under a floor it never actually reached. This holds the
            // curve inside its own points.
            preventCurveOverShooting: true,
            color: color,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            showingIndicators: touched == null ? const [] : [touched],
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  color.withValues(alpha: 0.22),
                  color.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    // The chart is always the Stack's first child, hovered or not. Returning
    // the bare chart when nothing is touched would move it to a different slot
    // in the tree on every hover, rebuilding its element and restarting the
    // implicit animation it draws itself with — a curve that redraws from
    // scratch each time the pointer arrives.
    return LayoutBuilder(
      builder: (context, constraints) {
        final plotWidth = constraints.maxWidth;
        final plotHeight = math.max(
          0.0,
          constraints.maxHeight - _kNetWorthBottomReserved,
        );
        final spanX = spots.length <= 1 ? 1.0 : (spots.length - 1).toDouble();
        final spanY = maxY - minY;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            chart,
            if (touchedPoint != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomSingleChildLayout(
                    delegate: _ChartBubbleLayout(
                      anchor: Offset(
                        spots[touched!].x / spanX * plotWidth,
                        spanY == 0
                            ? plotHeight
                            : plotHeight *
                                  (1 - (spots[touched].y - minY) / spanY),
                      ),
                    ),
                    child: ChartHoverBubble(
                      periodLabel: DateFormat(
                        'MMMM yyyy',
                      ).format(touchedPoint.date),
                      valueLabel: formatNetCents(touchedPoint.totalCents),
                      valueColor: touchedNegative
                          ? widget.negativeColor
                          : color,
                      detailLabel:
                          '${formatNetCents(touchedPoint.cashCents)} ledger · '
                          '${formatNetCents(touchedPoint.assetCents)} assets',
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Centres a [ChartHoverBubble] on the datapoint it describes, sitting it just
/// above the point.
///
/// A layout delegate rather than arithmetic at the call site because both
/// offsets need the bubble's real size, and the bubble is sized to whatever
/// date and amount it happens to be showing.
///
/// Horizontally the bubble is clamped into the plot. Centred on a point at
/// either end it overhangs by half its width, and the net-worth bubble's
/// ledger/assets line made that wide enough to run past the window edge. The
/// bubble slides off-centre there instead; it still sits directly above the
/// point, just not centred on it.
class _ChartBubbleLayout extends SingleChildLayoutDelegate {
  const _ChartBubbleLayout({required this.anchor});

  /// The datapoint, in the enclosing [Stack]'s coordinates.
  final Offset anchor;

  static const double _gap = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    (anchor.dx - childSize.width / 2).clamp(
      0.0,
      math.max(0.0, size.width - childSize.width),
    ),
    anchor.dy - childSize.height - _gap,
  );

  @override
  bool shouldRelayout(_ChartBubbleLayout oldDelegate) =>
      anchor != oldDelegate.anchor;
}

class _AssetRow extends ConsumerStatefulWidget {
  const _AssetRow({
    required this.asset,
    required this.valuation,
    required this.roomSummary,
    required this.roomMemberCount,
  });

  final Asset asset;
  final AssetValuation? valuation;

  /// The room's figures when the asset is in one, else null.
  final RoomYearSummary? roomSummary;

  /// Live assets in the asset's room, itself included. Transfer needs two.
  final int roomMemberCount;

  @override
  ConsumerState<_AssetRow> createState() => _AssetRowState();
}

class _AssetRowState extends ConsumerState<_AssetRow> {
  final _menuKey = GlobalKey<ContextMenuRegionState>();

  /// Where the last press landed, so a long-press opens the menu under the
  /// finger the way a right-click opens it under the pointer.
  Offset _pressPosition = Offset.zero;

  List<ContextMenuItem> _menuItems() {
    final asset = widget.asset;
    if (asset.contributionRoomId == null || widget.roomSummary == null) {
      return [
        ContextMenuItem(
          label: 'Track contribution room…',
          icon: PhosphorIconsRegular.chartBar,
          onTap: () => showContributionRoomModal(context, ref, asset: asset),
        ),
      ];
    }
    return [
      ContextMenuItem(
        label: 'Contribute…',
        icon: PhosphorIconsRegular.arrowDownLeft,
        onTap: () => showRoomCashEventModal(
          context,
          ref,
          asset: asset,
          kind: RoomEventKind.contribution,
        ),
      ),
      ContextMenuItem(
        label: 'Withdraw…',
        icon: PhosphorIconsRegular.arrowUpRight,
        onTap: () => showRoomCashEventModal(
          context,
          ref,
          asset: asset,
          kind: RoomEventKind.withdrawal,
        ),
      ),
      if (widget.roomMemberCount >= 2)
        ContextMenuItem(
          label: 'Transfer…',
          icon: PhosphorIconsRegular.arrowsLeftRight,
          onTap: () => showRoomTransferModal(context, ref, from: asset),
        ),
      ContextMenuItem(
        label: 'Edit contribution room…',
        icon: PhosphorIconsRegular.pencilSimple,
        onTap: () => showContributionRoomModal(context, ref, asset: asset),
      ),
      ContextMenuItem(
        label: 'Detach from room',
        icon: PhosphorIconsRegular.linkBreak,
        onTap: () => _detach(),
      ),
    ];
  }

  Future<void> _detach() async {
    final repo = ref.read(financeRepositoryProvider);
    // The container outlives this row; `ref` doesn't once the list rebuilds.
    final container = ProviderScope.containerOf(context, listen: false);
    await setAssetContributionRoom(repo, widget.asset.id, null);
    container.invalidate(assetsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final asset = widget.asset;
    final color = paletteColor(asset.colorValue, context);
    final value = widget.valuation?.valueCents;
    final summary = widget.roomSummary;

    return ContextMenuRegion(
      key: _menuKey,
      itemsBuilder: _menuItems,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTapDown: (details) => _pressPosition = details.globalPosition,
        onTap: () => showAssetModal(context, ref, existing: asset),
        onLongPress: () => _menuKey.currentState?.openMenuAt(_pressPosition),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      asset.name,
                      style: theme.textTheme.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    value == null ? 'Not valued' : formatCents(value),
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: value != null && value < 0
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
              if (summary != null)
                Padding(
                  // Under the name, clear of the colour dot.
                  padding: const EdgeInsets.only(left: 16, top: 4),
                  child: ContributionRoomBar(summary: summary, color: color),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
