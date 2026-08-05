import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
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

/// How many buckets the cash-flow dashboard shows per granularity.
int _periodsFor(CashFlowGranularity g) =>
    g == CashFlowGranularity.yearly ? 5 : 12;

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
      periods: _periodsFor(granularity),
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
                : BarChart(
                    BarChartData(
                      maxY: maxY,
                      alignment: BarChartAlignment.spaceAround,
                      barTouchData: BarTouchData(
                        touchTooltipData: BarTouchTooltipData(
                          getTooltipColor: (_) =>
                              theme.colorScheme.surfaceContainerHighest,
                          getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                              BarTooltipItem(
                            _compactMoney(rod.toY),
                            TextStyle(
                              color: rod.color,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (_) => FlLine(
                          color:
                              theme.colorScheme.outline.withValues(alpha: 0.10),
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
                            reservedSize: 42,
                            getTitlesWidget: (value, _) => Text(
                              _compactMoney(value),
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(fontSize: 9),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
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
                                  _periodLabel(
                                    series[i].periodStart,
                                    granularity,
                                  ),
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(fontSize: 9),
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
                            barsSpace: 2,
                            barRods: [
                              BarChartRodData(
                                toY: series[i].incomeCents / 100,
                                color: kIncomeGreen,
                                width: 5,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(2),
                                ),
                              ),
                              BarChartRodData(
                                toY: series[i].expenseCents / 100,
                                color: accent,
                                width: 5,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(2),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  String _periodLabel(DateTime start, CashFlowGranularity granularity) {
    switch (granularity) {
      case CashFlowGranularity.weekly:
        return DateFormat('MMM d').format(start);
      case CashFlowGranularity.monthly:
        return DateFormat('MMM').format(start);
      case CashFlowGranularity.yearly:
        return DateFormat('yyyy').format(start);
    }
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
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 44,
                      sections: [
                        for (final slice in slices)
                          PieChartSectionData(
                            value: slice.amountCents.toDouble(),
                            color: Color(slice.colorValue),
                            radius: 18,
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
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'spent',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
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
                        groupByCategory ? slice.label : '#${slice.label}',
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
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ProviderScope(
        parent: ProviderScope.containerOf(context),
        child: const _CategoryManager(),
      ),
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

class _NetWorthChart extends StatelessWidget {
  const _NetWorthChart({required this.series, required this.color});

  final List<NetWorthPoint> series;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spots = [
      for (var i = 0; i < series.length; i++)
        FlSpot(i.toDouble(), series[i].totalCents / 100),
    ];
    final values = spots.map((s) => s.y).toList();
    var minY = values.reduce((a, b) => a < b ? a : b);
    var maxY = values.reduce((a, b) => a > b ? a : b);
    if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }
    final pad = (maxY - minY) * 0.15;

    return LineChart(
      LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => theme.colorScheme.surfaceContainerHighest,
            getTooltipItems: (touched) => touched
                .map(
                  (spot) => LineTooltipItem(
                    _compactMoney(spot.y),
                    TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
                .toList(),
          ),
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
              reservedSize: 18,
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
            color: color,
            barWidth: 2,
            dotData: const FlDotData(show: false),
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
  }
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
