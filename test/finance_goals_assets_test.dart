// Fixes from the Phase 14–15 finance pass: the narrow layout puts the radar
// and budgets above the ledger (BUG-121), Tab skips the subscription sheet's
// Billing dropdown (BUG-122), a goal can't be overdrawn and shows a negative
// balance with its sign (BUG-125), a goal's allocations are listed, editable
// and deletable and a post-dated one waits for its day (BUG-126), deleting a
// goal offers Undo (BUG-127), contribution rows are left out of income and
// spending (BUG-128), a post-dated valuation isn't today's value (BUG-129),
// and an asset's valuations are listed and deletable (BUG-130).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/features/finance/finance_allocate_modal.dart';
import 'package:voyager/features/finance/finance_asset_modal.dart';
import 'package:voyager/features/finance/finance_goal_modal.dart';
import 'package:voyager/features/finance/finance_page.dart';
import 'package:voyager/features/finance/finance_subscription_modal.dart';

import 'fakes/fake_weather_api_client.dart';

DateTime get _today {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

FinancialTransaction _tx(
  String id,
  TransactionType type,
  int cents, {
  String? roomEventId,
  List<String> tags = const [],
}) {
  final now = utcNow();
  return FinancialTransaction(
    id: id,
    createdAt: now,
    updatedAt: now,
    type: type,
    amountCents: cents,
    occurredAt: _today.add(const Duration(hours: 9)),
    tags: tags,
    roomEventId: roomEventId,
  );
}

SavingsGoal _goal() {
  final now = utcNow();
  return SavingsGoal(
    id: 'g1',
    createdAt: now,
    updatedAt: now,
    name: 'Trip',
    targetCents: 200000,
  );
}

GoalAllocation _allocation(String id, int cents, {DateTime? at, String? note}) {
  final now = utcNow();
  return GoalAllocation(
    id: id,
    createdAt: now,
    updatedAt: now,
    goalId: 'g1',
    amountCents: cents,
    allocatedAt: at ?? _today,
    note: note,
  );
}

Asset _asset() {
  final now = utcNow();
  return Asset(id: 'a1', createdAt: now, updatedAt: now, name: 'TFSA A');
}

AssetValuation _valuation(String id, int cents, DateTime asOf) {
  final now = utcNow();
  return AssetValuation(
    id: id,
    createdAt: now,
    updatedAt: now,
    assetId: 'a1',
    valueCents: cents,
    asOf: asOf,
  );
}

/// Pumps [home] over an in-memory database seeded through [seed], and returns
/// the repository for checking what was written.
Future<DriftFinanceRepository> _pump(
  WidgetTester tester, {
  required Future<void> Function(DriftFinanceRepository repo) seed,
  required Widget Function() home,
  Size size = const Size(1200, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftFinanceRepository(db);
  await seed(repo);

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  await container.read(transactionsProvider.future);
  await container.read(goalAllocationsProvider.future);
  await container.read(assetValuationsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: home())),
    ),
  );
  await _settle(tester);
  return repo;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// A button that opens a sheet through [open], for [_pump]'s `home`.
Widget _opener(void Function(BuildContext context, WidgetRef ref) open) =>
    Consumer(
      builder: (context, ref, _) => TextButton(
        onPressed: () => open(context, ref),
        child: const Text('open'),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await _settle(tester);
}

Finder _field(int index) => find.byType(EditableText).at(index);

bool _hasFocus(WidgetTester tester, int index) =>
    tester.widget<EditableText>(_field(index)).focusNode.hasFocus;

String _text(WidgetTester tester, int index) =>
    tester.widget<EditableText>(_field(index)).controller.text;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('BUG-121 the narrow ledger has the radar and budgets on top', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(720, 1000),
      seed: (repo) async {
        for (var i = 0; i < 60; i++) {
          await repo.upsertTransaction(
            _tx('t$i', TransactionType.expense, 100 + i),
          );
        }
      },
      home: () => const FinancePage(),
    );

    expect(find.text('Subscription & Bill Radar'), findsOneWidget);
    expect(find.text('Budgets & Pacing'), findsOneWidget);
  });

  testWidgets('BUG-122 Tab goes from Amount to Store, past Billing', (
    tester,
  ) async {
    await _pump(
      tester,
      seed: (_) async {},
      home: () =>
          _opener((context, ref) => showSubscriptionModal(context, ref)),
    );
    await _open(tester);

    await tester.tap(_field(1));
    await tester.pump();
    expect(_hasFocus(tester, 1), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    // Name, Amount, Store, Note.
    expect(_hasFocus(tester, 2), isTrue);
  });

  testWidgets('BUG-125 a withdrawal beyond the balance is refused', (
    tester,
  ) async {
    final goal = _goal();
    final repo = await _pump(
      tester,
      seed: (repo) async {
        await repo.upsertSavingsGoal(goal);
        await repo.upsertGoalAllocation(_allocation('al1', 50000));
      },
      home: () => _opener(
        (context, ref) => showAllocateModal(context, ref, goal: goal),
      ),
    );
    await _open(tester);

    await tester.tap(find.text('Withdraw'));
    await tester.pump();
    await tester.enterText(_field(0), '600');
    await tester.pump();
    expect(find.text(r'This goal holds $500.00'), findsOneWidget);
    await tester.tap(find.text('Withdraw').last);
    await _settle(tester);
    expect((await repo.listGoalAllocations()).length, 1);

    await tester.enterText(_field(0), '500');
    await tester.pump();
    expect(find.text(r'This goal holds $500.00'), findsNothing);
  });

  testWidgets('BUG-125 a withdrawal is checked against later days too', (
    tester,
  ) async {
    final goal = _goal();
    final nextWeek = _today.add(const Duration(days: 7));
    await _pump(
      tester,
      seed: (repo) async {
        await repo.upsertSavingsGoal(goal);
        await repo.upsertGoalAllocation(_allocation('al1', 10000));
        await repo.upsertGoalAllocation(
          _allocation('al2', -10000, at: nextWeek),
        );
      },
      home: () => _opener(
        (context, ref) => showAllocateModal(context, ref, goal: goal),
      ),
    );
    await _open(tester);

    await tester.tap(find.text('Withdraw'));
    await tester.pump();
    await tester.enterText(_field(0), '100');
    await tester.pump();
    // Today it holds $100.00; next week's withdrawal would take it below $0.
    expect(
      find.textContaining(r'That leaves this goal at -$100.00 on'),
      findsOneWidget,
    );
  });

  testWidgets('BUG-125 a post-dated withdrawal can use a deposit that day', (
    tester,
  ) async {
    final goal = _goal();
    final nextWeek = _today.add(const Duration(days: 7));
    final withdrawal = _allocation('al2', -5000, at: nextWeek);
    await _pump(
      tester,
      seed: (repo) async {
        await repo.upsertSavingsGoal(goal);
        await repo.upsertGoalAllocation(
          _allocation('al1', 20000, at: nextWeek),
        );
        await repo.upsertGoalAllocation(withdrawal);
      },
      home: () => _opener(
        (context, ref) =>
            showAllocateModal(context, ref, goal: goal, existing: withdrawal),
      ),
    );
    await _open(tester);

    expect(_text(tester, 0), '50.00');
    expect(find.textContaining('This goal holds'), findsNothing);
    expect(find.textContaining('That leaves'), findsNothing);
  });

  test('BUG-126 a post-dated allocation waits for its day', () {
    final allocations = [
      _allocation('al1', 50000),
      _allocation('al2', 10000, at: _today.add(const Duration(days: 3))),
    ];
    expect(goalAllocatedCents(allocations, 'g1', asOf: DateTime.now()), 50000);
    expect(goalAllocatedCents(allocations, 'g1'), 60000);
  });

  testWidgets(
    'BUG-126 the goal sheet lists allocations; one can be edited and deleted',
    (tester) async {
      final goal = _goal();
      final repo = await _pump(
        tester,
        seed: (repo) async {
          await repo.upsertSavingsGoal(goal);
          await repo.upsertGoalAllocation(
            _allocation('al1', 50000, note: 'From October paycheck'),
          );
          await repo.upsertGoalAllocation(
            _allocation('al2', 10000, at: _today.add(const Duration(days: 3))),
          );
        },
        home: () => _opener(
          (context, ref) => showGoalModal(context, ref, existing: goal),
        ),
      );
      await _open(tester);

      expect(find.textContaining('From October paycheck'), findsOneWidget);
      expect(find.textContaining('Upcoming'), findsOneWidget);
      expect(find.text(r'+$500.00'), findsOneWidget);

      // Edit: the same row, a new amount.
      await tester.tap(find.text(r'+$500.00'));
      await _settle(tester);
      final amount = find.byType(EditableText).at(3);
      expect(tester.widget<EditableText>(amount).controller.text, '500.00');
      await tester.enterText(amount, '450');
      await tester.tap(find.text('Save').last);
      await _settle(tester);
      final edited = (await repo.listGoalAllocations()).firstWhere(
        (a) => a.id == 'al1',
      );
      expect(edited.amountCents, 45000);
      expect(edited.note, 'From October paycheck');

      // Delete and Undo.
      await tester.tap(find.byTooltip('Delete').last);
      await _settle(tester);
      expect((await repo.listGoalAllocations()).map((a) => a.id), ['al2']);
      await tester.tap(find.text('Undo'));
      await _settle(tester);
      expect((await repo.listGoalAllocations()).length, 2);
    },
  );

  testWidgets('BUG-127 deleting a goal offers Undo, which restores it all', (
    tester,
  ) async {
    final goal = _goal();
    final repo = await _pump(
      tester,
      seed: (repo) async {
        await repo.upsertSavingsGoal(goal);
        await repo.upsertGoalAllocation(_allocation('al1', 50000));
        await repo.upsertGoalAllocation(_allocation('gone', 700));
        await repo.softDeleteGoalAllocation('gone');
      },
      home: () => _opener(
        (context, ref) => showGoalModal(context, ref, existing: goal),
      ),
    );
    await _open(tester);

    await tester.tap(find.byTooltip('Delete').first);
    await _settle(tester);
    expect(find.text('Deleted "Trip"'), findsOneWidget);
    expect(await repo.listSavingsGoals(), isEmpty);
    expect(await repo.listGoalAllocations(), isEmpty);

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    expect((await repo.listSavingsGoals()).single.name, 'Trip');
    // The one deleted on its own before stays deleted.
    expect((await repo.listGoalAllocations()).map((a) => a.id), ['al1']);
  });

  test(
    'BUG-128 contribution rows count toward cash, not income or spending',
    () {
      final transactions = [
        _tx('pay', TransactionType.deposit, 100000),
        _tx('food', TransactionType.expense, 2000, tags: ['food']),
        // A $300 contribution and a $100 withdrawal.
        _tx(
          'in',
          TransactionType.expense,
          30000,
          roomEventId: 'e1',
          tags: ['food'],
        ),
        _tx('out', TransactionType.deposit, 10000, roomEventId: 'e2'),
      ];
      final today = DateTime.now();

      expect(monthToDateNet(transactions, today), 98000);
      final day = dailyNetSeries(transactions, from: _today, to: _today).single;
      expect(day.incomeCents, 100000);
      expect(day.expenseCents, 2000);
      expect(budgetSpentCents(transactions, 'food', today), 2000);
      final slices = spendingBreakdown(
        transactions,
        from: _today,
        to: _today.add(const Duration(days: 1)),
        categories: const [],
        tagColors: const {},
        groupByCategory: false,
      );
      expect(slices.fold<int>(0, (s, x) => s + x.amountCents), 2000);
      // Cash is what moved: +1,000 − 20 − 300 + 100.
      expect(
        netWorthSeries(
          transactions,
          const [],
          const [],
          months: 1,
        ).last.cashCents,
        78000,
      );
    },
  );

  testWidgets(
    "BUG-129 the sheet seeds today's value and a note edit writes none",
    (tester) async {
      final asset = _asset();
      final repo = await _pump(
        tester,
        seed: (repo) async {
          await repo.upsertAsset(asset);
          await repo.upsertAssetValuation(_valuation('v1', 1175000, _today));
          await repo.upsertAssetValuation(
            _valuation('v2', 1575000, _today.add(const Duration(days: 14))),
          );
        },
        home: () => _opener(
          (context, ref) => showAssetModal(context, ref, existing: asset),
        ),
      );
      await _open(tester);
      await _settle(tester);

      expect(_text(tester, 1), '11750.00');
      await tester.enterText(_field(2), 'x');
      await tester.tap(find.text('Save'));
      await _settle(tester);

      final today = (await repo.listAssetValuations(
        assetId: 'a1',
      )).firstWhere((v) => v.id == 'v1');
      expect(today.valueCents, 1175000);
      expect(today.version, 0);
    },
  );

  testWidgets('BUG-129 an old figure saved as it is is recorded for today', (
    tester,
  ) async {
    final asset = _asset();
    final repo = await _pump(
      tester,
      seed: (repo) async {
        await repo.upsertAsset(asset);
        await repo.upsertAssetValuation(
          _valuation('v1', 1000000, _today.subtract(const Duration(days: 90))),
        );
      },
      home: () => _opener(
        (context, ref) => showAssetModal(context, ref, existing: asset),
      ),
    );
    await _open(tester);
    await _settle(tester);

    expect(_text(tester, 1), '10000.00');
    await tester.tap(find.text('Save'));
    await _settle(tester);

    final valuations = await repo.listAssetValuations(assetId: 'a1');
    expect(valuations.length, 2);
    expect(
      valuations.where((v) => v.asOf == _today).single.valueCents,
      1000000,
    );
  });

  testWidgets('BUG-130 the asset sheet lists valuations; one can be deleted', (
    tester,
  ) async {
    final asset = _asset();
    final repo = await _pump(
      tester,
      seed: (repo) async {
        await repo.upsertAsset(asset);
        await repo.upsertAssetValuation(
          _valuation('v1', 30000, _today.subtract(const Duration(days: 30))),
        );
        await repo.upsertAssetValuation(_valuation('v2', 950000, _today));
      },
      home: () => _opener(
        (context, ref) => showAssetModal(context, ref, existing: asset),
      ),
    );
    await _open(tester);

    expect(find.text(r'$300.00'), findsOneWidget);
    expect(find.text(r'$9,500.00'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete').last);
    await _settle(tester);
    expect((await repo.listAssetValuations(assetId: 'a1')).map((v) => v.id), [
      'v2',
    ]);
    expect(find.text(r'$300.00'), findsNothing);

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    expect((await repo.listAssetValuations(assetId: 'a1')).length, 2);
  });
}
