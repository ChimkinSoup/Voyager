import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';

/// Time bucket for the income-vs-expense dashboard.
enum CashFlowGranularity { weekly, monthly, yearly }

String cashFlowGranularityLabel(CashFlowGranularity g) {
  switch (g) {
    case CashFlowGranularity.weekly:
      return 'Weekly';
    case CashFlowGranularity.monthly:
      return 'Monthly';
    case CashFlowGranularity.yearly:
      return 'Yearly';
  }
}

/// Total money in and out for one bucket of the cash-flow dashboard.
class CashFlowPoint {
  const CashFlowPoint({
    required this.periodStart,
    required this.incomeCents,
    required this.expenseCents,
  });

  final DateTime periodStart;
  final int incomeCents;
  final int expenseCents;

  int get netCents => incomeCents - expenseCents;
}

/// The canonical start of the bucket containing [date] at [granularity].
DateTime cashFlowPeriodStart(
  DateTime date,
  CashFlowGranularity granularity, {
  bool weekStartsMonday = true,
}) {
  final day = DateTime(date.year, date.month, date.day);
  switch (granularity) {
    case CashFlowGranularity.weekly:
      final offset =
          weekStartsMonday ? day.weekday - DateTime.monday : day.weekday % 7;
      return day.subtract(Duration(days: offset));
    case CashFlowGranularity.monthly:
      return DateTime(day.year, day.month, 1);
    case CashFlowGranularity.yearly:
      return DateTime(day.year, 1, 1);
  }
}

/// Steps a bucket start back by [count] periods.
DateTime _stepBack(
  DateTime start,
  CashFlowGranularity granularity,
  int count,
) {
  switch (granularity) {
    case CashFlowGranularity.weekly:
      return start.subtract(Duration(days: 7 * count));
    case CashFlowGranularity.monthly:
      return DateTime(start.year, start.month - count, 1);
    case CashFlowGranularity.yearly:
      return DateTime(start.year - count, 1, 1);
  }
}

/// Income vs. expense totals for the last [periods] buckets, oldest first.
/// Buckets with no activity are still emitted (as zeroes) so the chart keeps a
/// continuous time axis.
List<CashFlowPoint> cashFlowSeries(
  List<FinancialTransaction> transactions, {
  required CashFlowGranularity granularity,
  int periods = 12,
  DateTime? now,
  bool weekStartsMonday = true,
}) {
  final today = now ?? DateTime.now();
  final currentStart = cashFlowPeriodStart(
    today,
    granularity,
    weekStartsMonday: weekStartsMonday,
  );

  final starts = <DateTime>[
    for (var i = periods - 1; i >= 0; i--)
      _stepBack(currentStart, granularity, i),
  ];

  final income = <DateTime, int>{for (final s in starts) s: 0};
  final expense = <DateTime, int>{for (final s in starts) s: 0};
  final earliest = starts.first;

  for (final t in transactions) {
    if (t.occurredAt.isBefore(earliest)) continue;
    final bucket = cashFlowPeriodStart(
      t.occurredAt,
      granularity,
      weekStartsMonday: weekStartsMonday,
    );
    if (!income.containsKey(bucket)) continue;
    if (t.type == TransactionType.deposit) {
      income[bucket] = income[bucket]! + t.amountCents;
    } else {
      expense[bucket] = expense[bucket]! + t.amountCents;
    }
  }

  return [
    for (final s in starts)
      CashFlowPoint(
        periodStart: s,
        incomeCents: income[s]!,
        expenseCents: expense[s]!,
      ),
  ];
}

/// One slice of the spending breakdown.
class BreakdownSlice {
  const BreakdownSlice({
    required this.label,
    required this.colorValue,
    required this.amountCents,
  });

  final String label;
  final int colorValue;
  final int amountCents;
}

/// Label used for expenses that carry no tag at all.
const String kUntaggedLabel = 'Untagged';

/// Label used for tagged expenses whose tags belong to no category.
const String kUncategorizedLabel = 'Uncategorized';

/// Fallback slice color when no tag/category color is known.
const int kBreakdownFallbackColor = 0xFF8A8A8A;

