// The finance ledger's Ctrl+F search: store, note and tag text, `#tag` for
// tags alone, and amounts matched by prefix.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:voyager/features/finance/finance_search.dart';
import 'package:voyager/features/todo/todo_list_search_bar.dart';

import 'fakes/fake_weather_api_client.dart';

FinancialTransaction _tx(
  String id, {
  int amountCents = 4200,
  String? origin,
  String? note,
  List<String> tags = const [],
}) {
  final now = utcNow();
  return FinancialTransaction(
    id: id,
    createdAt: now,
    updatedAt: now,
    type: TransactionType.expense,
    amountCents: amountCents,
    occurredAt: DateTime(2026, 8, 20),
    origin: origin,
    note: note,
    tags: tags,
  );
}

bool _matches(FinancialTransaction t, String query) =>
    financeTransactionMatches(t, financeSearchTokens(query));

void main() {
  group('financeTransactionMatches', () {
    final costco = _tx(
      'a',
      amountCents: 12050,
      origin: 'Costco',
      note: 'Paper towels',
      tags: ['Groceries'],
    );

    test('an empty query matches everything', () {
      expect(_matches(costco, ''), isTrue);
      expect(_matches(costco, '   #  '), isTrue);
    });

    test('a bare amount marker is dropped until a number follows it', () {
      expect(financeSearchTokens(r'$'), isEmpty);
      expect(financeSearchTokens('-'), isEmpty);
      expect(financeSearchTokens('+'), isEmpty);
      expect(financeSearchTokens(r'-$'), isEmpty);
      expect(_matches(costco, r'costco $'), isTrue);
    });

    test('text matches store, note and tags, case-insensitively', () {
      expect(_matches(costco, 'cost'), isTrue);
      expect(_matches(costco, 'TOWEL'), isTrue);
      expect(_matches(costco, 'grocer'), isTrue);
      expect(_matches(costco, 'walmart'), isFalse);
    });

    test('every word has to match somewhere', () {
      expect(_matches(costco, 'costco paper'), isTrue);
      expect(_matches(costco, 'costco walmart'), isFalse);
    });

    test('#tag matches tags by prefix only', () {
      expect(_matches(costco, '#groc'), isTrue);
      expect(_matches(costco, '#costco'), isFalse);
      expect(_matches(costco, '#ceries'), isFalse);
    });

    test('numbers match the start of the amount', () {
      expect(_matches(costco, '120'), isTrue);
      expect(_matches(costco, '12'), isTrue);
      expect(_matches(costco, '120.5'), isTrue);
      expect(_matches(costco, '120.50'), isTrue);
      expect(_matches(costco, r'$120.50'), isTrue);
      expect(_matches(costco, '-120'), isTrue);
      expect(_matches(costco, '20'), isFalse);
      expect(_matches(costco, '120.51'), isFalse);
    });

    test('thousands separators are ignored', () {
      final rent = _tx('r', amountCents: 129900, origin: 'Landlord');
      expect(_matches(rent, '1,299'), isTrue);
      expect(_matches(rent, r'$1,299.00'), isTrue);
    });

    test('sub-dollar amounts pad their cents', () {
      final gum = _tx('g', amountCents: 5, origin: 'Kiosk');
      expect(_matches(gum, '0.05'), isTrue);
      expect(_matches(gum, '0.5'), isFalse);
    });
  });

  group('ledger search bar', () {
    setUpAll(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    });

    Future<void> pumpLedger(
      WidgetTester tester, {
      List<FinancialTransaction> extra = const [],
    }) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final repo = DriftFinanceRepository(db);
      await repo.upsertTransaction(
        _tx('a', origin: 'Costco', tags: ['groceries']),
      );
      await repo.upsertTransaction(_tx('b', origin: 'Shell', note: 'Gas'));
      for (final t in extra) {
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

    Future<void> pressCtrlF(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    // Past the search bar's debounce.
    Future<void> typeQuery(WidgetTester tester, String query) async {
      await tester.enterText(
        find.descendant(
          of: find.byType(TodoListSearchBar),
          matching: find.byType(TextField),
        ),
        query,
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
    }

    testWidgets('Ctrl+F opens it, typing filters, Esc restores', (
      tester,
    ) async {
      await pumpLedger(tester);
      expect(find.byType(TodoListSearchBar), findsNothing);
      expect(find.text('Costco', findRichText: true), findsOneWidget);
      expect(find.text('Shell - Gas', findRichText: true), findsOneWidget);

      await pressCtrlF(tester);
      expect(find.byType(TodoListSearchBar), findsOneWidget);

      await typeQuery(tester, '#groc');
      expect(find.text('Costco', findRichText: true), findsOneWidget);
      expect(find.text('Shell - Gas', findRichText: true), findsNothing);
      expect(find.text('1 match'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(TodoListSearchBar), findsNothing);
      expect(find.text('Shell - Gas', findRichText: true), findsOneWidget);
    });

    testWidgets('a search with no hits says so', (tester) async {
      await pumpLedger(tester);
      await pressCtrlF(tester);
      await typeQuery(tester, 'walmart');
      expect(find.text('No transactions match your search.'), findsOneWidget);
    });

    testWidgets('a search starts its results from the top', (tester) async {
      await pumpLedger(
        tester,
        extra: [
          for (var i = 0; i < 60; i++)
            _tx(
              'x$i',
              origin: 'Cafe $i',
            ).copyWith(occurredAt: DateTime(2026, 6, 1).add(Duration(days: i))),
        ],
      );
      final scrollable = find.byType(Scrollable).first;
      await tester.drag(scrollable, const Offset(0, -3000));
      await tester.pumpAndSettle();
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.pixels, greaterThan(0));

      await pressCtrlF(tester);
      await typeQuery(tester, 'cafe');
      await tester.pumpAndSettle();
      expect(position.pixels, 0);
    });
  });
}
