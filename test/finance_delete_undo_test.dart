// The ledger row's delete used to confirm with a Material [SnackBar], which is
// the one place in the app that did. It now raises the same VoyagerToast every
// other soft delete does — asserted here both ways round, because a stray
// SnackBar would look almost right while sitting in the wrong corner with the
// wrong dwell.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart' show kSecondaryButton;
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

Future<DriftFinanceRepository> pumpLedger(
  WidgetTester tester, {
  String? origin,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftFinanceRepository(db);
  final now = utcNow();
  for (var i = 0; i < 3; i++) {
    await repo.upsertTransaction(
      FinancialTransaction(
        id: 'txn-$i',
        createdAt: now,
        updatedAt: now,
        type: TransactionType.expense,
        amountCents: 1000 + i,
        occurredAt: DateTime(2026, 8, 20 - i),
        origin: origin,
        note: 'Row $i',
        tags: const ['food'],
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
  return repo;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('deleting a row raises a toast, not a SnackBar', (tester) async {
    final repo = await pumpLedger(tester);

    await tester.longPress(find.text('Row 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Deleted "Row 1"'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    final live = await repo.listTransactions();
    expect(live.map((t) => t.note), isNot(contains('Row 1')));
  });

  testWidgets('Undo puts the transaction back as it was', (tester) async {
    final repo = await pumpLedger(tester);
    final before = (await repo.listTransactions()).firstWhere(
      (t) => t.id == 'txn-1',
    );

    await tester.longPress(find.text('Row 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final restored = (await repo.listTransactions()).where(
      (t) => t.id == 'txn-1',
    );
    expect(restored, hasLength(1));
    expect(restored.single.deletedAt, isNull);
    // Every field comes back, not just the row: the restore rebuilds the
    // transaction from a snapshot rather than resurrecting the tombstone,
    // which has no content of its own to speak of.
    expect(restored.single.note, 'Row 1');
    expect(restored.single.amountCents, before.amountCents);
    expect(restored.single.tags, before.tags);
    expect(restored.single.occurredAt, before.occurredAt);
    expect(
      restored.single.version,
      greaterThan(before.version + 1),
      reason: 'the delete wrote version + 1; the restore has to outrank it',
    );
    expect(find.text('Row 1'), findsOneWidget);
  });

  testWidgets('Convert clears the origin along with the type', (tester) async {
    final repo = await pumpLedger(tester, origin: 'Walmart');

    await tester.tap(
      find.textContaining('Row 1', findRichText: true),
      buttons: kSecondaryButton,
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Convert to deposit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final converted = (await repo.listTransactions()).firstWhere(
      (t) => t.id == 'txn-1',
    );
    expect(converted.type, TransactionType.deposit);
    expect(converted.origin, isNull, reason: 'a store is not a source');
    expect(converted.note, 'Row 1');
    expect(converted.amountCents, 1001);
  });
}
