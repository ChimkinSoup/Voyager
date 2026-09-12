import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';

/// [value] trimmed, or null when nothing is left — the rule a transaction's
/// origin and note are both saved under.
String? trimToNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// A ledger row's title, split so the origin can be drawn with more weight
/// than the note after it.
///
/// [origin] is null when the transaction has none; [detail] is what follows
/// it — the note, or with no origin either, the `Expense` / `Deposit`
/// fallback. Null only when there is an origin and no note.
typedef LedgerTitle = ({String? origin, String? detail});

LedgerTitle ledgerTransactionTitle(
  String? origin,
  String? note,
  TransactionType type,
) {
  final o = trimToNull(origin);
  final n = trimToNull(note);
  if (o != null) return (origin: o, detail: n);
  return (
    origin: null,
    detail: n ?? (type == TransactionType.deposit ? 'Deposit' : 'Expense'),
  );
}

/// The distinct origins on live transactions of [type], most recently used
/// first.
///
/// Recency is the newest [FinancialTransaction.occurredAt] carrying that exact
/// string, then [FinancialTransaction.updatedAt]. Rows dated after [now] still
/// count, but rank as used at [now]: a post-dated rent deposit was used when
/// it was entered, and should not sit above yesterday's store until its day
/// arrives. Soft-deleted rows are skipped here as well as by the repository,
/// so a caller holding a list that still has tombstones in it gets the same
/// answer. Case-sensitive: `Walmart` and `walmart` are both returned.
List<String> recentTransactionOrigins(
  Iterable<FinancialTransaction> transactions,
  TransactionType type,
  DateTime now,
) {
  DateTime usedAt(FinancialTransaction t) =>
      t.occurredAt.isAfter(now) ? now : t.occurredAt;
  final candidates = [
    for (final t in transactions)
      if (t.deletedAt == null && t.type == type && trimToNull(t.origin) != null)
        t,
  ]..sort((a, b) {
      final byUsed = usedAt(b).compareTo(usedAt(a));
      return byUsed != 0 ? byUsed : b.updatedAt.compareTo(a.updatedAt);
    });
  final seen = <String>{};
  return [
    for (final t in candidates)
      if (seen.add(t.origin!.trim())) t.origin!.trim(),
  ];
}

/// The origins worth offering for [query], in the order to offer them.
///
/// [origins] comes from [recentTransactionOrigins] and keeps its recency
/// order: every origin is one the user has used, so there is no unused
/// catalogue to rank below them the way the Jobs company list has. Matching is
/// a case-insensitive substring — typing `wal` should still find `Walmart` —
/// even though the origins themselves stay distinct by case. An empty query
/// offers them all.
List<String> filterTransactionOrigins(List<String> origins, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return origins;
  return [
    for (final origin in origins)
      if (origin.toLowerCase().contains(needle)) origin,
  ];
}
