import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';

void main() {
  late AppDatabase db;
  late DriftFinanceRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = DriftFinanceRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  FinancialTransaction make({
    required TransactionType type,
    required int amountCents,
    required DateTime occurredAt,
    List<String> tags = const [],
    String? note,
    String? id,
  }) {
    final now = utcNow();
    return FinancialTransaction(
      id: id ?? newId(),
      createdAt: now,
      updatedAt: now,
      type: type,
      amountCents: amountCents,
      occurredAt: occurredAt,
      tags: tags,
      note: note,
    );
  }

  test('persists and lists transactions newest-first', () async {
    final older = make(
      type: TransactionType.expense,
      amountCents: 1500,
      occurredAt: DateTime(2026, 7, 10),
    );
    final newer = make(
      type: TransactionType.deposit,
      amountCents: 20000,
      occurredAt: DateTime(2026, 7, 15),
    );
    await repo.upsertTransaction(older);
    await repo.upsertTransaction(newer);

    final list = await repo.listTransactions();
    expect(list, hasLength(2));
    expect(list.first.id, newer.id, reason: 'newest occurredAt comes first');
    expect(list.last.id, older.id);
  });

  test('round-trips tags, note and type', () async {
    final tx = make(
      type: TransactionType.expense,
      amountCents: 4299,
      occurredAt: DateTime(2026, 7, 15),
      tags: ['groceries', 'travel'],
      note: 'Dinner with friends',
    );
    await repo.upsertTransaction(tx);

    final loaded = (await repo.listTransactions()).single;
    expect(loaded.type, TransactionType.expense);
    expect(loaded.amountCents, 4299);
    expect(loaded.tags, ['groceries', 'travel']);
    expect(loaded.note, 'Dinner with friends');
    expect(loaded.signedCents, -4299);
  });

  test('soft delete hides from default listing but tombstone remains', () async {
    final tx = make(
      type: TransactionType.deposit,
      amountCents: 500,
      occurredAt: DateTime(2026, 7, 15),
    );
    await repo.upsertTransaction(tx);
    await repo.softDeleteTransaction(tx.id);

    expect(await repo.listTransactions(), isEmpty);
    final withDeleted = await repo.listTransactions(includeDeleted: true);
    expect(withDeleted, hasLength(1));
    expect(withDeleted.single.deletedAt, isNotNull);
  });

  test('purge removes tombstones past the retention window', () async {
    final tx = make(
      type: TransactionType.expense,
      amountCents: 999,
      occurredAt: DateTime(2026, 7, 15),
    );
    await repo.upsertTransaction(tx);
    await repo.softDeleteTransaction(tx.id);

    // Not yet expired.
    await repo.purgeExpiredDeleted(utcNow());
    expect(await repo.listTransactions(includeDeleted: true), hasLength(1));

    // Past the retention window.
    final future =
        utcNow().add(Duration(days: softDeleteRetentionDays + 1));
    await repo.purgeExpiredDeleted(future);
    expect(await repo.listTransactions(includeDeleted: true), isEmpty);
  });

  test('signedCents reflects deposit vs expense direction', () {
    final deposit = make(
      type: TransactionType.deposit,
      amountCents: 1000,
      occurredAt: DateTime(2026, 7, 15),
    );
    final expense = make(
      type: TransactionType.expense,
      amountCents: 1000,
      occurredAt: DateTime(2026, 7, 15),
    );
    expect(deposit.signedCents, 1000);
    expect(expense.signedCents, -1000);
  });

  test('formatCents renders currency with optional sign', () {
    expect(formatCents(1250), r'$12.50');
    expect(formatCents(1250, signed: true), r'+$12.50');
    expect(formatCents(-1250, signed: true), r'-$12.50');
    expect(formatCents(0, signed: true), r'+$0.00');
  });

  // -- Subscriptions -------------------------------------------------------

  Subscription makeSub({
    required int amountCents,
    required BillingPeriod period,
    required DateTime anchorDueDate,
    String name = 'Sub',
    String? id,
  }) {
    final now = utcNow();
    return Subscription(
      id: id ?? newId(),
      createdAt: now,
      updatedAt: now,
      name: name,
      amountCents: amountCents,
      period: period,
      anchorDueDate: anchorDueDate,
    );
  }

  test('subscriptions list soonest-due first', () async {
    final soon = makeSub(
      amountCents: 500,
      period: BillingPeriod.monthly,
      anchorDueDate: DateTime.now().add(const Duration(days: 2)),
      name: 'Soon',
    );
    final later = makeSub(
      amountCents: 500,
      period: BillingPeriod.monthly,
      anchorDueDate: DateTime.now().add(const Duration(days: 20)),
      name: 'Later',
    );
    await repo.upsertSubscription(later);
    await repo.upsertSubscription(soon);

    final list = await repo.listSubscriptions();
    expect(list.map((s) => s.name), ['Soon', 'Later']);
  });

  test('subscription round-trips period, color and anchor', () async {
    final sub = makeSub(
      amountCents: 1500,
      period: BillingPeriod.monthly,
      anchorDueDate: DateTime(2026, 7, 15),
    );
    await repo.upsertSubscription(sub);
    final loaded = (await repo.listSubscriptions()).single;
    expect(loaded.period, BillingPeriod.monthly);
    expect(loaded.amountCents, 1500);
    expect(loaded.anchorDueDate, DateTime(2026, 7, 15));
  });

  test('soft delete + purge tombstones subscriptions', () async {
    final sub = makeSub(
      amountCents: 999,
      period: BillingPeriod.yearly,
      anchorDueDate: DateTime(2026, 1, 1),
    );
    await repo.upsertSubscription(sub);
    await repo.softDeleteSubscription(sub.id);
    expect(await repo.listSubscriptions(), isEmpty);
    expect(await repo.listSubscriptions(includeDeleted: true), hasLength(1));

    final future = utcNow().add(Duration(days: softDeleteRetentionDays + 1));
    await repo.purgeExpiredDeleted(future);
    expect(await repo.listSubscriptions(includeDeleted: true), isEmpty);
  });

  test('annualized cost scales by cadence', () {
    expect(annualCentsFor(1500, BillingPeriod.monthly), 18000);
    expect(annualCentsFor(1500, BillingPeriod.yearly), 1500);
    expect(annualCentsFor(1000, BillingPeriod.weekly), 52000);
    expect(annualCentsFor(1000, BillingPeriod.quarterly), 4000);
  });

  test('nextDueDate rolls a monthly bill forward, clamping month-end', () {
    // Anchored on the 31st; February has no 31st, so it clamps to Feb 28.
    final due = nextDueDate(
      DateTime(2026, 1, 31),
      BillingPeriod.monthly,
      DateTime(2026, 2, 15),
    );
    expect(due, DateTime(2026, 2, 28));
  });

  test('nextDueDate rolls a weekly bill forward from a past anchor', () {
    final due = nextDueDate(
      DateTime(2026, 7, 1),
      BillingPeriod.weekly,
      DateTime(2026, 7, 18),
    );
    expect(due, DateTime(2026, 7, 22));
  });

  test('nextDueDate returns a future anchor unchanged', () {
    final anchor = DateTime.now().add(const Duration(days: 5));
    final expected = DateTime(anchor.year, anchor.month, anchor.day);
    final due = nextDueDate(anchor, BillingPeriod.monthly, DateTime.now());
    expect(due, expected);
  });

  // -- Budgets -------------------------------------------------------------

  Budget makeBudget({
    required String tag,
    required int limitCents,
    String? id,
  }) {
    final now = utcNow();
    return Budget(
      id: id ?? newId(),
      createdAt: now,
      updatedAt: now,
      tag: tag,
      limitCents: limitCents,
    );
  }

  test('budgets persist, list alphabetically, and soft delete + purge',
      () async {
    await repo.upsertBudget(makeBudget(tag: 'travel', limitCents: 50000));
    final dining = makeBudget(tag: 'dining_out', limitCents: 20000);
    await repo.upsertBudget(dining);

    final list = await repo.listBudgets();
    expect(list.map((b) => b.tag), ['dining_out', 'travel']);

    await repo.softDeleteBudget(dining.id);
    expect((await repo.listBudgets()).map((b) => b.tag), ['travel']);
    expect(await repo.listBudgets(includeDeleted: true), hasLength(2));

    final future = utcNow().add(Duration(days: softDeleteRetentionDays + 1));
    await repo.purgeExpiredDeleted(future);
    expect(await repo.listBudgets(includeDeleted: true), hasLength(1));
  });

  test('budget spend counts only tagged expenses in the given month', () {
    final month = DateTime(2026, 7, 15);
    final transactions = [
      // Counts.
      make(
        type: TransactionType.expense,
        amountCents: 3000,
        occurredAt: DateTime(2026, 7, 2),
        tags: ['dining_out'],
      ),
      // Counts (multi-tag transactions count in full toward each tag).
      make(
        type: TransactionType.expense,
        amountCents: 1000,
        occurredAt: DateTime(2026, 7, 20),
        tags: ['dining_out', 'travel'],
      ),
      // Excluded: deposit.
      make(
        type: TransactionType.deposit,
        amountCents: 9999,
        occurredAt: DateTime(2026, 7, 5),
        tags: ['dining_out'],
      ),
      // Excluded: different month.
      make(
        type: TransactionType.expense,
        amountCents: 8888,
        occurredAt: DateTime(2026, 6, 30),
        tags: ['dining_out'],
      ),
      // Excluded: different tag.
      make(
        type: TransactionType.expense,
        amountCents: 7777,
        occurredAt: DateTime(2026, 7, 8),
        tags: ['groceries'],
      ),
      // Excluded: untagged.
      make(
        type: TransactionType.expense,
        amountCents: 6666,
        occurredAt: DateTime(2026, 7, 9),
      ),
    ];

    expect(budgetSpentCents(transactions, 'dining_out', month), 4000);
    expect(budgetSpentCents(transactions, 'travel', month), 1000);
    expect(budgetSpentCents(transactions, 'unused', month), 0);
  });

  test('monthPaceFraction tracks how far through the month we are', () {
    // July has 31 days.
    expect(monthPaceFraction(DateTime(2026, 7, 31)), 1.0);
    expect(
      monthPaceFraction(DateTime(2026, 7, 1)),
      closeTo(1 / 31, 1e-9),
    );
    // April has 30 days, so the 15th is halfway.
    expect(monthPaceFraction(DateTime(2026, 4, 15)), closeTo(0.5, 1e-9));
  });

  test('budgetStatus classifies against limit and pace', () {
    // Half spent at the halfway mark -> on track.
    expect(
      budgetStatus(spentCents: 10000, limitCents: 20000, pace: 0.5),
      BudgetStatus.onTrack,
    );
    // Three quarters spent at the halfway mark -> ahead of pace.
    expect(
      budgetStatus(spentCents: 15000, limitCents: 20000, pace: 0.5),
      BudgetStatus.aheadOfPace,
    );
    // Past the limit -> over budget, regardless of pace.
    expect(
      budgetStatus(spentCents: 25000, limitCents: 20000, pace: 0.99),
      BudgetStatus.overBudget,
    );
    // Exactly at pace is still on track (not yet ahead).
    expect(
      budgetStatus(spentCents: 5000, limitCents: 10000, pace: 0.5),
      BudgetStatus.onTrack,
    );
  });

  // -- Categories, assets & valuations -------------------------------------

  test('categories round-trip tags and list alphabetically', () async {
    final now = utcNow();
    await repo.upsertCategory(
      FinanceCategory(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        name: 'Transport',
        tags: const ['uber'],
      ),
    );
    final eating = FinanceCategory(
      id: newId(),
      createdAt: now,
      updatedAt: now,
      name: 'Eating out',
      colorValue: 0xFFAA0000,
      tags: const ['mcdonalds', 'burger_king'],
    );
    await repo.upsertCategory(eating);

    final list = await repo.listCategories();
    expect(list.map((c) => c.name), ['Eating out', 'Transport']);
    expect(list.first.tags, ['mcdonalds', 'burger_king']);
    expect(list.first.colorValue, 0xFFAA0000);
    expect(list.first.containsTag('MCDONALDS'), isTrue,
        reason: 'tag matching is case-insensitive');

    await repo.softDeleteCategory(eating.id);
    expect((await repo.listCategories()).map((c) => c.name), ['Transport']);
  });

  test('assets and valuations persist, newest valuation first', () async {
    final now = utcNow();
    final asset = Asset(
      id: newId(),
      createdAt: now,
      updatedAt: now,
      name: 'Index fund',
      note: 'Brokerage',
    );
    await repo.upsertAsset(asset);

    await repo.upsertAssetValuation(
      AssetValuation(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        assetId: asset.id,
        valueCents: 50000,
        asOf: DateTime(2026, 5, 1),
      ),
    );
    await repo.upsertAssetValuation(
      AssetValuation(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        assetId: asset.id,
        valueCents: 60000,
        asOf: DateTime(2026, 7, 1),
      ),
    );

    final assets = await repo.listAssets();
    expect(assets.single.name, 'Index fund');
    expect(assets.single.note, 'Brokerage');

    final valuations = await repo.listAssetValuations(assetId: asset.id);
    expect(valuations.map((v) => v.valueCents), [60000, 50000]);
  });

  test('deleting an asset tombstones its valuations too', () async {
    final now = utcNow();
    final asset = Asset(
      id: newId(),
      createdAt: now,
      updatedAt: now,
      name: 'Car',
    );
    await repo.upsertAsset(asset);
    await repo.upsertAssetValuation(
      AssetValuation(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        assetId: asset.id,
        valueCents: 800000,
        asOf: DateTime(2026, 7, 1),
      ),
    );

    await repo.softDeleteAsset(asset.id);

    expect(await repo.listAssets(), isEmpty);
    expect(
      await repo.listAssetValuations(assetId: asset.id),
      isEmpty,
      reason: 'a deleted asset must stop contributing to net worth',
    );
    expect(
      await repo.listAssetValuations(assetId: asset.id, includeDeleted: true),
      hasLength(1),
    );

    final future = utcNow().add(Duration(days: softDeleteRetentionDays + 1));
    await repo.purgeExpiredDeleted(future);
    expect(await repo.listAssets(includeDeleted: true), isEmpty);
    expect(await repo.listAssetValuations(includeDeleted: true), isEmpty);
  });

  // -- Savings goals & allocations -----------------------------------------

  SavingsGoal makeGoal({
    required String name,
    required int targetCents,
    DateTime? targetDate,
    String? id,
  }) {
    final now = utcNow();
    return SavingsGoal(
      id: id ?? newId(),
      createdAt: now,
      updatedAt: now,
      name: name,
      targetCents: targetCents,
      targetDate: targetDate,
    );
  }

  Future<void> allocate(String goalId, int amountCents, DateTime at) {
    final now = utcNow();
    return repo.upsertGoalAllocation(
      GoalAllocation(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        goalId: goalId,
        amountCents: amountCents,
        allocatedAt: at,
      ),
    );
  }

  test('goals persist with target date and list newest-last', () async {
    final goal = makeGoal(
      name: 'Japan trip',
      targetCents: 500000,
      targetDate: DateTime(2027, 3, 1),
    );
    await repo.upsertSavingsGoal(goal);

    final loaded = (await repo.listSavingsGoals()).single;
    expect(loaded.name, 'Japan trip');
    expect(loaded.targetCents, 500000);
    expect(loaded.targetDate, DateTime(2027, 3, 1));
  });

  test('allocations sum toward a goal, newest first', () async {
    final goal = makeGoal(name: 'Laptop', targetCents: 200000);
    final other = makeGoal(name: 'Other', targetCents: 100000);
    await repo.upsertSavingsGoal(goal);
    await repo.upsertSavingsGoal(other);

    await allocate(goal.id, 50000, DateTime(2026, 5, 1));
    await allocate(goal.id, 30000, DateTime(2026, 7, 1));
    await allocate(other.id, 99999, DateTime(2026, 6, 1));

    final allocations = await repo.listGoalAllocations(goalId: goal.id);
    expect(allocations.map((a) => a.amountCents), [30000, 50000]);

    final all = await repo.listGoalAllocations();
    expect(goalAllocatedCents(all, goal.id), 80000);
    expect(goalAllocatedCents(all, other.id), 99999);
  });

  test('a negative allocation records a withdrawal', () async {
    final goal = makeGoal(name: 'Emergency fund', targetCents: 100000);
    await repo.upsertSavingsGoal(goal);
    await allocate(goal.id, 50000, DateTime(2026, 6, 1));
    await allocate(goal.id, -20000, DateTime(2026, 7, 1));

    final all = await repo.listGoalAllocations();
    expect(goalAllocatedCents(all, goal.id), 30000);
  });

  test('deleting a goal tombstones its allocations too', () async {
    final goal = makeGoal(name: 'Bike', targetCents: 100000);
    await repo.upsertSavingsGoal(goal);
    await allocate(goal.id, 25000, DateTime(2026, 7, 1));

    await repo.softDeleteSavingsGoal(goal.id);
    expect(await repo.listSavingsGoals(), isEmpty);
    expect(await repo.listGoalAllocations(goalId: goal.id), isEmpty);
    expect(
      await repo.listGoalAllocations(goalId: goal.id, includeDeleted: true),
      hasLength(1),
    );

    final future = utcNow().add(Duration(days: softDeleteRetentionDays + 1));
    await repo.purgeExpiredDeleted(future);
    expect(await repo.listSavingsGoals(includeDeleted: true), isEmpty);
    expect(await repo.listGoalAllocations(includeDeleted: true), isEmpty);
  });

  test('goalProgress clamps and handles edge cases', () {
    expect(goalProgress(0, 1000), 0.0);
    expect(goalProgress(500, 1000), 0.5);
    expect(goalProgress(1000, 1000), 1.0);
    // Overfunding never pushes the ring past full.
    expect(goalProgress(1500, 1000), 1.0);
    // A non-positive target reads as complete rather than dividing by zero.
    expect(goalProgress(0, 0), 1.0);
    // Withdrawing below zero clamps to empty.
    expect(goalProgress(-500, 1000), 0.0);
  });

  test('daysUntilTarget counts down and goes negative when overdue', () {
    final from = DateTime(2026, 7, 18);
    expect(
      makeGoal(
        name: 'g',
        targetCents: 100,
        targetDate: DateTime(2026, 7, 28),
      ).daysUntilTarget(from),
      10,
    );
    expect(
      makeGoal(
        name: 'g',
        targetCents: 100,
        targetDate: DateTime(2026, 7, 18),
      ).daysUntilTarget(from),
      0,
    );
    expect(
      makeGoal(
        name: 'g',
        targetCents: 100,
        targetDate: DateTime(2026, 7, 10),
      ).daysUntilTarget(from),
      -8,
    );
    expect(
      makeGoal(name: 'g', targetCents: 100).daysUntilTarget(from),
      isNull,
    );
  });

  test('settings persist the annualized-cost toggle', () async {
    final settingsRepo = DriftSettingsRepository(db);
    final base = await settingsRepo.getSettings();
    expect(base.showAnnualizedSubscriptionCost, isFalse);
    await settingsRepo
        .saveSettings(base.copyWith(showAnnualizedSubscriptionCost: true));
    final reloaded = await settingsRepo.getSettings();
    expect(reloaded.showAnnualizedSubscriptionCost, isTrue);
  });
}
