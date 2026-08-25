import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

/// A single ledger entry — an expense or a deposit.
///
/// Money is stored as an integer number of cents ([amountCents]) to avoid
/// floating-point rounding drift; [amountCents] is always non-negative and the
/// flow direction is carried by [type]. Use [signedCents] when you need the
/// value with its sign applied (negative for expenses).
class FinancialTransaction extends SoftDeletable {
  const FinancialTransaction({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.type,
    required this.amountCents,
    required this.occurredAt,
    this.note,
    this.tags = const [],
  });

  final TransactionType type;

  /// Absolute magnitude of the transaction in cents (always >= 0).
  final int amountCents;

  /// When the transaction took place (local wall-clock, matching the tracker
  /// convention of storing the naive local instant rather than UTC). The
  /// ledger groups transactions by this value's calendar day.
  final DateTime occurredAt;

  /// Optional free-text note (e.g. "Dinner with friends").
  final String? note;

  /// Tag names (without a leading `#`). Reuses the shared tag-color table.
  final List<String> tags;

  /// The value with its sign applied: negative for expenses, positive for
  /// deposits.
  int get signedCents =>
      type == TransactionType.expense ? -amountCents : amountCents;

  FinancialTransaction copyWith({
    TransactionType? type,
    int? amountCents,
    DateTime? occurredAt,
    String? note,
    List<String>? tags,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
  }) {
    return FinancialTransaction(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: deletedAt ?? this.deletedAt,
      type: type ?? this.type,
      amountCents: amountCents ?? this.amountCents,
      occurredAt: occurredAt ?? this.occurredAt,
      note: note ?? this.note,
      tags: tags ?? this.tags,
    );
  }
}

/// A recurring subscription or bill in the Bill Radar.
///
/// [anchorDueDate] records one known due date; the actual upcoming due date is
/// derived on demand by rolling it forward by [period] (see [nextDueDate]), so
/// the radar always surfaces the next occurrence without needing a background
/// job to advance a stored value.
class Subscription extends SoftDeletable {
  const Subscription({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    required this.amountCents,
    required this.period,
    required this.anchorDueDate,
    this.colorValue = 0xFF7C9EFF,
    this.note,
  });

  final String name;
  final int amountCents;
  final BillingPeriod period;
  final DateTime anchorDueDate;
  final int colorValue;
  final String? note;

  /// Total cost across a full year at this cadence.
  int get annualCents => annualCentsFor(amountCents, period);

  /// The next due date on or after [from] (defaults to now).
  DateTime nextDue([DateTime? from]) =>
      nextDueDate(anchorDueDate, period, from ?? DateTime.now());

  /// Whole days from [from]'s calendar day until the next due date. 0 = due
  /// today, negative should never occur (the next due date is always >= today).
  int daysUntilDue([DateTime? from]) {
    final base = from ?? DateTime.now();
    final due = nextDue(base);
    // Counted in UTC so the subtraction is offset-free: differencing two local
    // wall-clock midnights across a DST transition yields 23h or 25h for a
    // nominal day, which truncates a bill due tomorrow to "Due today".
    return DateTime.utc(due.year, due.month, due.day)
        .difference(DateTime.utc(base.year, base.month, base.day))
        .inDays;
  }

  Subscription copyWith({
    String? name,
    int? amountCents,
    BillingPeriod? period,
    DateTime? anchorDueDate,
    int? colorValue,
    String? note,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
  }) {
    return Subscription(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      amountCents: amountCents ?? this.amountCents,
      period: period ?? this.period,
      anchorDueDate: anchorDueDate ?? this.anchorDueDate,
      colorValue: colorValue ?? this.colorValue,
      note: note ?? this.note,
    );
  }
}

/// Number of billing cycles [period] completes in a year.
int billingPeriodsPerYear(BillingPeriod period) {
  switch (period) {
    case BillingPeriod.weekly:
      return 52;
    case BillingPeriod.biweekly:
      return 26;
    case BillingPeriod.monthly:
      return 12;
    case BillingPeriod.quarterly:
      return 4;
    case BillingPeriod.yearly:
      return 1;
  }
}

