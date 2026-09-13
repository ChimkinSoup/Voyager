// The hero net-flow chart's pure pieces: daily buckets, the MTD delta, the
// heatmap scale, and where zero splits the line's colours.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/features/finance/finance_net_flow_chart.dart';
import 'package:voyager/features/finance/finance_net_flow_hero.dart';
import 'package:voyager/features/finance/finance_ui_prefs.dart';

void main() {
  FinancialTransaction tx(
    TransactionType type,
    int cents,
    DateTime occurredAt, {
    List<String> tags = const [],
  }) {
    final now = utcNow();
    return FinancialTransaction(
      id: newId(),
      createdAt: now,
      updatedAt: now,
      type: type,
      amountCents: cents,
      occurredAt: occurredAt,
      tags: tags,
    );
  }

  FinancialTransaction spend(
    int cents,
    DateTime at, {
    List<String> tags = const [],
  }) => tx(TransactionType.expense, cents, at, tags: tags);
  FinancialTransaction earn(
    int cents,
    DateTime at, {
    List<String> tags = const [],
  }) => tx(TransactionType.deposit, cents, at, tags: tags);

  group('dailyNetSeries', () {
    test('emits every day inclusive, quiet days as zeros', () {
      final flows = dailyNetSeries(
        [
          spend(500, DateTime(2026, 9, 1, 23, 59)),
          earn(2000, DateTime(2026, 9, 3, 0, 1)),
          spend(300, DateTime(2026, 9, 3, 12)),
        ],
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 9, 4),
      );

      expect(
        [for (final f in flows) f.day],
        [
          DateTime(2026, 9, 1),
          DateTime(2026, 9, 2),
          DateTime(2026, 9, 3),
          DateTime(2026, 9, 4),
        ],
      );
      expect([for (final f in flows) f.netCents], [-500, 0, 1700, 0]);
      expect(flows[2].incomeCents, 2000);
      expect(flows[2].expenseCents, 300);
    });

    test('drops transactions outside the window, before and after', () {
      final flows = dailyNetSeries(
        [
          spend(100, DateTime(2026, 8, 31, 23, 59)),
          spend(100, DateTime(2026, 9, 5)),
          spend(700, DateTime(2026, 9, 2, 8)),
        ],
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 9, 4),
      );
      expect([for (final f in flows) f.netCents], [0, -700, 0, 0]);
    });

    test('a window across both DST transitions still has one slot a day', () {
      final flows = dailyNetSeries(
        [spend(100, DateTime(2026, 11, 2, 0, 30))],
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 12, 31),
      );
      expect(flows, hasLength(365));
      expect(flows.last.day, DateTime(2026, 12, 31));
      final nov2 = flows.indexWhere((f) => f.day == DateTime(2026, 11, 2));
      expect(flows[nov2].expenseCents, 100);
    });

    test('where narrows the sums but never the days', () {
      final flows = dailyNetSeries(
        [
          spend(400, DateTime(2026, 9, 1), tags: ['food']),
          spend(900, DateTime(2026, 9, 1), tags: ['rent']),
          earn(5000, DateTime(2026, 9, 2)),
        ],
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 9, 2),
        where: (t) => t.tags.contains('food'),
      );
      expect([for (final f in flows) f.netCents], [-400, 0]);
    });
  });

  group('month-to-date', () {
    final txs = [
      earn(10000, DateTime(2026, 9, 1)),
      spend(2500, DateTime(2026, 9, 12, 23)),
      // Tomorrow: not counted yet.
      spend(99999, DateTime(2026, 9, 13)),
      spend(4000, DateTime(2026, 8, 12, 22)),
      // Past the same day-of-month last month.
      spend(8000, DateTime(2026, 8, 13)),
    ];

    test('this month runs from the 1st through the end of today', () {
      expect(monthToDateNet(txs, DateTime(2026, 9, 12)), 7500);
    });

    test('last month covers the same day-of-month span', () {
      expect(priorMonthToDateNet(txs, DateTime(2026, 9, 12)), -4000);
    });

    test("a day past last month's end compares against all of it", () {
      final march = [
        spend(100, DateTime(2026, 2, 28, 20)),
        spend(100, DateTime(2026, 3, 1)),
      ];
      expect(priorMonthToDateNet(march, DateTime(2026, 3, 31)), -100);
    });

    test('January reaches back into December of the previous year', () {
      expect(
        priorMonthToDateNet([
          earn(300, DateTime(2025, 12, 5)),
        ], DateTime(2026, 1, 5)),
        300,
      );
    });
  });

  test('busiestDailyFlow scales on magnitude, per series', () {
    final flows = [
      DailyFlow(day: DateTime(2026, 9, 1), incomeCents: 100, expenseCents: 900),
      DailyFlow(day: DateTime(2026, 9, 2), incomeCents: 500),
    ];
    expect(busiestDailyFlow(flows, NetFlowSeries.net), 800);
    expect(busiestDailyFlow(flows, NetFlowSeries.income), 500);
    expect(busiestDailyFlow(flows, NetFlowSeries.expense), 900);
    expect(busiestDailyFlow(const [], NetFlowSeries.net), 0);
  });

  group('zeroStopFraction', () {
    test('a band straddling zero splits where zero sits', () {
      expect(zeroStopFraction(top: 30, bottom: -10), 0.75);
      expect(zeroStopFraction(top: 10, bottom: -30), 0.25);
    });

    test('a band on one side of zero needs no split', () {
      expect(zeroStopFraction(top: 30, bottom: 1), isNull);
      expect(zeroStopFraction(top: -1, bottom: -30), isNull);
    });

    test('touching zero from above puts the stop on the bottom edge', () {
      expect(zeroStopFraction(top: 30, bottom: 0), 1);
      expect(zeroStopFraction(top: 0, bottom: -30), 0);
    });

    test('a flat band has nothing to split', () {
      expect(zeroStopFraction(top: 0, bottom: 0), isNull);
    });
  });

  test('range starts count calendar days back through today', () {
    final today = DateTime(2026, 9, 12, 15);
    expect(
      financeHeroRangeStart(FinanceHeroRange.month, today),
      DateTime(2026, 9, 1),
    );
    expect(
      financeHeroRangeStart(FinanceHeroRange.d7, today),
      DateTime(2026, 9, 6),
    );
    expect(
      financeHeroRangeStart(FinanceHeroRange.d30, today),
      DateTime(2026, 8, 14),
    );
    expect(
      financeHeroRangeStart(FinanceHeroRange.d90, today),
      DateTime(2026, 6, 15),
    );
    expect(
      financeHeroRangeStart(FinanceHeroRange.ytd, today),
      DateTime(2026, 1, 1),
    );
  });
}
