// A transaction note is written in a formatting field, so the ledger row has to
// render it the way the editor does: `**Dinner**` shows the reader a bold word,
// not the raw asterisks around it (EMPHASIS_FORMATTING.md §10).

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

  testWidgets('a ledger row bolds its note and hides the markers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final now = utcNow();
    await DriftFinanceRepository(db).upsertTransaction(
      FinancialTransaction(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        type: TransactionType.expense,
        amountCents: 4200,
        occurredAt: DateTime(2026, 8, 20),
        note: '**Dinner** with friends',
      ),
    );

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

    // The stored string is untouched; only how it is drawn changes.
    final note = find.text('**Dinner** with friends');
    expect(note, findsOneWidget);
    final paragraph = tester.widget<RichText>(
      find.descendant(of: note, matching: find.byType(RichText)),
    );

    final runs = <(String, TextStyle?)>[];
    void walk(InlineSpan node, TextStyle? inherited) {
      if (node is! TextSpan) return;
      final style = node.style == null
          ? inherited
          : (inherited ?? const TextStyle()).merge(node.style);
      final text = node.text;
      if (text != null && text.isNotEmpty) runs.add((text, style));
      for (final child in node.children ?? const <InlineSpan>[]) {
        walk(child, style);
      }
    }

    walk(paragraph.text, null);
    expect(
      runs.firstWhere((r) => r.$1 == 'Dinner').$2?.fontWeight,
      FontWeight.bold,
    );
    final markers = runs.where((r) => r.$1 == '**').toList();
    expect(markers, hasLength(2));
    expect(markers.every((r) => r.$2?.fontSize == 0), isTrue);
  });
}
