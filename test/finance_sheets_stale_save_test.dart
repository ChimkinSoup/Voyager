// The finance edit sheets saved the whole row from the copy they opened with,
// so a change another device made while one was open was reverted on Save
// (BUG-233). Each now applies only the fields edited in it; the transaction
// sheet's case is in finance_transaction_stale_save_test.dart.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/finance/finance_allocate_modal.dart';
import 'package:voyager/features/finance/finance_asset_modal.dart';
import 'package:voyager/features/finance/finance_budget_modal.dart';
import 'package:voyager/features/finance/finance_category_modal.dart';
import 'package:voyager/features/finance/finance_contribution_room_modal.dart';
import 'package:voyager/features/finance/finance_goal_modal.dart';
import 'package:voyager/features/finance/finance_subscription_modal.dart';

import 'fakes/fake_weather_api_client.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Finder _fieldHolding(String text) => find.byWidgetPredicate(
  (w) => w is EditableText && w.controller.text == text,
);

final _now = utcNow();

/// Opens a sheet with [open] over [seed], lets [elsewhere] change the row as
/// another device's pull would, retypes the field holding [from] as [to] and
/// saves.
Future<FinanceRepository> _editWhileChanged(
  WidgetTester tester, {
  required Future<void> Function(FinanceRepository repo) seed,
  required void Function(BuildContext context, WidgetRef ref) open,
  required Future<void> Function(FinanceRepository repo) elsewhere,
  required String from,
  required String to,
}) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  final repo = container.read(financeRepositoryProvider);
  await seed(repo);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => open(context, ref),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
  expect(_fieldHolding(from), findsOneWidget);

  await elsewhere(repo);

  await tester.enterText(_fieldHolding(from), to);
  await tester.pump();
  await tester.tap(find.text('Save').last);
  await _settle(tester);
  return repo;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final goal = SavingsGoal(
    id: 'goal',
    createdAt: _now,
    updatedAt: _now,
    version: 1,
    name: 'Trip',
    targetCents: 10000,
    note: 'Old note',
  );

  testWidgets('goal: a rename keeps a target and note changed elsewhere', (
    tester,
  ) async {
    final repo = await _editWhileChanged(
      tester,
      seed: (repo) => repo.upsertSavingsGoal(goal),
      open: (context, ref) => showGoalModal(context, ref, existing: goal),
      elsewhere: (repo) => repo.upsertSavingsGoal(
        goal.copyWith(targetCents: 5000, note: 'Changed elsewhere', version: 2),
      ),
      from: 'Trip',
      to: 'Trip 2',
    );
    final stored = (await repo.listSavingsGoals()).single;
    expect(stored.name, 'Trip 2');
    expect(stored.targetCents, 5000);
    expect(stored.note, 'Changed elsewhere');
  });

  testWidgets('asset: a rename keeps a note changed elsewhere', (
    tester,
  ) async {
    final asset = Asset(
      id: 'asset',
      createdAt: _now,
      updatedAt: _now,
      version: 1,
      name: 'Brokerage',
      note: 'Old note',
    );
    final repo = await _editWhileChanged(
      tester,
      seed: (repo) => repo.upsertAsset(asset),
      open: (context, ref) => showAssetModal(context, ref, existing: asset),
      elsewhere: (repo) => repo.upsertAsset(
        asset.copyWith(note: 'Changed elsewhere', version: 2),
      ),
      from: 'Brokerage',
      to: 'Broker',
    );
    final stored = (await repo.listAssets()).single;
    expect(stored.name, 'Broker');
    expect(stored.note, 'Changed elsewhere');
  });

  testWidgets('subscription: a store edit keeps a name and amount changed '
      'elsewhere', (tester) async {
    final subscription = Subscription(
      id: 'sub',
      createdAt: _now,
      updatedAt: _now,
      version: 1,
      name: 'Stream',
      amountCents: 1500,
      period: BillingPeriod.monthly,
      anchorDueDate: DateTime(2026, 10, 1),
      store: 'Old store',
    );
    final repo = await _editWhileChanged(
      tester,
      seed: (repo) => repo.upsertSubscription(subscription),
      open: (context, ref) =>
          showSubscriptionModal(context, ref, existing: subscription),
      elsewhere: (repo) => repo.upsertSubscription(
        subscription.copyWith(name: 'Stream HD', amountCents: 1999, version: 2),
      ),
      from: 'Old store',
      to: 'Shop',
    );
    final stored = (await repo.getSubscription('sub'))!;
    expect(stored.store, 'Shop');
    expect(stored.name, 'Stream HD');
    expect(stored.amountCents, 1999);
  });

  testWidgets('budget: a limit edit keeps a tag changed elsewhere', (
    tester,
  ) async {
    final budget = Budget(
      id: 'budget',
      createdAt: _now,
      updatedAt: _now,
      version: 1,
      tag: 'food',
      limitCents: 10000,
    );
    final repo = await _editWhileChanged(
      tester,
      seed: (repo) => repo.upsertBudget(budget),
      open: (context, ref) => showBudgetModal(context, ref, existing: budget),
      elsewhere: (repo) =>
          repo.upsertBudget(budget.copyWith(tag: 'groceries', version: 2)),
      from: '100.00',
      to: '250.00',
    );
    final stored = (await repo.listBudgets()).single;
    expect(stored.limitCents, 25000);
    expect(stored.tag, 'groceries');
    // Versioned off the row on disk, not the copy the sheet opened with.
    expect(stored.version, 3);
  });

  testWidgets('category: a rename keeps tags changed elsewhere', (
    tester,
  ) async {
    final category = FinanceCategory(
      id: 'cat',
      createdAt: _now,
      updatedAt: _now,
      version: 1,
      name: 'Food',
      tags: const ['food'],
    );
    final repo = await _editWhileChanged(
      tester,
      seed: (repo) => repo.upsertCategory(category),
      open: (context, ref) =>
          showCategoryModal(context, ref, existing: category),
      elsewhere: (repo) => repo.upsertCategory(
        category.copyWith(tags: const ['dining', 'food'], version: 2),
      ),
      from: 'Food',
      to: 'Eats',
    );
    final stored = (await repo.listCategories()).single;
    expect(stored.name, 'Eats');
    expect(stored.tags, ['dining', 'food']);
  });

  testWidgets('allocation: a note edit keeps an amount changed elsewhere', (
    tester,
  ) async {
    final allocation = GoalAllocation(
      id: 'alloc',
      createdAt: _now,
      updatedAt: _now,
      version: 1,
      goalId: goal.id,
      amountCents: 1000,
      allocatedAt: DateTime(2026, 10, 1),
      note: 'Old note',
    );
    final repo = await _editWhileChanged(
      tester,
      seed: (repo) async {
        await repo.upsertSavingsGoal(goal);
        await repo.upsertGoalAllocation(allocation);
      },
      open: (context, ref) =>
          showAllocateModal(context, ref, goal: goal, existing: allocation),
      elsewhere: (repo) => repo.upsertGoalAllocation(
        allocation.copyWith(amountCents: 3000, version: 2),
      ),
      from: 'Old note',
      to: 'New note',
    );
    final stored = (await repo.listGoalAllocations(goalId: goal.id)).single;
    expect(stored.note, 'New note');
    expect(stored.amountCents, 3000);
  });

  testWidgets('contribution room: a limit edit keeps a name changed '
      'elsewhere', (tester) async {
    final year = DateTime.now().year;
    final room = ContributionRoom(
      id: 'room',
      createdAt: _now,
      updatedAt: _now,
      version: 1,
      name: 'TFSA',
      baselineRemainingCents: 500000,
      baselineAsOf: _now,
      annualLimits: [AnnualLimit(fromYear: year, cents: 700000)],
    );
    final asset = Asset(
      id: 'asset',
      createdAt: _now,
      updatedAt: _now,
      name: 'TFSA A',
      contributionRoomId: room.id,
    );
    final repo = await _editWhileChanged(
      tester,
      seed: (repo) async {
        await repo.upsertContributionRoom(room);
        await repo.upsertAsset(asset);
      },
      open: (context, ref) =>
          showContributionRoomModal(context, ref, asset: asset),
      elsewhere: (repo) => repo.upsertContributionRoom(
        room.copyWith(name: 'TFSA joint', version: 2),
      ),
      from: '7000.00',
      to: '8000.00',
    );
    final stored = (await repo.listContributionRooms()).single;
    expect(stored.name, 'TFSA joint');
    expect(stored.annualLimitFor(year), 800000);
  });
}
