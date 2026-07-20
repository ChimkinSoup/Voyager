import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/features/finance/finance_analytics_view.dart';
import 'package:voyager/features/finance/finance_bill_radar.dart';
import 'package:voyager/features/finance/finance_budget_panel.dart';
import 'package:voyager/features/finance/finance_goals_view.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';

/// Screen width at/above which the dashboard splits into ledger (left 60%) and
/// insights sidebar (right 40%).
const double _kSplitBreakpoint = 880;

/// Which section of the finance page is showing: the day-to-day ledger
/// dashboard, the macro analytics suite, or the savings goals.
enum _FinanceViewMode { ledger, analytics, goals }

final _financeViewModeProvider =
    StateProvider<_FinanceViewMode>((_) => _FinanceViewMode.ledger);

class FinancePage extends ConsumerWidget {
  const FinancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transactionsAsync = ref.watch(transactionsProvider);
    final tagColorsAsync = ref.watch(tagColorsProvider);
    final tagColors = tagColorsAsync.valueOrNull ?? const <String, int>{};

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Log transaction',
        onPressed: () => showFinanceTransactionModal(context, ref),
        child: const Icon(PhosphorIconsRegular.plus),
      ),
      body: transactionsAsync.when(
        data: (transactions) =>
            _FinanceView(transactions: transactions, tagColors: tagColors),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      ),
    );
  }
}

class _FinanceView extends ConsumerWidget {
  const _FinanceView({required this.transactions, required this.tagColors});

  final List<FinancialTransaction> transactions;
  final Map<String, int> tagColors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(_financeViewModeProvider);
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);
    final nextMonth = DateTime(now.year, now.month + 1, 1);
    final monthNet = transactions
        .where(
          (t) =>
              !t.occurredAt.isBefore(monthStart) &&
              t.occurredAt.isBefore(nextMonth),
        )
        .fold<int>(0, (sum, t) => sum + t.signedCents);

    final spark = _sparklineSeries(transactions, days: 30);

    final hero = _HeroSection(
      monthNet: monthNet,
      monthLabel: DateFormat.MMMM().format(now),
      sparkline: spark,
    );

    final ledger = _LedgerFeed(
      transactions: transactions,
      tagColors: tagColors,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _kSplitBreakpoint;
        final horizontal = wide ? 20.0 : 16.0;

        final header = Padding(
          padding: EdgeInsets.fromLTRB(horizontal, 20, horizontal, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              hero,
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<_FinanceViewMode>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: _FinanceViewMode.ledger,
                      icon: Icon(PhosphorIconsRegular.receipt, size: 15),
                      label: Text('Ledger'),
                    ),
                    ButtonSegment(
                      value: _FinanceViewMode.analytics,
                      icon: Icon(PhosphorIconsRegular.chartLine, size: 15),
                      label: Text('Analytics'),
                    ),
                    ButtonSegment(
                      value: _FinanceViewMode.goals,
                      icon: Icon(PhosphorIconsRegular.flag, size: 15),
                      label: Text('Goals'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (set) {
                    if (set.isNotEmpty) {
                      ref.read(_financeViewModeProvider.notifier).state =
                          set.first;
                    }
                  },
                ),
              ),
            ],
          ),
        );

        final Widget body;
        if (mode == _FinanceViewMode.analytics) {
          body = const FinanceAnalyticsView();
        } else if (mode == _FinanceViewMode.goals) {
          body = const FinanceGoalsView();
        } else if (wide) {
          body = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 6, child: ledger),
              const SizedBox(width: 8),
              const Expanded(flex: 4, child: _InsightsSidebar()),
            ],
          );
        } else {
          body = ListView(
            padding: EdgeInsets.fromLTRB(horizontal, 4, horizontal, 96),
            children: [
              ..._LedgerFeed.buildDayGroups(context, transactions, tagColors),
              const SizedBox(height: 24),
              const _InsightsSidebar(),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header, Expanded(child: body)],
        );
      },
    );
  }
}

/// Cumulative net-flow (in cents) for each of the last [days] days, oldest
/// first — the trajectory drawn by the hero sparkline.
List<double> _sparklineSeries(
  List<FinancialTransaction> transactions,
  {required int days}
) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final start = today.subtract(Duration(days: days - 1));

  final perDay = List<int>.filled(days, 0);
  for (final t in transactions) {
    final d = DateTime(t.occurredAt.year, t.occurredAt.month, t.occurredAt.day);
    if (d.isBefore(start) || d.isAfter(today)) continue;
    final index = d.difference(start).inDays;
    perDay[index] += t.signedCents;
  }

  final cumulative = <double>[];
  var running = 0;
  for (final value in perDay) {
    running += value;
    cumulative.add(running.toDouble());
  }
  return cumulative;
}

// ---------------------------------------------------------------------------
// Hero section — Net Flow + minimalist trajectory sparkline
// ---------------------------------------------------------------------------

class _HeroSection extends StatelessWidget {
  const _HeroSection({
    required this.monthNet,
    required this.monthLabel,
    required this.sparkline,
  });

