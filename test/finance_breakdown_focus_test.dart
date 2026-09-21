// Click-to-focus on the spending breakdown: what the legend and the filter
// text do, and how focus interacts with the Category/Tag grouping.

import 'dart:math' as math;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/features/finance/finance_page.dart';
import 'package:voyager/features/finance/finance_ui_prefs.dart';

import 'fakes/fake_weather_api_client.dart';

/// A day inside the current month, which is the only window the breakdown
/// ever looks at.
final _thisMonth = () {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}();

Future<void> pumpBreakdown(
  WidgetTester tester, {
  MemoryFinanceUiPrefsStore? prefsStore,
  bool withIncome = false,
}) async {
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftFinanceRepository(db);
  final now = utcNow();

  Future<void> expense(String id, int cents, List<String> tags) =>
      repo.upsertTransaction(
        FinancialTransaction(
          id: id,
          createdAt: now,
          updatedAt: now,
          type: TransactionType.expense,
          amountCents: cents,
          occurredAt: _thisMonth,
          note: id,
          tags: tags,
        ),
      );

  await expense('plain-food', 1000, const ['food']);
  await expense('food-and-thai', 3000, const ['food', 'thai']);
  await expense('rent-only', 5000, const ['rent']);
  if (withIncome) {
    await repo.upsertTransaction(
      FinancialTransaction(
        id: 'paycheque',
        createdAt: now,
        updatedAt: now,
        type: TransactionType.deposit,
        amountCents: 90000,
        occurredAt: _thisMonth,
        origin: 'Employer',
      ),
    );
  }

  await repo.upsertCategory(
    FinanceCategory(
      id: 'cat-1',
      createdAt: now,
      updatedAt: now,
      name: 'Eating out',
      tags: const ['food'],
    ),
  );

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      financeUiPrefsStoreProvider.overrideWithValue(
        prefsStore ?? MemoryFinanceUiPrefsStore(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  await container.read(transactionsProvider.future);
  await container.read(financeCategoriesProvider.future);
  await container.read(tagColorsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: FinancePage())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));

  await tester.tap(find.text('Analytics'));
  await tester.pumpAndSettle();
}

