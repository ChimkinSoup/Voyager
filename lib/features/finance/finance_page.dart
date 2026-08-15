import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/tag_chip.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/features/finance/finance_analytics_view.dart';
import 'package:voyager/features/finance/finance_bill_radar.dart';
import 'package:voyager/features/finance/finance_budget_panel.dart';
import 'package:voyager/features/finance/finance_goals_view.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';

/// Screen width at/above which the dashboard splits into ledger (left 60%) and
/// insights sidebar (right 40%).
const double _kSplitBreakpoint = 880;

/// Which section of the finance page is showing: the day-to-day ledger
/// dashboard, the macro analytics suite, or the savings goals.
enum _FinanceViewMode { ledger, analytics, goals }

final _financeViewModeProvider = StateProvider<_FinanceViewMode>(
  (_) => _FinanceViewMode.ledger,
);

class FinancePage extends ConsumerWidget {
  const FinancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transactionsAsync = ref.watch(transactionsProvider);
    final tagColorsAsync = ref.watch(tagColorsProvider);
    final tagColors = tagColorsAsync.valueOrNull ?? const <String, int>{};

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: GlassButton(
        tooltip: 'Log transaction',
        onPressed: () => showFinanceTransactionModal(context, ref),
        icon: const Icon(PhosphorIconsRegular.plus),
        width: 56,
        height: 56,
        borderRadius: BorderRadius.circular(28),
        elevation: 3,
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

class _FinanceView extends ConsumerStatefulWidget {
  const _FinanceView({required this.transactions, required this.tagColors});

  final List<FinancialTransaction> transactions;
  final Map<String, int> tagColors;

  @override
  ConsumerState<_FinanceView> createState() => _FinanceViewState();
}

/// Everything that affects what a `_TransactionRow` renders. Used to decide
/// whether a cached row widget instance (see `_FinanceViewState._rowFor`)
/// can be reused as-is.
typedef _TxnRowSignature = ({
  TransactionType type,
  int amountCents,
  String? note,
  String tagsKey,
  Map<String, int> tagColors,
});

/// A day-group header in the flattened ledger entry list (see
/// `_FinanceViewState._ledgerEntries`).
class _LedgerDayHeader {
  const _LedgerDayHeader({required this.day, required this.netCents});
  final DateTime day;
  final int netCents;
}

/// Marks the gap after a day group in the flattened ledger entry list.
class _LedgerSpacer {
  const _LedgerSpacer();
}

const _ledgerSpacer = _LedgerSpacer();

class _FinanceViewState extends ConsumerState<_FinanceView> {
  // Reuses the same _TransactionRow widget instance across rebuilds for
  // transactions whose _TxnRowSignature hasn't changed, so Flutter's element
  // reconciliation skips rebuilding them entirely — a single delete/edit
  // invalidates transactionsProvider wholesale (see _TransactionRow's
  // onLongPress below), which would otherwise reconstruct, and thus rebuild,
  // every mounted row, not just the one that changed. Keyed by transaction
  // id; pruned to the ids actually present at the end of every build.
  final _rowWidgetCache = <String, _TransactionRow>{};
  final _rowSignatureCache = <String, _TxnRowSignature>{};

  _TransactionRow _rowFor(
    FinancialTransaction transaction,
    Map<String, int> tagColors,
  ) {
    final signature = (
      type: transaction.type,
      amountCents: transaction.amountCents,
      note: transaction.note,
      // transaction.tags is a fresh List instance on every fetch even when
      // unchanged, and a record's == on a List field is reference identity
      // — comparing it directly would defeat the cache for every tagged
      // row. The separator keeps ["ab"] and ["a", "b"] from colliding.
      tagsKey: transaction.tags.join(String.fromCharCode(0)),
      tagColors: tagColors,
    );
    final cached = _rowWidgetCache[transaction.id];
    if (cached != null && _rowSignatureCache[transaction.id] == signature) {
      return cached;
    }
    final row = _TransactionRow(
      key: ValueKey(transaction.id),
      transaction: transaction,
      tagColors: tagColors,
    );
    _rowWidgetCache[transaction.id] = row;
    _rowSignatureCache[transaction.id] = signature;
    return row;
  }

  /// Flattens the day-grouped ledger into an index a sliver can build
  /// lazily: a header, that day's transactions, then a spacer, newest day
  /// first.
  List<Object> _ledgerEntries(List<FinancialTransaction> transactions) {
    if (transactions.isEmpty) return const [];
    final groups = <DateTime, List<FinancialTransaction>>{};
    for (final t in transactions) {
      final day = DateTime(
        t.occurredAt.year,
        t.occurredAt.month,
        t.occurredAt.day,
      );
      groups.putIfAbsent(day, () => []).add(t);
    }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    final entries = <Object>[];
    for (final day in days) {
      final dayTransactions = groups[day]!;
      final dayNet = dayTransactions.fold<int>(
        0,
        (sum, t) => sum + t.signedCents,
      );
      entries.add(_LedgerDayHeader(day: day, netCents: dayNet));
      entries.addAll(dayTransactions);
      entries.add(_ledgerSpacer);
    }
    return entries;
  }

  Widget _ledgerEntryAt(
    List<Object> entries,
    Map<String, int> tagColors,
    int index,
  ) {
    final entry = entries[index];
    if (entry is _LedgerDayHeader) {
      return _DayHeader(day: entry.day, netCents: entry.netCents);
    }
    if (entry is _LedgerSpacer) {
      return const SizedBox(height: 12);
    }
    return _rowFor(entry as FinancialTransaction, tagColors);
  }

  /// The ledger as a lazily-built sliver, or the empty state as a single
  /// sliver item when there are no transactions.
  Widget _ledgerSliver(
    List<FinancialTransaction> transactions,
    Map<String, int> tagColors,
  ) {
    final entries = _ledgerEntries(transactions);
    if (entries.isEmpty) {
      return const SliverToBoxAdapter(child: _EmptyLedger());
    }
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => _ledgerEntryAt(entries, tagColors, index),
        childCount: entries.length,
        // A transaction added/removed anywhere shifts every entry after it
        // to a new index. Without this, the framework can't match a
        // `_TransactionRow`'s ValueKey back to its old Element when that
        // happens, so it destroys and recreates every shifted row instead of
        // reusing `_rowFor`'s cached widget — same issue as todo's row list.
        findChildIndexCallback: (key) {
          if (key is! ValueKey<String>) return null;
          final id = key.value;
          final index = entries.indexWhere(
            (e) => e is FinancialTransaction && e.id == id,
          );
          return index == -1 ? null : index;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final transactions = widget.transactions;
    final tagColors = widget.tagColors;
    final liveIds = {for (final t in transactions) t.id};
    _rowWidgetCache.removeWhere((id, _) => !liveIds.contains(id));
    _rowSignatureCache.removeWhere((id, _) => !liveIds.contains(id));

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

        final Widget ledgerBody;
        if (wide) {
          ledgerBody = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 6,
                child: KeepAliveCustomScrollView(
                  storageKey: ShellPageStorageKeys.financeLedgerWide,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 12, 96),
                      sliver: _ledgerSliver(transactions, tagColors),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(flex: 4, child: _InsightsSidebar()),
            ],
          );
        } else {
          ledgerBody = KeepAliveCustomScrollView(
            storageKey: ShellPageStorageKeys.financeLedgerNarrow,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(horizontal, 4, horizontal, 0),
                sliver: _ledgerSliver(transactions, tagColors),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 96),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    children: const [
                      BillRadarPanel(),
                      SizedBox(height: 12),
                      BudgetPanel(),
                    ],
                  ),
                ),
              ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Expanded(
              child: VoyagerCrossfadeIndex(
                index: mode.index,
                children: [
                  KeyedSubtree(
                    key: ValueKey(wide ? 'ledger-wide' : 'ledger-narrow'),
                    child: ledgerBody,
                  ),
                  const FinanceAnalyticsView(),
                  const FinanceGoalsView(),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Cumulative net-flow (in cents) for each of the last [days] days, oldest
/// first — the trajectory drawn by the hero sparkline.
List<double> _sparklineSeries(
  List<FinancialTransaction> transactions, {
  required int days,
}) {
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
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
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
            width: 180,
            height: 56,
            child: CustomPaint(
              painter: _SparklinePainter(values: sparkline, color: accent),
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
        colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.0)],
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
//
// Built lazily via _FinanceViewState._ledgerSliver/_ledgerEntries above,
// which flattens the day-grouping this comment used to describe into an
// indexable list a SliverList can build on demand instead of constructing a
// row for every transaction ever logged on every rebuild.
// ---------------------------------------------------------------------------

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
  const _TransactionRow({
    super.key,
    required this.transaction,
    required this.tagColors,
  });

  final FinancialTransaction transaction;
  final Map<String, int> tagColors;

  // Counts how many _TransactionRow builds land in the same frame, to check
  // whether the row cache (see _FinanceViewState._rowFor) is actually
  // holding — mirrors _TaskRowState's counter in todo_page.dart.
  static var _rowBuildsThisFrame = 0;
  static var _rowBuildFlushScheduled = false;

  static void _noteRowBuild() {
    if (!DevFlags.verboseSync) return;
    _rowBuildsThisFrame++;
    if (_rowBuildFlushScheduled) return;
    _rowBuildFlushScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      debugPrint(
        '[jank] _TransactionRow builds this frame: $_rowBuildsThisFrame',
      );
      _rowBuildsThisFrame = 0;
      _rowBuildFlushScheduled = false;
    });
  }

  Future<void> _delete(WidgetRef ref) async {
    await ref
        .read(financeRepositoryProvider)
        .softDeleteTransaction(transaction.id);
    ref.invalidate(transactionsProvider);
  }

  /// Flips an expense to a deposit or back, leaving everything else alone.
  ///
  /// The stored amount is a magnitude and the sign lives in [type] (see
  /// [FinancialTransaction.signedCents]), so this really is a one-field edit —
  /// nothing about the money has to be recomputed.
  Future<void> _convert(WidgetRef ref) async {
    final flipped = transaction.type == TransactionType.expense
        ? TransactionType.deposit
        : TransactionType.expense;
    await ref.read(financeRepositoryProvider).upsertTransaction(
          transaction.copyWith(
            type: flipped,
            updatedAt: utcNow(),
            version: transaction.version + 1,
          ),
        );
    ref.invalidate(transactionsProvider);
  }

  /// Files the same transaction again under today's date.
  ///
  /// Today at the current time, not today at the original's time: the ledger
  /// orders a day's transactions by [FinancialTransaction.occurredAt], so
  /// carrying the old clock time over would drop the copy into the middle of
  /// today's group rather than at the end of it.
  Future<void> _duplicate(WidgetRef ref) async {
    final now = utcNow();
    await ref.read(financeRepositoryProvider).upsertTransaction(
          FinancialTransaction(
            id: newId(),
            createdAt: now,
            updatedAt: now,
            type: transaction.type,
            amountCents: transaction.amountCents,
            occurredAt: DateTime.now(),
            note: transaction.note,
            tags: transaction.tags,
          ),
        );
    ref.invalidate(transactionsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _noteRowBuild();
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final isDeposit = transaction.type == TransactionType.deposit;
    final amountColor = isDeposit ? kIncomeGreen : accent;

    return ContextMenuRegion(
      // Built on right-click rather than eagerly: the ledger rebuilds
      // wholesale whenever a transaction changes, and these entries are only
      // ever looked at by the row actually being clicked.
      itemsBuilder: () => [
        ContextMenuItem(
          label: isDeposit ? 'Convert to expense' : 'Convert to deposit',
          icon: PhosphorIconsRegular.arrowsLeftRight,
          onTap: () => _convert(ref),
        ),
        ContextMenuItem(
          label: 'Duplicate',
          icon: PhosphorIconsRegular.copy,
          onTap: () => _duplicate(ref),
        ),
        ContextMenuItem(
          label: 'Delete',
          icon: PhosphorIconsRegular.trash,
          isDestructive: true,
          onTap: () => _delete(ref),
        ),
      ],
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () =>
            showFinanceTransactionModal(context, ref, existing: transaction),
        onLongPress: () => _delete(ref),
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
                            TagChip(tag: tag, colorValue: tagColors[tag]),
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
      children: const [BillRadarPanel(), SizedBox(height: 12), BudgetPanel()],
    );
  }
}