/// Annualized cost of paying [amountCents] every [period].
int annualCentsFor(int amountCents, BillingPeriod period) =>
    amountCents * billingPeriodsPerYear(period);

/// Human label for a billing cadence (e.g. "Monthly").
String billingPeriodLabel(BillingPeriod period) {
  switch (period) {
    case BillingPeriod.weekly:
      return 'Weekly';
    case BillingPeriod.biweekly:
      return 'Every 2 weeks';
    case BillingPeriod.monthly:
      return 'Monthly';
    case BillingPeriod.quarterly:
      return 'Quarterly';
    case BillingPeriod.yearly:
      return 'Yearly';
  }
}

/// The first due date on or after [from]'s calendar day, rolling [anchor]
/// forward by [period]. Month-based cadences advance from the original anchor
/// (clamping the day to each target month's length) so a due-on-the-31st bill
/// doesn't drift earlier over time.
DateTime nextDueDate(DateTime anchor, BillingPeriod period, DateTime from) {
  final today = DateTime(from.year, from.month, from.day);
  final start = DateTime(anchor.year, anchor.month, anchor.day);
  if (!start.isBefore(today)) return start;

  switch (period) {
    case BillingPeriod.weekly:
    case BillingPeriod.biweekly:
      final step = period == BillingPeriod.weekly ? 7 : 14;
      // Both halves stay on the calendar rather than on absolute elapsed
      // time. Across a DST transition two local midnights are 23h apart, so
      // differencing them locally counts a day short — enough to land the
      // "next" due date in the past — and adding a Duration to a wall-clock
      // midnight lands at 23:00 the day before.
      final elapsed = DateTime.utc(today.year, today.month, today.day)
          .difference(DateTime.utc(start.year, start.month, start.day))
          .inDays;
      final cycles = (elapsed / step).ceil();
      return DateTime(start.year, start.month, start.day + cycles * step);
    case BillingPeriod.monthly:
    case BillingPeriod.quarterly:
    case BillingPeriod.yearly:
      final stepMonths = period == BillingPeriod.monthly
          ? 1
          : period == BillingPeriod.quarterly
              ? 3
              : 12;
      var cycles = 0;
      DateTime due;
      do {
        cycles++;
        due = _addMonths(start, stepMonths * cycles);
      } while (due.isBefore(today));
      return due;
  }
}

DateTime _addMonths(DateTime date, int months) {
  final zeroBased = date.month - 1 + months;
  final year = date.year + (zeroBased ~/ 12);
  final month = (zeroBased % 12) + 1;
  final day = math.min(date.day, daysInMonth(year, month));
  return DateTime(year, month, day);
}

/// Number of days in the given calendar month.
int daysInMonth(int year, int month) {
  final firstOfNext = month == 12
      ? DateTime(year + 1, 1, 1)
      : DateTime(year, month + 1, 1);
  return firstOfNext.subtract(const Duration(days: 1)).day;
}

/// A soft monthly spending limit on a single tag (e.g. "keep #dining_out under
/// $200 this month"). Budgets reset with each calendar month — the limit is
/// compared against that month's tagged expenses only.
class Budget extends SoftDeletable {
  const Budget({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.tag,
    required this.limitCents,
  });

  /// Tag name without a leading `#`.
  final String tag;
  final int limitCents;

  Budget copyWith({
    String? tag,
    int? limitCents,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
  }) {
    return Budget(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: deletedAt ?? this.deletedAt,
      tag: tag ?? this.tag,
      limitCents: limitCents ?? this.limitCents,
    );
  }
}

/// How a budget's spending compares to where it "should" be this far into the
/// month.
enum BudgetStatus {
  /// Spending is at or behind the month's elapsed pace.
  onTrack,

  /// Still under the limit, but spending faster than the month is elapsing.
  aheadOfPace,

  /// The limit has been exceeded.
  overBudget,
}

/// Total expense cents tagged [tag] within the calendar month containing
/// [month]. Deposits never count toward a budget, and a transaction carrying
/// several tags counts in full toward each of their budgets.
int budgetSpentCents(
  List<FinancialTransaction> transactions,
  String tag,
  DateTime month,
) {
  final start = DateTime(month.year, month.month, 1);
  final next = DateTime(month.year, month.month + 1, 1);
  var total = 0;
  for (final t in transactions) {
    if (t.type != TransactionType.expense) continue;
    if (t.occurredAt.isBefore(start) || !t.occurredAt.isBefore(next)) continue;
    if (!t.tags.contains(tag)) continue;
    total += t.amountCents;
  }
  return total;
}

