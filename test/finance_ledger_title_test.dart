// A ledger row titles itself `Store - Note`, with the origin a step larger and
// bold and the note in the row's regular style
// (FINANCE_TRANSACTION_ORIGIN_HLD.md §6). The note is still drawn as prose:
// `**floss**` shows a bold word, not the asterisks around it.

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

Future<void> _pumpLedger(
  WidgetTester tester,
  List<FinancialTransaction> transactions,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftFinanceRepository(db);
  for (final t in transactions) {
    await repo.upsertTransaction(t);
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
}

FinancialTransaction _tx(
  String id, {
  TransactionType type = TransactionType.expense,
  String? origin,
  String? note,
}) {
  final now = utcNow();
  return FinancialTransaction(
    id: id,
    createdAt: now,
    updatedAt: now,
    type: type,
    amountCents: 4200,
    occurredAt: DateTime(2026, 8, 20),
    origin: origin,
    note: note,
  );
}

/// The styled runs of the one title that reads [plain], flattened.
List<(String, TextStyle?)> _runs(WidgetTester tester, String plain) {
  final title = find.byWidgetPredicate(
    (w) => w is LedgerTitleText,
  );
  final paragraphs = tester
      .widgetList<RichText>(
        find.descendant(of: title, matching: find.byType(RichText)),
      )
      .where((p) => p.text.toPlainText() == plain)
      .toList();
  expect(paragraphs, hasLength(1), reason: 'one title reads "$plain"');

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

  walk(paragraphs.single.text, null);
  return runs;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('origin is bold and larger; the note after it is not', (
    tester,
  ) async {
    await _pumpLedger(tester, [
      _tx('a', origin: 'Walmart', note: 'Toothpaste'),
    ]);

    final runs = _runs(tester, 'Walmart - Toothpaste');
    final origin = runs.firstWhere((r) => r.$1 == 'Walmart').$2;
    final note = runs.firstWhere((r) => r.$1 == 'Toothpaste').$2;

    expect(origin?.fontWeight, FontWeight.w600);
    expect(note?.fontWeight, isNot(FontWeight.w600));
    expect(origin!.fontSize!, greaterThan(note!.fontSize!));
  });

  testWidgets('origin alone, note alone, and the type fallback', (
    tester,
  ) async {
    await _pumpLedger(tester, [
      _tx('a', origin: 'Costco'),
      _tx('b', note: 'Lunch'),
      _tx('c', type: TransactionType.deposit),
    ]);

    expect(_runs(tester, 'Costco').single.$2?.fontWeight, FontWeight.w600);
    expect(
      _runs(tester, 'Lunch').single.$2?.fontWeight,
      isNot(FontWeight.w600),
    );
    expect(
      _runs(tester, 'Deposit').single.$2?.fontWeight,
      isNot(FontWeight.w600),
      reason: 'the fallback is not dressed up as an origin',
    );
  });

  testWidgets('the note renders emphasis and hides its markers', (
    tester,
  ) async {
    await _pumpLedger(tester, [
      _tx('a', origin: 'CVS', note: '**floss** and gum'),
      _tx('b', note: '*mints*'),
    ]);

    // The stored string is untouched; only how it is drawn changes.
    final runs = _runs(tester, 'CVS - **floss** and gum');
    expect(
      runs.firstWhere((r) => r.$1 == 'floss').$2?.fontWeight,
      FontWeight.bold,
    );
    expect(
      runs.firstWhere((r) => r.$1 == 'CVS').$2?.fontWeight,
      FontWeight.w600,
    );
    final markers = runs.where((r) => r.$1 == '**').toList();
    expect(markers, hasLength(2));
    expect(markers.every((r) => r.$2?.fontSize == 0), isTrue);

    final alone = _runs(tester, '*mints*');
    expect(
      alone.firstWhere((r) => r.$1 == 'mints').$2?.fontStyle,
      FontStyle.italic,
    );
  });
}
