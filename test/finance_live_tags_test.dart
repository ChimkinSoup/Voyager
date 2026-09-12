// A tag color row outlives the transactions that created it — nothing purges
// one when the last transaction carrying that tag is deleted. Neither tag
// picker may treat a surviving color as evidence the tag still exists.

import 'package:drift/drift.dart' show driftRuntimeOptions;
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
import 'package:voyager/features/finance/finance_page.dart';
import 'package:voyager/features/finance/finance_ui_prefs.dart';

import 'fakes/fake_weather_api_client.dart';

Future<void> pumpDashboard(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final finance = DriftFinanceRepository(db);
  final settings = DriftSettingsRepository(db);
  final now = utcNow();
  final today = DateTime.now();

  await finance.upsertTransaction(
    FinancialTransaction(
      id: 'txn-live',
      createdAt: now,
      updatedAt: now,
      type: TransactionType.expense,
      amountCents: 1000,
      occurredAt: DateTime(today.year, today.month, today.day),
      note: 'Lunch',
      tags: const ['food'],
    ),
  );
  // The tag a since-deleted transaction left a color behind for.
  await settings.setTagColor('ghost', 0xFFAA0000);

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
  await container.read(tagColorsProvider.future);
  await container.read(budgetsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: FinancePage())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));

  // The color is on disk, so a picker that reads tagColors.keys would show it.
  expect(
    (await container.read(tagColorsProvider.future)).containsKey('ghost'),
    isTrue,
  );
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the category modal offers live tags only', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.text('Analytics'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Manage categories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New category'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilterChip, '#food'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, '#ghost'), findsNothing);
  });

  testWidgets('the budget modal suggests live tags only', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.byTooltip('Add budget'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ActionChip, '#food'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '#ghost'), findsNothing);
  });
}
