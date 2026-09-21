// A post-dated transaction is scheduled, not spent: the ledger files it under
// Upcoming at the top, and the hero's net flow leaves it out until its day.

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

  testWidgets('future-dated rows sit under Upcoming and skip the hero total', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftFinanceRepository(db);
    final stamp = utcNow();
    final wall = DateTime.now();
    Future<void> add(String note, int cents, DateTime occurredAt) =>
        repo.upsertTransaction(
          FinancialTransaction(
            id: newId(),
            createdAt: stamp,
            updatedAt: stamp,
            type: TransactionType.expense,
            amountCents: cents,
            occurredAt: occurredAt,
            note: note,
          ),
        );
    // Early in the morning so today's row stays in this month even on the 1st.
    await add('Later', 10000, DateTime(wall.year, wall.month, wall.day + 1, 9));
    await add('Now', 500, DateTime(wall.year, wall.month, wall.day, 0, 1));
    await add('Before', 200, DateTime(wall.year, wall.month, wall.day - 1, 9));

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

    double top(Finder f) => tester.getTopLeft(f).dy;
    expect(find.text('UPCOMING'), findsOneWidget);
    expect(find.text('TOMORROW'), findsOneWidget);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(top(find.text('UPCOMING')), lessThan(top(find.text('Later'))));
    expect(top(find.text('Later')), lessThan(top(find.text('Now'))));

    // The hero counts today's $5 (and yesterday's $2 when it is in this
    // month), never tomorrow's $100.
    final expected = wall.day == 1 ? r'-$5.00' : r'-$7.00';
    final withFuture = wall.day == 1 ? r'-$105.00' : r'-$107.00';
    // findsWidgets: on the 1st, TODAY's day header reads the same -$5.00.
    expect(find.text(expected), findsWidgets);
    expect(find.text(withFuture), findsNothing);
  });

  test('settledTransactions keeps through the end of today only', () {
    final now = DateTime(2026, 9, 12, 8);
    final stamp = utcNow();
    FinancialTransaction at(DateTime d) => FinancialTransaction(
      id: newId(),
      createdAt: stamp,
      updatedAt: stamp,
      type: TransactionType.expense,
      amountCents: 100,
      occurredAt: d,
    );
    final lateToday = at(DateTime(2026, 9, 12, 23, 59, 59));
    final past = at(DateTime(2026, 9, 1));
    final tomorrow = at(DateTime(2026, 9, 13));

    expect(settledTransactions([tomorrow, lateToday, past], now), [
      lateToday,
      past,
    ]);
  });
}