/// The breakdown, seeded so that the third slice of a *focused* tag chart
/// drills into a bucket with only one slice of its own — the shape that used
/// to leave the pie holding an index past the end of its new slice list.
///
/// Tag mode, focused on `a`: children are `d` $300, `c` $200, `b` $100, and
/// `b`'s own bucket is the $100 it shares with `a` plus the $10 it carries
/// alone.
Future<void> pumpDeepBreakdown(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftFinanceRepository(db);
  final now = utcNow();

  Future<void> expense(String id, int cents, List<String> tags) =>
      repo.upsertTransaction(
        FinancialTransaction(
          id: id,
          createdAt: now,
          updatedAt: now,
          type: TransactionType.expense,
          amountCents: cents,
          occurredAt: _thisMonth,
          note: id,
          tags: tags,
        ),
      );

  await expense('t1', 10000, const ['a', 'b']);
  await expense('t2', 20000, const ['a', 'c']);
  await expense('t3', 30000, const ['a', 'd']);
  await expense('t4', 1000, const ['b']);

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      financeUiPrefsStoreProvider.overrideWithValue(
        MemoryFinanceUiPrefsStore(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  await container.read(transactionsProvider.future);
  await container.read(financeCategoriesProvider.future);
  await container.read(tagColorsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: FinancePage())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(find.text('Analytics'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Tag'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('a'));
  await tester.pumpAndSettle();
}

/// Taps the middle of slice [index]'s wedge.
///
/// fl_chart sweeps its sections clockwise from three o'clock, in screen
/// coordinates, so walking the preceding sweeps and stopping halfway into
/// this one lands on the ring.
Future<void> tapSlice(
  WidgetTester tester,
  List<int> centsBySlice,
  int index,
) async {
  final total = centsBySlice.fold<int>(0, (s, x) => s + x).toDouble();
  var swept = 0.0;
  for (var i = 0; i < index; i++) {
    swept += 2 * math.pi * centsBySlice[i] / total;
  }
  final mid = swept + math.pi * centsBySlice[index] / total;
  const radius = 44 + 18 / 2;
  final centre = tester.getCenter(find.byType(PieChart));
  await tester.tapAt(
    centre + Offset(math.cos(mid) * radius, math.sin(mid) * radius),
  );
  await tester.pumpAndSettle();
}

/// [testWidgets] on [platform].
///
/// The override is cleared in a `finally` rather than a `addTearDown`: the
/// framework's "no foundation debug variable was changed" check runs when the
/// body returns, before any teardown does.
void _platformWidgets(
  String description,
  TargetPlatform platform,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a category legend row drills into the tags inside it', (
    tester,
  ) async {
    await pumpBreakdown(tester);

    // Unfocused, category mode: the two buckets and the month's total.
    expect(find.text('Eating out'), findsOneWidget);
    expect(find.text('Uncategorized'), findsOneWidget);
    expect(find.textContaining('Filtering:'), findsNothing);

    await tester.tap(find.text('Eating out'));
    await tester.pumpAndSettle();

    expect(find.text('Filtering: Eating out'), findsOneWidget);
    // Both tags on the category's expenses, each counted in full, against a
    // centre that stays at the exclusive $40 the category actually cost.
    expect(find.text('food'), findsOneWidget);
    expect(find.text('thai'), findsOneWidget);
    expect(find.text('Uncategorized'), findsNothing);
    expect(find.text(r'$40.00'), findsWidgets);
  });

  testWidgets('the filter text clears the focus', (tester) async {
    await pumpBreakdown(tester);

    await tester.tap(find.text('Eating out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filtering: Eating out'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Filtering:'), findsNothing);
    expect(find.text('Uncategorized'), findsOneWidget);
  });

  testWidgets('focusing and clearing leave the pie where it was', (
    tester,
  ) async {
    await pumpBreakdown(tester);
    final top = tester.getTopLeft(find.byType(PieChart)).dy;

    await tester.tap(find.text('Eating out'));
    await tester.pumpAndSettle();
    expect(find.text('Filtering: Eating out'), findsOneWidget);
    expect(tester.getTopLeft(find.byType(PieChart)).dy, top);

    await tester.tap(find.text('Filtering: Eating out'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(PieChart)).dy, top);
  });

  testWidgets('clicking a tag under a category switches to Tag mode', (
    tester,
  ) async {
    await pumpBreakdown(tester);

    await tester.tap(find.text('Eating out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('thai'));
    await tester.pumpAndSettle();

    expect(find.text('Filtering: thai'), findsOneWidget);
    // And it opens on the money that legend row was showing. thai never leads
    // a tag list here, so a primary-tag-only bucket left this drill on an
    // empty "$0.00" chart one click after a "$30.00" row.
    expect(find.text('Nothing left in this bucket.'), findsNothing);
    expect(find.text(r'$30.00'), findsWidgets);

    final grouping = tester.widget<SegmentedButton<FinanceBreakdownMode>>(
      find.byType(SegmentedButton<FinanceBreakdownMode>),
    );
    expect(grouping.selected, {
      FinanceBreakdownMode.tag,
    }, reason: 'the Tag segment is selected');
  });

  testWidgets('switching Category to Tag drops the focus', (tester) async {
    await pumpBreakdown(tester);

    await tester.tap(find.text('Eating out'));
    await tester.pumpAndSettle();
    expect(find.text('Filtering: Eating out'), findsOneWidget);

    await tester.tap(find.text('Tag'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Filtering:'), findsNothing);
    // The unfocused tag chart: one bucket per primary tag.
    expect(find.text('food'), findsOneWidget);
    expect(find.text('rent'), findsOneWidget);
  });

  testWidgets('Store mode drops the focus and does not drill down', (
    tester,
  ) async {
    await pumpBreakdown(tester);

    await tester.tap(find.text('Eating out'));
    await tester.pumpAndSettle();
    expect(find.text('Filtering: Eating out'), findsOneWidget);

    await tester.tap(find.text('Store'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Filtering:'), findsNothing);
    // None of the seeded expenses names a store.
    expect(find.text(kNoStoreLabel), findsOneWidget);

    await tester.tap(find.text(kNoStoreLabel));
    await tester.pumpAndSettle();
    expect(find.textContaining('Filtering:'), findsNothing);
  });

  testWidgets('the title dropdown swaps in Income by Source and remembers it', (
    tester,
  ) async {
    final store = MemoryFinanceUiPrefsStore();
    await pumpBreakdown(tester, prefsStore: store);

    await tester.tap(find.text('Eating out'));
    await tester.pumpAndSettle();
    expect(find.text('Filtering: Eating out'), findsOneWidget);

    await tester.tap(find.text('Spending Breakdown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Income by Source'));
    await tester.pumpAndSettle();

    // One card, now showing income — and this month has none.
    expect(find.text('Spending Breakdown'), findsNothing);
    expect(find.text('No income recorded this month.'), findsOneWidget);
    expect(find.byType(SegmentedButton<FinanceBreakdownMode>), findsNothing);
    expect(find.byTooltip('Manage categories'), findsNothing);
    expect(store.prefs.breakdownChart, FinanceBreakdownChart.income);

    await tester.tap(find.text('Income by Source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spending Breakdown'));
    await tester.pumpAndSettle();

    expect(find.text('No income recorded this month.'), findsNothing);
    expect(
      find.textContaining('Filtering:'),
      findsNothing,
      reason: 'the drill-down does not wait behind the income chart',
    );
    expect(store.prefs.breakdownChart, FinanceBreakdownChart.spending);
  });

  testWidgets('switching charts leaves the pie where it was', (tester) async {
    await pumpBreakdown(tester, withIncome: true);

    // The month label moved with it: in Spending it shares a row with the
    // Category/Tag/Store control, in Income it stands alone.
    final month = find.text(DateFormat.yMMMM().format(DateTime.now()));
    Offset pieTopLeft() => tester.getTopLeft(find.byType(PieChart));

    final spendingPie = pieTopLeft();
    final spendingMonth = tester.getTopLeft(month);
    await tester.tap(find.text('Spending Breakdown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Income by Source'));
    await tester.pumpAndSettle();
    expect(find.text('Employer'), findsOneWidget);

    expect(pieTopLeft(), spendingPie);
    expect(tester.getTopLeft(month), spendingMonth);
  });

  testWidgets('switching charts morphs the pie rather than rebuilding it', (
    tester,
  ) async {
    await pumpBreakdown(tester, withIncome: true);

    // fl_chart only tweens between slice sets on a kept State; a new one
    // snaps straight to the new slices, as the income switch used to.
    State pie() => tester.state(find.byType(PieChart));
    final spendingPie = pie();

    await tester.tap(find.text('Spending Breakdown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Income by Source'));
    await tester.pumpAndSettle();
    expect(find.text('Employer'), findsOneWidget);
    expect(pie(), same(spendingPie));

    await tester.tap(find.text('Income by Source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spending Breakdown'));
    await tester.pumpAndSettle();
    expect(find.text('Employer'), findsNothing);
    expect(pie(), same(spendingPie));
  });

  testWidgets('the analytics page opens on the chart left showing', (
    tester,
  ) async {
    final store = MemoryFinanceUiPrefsStore()
      ..prefs = const FinanceUiPrefs(
        viewMode: FinanceViewMode.analytics,
        breakdownChart: FinanceBreakdownChart.income,
      );
    await pumpBreakdown(tester, prefsStore: store);

    expect(find.text('Income by Source'), findsOneWidget);
    expect(find.text('No income recorded this month.'), findsOneWidget);
    expect(find.text('Spending Breakdown'), findsNothing);
  });

  testWidgets('a tag drill-down splits the bucket without double-counting', (
    tester,
  ) async {
    await pumpBreakdown(tester);

    await tester.tap(find.text('Tag'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('food'));
    await tester.pumpAndSettle();

    expect(find.text('Filtering: food'), findsOneWidget);
    // $10 carried food alone, $30 carried thai as well — and they add to the
    // $40 in the centre.
    expect(find.text(r'$10.00'), findsOneWidget);
    expect(find.text(r'$30.00'), findsOneWidget);
    expect(find.text(r'$40.00'), findsWidgets);
  });

  // The pie's touched index is kept in State, and a drill-down that leaves the
  // filter line on screen keeps that State: the child list lines up, so the
  // element is reused and the index outlives the slices it was taken against.
  _platformWidgets(
    'drilling deeper on the pie survives a smaller bucket',
    TargetPlatform.windows,
    (tester) async {
      await pumpDeepBreakdown(tester);

      expect(find.text('Filtering: a'), findsOneWidget);
      // Slice 2 of three, whose own bucket holds a single slice.
      await tapSlice(tester, const [30000, 20000, 10000], 2);

      expect(tester.takeException(), isNull);
      expect(find.text('Filtering: b'), findsOneWidget);
      expect(find.text(r'$10.00'), findsWidgets);
    },
  );

  // fl_chart reports a tap-up as "uninteresting" everywhere but desktop and
  // web, so a click read out of the highlight state did nothing on a phone.
  _platformWidgets(
    'a pie slice is clickable off desktop too',
    TargetPlatform.android,
    (tester) async {
      await pumpDeepBreakdown(tester);

      await tapSlice(tester, const [30000, 20000, 10000], 0);

      expect(find.text('Filtering: d'), findsOneWidget);
    },
  );
}
