// The ledger row's hover wash has to be clipped by the ledger's own viewport.
//
// An [InkWell] paints its highlight into the nearest [Material] above it. With
// none inside the scroll view that was the page's own, which sits outside the
// viewport and so is not clipped by it: a row half-scrolled under the
// Ledger/Analytics/Goals bar had its grey wash drawn across that bar.

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

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('each ledger row owns the Material its ink paints into', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftFinanceRepository(db);
    final now = utcNow();
    for (var i = 0; i < 6; i++) {
      await repo.upsertTransaction(
        FinancialTransaction(
          id: newId(),
          createdAt: now,
          updatedAt: now,
          type: TransactionType.expense,
          amountCents: 1000 + i,
          occurredAt: DateTime(2026, 8, 20 - i),
          note: 'Row $i',
        ),
      );
    }

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

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FinancePage())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final row = find.ancestor(
      of: find.text('Row 0'),
      matching: find.byType(InkWell),
    );
    expect(row, findsOneWidget);

    // The Material the ink lands in must be inside the ledger's scrollable, so
    // the viewport's clip contains it.
    final material = find
        .ancestor(of: row, matching: find.byType(Material))
        .first;
    final viewport = find.ancestor(of: row, matching: find.byType(Scrollable));
    expect(
      find.descendant(of: viewport, matching: material),
      findsWidgets,
      reason: 'the row ink surface must live under the ledger viewport',
    );
  });
}
