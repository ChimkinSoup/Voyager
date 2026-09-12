import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_analytics.dart';

void main() {
  FinancialTransaction tx({
    required TransactionType type,
    required int amountCents,
    required DateTime occurredAt,
    List<String> tags = const [],
  }) {
    final now = utcNow();
    return FinancialTransaction(
      id: newId(),
      createdAt: now,
      updatedAt: now,
      type: type,
      amountCents: amountCents,
      occurredAt: occurredAt,
      tags: tags,
    );
  }

  // -- Cash flow -----------------------------------------------------------

  group('cashFlowPeriodStart', () {
    // 2026-07-18 is a Saturday.
    final saturday = DateTime(2026, 7, 18);

    test('weekly anchors to Monday when the week starts Monday', () {
      expect(
        cashFlowPeriodStart(saturday, CashFlowGranularity.weekly),
        DateTime(2026, 7, 13),
      );
    });

    test('weekly anchors to Sunday when the week starts Sunday', () {
      expect(
        cashFlowPeriodStart(
          saturday,
          CashFlowGranularity.weekly,
          weekStartsMonday: false,
        ),
        DateTime(2026, 7, 12),
      );
    });

    test('monthly and yearly anchor to period start', () {
      expect(
        cashFlowPeriodStart(saturday, CashFlowGranularity.monthly),
        DateTime(2026, 7, 1),
      );
      expect(
        cashFlowPeriodStart(saturday, CashFlowGranularity.yearly),
        DateTime(2026, 1, 1),
      );
    });
  });

  test('cashFlowSeries buckets income and expense, emitting empty periods', () {
    final now = DateTime(2026, 7, 18);
    final transactions = [
      tx(
        type: TransactionType.deposit,
        amountCents: 10000,
        occurredAt: DateTime(2026, 7, 5),
      ),
      tx(
        type: TransactionType.expense,
        amountCents: 3000,
        occurredAt: DateTime(2026, 7, 10),
      ),
      tx(
        type: TransactionType.expense,
        amountCents: 2000,
        occurredAt: DateTime(2026, 6, 15),
      ),
      // Outside the 3-month window — must be ignored.
      tx(
        type: TransactionType.deposit,
        amountCents: 5000,
        occurredAt: DateTime(2026, 4, 20),
      ),
    ];

    final series = cashFlowSeries(
      transactions,
      granularity: CashFlowGranularity.monthly,
      periods: 3,
      now: now,
    );

    expect(series, hasLength(3));
    expect(series.map((p) => p.periodStart), [
      DateTime(2026, 5, 1),
      DateTime(2026, 6, 1),
      DateTime(2026, 7, 1),
    ]);
    // May: empty bucket still emitted.
    expect(series[0].incomeCents, 0);
    expect(series[0].expenseCents, 0);
    expect(series[1].expenseCents, 2000);
    expect(series[2].incomeCents, 10000);
    expect(series[2].expenseCents, 3000);
    expect(series[2].netCents, 7000);
  });

  // A weekly window that spans a DST transition used to lose whole buckets:
  // stepping back by an absolute Duration from a wall-clock midnight lands at
  // 23:00 the previous day, so the bucket keys stopped matching the key a
  // transaction hashes to and its whole week read as $0.00.
  //
  // Runs on any machine: where there is no DST the arithmetic is unchanged,
  // and the assertions describe the calendar, not the offset.
  test('cashFlowSeries keeps every weekly bucket across a DST transition', () {
    // US DST begins 2026-03-08 and this window straddles it.
    final now = DateTime(2026, 4, 20);
    final transactions = [
      for (final day in [
        DateTime(2026, 2, 4, 12),
        DateTime(2026, 2, 11, 12),
        DateTime(2026, 2, 18, 12),
        DateTime(2026, 3, 4, 12),
        DateTime(2026, 3, 18, 12),
      ])
        tx(
          type: TransactionType.expense,
          amountCents: 1000,
          occurredAt: day,
        ),
    ];

    final series = cashFlowSeries(
      transactions,
      granularity: CashFlowGranularity.weekly,
      periods: 12,
      now: now,
    );

    // Every bucket starts on a Monday at wall-clock midnight.
    for (final point in series) {
      expect(point.periodStart.weekday, DateTime.monday);
      expect(point.periodStart.hour, 0);
    }
    // And nothing inside the window was dropped.
    expect(
      series.fold<int>(0, (sum, p) => sum + p.expenseCents),
      5000,
    );
  });

  // -- Spending breakdown --------------------------------------------------

  group('spendingBreakdown', () {
    final eatingOut = FinanceCategory(
      id: 'cat-1',
      createdAt: utcNow(),
      updatedAt: utcNow(),
      name: 'Eating out',
      colorValue: 0xFFAA0000,
      tags: const ['mcdonalds', 'burger_king'],
    );
    final from = DateTime(2026, 7, 1);
    final to = DateTime(2026, 8, 1);

    final transactions = [
      tx(
        type: TransactionType.expense,
        amountCents: 1000,
        occurredAt: DateTime(2026, 7, 3),
        tags: ['mcdonalds'],
      ),
      tx(
        type: TransactionType.expense,
        amountCents: 2000,
        occurredAt: DateTime(2026, 7, 4),
        tags: ['burger_king'],
      ),
      tx(
        type: TransactionType.expense,
        amountCents: 500,
        occurredAt: DateTime(2026, 7, 5),
        tags: ['rent'],
      ),
      tx(
        type: TransactionType.expense,
        amountCents: 300,
        occurredAt: DateTime(2026, 7, 6),
      ),
      // Deposits never appear in a spending breakdown.
      tx(
        type: TransactionType.deposit,
        amountCents: 9999,
        occurredAt: DateTime(2026, 7, 7),
        tags: ['mcdonalds'],
      ),
      // Outside the window.
      tx(
        type: TransactionType.expense,
        amountCents: 8888,
        occurredAt: DateTime(2026, 6, 30),
        tags: ['mcdonalds'],
      ),
    ];

    test('rolls tags up into categories, sorted by amount', () {
      final slices = spendingBreakdown(
        transactions,
        from: from,
        to: to,
        categories: [eatingOut],
        tagColors: const {},
        groupByCategory: true,
      );

      expect(slices.map((s) => s.label), [
        'Eating out',
        kUncategorizedLabel,
        kUntaggedLabel,
      ]);
      expect(slices[0].amountCents, 3000);
      expect(slices[0].colorValue, 0xFFAA0000);
      expect(slices[1].amountCents, 500);
      expect(slices[2].amountCents, 300);

      // Slices sum to total expenses in the window.
      expect(slices.fold<int>(0, (s, x) => s + x.amountCents), 3800);
    });

    test('groups by raw tag when categories are off', () {
      final slices = spendingBreakdown(
        transactions,
        from: from,
        to: to,
        categories: [eatingOut],
        tagColors: const {'burger_king': 0xFF00FF00},
        groupByCategory: false,
      );

      expect(slices.map((s) => s.label), [
        'burger_king',
        'mcdonalds',
        'rent',
        kUntaggedLabel,
      ]);
      expect(slices.first.colorValue, 0xFF00FF00);
    });

    test('attributes a multi-tag expense to one bucket only', () {
      final multi = [
        tx(
          type: TransactionType.expense,
          amountCents: 1000,
          occurredAt: DateTime(2026, 7, 3),
          tags: ['mcdonalds', 'rent'],
        ),
      ];
      final slices = spendingBreakdown(
        multi,
        from: from,
        to: to,
        categories: [eatingOut],
        tagColors: const {},
        groupByCategory: true,
      );

      // Counted once, under the first tag's category — not double-counted.
      expect(slices, hasLength(1));
      expect(slices.single.label, 'Eating out');
      expect(slices.single.amountCents, 1000);
    });
  });

  // -- Net worth -----------------------------------------------------------

  test('netWorthSeries combines cumulative cash with latest valuations', () {
    final now = DateTime(2026, 7, 18);
    final transactions = [
      tx(
        type: TransactionType.deposit,
        amountCents: 100000,
        occurredAt: DateTime(2026, 5, 10),
      ),
      tx(
        type: TransactionType.expense,
        amountCents: 20000,
        occurredAt: DateTime(2026, 6, 15),
      ),
    ];
    final asset = Asset(
      id: 'asset-1',
      createdAt: utcNow(),
      updatedAt: utcNow(),
      name: 'Index fund',
    );
    final valuations = [
      AssetValuation(
        id: 'v1',
        createdAt: utcNow(),
        updatedAt: utcNow(),
        assetId: 'asset-1',
        valueCents: 50000,
        asOf: DateTime(2026, 5, 1),
      ),
      AssetValuation(
        id: 'v2',
        createdAt: utcNow(),
        updatedAt: utcNow(),
        assetId: 'asset-1',
        valueCents: 60000,
        asOf: DateTime(2026, 7, 1),
      ),
    ];

    final series = netWorthSeries(
      transactions,
      [asset],
      valuations,
      months: 3,
      now: now,
    );

    expect(series, hasLength(3));
    expect(series.map((p) => p.date), [
      DateTime(2026, 5, 31),
      DateTime(2026, 6, 30),
      DateTime(2026, 7, 18),
    ]);

    // End of May: deposit only, asset still at its May valuation.
    expect(series[0].cashCents, 100000);
    expect(series[0].assetCents, 50000);
    expect(series[0].totalCents, 150000);

    // End of June: expense applied, asset unchanged (July valuation not yet).
    expect(series[1].cashCents, 80000);
    expect(series[1].assetCents, 50000);
    expect(series[1].totalCents, 130000);

    // Today: asset re-valued in July.
    expect(series[2].cashCents, 80000);
    expect(series[2].assetCents, 60000);
    expect(series[2].totalCents, 140000);
  });

  test('netWorthSeries supports negative valuations as debt', () {
    final now = DateTime(2026, 7, 18);
    final debt = Asset(
      id: 'debt-1',
      createdAt: utcNow(),
      updatedAt: utcNow(),
      name: 'Car loan',
    );
    final series = netWorthSeries(
      const [],
      [debt],
      [
        AssetValuation(
          id: 'v1',
          createdAt: utcNow(),
          updatedAt: utcNow(),
          assetId: 'debt-1',
          valueCents: -250000,
          asOf: DateTime(2026, 1, 1),
        ),
      ],
      months: 2,
      now: now,
    );
    expect(series.last.assetCents, -250000);
    expect(series.last.totalCents, -250000);
  });

  test('latestValuation picks the newest at or before a date', () {
    final valuations = [
      AssetValuation(
        id: 'v1',
        createdAt: utcNow(),
        updatedAt: utcNow(),
        assetId: 'a',
        valueCents: 100,
        asOf: DateTime(2026, 1, 1),
      ),
      AssetValuation(
        id: 'v2',
        createdAt: utcNow(),
        updatedAt: utcNow(),
        assetId: 'a',
        valueCents: 200,
        asOf: DateTime(2026, 6, 1),
      ),
      AssetValuation(
        id: 'v3',
        createdAt: utcNow(),
        updatedAt: utcNow(),
        assetId: 'other',
        valueCents: 999,
        asOf: DateTime(2026, 6, 1),
      ),
    ];

    expect(latestValuation(valuations, 'a')?.valueCents, 200);
    expect(
      latestValuation(valuations, 'a', asOf: DateTime(2026, 3, 1))?.valueCents,
      100,
    );
    expect(latestValuation(valuations, 'missing'), isNull);
  });
  // -- Breakdown focus -----------------------------------------------------

  group('spendingBreakdownFocusedByTag', () {
    final from = DateTime(2026, 7, 1);
    final to = DateTime(2026, 8, 1);

    test('a bucket with no co-tags is one slice equal to the parent', () {
      final result = spendingBreakdownFocusedByTag(
        [
          tx(
            type: TransactionType.expense,
            amountCents: 1000,
            occurredAt: DateTime(2026, 7, 3),
            tags: ['food'],
          ),
          tx(
            type: TransactionType.expense,
            amountCents: 500,
            occurredAt: DateTime(2026, 7, 4),
            tags: ['food'],
          ),
        ],
        from: from,
        to: to,
        tag: 'food',
        tagColors: const {},
      );

      expect(result.parentCents, 1500);
      expect(result.slices.map((s) => s.label), ['food']);
      expect(result.slices.single.amountCents, 1500);
    });

    test('splits exclusively between the tag alone and its first co-tag', () {
      final result = spendingBreakdownFocusedByTag(
        [
          tx(
            type: TransactionType.expense,
            amountCents: 1000,
            occurredAt: DateTime(2026, 7, 3),
            tags: ['food'],
          ),
          tx(
            type: TransactionType.expense,
            amountCents: 3000,
            occurredAt: DateTime(2026, 7, 4),
            tags: ['food', 'thai', 'drink'],
          ),
          tx(
            type: TransactionType.expense,
            amountCents: 400,
            occurredAt: DateTime(2026, 7, 5),
            tags: ['food', 'drink'],
          ),
          // Food is the second tag here, not the first. It is still money
          // spent on food, so the bucket takes it — filed, like any other
          // multi-tag expense, under its first tag that isn't food.
          tx(
            type: TransactionType.expense,
            amountCents: 9999,
            occurredAt: DateTime(2026, 7, 6),
            tags: ['thai', 'food'],
          ),
          // Deposits and out-of-window expenses never count.
          tx(
            type: TransactionType.deposit,
            amountCents: 7777,
            occurredAt: DateTime(2026, 7, 7),
            tags: ['food'],
          ),
          tx(
            type: TransactionType.expense,
            amountCents: 8888,
            occurredAt: DateTime(2026, 6, 30),
            tags: ['food'],
          ),
        ],
        from: from,
        to: to,
        tag: 'food',
        tagColors: const {'thai': 0xFF00FF00},
      );

      expect(result.parentCents, 14399);
      expect(result.slices.map((s) => s.label), ['thai', 'food', 'drink']);
      expect(result.slices[0].amountCents, 12999);
      expect(result.slices[0].colorValue, 0xFF00FF00);
      expect(result.slices[1].amountCents, 1000);
      expect(result.slices[2].amountCents, 400);
      expect(result.slices[2].colorValue, kBreakdownFallbackColor);

      // The children partition the parent — nothing counted twice.
      expect(
        result.slices.fold<int>(0, (s, x) => s + x.amountCents),
        result.parentCents,
      );
    });

    test('an empty bucket is zero with no slices', () {
      final result = spendingBreakdownFocusedByTag(
        const [],
        from: from,
        to: to,
        tag: 'food',
        tagColors: const {},
      );

      expect(result.parentCents, 0);
      expect(result.slices, isEmpty);
    });
  });

  group('spendingBreakdownFocusedByCategory', () {
    final eatingOut = FinanceCategory(
      id: 'cat-1',
      createdAt: utcNow(),
      updatedAt: utcNow(),
      name: 'Eating out',
      colorValue: 0xFFAA0000,
      tags: const ['food'],
    );
    final from = DateTime(2026, 7, 1);
    final to = DateTime(2026, 8, 1);

    final transactions = [
      tx(
        type: TransactionType.expense,
        amountCents: 3000,
        occurredAt: DateTime(2026, 7, 3),
        tags: ['food', 'thai'],
      ),
      tx(
        type: TransactionType.expense,
        amountCents: 1000,
        occurredAt: DateTime(2026, 7, 4),
        tags: ['food'],
      ),
      // Primary tag is in no category.
      tx(
        type: TransactionType.expense,
        amountCents: 700,
        occurredAt: DateTime(2026, 7, 5),
        tags: ['rent', 'home'],
      ),
      tx(
        type: TransactionType.expense,
        amountCents: 300,
        occurredAt: DateTime(2026, 7, 6),
      ),
      tx(
        type: TransactionType.deposit,
        amountCents: 9999,
        occurredAt: DateTime(2026, 7, 7),
        tags: ['food'],
      ),
    ];

    test('counts every tag in full, with the parent staying exclusive', () {
      final result = spendingBreakdownFocusedByCategory(
        transactions,
        from: from,
        to: to,
        categories: [eatingOut],
        label: 'Eating out',
        tagColors: const {'food': 0xFF112233},
      );

      expect(result.parentCents, 4000);
      expect(result.slices.map((s) => s.label), ['food', 'thai']);
      // The $30 two-tag expense lands in full under both of its tags, so the
      // children add to more than the category cost. That is the point.
      expect(result.slices[0].amountCents, 4000);
      expect(result.slices[0].colorValue, 0xFF112233);
      expect(result.slices[1].amountCents, 3000);
      expect(
        result.slices.fold<int>(0, (s, x) => s + x.amountCents),
        greaterThan(result.parentCents),
      );
    });

    test('Uncategorized collects the tags no category claims', () {
      final result = spendingBreakdownFocusedByCategory(
        transactions,
        from: from,
        to: to,
        categories: [eatingOut],
        label: kUncategorizedLabel,
        tagColors: const {},
      );

      expect(result.parentCents, 700);
      expect(result.slices.map((s) => s.label), ['rent', 'home']);
      expect(result.slices.every((s) => s.amountCents == 700), isTrue);
    });

    test('Untagged has nothing to subdivide, so it is one slice', () {
      final result = spendingBreakdownFocusedByCategory(
        transactions,
        from: from,
        to: to,
        categories: [eatingOut],
        label: kUntaggedLabel,
        tagColors: const {},
      );

      expect(result.parentCents, 300);
      expect(result.slices.map((s) => s.label), [kUntaggedLabel]);
      expect(result.slices.single.amountCents, 300);
      expect(result.slices.single.colorValue, kBreakdownFallbackColor);
    });

    test('an empty category is zero with no slices', () {
      final result = spendingBreakdownFocusedByCategory(
        transactions,
        from: from,
        to: to,
        categories: [eatingOut],
        label: 'Travel',
        tagColors: const {},
      );

      expect(result.parentCents, 0);
      expect(result.slices, isEmpty);
    });
  });
}