/// Fraction of the current month elapsed (0..1], the reference a budget's
/// spending is paced against. On the 15th of a 30-day month this is 0.5, so
/// having spent half the limit reads as exactly on track.
double monthPaceFraction(DateTime now) {
  final total = daysInMonth(now.year, now.month);
  return (now.day / total).clamp(0.0, 1.0);
}

/// Classifies [spentCents] against [limitCents] at the month's [pace].
BudgetStatus budgetStatus({
  required int spentCents,
  required int limitCents,
  required double pace,
}) {
  if (limitCents <= 0) return BudgetStatus.onTrack;
  if (spentCents > limitCents) return BudgetStatus.overBudget;
  return (spentCents / limitCents) > pace
      ? BudgetStatus.aheadOfPace
      : BudgetStatus.onTrack;
}

/// A user-defined grouping of tags (e.g. an "Eating out" category covering
/// `#mcdonalds` and `#burger_king`), used to roll spending up in the macro
/// analytics breakdown.
class FinanceCategory extends SoftDeletable {
  const FinanceCategory({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.colorValue = 0xFF7C9EFF,
    this.tags = const [],
  });

  final String name;
  final int colorValue;

  /// Tag names (without a leading `#`) rolled up under this category.
  final List<String> tags;

  bool containsTag(String tag) =>
      tags.any((t) => t.toLowerCase() == tag.toLowerCase());

  FinanceCategory copyWith({
    String? name,
    int? colorValue,
    List<String>? tags,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
  }) {
    return FinanceCategory(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      tags: tags ?? this.tags,
    );
  }
}

/// Something the user owns (or owes) that contributes to net worth beyond the
/// cash implied by their ledger — investments, property, vehicles, or a debt
/// recorded as a negative valuation.
class Asset extends SoftDeletable {
  const Asset({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.colorValue = 0xFF7C9EFF,
    this.note,
  });

  final String name;
  final int colorValue;
  final String? note;

  Asset copyWith({
    String? name,
    int? colorValue,
    String? note,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
  }) {
    return Asset(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      note: note ?? this.note,
    );
  }
}

/// A point-in-time valuation of an [Asset]. Assets are re-valued by appending
/// a new valuation rather than overwriting, so net worth can be reconstructed
/// for any past date. [valueCents] may be negative to represent a liability.
class AssetValuation extends SoftDeletable {
  const AssetValuation({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.assetId,
    required this.valueCents,
    required this.asOf,
  });

  final String assetId;
  final int valueCents;
  final DateTime asOf;

  AssetValuation copyWith({
    int? valueCents,
    DateTime? asOf,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
  }) {
    return AssetValuation(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: deletedAt ?? this.deletedAt,
      assetId: assetId,
      valueCents: valueCents ?? this.valueCents,
      asOf: asOf ?? this.asOf,
    );
  }
}

/// A savings bucket the user is working toward (e.g. "Japan trip") with a
/// target amount. Progress comes from [GoalAllocation]s rather than a stored
/// running total, so contributions keep their own history.
class SavingsGoal extends SoftDeletable {
  const SavingsGoal({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    required this.targetCents,
    this.colorValue = 0xFF7C9EFF,
    this.note,
    this.targetDate,
  });

  final String name;
  final int targetCents;
  final int colorValue;
  final String? note;

  /// Optional milestone date the goal is aimed at.
  final DateTime? targetDate;

  /// Whole days until [targetDate], or null when the goal has no date.
  /// Negative once the date has passed.
  int? daysUntilTarget([DateTime? from]) {
    final target = targetDate;
    if (target == null) return null;
    final base = from ?? DateTime.now();
    // UTC for the same reason as [Subscription.daysUntilDue]: a DST
    // transition inside the interval would otherwise cost or add a day.
    return DateTime.utc(target.year, target.month, target.day)
        .difference(DateTime.utc(base.year, base.month, base.day))
        .inDays;
  }

