import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/chart_hover_bubble.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/features/finance/finance_asset_modal.dart';
import 'package:voyager/features/finance/finance_category_modal.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart'
    show kIncomeGreen;

final _granularityProvider = StateProvider<CashFlowGranularity>(
  (_) => CashFlowGranularity.monthly,
);

/// True when the spending breakdown rolls tags up into categories.
final _groupByCategoryProvider = StateProvider<bool>((_) => true);

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
        final wide = constraints.maxWidth >= 880;
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
    required this.title,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;
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
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
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
    final granularity = ref.watch(_granularityProvider);
    final transactions =
        ref.watch(transactionsProvider).valueOrNull ?? const [];
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
            ref.read(_granularityProvider.notifier).state = set.first;
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
    if (next == _touched) return;
    setState(() => _touched = next);
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
                    // Thin out labels so they never collide.
                    final step = (series.length / 6).ceil();
                    if (i % step != 0) return const SizedBox.shrink();
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final groupByCategory = ref.watch(_groupByCategoryProvider);
    final transactions =
        ref.watch(transactionsProvider).valueOrNull ?? const [];
    final categories =
        ref.watch(financeCategoriesProvider).valueOrNull ?? const [];
    final tagColors = ref.watch(tagColorsProvider).valueOrNull ?? const {};

    final now = DateTime.now();
    final from = DateTime(now.year, now.month, 1);
    final to = DateTime(now.year, now.month + 1, 1);

    final slices = spendingBreakdown(
      transactions,
      from: from,
      to: to,
      categories: categories,
      tagColors: tagColors,
      groupByCategory: groupByCategory,
    );
    final total = slices.fold<int>(0, (s, x) => s + x.amountCents);

    return _AnalyticsCard(
      icon: PhosphorIconsRegular.chartPieSlice,
      title: 'Spending Breakdown',
      trailing: GlassButton(
        icon: const Icon(PhosphorIconsRegular.folderSimple, size: 16),
        dense: true,
        tooltip: 'Manage categories',
        onPressed: () => _showCategoryManager(context, ref),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                DateFormat.yMMMM().format(now),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 11),
                ),
                segments: const [
                  ButtonSegment(value: true, label: Text('Category')),
                  ButtonSegment(value: false, label: Text('Tag')),
                ],
                selected: {groupByCategory},
                onSelectionChanged: (set) {
                  if (set.isNotEmpty) {
                    ref.read(_groupByCategoryProvider.notifier).state =
                        set.first;
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (slices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Text(
                'No spending recorded this month.',
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
            for (final slice in slices.take(6))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Color(slice.colorValue),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        // No leading `#`, on a tag or a category alike. In a
                        // legend the marker is doing no work — nothing here is
                        // a tag *reference* the way it is in prose — and it
                        // made the two groupings of the same chart look like
                        // two different kinds of thing.
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
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _showCategoryManager(BuildContext context, WidgetRef ref) async {
    await showVoyagerSheet<void>(
      context: context,
      builder: (ctx) => ProviderScope(
        parent: ProviderScope.containerOf(context),
        child: const _CategoryManager(),
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
  const _BreakdownPie({required this.slices, required this.total});

  final List<BreakdownSlice> slices;
  final int total;

  @override
  State<_BreakdownPie> createState() => _BreakdownPieState();
}

class _BreakdownPieState extends State<_BreakdownPie> {
  static const double _centerRadius = 44;
  static const double _sliceRadius = 18;

  int? _touchedIndex;

  void _handleTouch(FlTouchEvent event, PieTouchResponse? response) {
    final section = response?.touchedSection;
    final next = !event.isInterestedForInteractions || section == null
        ? null
        : section.touchedSectionIndex;
    final resolved =
        next != null && next >= 0 && next < widget.slices.length ? next : null;
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
                  value: slices[i].amountCents.toDouble(),
                  color: Color(slices[i].colorValue),
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
                      valueColor: Color(slices[touched].colorValue),
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
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color:
                    theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
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
                  backgroundColor: Color(category.colorValue),
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
    final transactions =
        ref.watch(transactionsProvider).valueOrNull ?? const [];
    final assets = ref.watch(assetsProvider).valueOrNull ?? const [];
    final valuations =
        ref.watch(assetValuationsProvider).valueOrNull ?? const [];

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
              formatCents(current.totalCents),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: current.totalCents >= 0
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${formatCents(current.cashCents)} cash · '
              '${formatCents(current.assetCents)} assets',
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
                : _NetWorthChart(series: series, color: accent),
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
  const _NetWorthChart({required this.series, required this.color});

  final List<NetWorthPoint> series;
  final Color color;

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
    final color = widget.color;
    final spots = [
      for (var i = 0; i < series.length; i++)
        FlSpot(i.toDouble(), series[i].totalCents / 100),
    ];
    final values = spots.map((s) => s.y).toList();
    var minValue = values.reduce((a, b) => a < b ? a : b);
    var maxValue = values.reduce((a, b) => a > b ? a : b);
    if (minValue == maxValue) {
      minValue -= 1;
      maxValue += 1;
    }
    final pad = (maxValue - minValue) * 0.15;
    final minY = minValue - pad;
    final maxY = maxValue + pad;

    final touched =
        _touchedIndex != null && _touchedIndex! >= 0 && _touchedIndex! < series.length
        ? _touchedIndex
        : null;

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
            if (touched != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomSingleChildLayout(
                    delegate: _ChartBubbleLayout(
                      anchor: Offset(
                        spots[touched].x / spanX * plotWidth,
                        spanY == 0
                            ? plotHeight
                            : plotHeight *
                                  (1 - (spots[touched].y - minY) / spanY),
                      ),
                    ),
                    child: ChartHoverBubble(
                      periodLabel: DateFormat(
                        'MMMM yyyy',
                      ).format(series[touched].date),
                      valueLabel: formatCents(series[touched].totalCents),
                      valueColor: color,
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
/// Nothing clamps the result into the plot: a bubble centred near either end
/// overhangs the edge by up to half its width, and staying glued to the point
/// is worth that — clamping makes the bubble drift off the point exactly where
/// the series ends.
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
    anchor.dx - childSize.width / 2,
    anchor.dy - childSize.height - _gap,
  );

  @override
  bool shouldRelayout(_ChartBubbleLayout oldDelegate) =>
      anchor != oldDelegate.anchor;
}

class _AssetRow extends ConsumerWidget {
  const _AssetRow({required this.asset, required this.valuation});

  final Asset asset;
  final AssetValuation? valuation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = Color(asset.colorValue);
    final value = valuation?.valueCents;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showAssetModal(context, ref, existing: asset),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
      ),
    );
  }
}
