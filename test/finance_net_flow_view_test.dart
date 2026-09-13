// The hero opens a zoomed net-flow view, and a day tapped in its heatmap
// takes the ledger there — with a placeholder when that day has no rows.

import 'package:drift/drift.dart' show driftRuntimeOptions;
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
import 'package:voyager/features/finance/finance_page.dart';
import 'package:voyager/features/finance/finance_ui_prefs.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  final wall = DateTime.now();
  final today = DateTime(wall.year, wall.month, wall.day);
  // Empty on purpose; it is the day the heatmap tap asks for.
  final emptyDay = DateTime(wall.year, 1, 15);

  Future<ProviderContainer> pumpFinance(
    WidgetTester tester, {
    DateTime? alsoEmpty,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftFinanceRepository(db);
    final stamp = utcNow();
    // Four rows a day back for 400 days: a ledger far taller than the window.
    for (var i = 0; i < 400; i++) {
      final day = DateTime(today.year, today.month, today.day - i);
      if (day == emptyDay || day == alsoEmpty) continue;
      for (var n = 0; n < 4; n++) {
        await repo.upsertTransaction(
          FinancialTransaction(
            id: newId(),
            createdAt: stamp,
            updatedAt: stamp,
            type: n == 0 ? TransactionType.deposit : TransactionType.expense,
            amountCents: 1000 + 100 * n,
            occurredAt: DateTime(day.year, day.month, day.day, 9 + n),
            note: 'Row $i.$n',
            tags: n == 1 ? const ['food'] : const [],
          ),
        );
      }
    }

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

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FinancePage())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    return container;
  }

  Future<void> frames(WidgetTester tester, [int count = 30]) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  String headerFor(DateTime day) =>
      DateFormat('EEEE, MMM d').format(day).toUpperCase();

  /// Whether any match sits at the top of the ledger's viewport, where
  /// ensureVisible parks it. Headers carry no year, so the same date a year
  /// back can be built too.
  bool atLedgerTop(WidgetTester tester, Finder finder) {
    final viewportTop = tester
        .getTopLeft(find.byKey(ShellPageStorageKeys.financeLedgerWide))
        .dy;
    for (final element in finder.evaluate()) {
      final box = element.renderObject! as RenderBox;
      final top = box.localToGlobal(Offset.zero).dy;
      // The header's own top padding sits between the viewport edge and text.
      if (top >= viewportTop && top < viewportTop + 40) return true;
    }
    return false;
  }

  testWidgets('hero shows the month-to-date delta and opens the view', (
    tester,
  ) async {
    await pumpFinance(tester);

    expect(find.textContaining('vs last month'), findsOneWidget);

    await tester.tap(find.textContaining('Net flow ·'));
    await frames(tester, 12);
    expect(find.text('Net flow per day'), findsOneWidget);
    expect(find.text('7D'), findsOneWidget);

    await tester.tap(find.text('90D'));
    await frames(tester, 4);
    final container = ProviderScope.containerOf(
      tester.element(find.text('Net flow per day')),
    );
    expect(
      container.read(financeUiPrefsProvider).heroExpandRange,
      FinanceHeroRange.d90,
    );

    await tester.tap(find.byTooltip('Close'));
    await frames(tester, 12);
    expect(find.text('Net flow per day'), findsNothing);
  });

  testWidgets('tapping an empty heatmap day lands on a placeholder for it', (
    tester,
  ) async {
    final container = await pumpFinance(tester);
    container.read(financeLedgerTagFilterProvider.notifier).state = 'food';
    container
        .read(financeUiPrefsProvider.notifier)
        .setViewMode(FinanceViewMode.analytics);
    await frames(tester, 10);

    await tester.tap(find.textContaining('Net flow ·'));
    await frames(tester, 12);

    final januaryTile = find.ancestor(
      of: find.text('January'),
      matching: find.byType(Card),
    );
    await tester.tap(
      find.descendant(of: januaryTile, matching: find.text('15')),
    );
    await frames(tester, 40);

    expect(find.text('Net flow per day'), findsNothing);
    expect(
      container.read(financeUiPrefsProvider).viewMode,
      FinanceViewMode.ledger,
    );
    expect(container.read(financeLedgerTagFilterProvider), isNull);
    expect(find.text('No transactions'), findsOneWidget);
    expect(atLedgerTop(tester, find.text(headerFor(emptyDay))), isTrue);
  });

  testWidgets('the placeholder is laid out while the view is still closing', (
    tester,
  ) async {
    await pumpFinance(tester, alsoEmpty: today);
    expect(find.text('No transactions'), findsNothing);

    await tester.tap(find.textContaining('Net flow ·'));
    await frames(tester, 12);

    final monthTile = find.ancestor(
      of: find.text(DateFormat('MMMM').format(today)),
      matching: find.byType(Card),
    );
    final dayCell = find.descendant(
      of: monthTile,
      matching: find.text('${today.day}'),
    );
    await tester.ensureVisible(dayCell);
    await frames(tester, 4);
    await tester.tap(dayCell);
    await frames(tester, 2);

    expect(find.text('Net flow per day'), findsOneWidget);
    expect(find.text('No transactions'), findsOneWidget);
  });

  testWidgets('a jump to a day deep in the ledger scrolls its header in', (
    tester,
  ) async {
    final container = await pumpFinance(tester);
    final target = DateTime(today.year, today.month, today.day - 300);
    expect(find.text(headerFor(target)), findsNothing);

    container.read(financeLedgerJumpProvider.notifier).state =
        FinanceLedgerJump(target);
    await frames(tester, 60);

    expect(atLedgerTop(tester, find.text(headerFor(target))), isTrue);
    expect(find.text('No transactions'), findsNothing);
  });
}
