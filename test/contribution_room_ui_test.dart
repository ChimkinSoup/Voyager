// The contribution-room surfaces: the shared bar on asset rows, the asset
// row's menu, the Contribute sheet end to end, and the ledger menu on a
// linked row.

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
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/contribution_room_writer.dart';
import 'package:voyager/features/finance/finance_analytics_view.dart';
import 'package:voyager/features/finance/finance_page.dart';
import 'package:voyager/features/finance/finance_ui_prefs.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.now();
final _today = DateTime(_now.year, _now.month, _now.day);

Future<(DriftFinanceRepository, ProviderContainer)> _harness(
  WidgetTester tester, {
  required Widget home,
  Future<void> Function(DriftFinanceRepository repo)? seed,
}) async {
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftFinanceRepository(db);
  await seed?.call(repo);

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

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: home)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return (repo, container);
}

/// TFSA A and TFSA B share a $7,000 room with $1,000 already contributed;
/// Savings is in no room.
Future<void> _seedRoom(DriftFinanceRepository repo) async {
  final t = utcNow();
  await repo.upsertContributionRoom(
    ContributionRoom(
      id: 'room',
      createdAt: t,
      updatedAt: t,
      name: 'TFSA',
      baselineRemainingCents: 700000,
      baselineAsOf: DateTime(_today.year, 1, 1),
      annualLimits: [AnnualLimit(fromYear: _today.year, cents: 700000)],
    ),
  );
  for (final (id, name, roomId) in [
    ('a', 'TFSA A', 'room'),
    ('b', 'TFSA B', 'room'),
    ('s', 'Savings', null),
  ]) {
    await repo.upsertAsset(
      Asset(
        id: id,
        createdAt: t,
        updatedAt: t,
        name: name,
        contributionRoomId: roomId,
      ),
    );
    await upsertValuationOnDay(
      repo,
      assetId: id,
      day: _today,
      valueCents: 100000,
    );
  }
  final a = (await repo.listAssets()).firstWhere((x) => x.id == 'a');
  await saveRoomCashEvent(
    repo,
    asset: a,
    kind: RoomEventKind.contribution,
    amountCents: 100000,
    occurredAt: _now,
    eventId: 'seed-ev',
    transactionId: 'seed-tx',
  );
}

