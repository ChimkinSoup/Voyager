import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/domain/services/finance_origins.dart';

FinancialTransaction _tx(
  String id, {
  TransactionType type = TransactionType.expense,
  int cents = 100,
  String? origin,
  String? note,
  DateTime? occurredAt,
  DateTime? updatedAt,
  DateTime? deletedAt,
}) {
  final at = occurredAt ?? DateTime(2026, 9, 10);
  return FinancialTransaction(
    id: id,
    createdAt: at,
    updatedAt: updatedAt ?? at,
    deletedAt: deletedAt,
    type: type,
    amountCents: cents,
    occurredAt: at,
    origin: origin,
    note: note,
  );
}

final _now = DateTime(2026, 9, 12, 12);

void main() {
  group('ledgerTransactionTitle', () {
    test('origin and note', () {
      expect(
        ledgerTransactionTitle('Walmart', 'Toothpaste', TransactionType.expense),
        (origin: 'Walmart', detail: 'Toothpaste'),
      );
    });

    test('origin only', () {
      expect(
        ledgerTransactionTitle('Walmart', null, TransactionType.expense),
        (origin: 'Walmart', detail: null),
      );
    });

    test('note only', () {
      expect(
        ledgerTransactionTitle(null, 'Toothpaste', TransactionType.expense),
        (origin: null, detail: 'Toothpaste'),
      );
    });

    test('neither falls back to the type', () {
      expect(
        ledgerTransactionTitle(null, null, TransactionType.expense),
        (origin: null, detail: 'Expense'),
      );
      expect(
        ledgerTransactionTitle(null, null, TransactionType.deposit),
        (origin: null, detail: 'Deposit'),
      );
    });

    test('whitespace-only counts as empty, and set values are trimmed', () {
      expect(
        ledgerTransactionTitle('   ', ' \t', TransactionType.deposit),
        (origin: null, detail: 'Deposit'),
      );
      expect(
        ledgerTransactionTitle(' Costco ', '  ', TransactionType.expense),
        (origin: 'Costco', detail: null),
      );
    });
  });

  group('recentTransactionOrigins', () {
    test('distinct, most recently used first', () {
      final origins = recentTransactionOrigins([
        _tx('a', origin: 'Walmart', occurredAt: DateTime(2026, 9, 1)),
        _tx('b', origin: 'Costco', occurredAt: DateTime(2026, 9, 5)),
        _tx('c', origin: 'Walmart', occurredAt: DateTime(2026, 9, 8)),
        _tx('d', origin: 'Target', occurredAt: DateTime(2026, 9, 3)),
      ], TransactionType.expense, _now);

      expect(origins, ['Walmart', 'Costco', 'Target']);
    });

    test('same day breaks ties by updatedAt', () {
      final day = DateTime(2026, 9, 1);
      final origins = recentTransactionOrigins([
        _tx('a', origin: 'Old', occurredAt: day, updatedAt: DateTime(2026, 9, 2)),
        _tx('b', origin: 'New', occurredAt: day, updatedAt: DateTime(2026, 9, 3)),
      ], TransactionType.expense, _now);

      expect(origins, ['New', 'Old']);
    });

    test('only the requested type', () {
      final txs = [
        _tx('a', origin: 'Walmart'),
        _tx('b', type: TransactionType.deposit, origin: 'Payroll'),
      ];
      expect(recentTransactionOrigins(txs, TransactionType.expense, _now), [
        'Walmart',
      ]);
      expect(recentTransactionOrigins(txs, TransactionType.deposit, _now), [
        'Payroll',
      ]);
    });

    test('case-sensitive: both spellings survive', () {
      final origins = recentTransactionOrigins([
        _tx('a', origin: 'Walmart', occurredAt: DateTime(2026, 9, 2)),
        _tx('b', origin: 'walmart', occurredAt: DateTime(2026, 9, 1)),
      ], TransactionType.expense, _now);

      expect(origins, ['Walmart', 'walmart']);
    });

    test('soft-deleted and empty origins are left out', () {
      final origins = recentTransactionOrigins([
        _tx('a', origin: 'Costco', deletedAt: DateTime(2026, 9, 11)),
        _tx('b', origin: '   '),
        _tx('c'),
        _tx('d', origin: 'Target'),
      ], TransactionType.expense, _now);

      expect(origins, ['Target']);
    });

    test('future-dated rows count, ranked as used now', () {
      final origins = recentTransactionOrigins([
        _tx('rent', origin: 'Landlord', occurredAt: DateTime(2026, 10, 1)),
        _tx('b', origin: 'Costco', occurredAt: DateTime(2026, 9, 12, 9)),
        _tx('c', origin: 'Walmart', occurredAt: DateTime(2026, 9, 11)),
      ], TransactionType.expense, _now);

      expect(
        origins,
        ['Landlord', 'Costco', 'Walmart'],
        reason: 'post-dated, but entered now: above this morning, not hidden',
      );
    });

    test('a future row ties with now, and updatedAt breaks the tie', () {
      final origins = recentTransactionOrigins([
        _tx(
          'rent',
          origin: 'Landlord',
          occurredAt: DateTime(2026, 10, 1),
          updatedAt: DateTime(2026, 9, 1),
        ),
        _tx(
          'b',
          origin: 'Costco',
          occurredAt: _now,
          updatedAt: DateTime(2026, 9, 12, 12),
        ),
      ], TransactionType.expense, _now);

      expect(origins, ['Costco', 'Landlord'], reason: 'tied at now; updatedAt');
    });
  });

  group('filterTransactionOrigins', () {
    const origins = ['Kowalski', 'Walmart', 'walmart', 'Costco'];

    test('an empty query offers every origin in recency order', () {
      expect(filterTransactionOrigins(origins, '  '), origins);
    });

    test('matching ignores case but keeps both spellings', () {
      expect(filterTransactionOrigins(origins, 'WAL'), [
        'Kowalski',
        'Walmart',
        'walmart',
      ]);
    });
  });

  group('originBreakdown', () {
    final from = DateTime(2026, 9, 1);
    final to = DateTime(2026, 10, 1);
    int colorFor(String origin) => 0xFF000000 + origin.length;

    final txs = [
      _tx('a', cents: 500, origin: 'Walmart'),
      _tx('b', cents: 300, origin: 'walmart'),
      _tx('c', cents: 200, origin: 'Walmart'),
      _tx('d', cents: 400),
      _tx('e', cents: 50, origin: '  '),
      _tx('f', type: TransactionType.deposit, cents: 9000, origin: 'Payroll'),
      _tx('g', type: TransactionType.deposit, cents: 1000),
      // Outside the window.
      _tx('h', cents: 7777, origin: 'Walmart', occurredAt: DateTime(2026, 8, 31)),
    ];

    test('expenses bucket by store, case-sensitive, and sum to spending', () {
      final slices = originBreakdown(
        txs,
        from: from,
        to: to,
        type: TransactionType.expense,
        colorFor: colorFor,
      );

      expect(
        {for (final s in slices) s.label: s.amountCents},
        {'Walmart': 700, kNoStoreLabel: 450, 'walmart': 300},
      );
      expect(slices.map((s) => s.label), ['Walmart', kNoStoreLabel, 'walmart']);
      expect(slices.fold<int>(0, (s, x) => s + x.amountCents), 1450);
      expect(
        slices.firstWhere((s) => s.label == kNoStoreLabel).colorValue,
        kBreakdownFallbackColor,
      );
      expect(
        slices.firstWhere((s) => s.label == 'Walmart').colorValue,
        colorFor('Walmart'),
      );
    });

    test('deposits bucket by source and sum to income', () {
      final slices = originBreakdown(
        txs,
        from: from,
        to: to,
        type: TransactionType.deposit,
        colorFor: colorFor,
      );

      expect(
        {for (final s in slices) s.label: s.amountCents},
        {'Payroll': 9000, kNoSourceLabel: 1000},
      );
    });
  });
}
