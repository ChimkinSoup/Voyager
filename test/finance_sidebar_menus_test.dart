// The right-click menus on the Bill Radar and Budget tiles, and the ledger
// filter a budget's "View expenses" leaves behind.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/features/finance/finance_budget_panel.dart';
import 'package:voyager/features/finance/finance_page.dart';
import 'package:voyager/features/finance/finance_ui_prefs.dart';

import 'fakes/fake_weather_api_client.dart';

/// Today, as the app's date-only fields store it.
final _today = () {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}();

class _Harness {
  _Harness(this.repo, this.container);

  final DriftFinanceRepository repo;
  final ProviderContainer container;
}

Future<_Harness> pumpDashboard(WidgetTester tester) async {
  // Tall and wide: the insights sidebar only exists past the split
  // breakpoint, and a short window parks tiles under the pinned chrome.
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftFinanceRepository(db);
  final now = utcNow();

  // Two months apart, so a month-scoped filter would be visibly wrong.
  await repo.upsertTransaction(
    FinancialTransaction(
      id: 'txn-thai',
      createdAt: now,
      updatedAt: now,
      type: TransactionType.expense,
      amountCents: 3000,
      occurredAt: DateTime(_today.year, _today.month, _today.day),
      note: 'Pad see ew',
      tags: const ['food', 'thai'],
    ),
  );
  await repo.upsertTransaction(
    FinancialTransaction(
      id: 'txn-old-thai',
      createdAt: now,
      updatedAt: now,
      type: TransactionType.expense,
      amountCents: 1500,
      occurredAt: DateTime(_today.year, _today.month - 2, 14),
      note: 'Green curry',
      tags: const ['thai'],
    ),
  );
  await repo.upsertTransaction(
    FinancialTransaction(
      id: 'txn-rent',
      createdAt: now,
      updatedAt: now,
      type: TransactionType.expense,
      amountCents: 90000,
      occurredAt: DateTime(_today.year, _today.month, _today.day),
      note: 'Rent',
      tags: const ['rent'],
    ),
  );
  await repo.upsertSubscription(
    Subscription(
      id: 'sub-1',
      createdAt: now,
      updatedAt: now,
      name: 'Netflix',
      amountCents: 1599,
      period: BillingPeriod.monthly,
      anchorDueDate: DateTime(_today.year, _today.month, _today.day + 3),
    ),
  );
  await repo.upsertBudget(
    Budget(
      id: 'bud-1',
      createdAt: now,
      updatedAt: now,
      tag: 'thai',
      limitCents: 20000,
    ),
  );

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      // The real store writes into the app documents directory, which a test
      // has no business touching.
      financeUiPrefsStoreProvider.overrideWithValue(
        MemoryFinanceUiPrefsStore(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  await container.read(transactionsProvider.future);
  await container.read(subscriptionsProvider.future);
  await container.read(budgetsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: FinancePage())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return _Harness(repo, container);
}

/// The budget tile's own chip, not the identical one on a ledger row.
final budgetTile = find.descendant(
  of: find.byType(BudgetPanel),
  matching: find.text('#thai'),
);

Future<void> openMenuOn(WidgetTester tester, Finder target) async {
  await tester.tap(target, buttons: kSecondaryButton, warnIfMissed: false);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  group('budget menu', () {
    testWidgets('View expenses filters the ledger all-time, and clears', (
      tester,
    ) async {
      await pumpDashboard(tester);

      expect(find.text('Rent'), findsOneWidget);

      await openMenuOn(tester, budgetTile);
      await tester.tap(find.text('View expenses'));
      await tester.pumpAndSettle();

      expect(find.text('Pad see ew'), findsOneWidget);
      // Two months back, so the filter is not quietly month-scoped.
      expect(find.text('Green curry'), findsOneWidget);
      expect(find.text('Rent'), findsNothing);

      await tester.tap(find.text('Expenses tagged #thai'));
      await tester.pumpAndSettle();

      expect(find.text('Rent'), findsOneWidget);
    });

    testWidgets('Delete offers an undo that puts the budget back', (
      tester,
    ) async {
      final harness = await pumpDashboard(tester);

      await openMenuOn(tester, budgetTile);
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Deleted "thai"'), findsOneWidget);
      expect(await harness.repo.listBudgets(), isEmpty);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final restored = await harness.repo.listBudgets();
      expect(restored.map((b) => b.tag), ['thai']);
    });
  });

  group('bill menu', () {
    testWidgets('Duplicate copies the bill and anchors it to today', (
      tester,
    ) async {
      final harness = await pumpDashboard(tester);

      await openMenuOn(tester, find.text('Netflix'));
      await tester.tap(find.text('Duplicate'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final bills = await harness.repo.listSubscriptions();
      expect(bills.length, 2);
      final copy = bills.firstWhere((b) => b.id != 'sub-1');
      expect(copy.name, 'Netflix');
      expect(copy.amountCents, 1599);
      expect(copy.period, BillingPeriod.monthly);
      expect(
        DateTime(
          copy.anchorDueDate.year,
          copy.anchorDueDate.month,
          copy.anchorDueDate.day,
        ),
        _today,
      );
    });

    testWidgets('Delete offers an undo that puts the bill back', (
      tester,
    ) async {
      final harness = await pumpDashboard(tester);
      // Marked paid before the delete: the restore rebuilds the bill field by
      // field rather than copyWith'ing it (copyWith cannot clear a tombstone),
      // and a field left off that list comes back silently cleared.
      final paid = (await harness.repo.getSubscription(
        'sub-1',
      ))!.nextDue(DateTime.now());
      await harness.repo.upsertSubscription(
        (await harness.repo.getSubscription(
          'sub-1',
        ))!.copyWith(paidThroughDate: paid),
      );
      // The tile's own snapshot is what gets written back, so it has to have
      // seen the payment before the delete.
      harness.container.invalidate(subscriptionsProvider);
      await tester.pumpAndSettle();

      await openMenuOn(tester, find.text('Netflix'));
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Deleted "Netflix"'), findsOneWidget);
      expect(await harness.repo.listSubscriptions(), isEmpty);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final restored = (await harness.repo.listSubscriptions()).single;
      expect(restored.name, 'Netflix');
      expect(restored.paidThroughDate, paid);
    });

    testWidgets('Log payment cancelled leaves the due date alone', (
      tester,
    ) async {
      final harness = await pumpDashboard(tester);
      final before = (await harness.repo.getSubscription('sub-1'))!;

      await openMenuOn(tester, find.text('Netflix'));
      await tester.tap(find.text('Log payment'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      final after = (await harness.repo.getSubscription('sub-1'))!;
      expect(after.anchorDueDate, before.anchorDueDate);
      expect(after.paidThroughDate, isNull);
      expect(after.version, before.version);
    });

    testWidgets('Log payment saved advances the due date by one period', (
      tester,
    ) async {
      final harness = await pumpDashboard(tester);
      final before = (await harness.repo.getSubscription('sub-1'))!;
      final paidDue = before.nextDue(DateTime.now());

      await openMenuOn(tester, find.text('Netflix'));
      await tester.tap(find.text('Log payment'));
      await tester.pumpAndSettle();

      // The sheet opens prefilled from the bill.
      expect(find.text('15.99'), findsOneWidget);
      expect(find.text('Netflix'), findsWidgets);

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      final logged = (await harness.repo.listTransactions()).firstWhere(
        (t) => t.origin == 'Netflix',
      );
      expect(logged.note, isNull, reason: 'the bill names the store only');
      expect(logged.type, TransactionType.expense);
      expect(logged.amountCents, 1599);
      expect(logged.tags, isEmpty);

      final after = (await harness.repo.getSubscription('sub-1'))!;
      // The settled occurrence is recorded and the anchor is untouched, so the
      // bill keeps its day of month no matter how many months it's paid for.
      expect(after.paidThroughDate, paidDue);
      expect(after.anchorDueDate, before.anchorDueDate);
      expect(
        after.nextDue(DateTime.now()),
        nextDueDate(
          before.anchorDueDate,
          BillingPeriod.monthly,
          DateTime(paidDue.year, paidDue.month, paidDue.day + 1),
        ),
      );
      expect(after.nextDue(DateTime.now()).isAfter(paidDue), isTrue);
    });
  });
}
