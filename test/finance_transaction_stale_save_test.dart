// The transaction Edit sheet saved the whole row from the copy it opened with,
// so a change another device made while it was open was reverted on Save
// (BUG-233). Only the fields edited in the sheet are applied now.

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
import 'package:voyager/features/finance/finance_transaction_modal.dart';

import 'fakes/fake_weather_api_client.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Finder _fieldHolding(String text) => find.byWidgetPredicate(
  (w) => w is EditableText && w.controller.text == text,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('saving a store edit keeps an amount and note changed '
      'elsewhere meanwhile', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftFinanceRepository(db);
    final now = utcNow();
    final opened = FinancialTransaction(
      id: 'tx',
      createdAt: now,
      updatedAt: now,
      version: 1,
      type: TransactionType.expense,
      amountCents: 105,
      occurredAt: DateTime.now(),
      note: 'Lunch',
    );
    await repo.upsertTransaction(opened);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () =>
                    showFinanceTransactionModal(context, ref, existing: opened),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
    expect(_fieldHolding('Lunch'), findsOneWidget);

    // Another device changes the amount and note while the sheet is open.
    await repo.upsertTransaction(
      opened.copyWith(amountCents: 5555, note: 'Changed elsewhere'),
    );

    await tester.enterText(_fieldHolding('').first, 'Shop');
    await tester.tap(find.text('Save').last);
    await _settle(tester);

    final stored = (await repo.getTransaction('tx'))!;
    expect(stored.origin, 'Shop');
    expect(stored.amountCents, 5555);
    expect(stored.note, 'Changed elsewhere');
  });
}