/// Spending breakdown over [from, to), grouped by category or by raw tag.
///
/// Each transaction is attributed to exactly **one** bucket — the category (or
/// tag) of its first tag — so the slices always sum to total expenses and the
/// chart reads as a true share-of-spending. Deposits are excluded.
List<BreakdownSlice> spendingBreakdown(
  List<FinancialTransaction> transactions, {
  required DateTime from,
  required DateTime to,
  required List<FinanceCategory> categories,
  required Map<String, int> tagColors,
  required bool groupByCategory,
}) {
  final totals = <String, int>{};
  final colors = <String, int>{};

  for (final t in transactions) {
    if (t.type != TransactionType.expense) continue;
    if (t.occurredAt.isBefore(from) || !t.occurredAt.isBefore(to)) continue;

    String label;
    int colorValue;

    if (t.tags.isEmpty) {
      label = kUntaggedLabel;
      colorValue = kBreakdownFallbackColor;
    } else {
      final primaryTag = t.tags.first;
      if (groupByCategory) {
        final category = categories
            .cast<FinanceCategory?>()
            .firstWhere((c) => c!.containsTag(primaryTag), orElse: () => null);
        if (category != null) {
          label = category.name;
          colorValue = category.colorValue;
        } else {
          label = kUncategorizedLabel;
          colorValue = kBreakdownFallbackColor;
        }
      } else {
        label = primaryTag;
        colorValue = tagColors[primaryTag] ?? kBreakdownFallbackColor;
      }
    }

    totals[label] = (totals[label] ?? 0) + t.amountCents;
    colors[label] = colorValue;
  }

  final slices = [
    for (final entry in totals.entries)
      BreakdownSlice(
        label: entry.key,
        colorValue: colors[entry.key] ?? kBreakdownFallbackColor,
        amountCents: entry.value,
      ),
  ];
  slices.sort((a, b) => b.amountCents.compareTo(a.amountCents));
  return slices;
}

/// A single point on the net-worth graph.
class NetWorthPoint {
  const NetWorthPoint({
    required this.date,
    required this.cashCents,
    required this.assetCents,
  });

  final DateTime date;

  /// Cumulative net of every ledger transaction on or before [date].
  final int cashCents;

  /// Sum of each asset's most recent valuation on or before [date].
  final int assetCents;

  int get totalCents => cashCents + assetCents;
}

/// Accumulated wealth over the last [months] month-ends (oldest first), as the
/// ledger's cumulative cash plus each asset's latest valuation at that date.
List<NetWorthPoint> netWorthSeries(
  List<FinancialTransaction> transactions,
  List<Asset> assets,
  List<AssetValuation> valuations, {
  int months = 12,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();

  // Sample at each month boundary, ending with today so the last point
  // reflects the present rather than a stale month-end.
  final dates = <DateTime>[
    for (var i = months - 1; i >= 1; i--)
      DateTime(today.year, today.month - i + 1, 1)
          .subtract(const Duration(days: 1)),
    DateTime(today.year, today.month, today.day),
  ];

  // Valuations grouped per asset, newest first, so the lookup below can stop
  // at the first entry that is on or before the sample date.
  final byAsset = <String, List<AssetValuation>>{};
  for (final v in valuations) {
    byAsset.putIfAbsent(v.assetId, () => []).add(v);
  }
  for (final list in byAsset.values) {
    list.sort((a, b) => b.asOf.compareTo(a.asOf));
  }

  final points = <NetWorthPoint>[];
  for (final date in dates) {
    final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59);

    var cash = 0;
    for (final t in transactions) {
      if (t.occurredAt.isAfter(endOfDay)) continue;
      cash += t.signedCents;
    }

    var assetTotal = 0;
    for (final asset in assets) {
      final history = byAsset[asset.id];
      if (history == null) continue;
      for (final v in history) {
        if (!v.asOf.isAfter(endOfDay)) {
          assetTotal += v.valueCents;
          break;
        }
      }
    }

    points.add(
      NetWorthPoint(date: date, cashCents: cash, assetCents: assetTotal),
    );
  }
  return points;
}

/// The most recent valuation for [assetId], or null when never valued.
AssetValuation? latestValuation(
  List<AssetValuation> valuations,
  String assetId, {
  DateTime? asOf,
}) {
  AssetValuation? best;
  for (final v in valuations) {
    if (v.assetId != assetId) continue;
    if (asOf != null && v.asOf.isAfter(asOf)) continue;
    if (best == null || v.asOf.isAfter(best.asOf)) best = v;
  }
  return best;
}
