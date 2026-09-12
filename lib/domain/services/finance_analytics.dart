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
      // Calendar-day arithmetic, not a Duration: a Duration is absolute
      // elapsed time, so subtracting one across a DST transition lands an
      // hour off a wall-clock midnight and the bucket key stops matching the
      // starts built by _stepBack.
      return DateTime(day.year, day.month, day.day - offset);
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
      // See cashFlowPeriodStart: stepping by a Duration drifts an hour across
      // a DST boundary, which would leave these keys unable to match the
      // bucket a transaction hashes to.
      return DateTime(start.year, start.month, start.day - 7 * count);
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

/// The result of drilling into one breakdown bucket.
///
/// [parentCents] is what the focused bucket actually cost — each expense in
/// it counted once. It is carried alongside the children because the two only
/// agree in tag mode: a category's child slices count a multi-tag expense once
/// per tag (see [spendingBreakdownFocusedByCategory]), so their sum can run
/// past the parent. [parentCents] is the number the donut's centre should
/// read.
class BreakdownFocusResult {
  const BreakdownFocusResult({
    required this.parentCents,
    required this.slices,
  });

  final int parentCents;
  final List<BreakdownSlice> slices;
}

/// How the money spent on [tag] this period splits by co-tag.
///
/// The parent bucket is every expense in `[from, to)` **carrying** [tag],
/// wherever it sits in the list — not just the ones it leads. The unfocused
/// tag chart has to file each expense under one tag to keep the pie summing
/// to the month, but a drill-down is a question about one tag, and answering
/// "what did I spend on thai" with only the expenses that happened to list
/// thai first is how a `$30` row clicked in the legend used to open a `$0`
/// bucket.
///
/// Each of those expenses is then attributed to a single child — the first
/// tag on it that isn't [tag], or [tag] itself when it carried no others. So
/// the children still partition the parent, and the focused donut still reads
/// as a true share-of: "of the money spent on food, how much was only food
/// and how much came in carrying thai".
///
/// The centre can therefore read more than the slice that was clicked in the
/// unfocused tag chart: that slice was food-as-primary, this is all of food.
BreakdownFocusResult spendingBreakdownFocusedByTag(
  List<FinancialTransaction> transactions, {
  required DateTime from,
  required DateTime to,
  required String tag,
  required Map<String, int> tagColors,
}) {
  final totals = <String, int>{};
  var parentCents = 0;

  for (final t in transactions) {
    if (t.type != TransactionType.expense) continue;
    if (t.occurredAt.isBefore(from) || !t.occurredAt.isBefore(to)) continue;
    if (!t.tags.contains(tag)) continue;

    parentCents += t.amountCents;
    // `where` rather than `skip(1)`: a transaction tagged `#food #food #thai`
    // would otherwise attribute itself to a second copy of the focused tag.
    final others = t.tags.where((other) => other != tag);
    final label = others.isEmpty ? tag : others.first;
    totals[label] = (totals[label] ?? 0) + t.amountCents;
  }

  return BreakdownFocusResult(
    parentCents: parentCents,
    slices: _sliceList(totals, tagColors),
  );
}

/// Every tag appearing on the expenses filed under the bucket [label] drew.
///
/// [label] is a slice label from the category-grouped chart — a category name,
/// [kUncategorizedLabel], or [kUntaggedLabel] — so the parent bucket is
/// resolved by the same rule [spendingBreakdown] used to put the slice there.
///
/// Children are counted budget-style: a $30 `#food #thai` expense adds $30 to
/// *both* tags. That double-count is the point — it answers "what did I spend
/// on thai this month", which an exclusive split can't — and it is why
/// [BreakdownFocusResult.parentCents] exists. [kUntaggedLabel] has nothing to
/// subdivide, so it comes back as a single slice of the parent total.
BreakdownFocusResult spendingBreakdownFocusedByCategory(
  List<FinancialTransaction> transactions, {
  required DateTime from,
  required DateTime to,
  required List<FinanceCategory> categories,
  required String label,
  required Map<String, int> tagColors,
}) {
  final untagged = label == kUntaggedLabel;
  final uncategorized = label == kUncategorizedLabel;

  final totals = <String, int>{};
  var parentCents = 0;

  for (final t in transactions) {
    if (t.type != TransactionType.expense) continue;
    if (t.occurredAt.isBefore(from) || !t.occurredAt.isBefore(to)) continue;

    if (t.tags.isEmpty) {
      if (!untagged) continue;
    } else if (untagged) {
      continue;
    } else {
      final category = categories
          .cast<FinanceCategory?>()
          .firstWhere((c) => c!.containsTag(t.tags.first), orElse: () => null);
      if (uncategorized) {
        if (category != null) continue;
      } else if (category?.name != label) {
        continue;
      }
    }

    parentCents += t.amountCents;
    for (final tag in t.tags) {
      totals[tag] = (totals[tag] ?? 0) + t.amountCents;
    }
  }

  if (untagged) {
    return BreakdownFocusResult(
      parentCents: parentCents,
      slices: [
        BreakdownSlice(
          label: kUntaggedLabel,
          colorValue: kBreakdownFallbackColor,
          amountCents: parentCents,
        ),
      ],
    );
  }

  return BreakdownFocusResult(
    parentCents: parentCents,
    slices: _sliceList(totals, tagColors),
  );
}

/// Tag totals as colored slices, largest first.
List<BreakdownSlice> _sliceList(
  Map<String, int> totals,
  Map<String, int> tagColors,
) {
  final slices = [
    for (final entry in totals.entries)
      BreakdownSlice(
        label: entry.key,
        colorValue: tagColors[entry.key] ?? kBreakdownFallbackColor,
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

  /// Cumulative ledger balance (deposits − expenses) on or before [date].
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

  // Cumulative cash is a single sweep rather than a full pass per sample:
  // the sample dates ascend, so each one only has to absorb the transactions
  // the previous one didn't.
  final ordered = [...transactions]
    ..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
  var cursor = 0;
  var cash = 0;

  final points = <NetWorthPoint>[];
  for (final date in dates) {
    final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59);

    while (cursor < ordered.length &&
        !ordered[cursor].occurredAt.isAfter(endOfDay)) {
      cash += ordered[cursor].signedCents;
      cursor++;
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