  final int monthNet;
  final String monthLabel;
  final List<double> sparkline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final positive = monthNet >= 0;
    final valueColor = positive ? kIncomeGreen : accent;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Net flow · $monthLabel',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    formatCents(monthNet, signed: true),
                    style: theme.textTheme.displaySmall?.copyWith(
                      color: valueColor,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 120,
            height: 56,
            child: CustomPaint(
              painter: _SparklinePainter(
                values: sparkline,
                color: accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws a smooth curve through [values] with no axes or gridlines — just the
/// line and a soft gradient fill beneath it.
class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    var minV = values.first;
    var maxV = values.first;
    for (final v in values) {
      minV = math.min(minV, v);
      maxV = math.max(maxV, v);
    }
    final range = (maxV - minV).abs() < 1e-9 ? 1.0 : (maxV - minV);

    final dx = size.width / (values.length - 1);
    Offset pointAt(int i) {
      final x = dx * i;
      final norm = (values[i] - minV) / range;
      // Leave a little vertical breathing room top and bottom.
      final y = size.height - (norm * (size.height - 6)) - 3;
      return Offset(x, y);
    }

    final points = [for (var i = 0; i < values.length; i++) pointAt(i)];

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      path.cubicTo(midX, p0.dy, midX, p1.dy, p1.dx, p1.dy);
    }

    // Gradient fill beneath the curve.
    final fillPath = Path.from(path)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.22),
          color.withValues(alpha: 0.0),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}

// ---------------------------------------------------------------------------
// Ledger feed — reverse-chronological transactions grouped by day
// ---------------------------------------------------------------------------

class _LedgerFeed extends StatelessWidget {
  const _LedgerFeed({required this.transactions, required this.tagColors});

  final List<FinancialTransaction> transactions;
  final Map<String, int> tagColors;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 12, 96),
      children: buildDayGroups(context, transactions, tagColors),
    );
  }

  /// Builds the day-grouped ledger as a flat widget list, shared by the split
  /// (sidebar) and stacked (single-column) layouts.
  static List<Widget> buildDayGroups(
    BuildContext context,
    List<FinancialTransaction> transactions,
    Map<String, int> tagColors,
  ) {
    if (transactions.isEmpty) {
      return const [_EmptyLedger()];
    }

    // Group by local calendar day, preserving the newest-first order.
    final groups = <DateTime, List<FinancialTransaction>>{};
    for (final t in transactions) {
      final day =
          DateTime(t.occurredAt.year, t.occurredAt.month, t.occurredAt.day);
      groups.putIfAbsent(day, () => []).add(t);
    }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    final widgets = <Widget>[];
    for (final day in days) {
      final dayTransactions = groups[day]!;
      final dayNet =
          dayTransactions.fold<int>(0, (sum, t) => sum + t.signedCents);
      widgets.add(_DayHeader(day: day, netCents: dayNet));
      for (final t in dayTransactions) {
        widgets.add(_TransactionRow(transaction: t, tagColors: tagColors));
      }
      widgets.add(const SizedBox(height: 12));
    }
    return widgets;
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.netCents});

  final DateTime day;
  final int netCents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Row(
        children: [
          Text(
            _label(day),
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.4,
            ),
          ),
          const Spacer(),
          Text(
            formatCents(netCents, signed: true),
            style: theme.textTheme.labelMedium?.copyWith(
              color: netCents >= 0
                  ? kIncomeGreen
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _label(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return 'TODAY';
    if (day == today.subtract(const Duration(days: 1))) return 'YESTERDAY';
    return DateFormat('EEEE, MMM d').format(day).toUpperCase();
  }
}

class _TransactionRow extends ConsumerWidget {
  const _TransactionRow({required this.transaction, required this.tagColors});

  final FinancialTransaction transaction;
  final Map<String, int> tagColors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final isDeposit = transaction.type == TransactionType.deposit;
    final amountColor = isDeposit ? kIncomeGreen : accent;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showFinanceTransactionModal(context, ref, existing: transaction),
      onLongPress: () async {
        await ref
            .read(financeRepositoryProvider)
            .softDeleteTransaction(transaction.id);
        ref.invalidate(transactionsProvider);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: amountColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isDeposit
                    ? PhosphorIconsRegular.arrowDownLeft
                    : PhosphorIconsRegular.arrowUpRight,
                size: 16,
                color: amountColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    transaction.note ?? (isDeposit ? 'Deposit' : 'Expense'),
                    style: theme.textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (transaction.tags.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final tag in transaction.tags)
                          _TagChip(tag: tag, colorValue: tagColors[tag]),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              formatCents(transaction.signedCents, signed: true),
              style: theme.textTheme.titleSmall?.copyWith(
                color: amountColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag, this.colorValue});

  final String tag;
  final int? colorValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = colorValue != null
        ? Color(colorValue!)
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '#$tag',
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _EmptyLedger extends StatelessWidget {
  const _EmptyLedger();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIconsRegular.receipt,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            'No transactions yet.\nTap + to log your first one.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Insights sidebar — placeholder panels for later phases
// ---------------------------------------------------------------------------

class _InsightsSidebar extends StatelessWidget {
  const _InsightsSidebar();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 20, 96),
      children: const [
        BillRadarPanel(),
        SizedBox(height: 12),
        BudgetPanel(),
      ],
    );
  }
}

