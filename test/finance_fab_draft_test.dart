// The ledger's + button opens the new-transaction sheet on the same session
// draft as the finance hotkey, and hands its own unsaved fields back to it.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/features/finance/finance_page.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the + button shares the hotkey draft both ways', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
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
    await container.read(transactionsProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FinancePage())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // A draft left by the hotkey.
    container.read(financeCaptureDraftProvider.notifier).state =
        const FinanceTransactionDraft(origin: 'Costco');

    await tester.tap(find.byTooltip('Log transaction'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .map((e) => e.controller.text),
      contains('Costco'),
      reason: 'the + button opens on the hotkey draft',
    );

    await tester.enterText(
      find.descendant(
        of: find.widgetWithText(VoyagerTextField, 'Note'),
        matching: find.byType(EditableText),
      ),
      'Snacks',
    );
    Navigator.of(tester.element(find.text('Note'))).pop();
    await tester.pumpAndSettle();

    final draft = container.read(financeCaptureDraftProvider);
    expect(draft?.origin, 'Costco');
    expect(draft?.note, 'Snacks', reason: 'the + sheet hands its draft back');
  });
}