Future<void> _rightClick(WidgetTester tester, Finder target) async {
  await tester.tap(target, buttons: kSecondaryButton, warnIfMissed: false);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('every asset in the room shows the shared bar, others none', (
    tester,
  ) async {
    await _harness(tester, home: const FinanceAnalyticsView(), seed: _seedRoom);
    expect(find.text(r'$1,000/$7,000'), findsNWidgets(2));
    expect(find.text('Savings'), findsOneWidget);
  });

  testWidgets('the menu offers room actions only on tracked assets', (
    tester,
  ) async {
    await _harness(tester, home: const FinanceAnalyticsView(), seed: _seedRoom);

    await _rightClick(tester, find.text('TFSA A'));
    expect(find.text('Contribute…'), findsOneWidget);
    expect(find.text('Withdraw…'), findsOneWidget);
    expect(find.text('Transfer…'), findsOneWidget);
    expect(find.text('Track contribution room…'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await _rightClick(tester, find.text('Savings'));
    expect(find.text('Track contribution room…'), findsOneWidget);
    expect(find.text('Contribute…'), findsNothing);
  });

  testWidgets('Contribute proposes the new value and fills the bar', (
    tester,
  ) async {
    final (repo, _) = await _harness(
      tester,
      home: const FinanceAnalyticsView(),
      seed: _seedRoom,
    );

    await _rightClick(tester, find.text('TFSA B'));
    await tester.tap(find.text('Contribute…'));
    await tester.pumpAndSettle();

    final fields = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(EditableText),
    );
    await tester.enterText(fields.first, '500');
    await tester.pump();
    // $1,000 before, so the sheet proposes $1,500 without being asked.
    expect(find.text('1500.00'), findsOneWidget);

    await tester.tap(find.text('Contribute').last);
    await tester.pumpAndSettle();

    final events = await repo.listAssetRoomEvents();
    final added = events.firstWhere((e) => e.assetId == 'b');
    expect(added.amountCents, 50000);
    final tx = (await repo.getTransaction(added.transactionId!))!;
    expect(tx.type, TransactionType.deposit);
    expect(
      (await repo.listAssetValuations(assetId: 'b')).first.valueCents,
      150000,
    );
    expect(find.text(r'$1,500/$7,000'), findsNWidgets(2));
  });

  testWidgets(
    'revaluing from an edited contribution refreshes the open asset sheet',
    (tester) async {
      final (repo, _) = await _harness(
        tester,
        home: const FinanceAnalyticsView(),
        seed: _seedRoom,
      );

      await tester.tap(find.text('TFSA A'));
      await tester.pumpAndSettle();
      expect(find.text('1000.00'), findsOneWidget);

      await tester.tap(find.text('Contribution'));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet).last;
      // Amount, new value, note.
      final fields = find.descendant(
        of: sheet,
        matching: find.byType(EditableText),
      );
      await tester.enterText(fields.at(1), '4321');
      await tester.pump();
      await tester.tap(find.descendant(of: sheet, matching: find.text('Save')));
      await tester.pumpAndSettle();

      // The asset sheet underneath follows the new figure...
      expect(find.text('4321.00'), findsOneWidget);
      expect(find.text('1000.00'), findsNothing);

      // ...so saving it doesn't write the old one back.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        (await repo.listAssetValuations(assetId: 'a')).first.valueCents,
        432100,
      );
    },
  );

  testWidgets('the asset sheet leaves a typed value alone when revalued', (
    tester,
  ) async {
    await _harness(tester, home: const FinanceAnalyticsView(), seed: _seedRoom);

    await tester.tap(find.text('TFSA A'));
    await tester.pumpAndSettle();
    final assetFields = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(EditableText),
    );
    // Name, current value, note.
    await tester.enterText(assetFields.at(1), '999');
    await tester.pump();

    await tester.tap(find.text('Contribution'));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet).last;
    final fields = find.descendant(
      of: sheet,
      matching: find.byType(EditableText),
    );
    await tester.enterText(fields.at(1), '4321');
    await tester.pump();
    await tester.tap(find.descendant(of: sheet, matching: find.text('Save')));
    await tester.pumpAndSettle();

    expect(find.text('999'), findsOneWidget);
  });

  testWidgets('a linked ledger row offers no Convert or Duplicate', (
    tester,
  ) async {
    await _harness(
      tester,
      home: const FinancePage(),
      seed: (repo) async {
        await _seedRoom(repo);
        final t = utcNow();
        await repo.upsertTransaction(
          FinancialTransaction(
            id: 'plain',
            createdAt: t,
            updatedAt: t,
            type: TransactionType.expense,
            amountCents: 900,
            occurredAt: _now,
            note: 'Coffee',
          ),
        );
      },
    );

    await _rightClick(
      tester,
      find.textContaining('TFSA A', findRichText: true).first,
    );
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Duplicate'), findsNothing);
    expect(find.text('Convert to expense'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await _rightClick(
      tester,
      find.textContaining('Coffee', findRichText: true),
    );
    expect(find.text('Duplicate'), findsOneWidget);
  });

  testWidgets('deleting a linked ledger row and undoing restores its event', (
    tester,
  ) async {
    final (repo, _) = await _harness(
      tester,
      home: const FinancePage(),
      seed: _seedRoom,
    );

    await tester.longPress(
      find.textContaining('TFSA A', findRichText: true).first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(await repo.listAssetRoomEvents(), isEmpty);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final event = (await repo.listAssetRoomEvents()).single;
    expect(event.id, 'seed-ev');
    expect((await repo.getTransaction('seed-tx'))!.deletedAt, isNull);
  });
}