  SavingsGoal copyWith({
    String? name,
    int? targetCents,
    int? colorValue,
    String? note,
    DateTime? targetDate,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
  }) {
    return SavingsGoal(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      targetCents: targetCents ?? this.targetCents,
      colorValue: colorValue ?? this.colorValue,
      note: note ?? this.note,
      targetDate: targetDate ?? this.targetDate,
    );
  }
}

/// A single contribution into a [SavingsGoal]. Amounts may be negative to
/// record withdrawing from a bucket.
class GoalAllocation extends SoftDeletable {
  const GoalAllocation({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.goalId,
    required this.amountCents,
    required this.allocatedAt,
    this.note,
  });

  final String goalId;
  final int amountCents;
  final DateTime allocatedAt;
  final String? note;

  GoalAllocation copyWith({
    int? amountCents,
    DateTime? allocatedAt,
    String? note,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
  }) {
    return GoalAllocation(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: deletedAt ?? this.deletedAt,
      goalId: goalId,
      amountCents: amountCents ?? this.amountCents,
      allocatedAt: allocatedAt ?? this.allocatedAt,
      note: note ?? this.note,
    );
  }
}

/// Total allocated into [goalId] across [allocations].
int goalAllocatedCents(List<GoalAllocation> allocations, String goalId) {
  var total = 0;
  for (final a in allocations) {
    if (a.goalId == goalId) total += a.amountCents;
  }
  return total;
}

/// Fraction of a goal that's funded, clamped to 0..1 for ring rendering.
/// A goal with a non-positive target reads as complete.
double goalProgress(int allocatedCents, int targetCents) {
  if (targetCents <= 0) return 1;
  return (allocatedCents / targetCents).clamp(0.0, 1.0);
}

/// The largest amount any finance field accepts, in cents — $99,999,999.99.
const int kMaxAmountCents = 9999999999;

/// Parses a money field into cents, or null when the text isn't a usable
/// amount.
///
/// The amount fields filter keystrokes down to digits and dots but don't
/// validate the shape, so `1.2.3` and `.` arrive here unparseable and a long
/// enough paste parses to `Infinity`, whose `round()` throws. The bound is
/// checked on the rounded cents rather than the dollar value, so `0.001` —
/// positive, but zero cents — is rejected rather than written as a $0.00 row.
int? parseAmountCents(String text) {
  final value = double.tryParse(text.replaceAll(RegExp(r'[^0-9.]'), ''));
  if (value == null || !value.isFinite) return null;
  final cents = (value * 100).round();
  if (cents <= 0 || cents > kMaxAmountCents) return null;
  return cents;
}

/// As [parseAmountCents], but signed and zero-tolerant: an asset can be worth
/// nothing, or be a debt held as a negative value.
///
/// The `-` has to be leading and alone — the value field's formatter allows it
/// anywhere, and `1-2` is not a number even though stripping the sign would
/// make it look like $12.00.
int? parseSignedAmountCents(String text) {
  final raw = text.trim();
  if (!RegExp(r'^-?\d*\.?\d*$').hasMatch(raw)) return null;
  final value = double.tryParse(raw.replaceAll(RegExp(r'[^0-9.]'), ''));
  if (value == null || !value.isFinite) return null;
  final cents = (value * 100).round();
  if (cents > kMaxAmountCents) return null;
  return raw.startsWith('-') ? -cents : cents;
}

/// Hoisted rather than built per call: constructing a [NumberFormat] parses a
/// locale number pattern, and [formatCents] renders every figure in the
/// feature, so a full ledger repaint would otherwise pay for a few hundred
/// pattern parses in one frame.
final _currencyFormat = NumberFormat.currency(symbol: r'$', decimalDigits: 2);

/// Formats a cent amount as a currency string (e.g. `1250` -> `$12.50`).
///
/// When [signed] is true, deposits are prefixed with `+` and expenses with `-`;
/// otherwise the magnitude is returned unsigned.
String formatCents(int cents, {bool signed = false}) {
  final magnitude = _currencyFormat.format(cents.abs() / 100);
  if (!signed) return magnitude;
  final sign = cents < 0 ? '-' : '+';
  return '$sign$magnitude';
}
