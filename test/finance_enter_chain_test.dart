// Finance sheets walk their text fields on Enter and commit on Ctrl+Enter
// (CTRL_ENTER_SUBMIT_HLD.md §5). The transaction sheet is the one that gets
// the full treatment here because it is the awkward one: its Store/Source
// field and its Tags field both sit behind a completion list that bare Enter
// belongs to but Ctrl+Enter must not, and Enter in Tags — the last field —
// saves (FINANCE_TRANSACTION_ORIGIN_HLD.md §5).
//
// A real Enter reaches a single-line field twice — as a key event through the
// focus tree, then as the platform's `done` action if nothing claimed the key.
// flutter_test only delivers the first, so [_pressEnter] sends both.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';

import 'fakes/fake_weather_api_client.dart';

Future<DriftFinanceRepository> _openTransactionSheet(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftFinanceRepository(db);
  // One tagged row, so `#gro` has something to complete to, and one origin of
  // each type for the Store/Source list.
  final now = utcNow();
  await repo.upsertTransaction(
    FinancialTransaction(
      id: 'seed',
      createdAt: now,
      updatedAt: now,
      type: TransactionType.expense,
      amountCents: 500,
      occurredAt: DateTime(2026, 8, 1),
      origin: 'Loblaws',
      tags: const ['groceries'],
    ),
  );
  await repo.upsertTransaction(
    FinancialTransaction(
      id: 'seed-deposit',
      createdAt: now,
      updatedAt: now,
      type: TransactionType.deposit,
      amountCents: 90000,
      occurredAt: DateTime(2026, 8, 1),
      origin: 'Payroll',
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
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showFinanceTransactionModal(context, ref),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
  return repo;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Amount, Store/Source, Note, Tags — the sheet's text fields in visual order.
Finder _field(int index) => find.byType(EditableText).at(index);

const _amount = 0;
const _origin = 1;
const _note = 2;
const _tags = 3;

String _text(WidgetTester tester, int index) =>
    tester.widget<EditableText>(_field(index)).controller.text;

bool _hasFocus(WidgetTester tester, int index) =>
    tester.widget<EditableText>(_field(index)).focusNode.hasFocus;

bool _sheetOpen() => find.byType(EditableText).evaluate().isNotEmpty;

Future<void> _pressEnter(WidgetTester tester, {bool multiline = false}) async {
  final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  if (!handled) {
    await tester.testTextInput.receiveAction(
      multiline ? TextInputAction.newline : TextInputAction.done,
    );
  }
  await tester.pump();
}

Future<void> _pressCtrlEnter(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await _settle(tester);
}

Future<List<FinancialTransaction>> _added(DriftFinanceRepository repo) async =>
    (await repo.listTransactions())
        .where((t) => !t.id.startsWith('seed'))
        .toList();

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('Enter walks Amount → Store → Note → Tags, then saves', (
    tester,
  ) async {
    final repo = await _openTransactionSheet(tester);
    expect(_hasFocus(tester, _amount), isTrue, reason: 'Amount autofocuses');

    await tester.enterText(_field(_amount), '12.50');
    await _pressEnter(tester);
    expect(_hasFocus(tester, _origin), isTrue, reason: 'Amount → Store');
    expect(_sheetOpen(), isTrue);

    // Typed past the suggestion, so the list is closed and Enter moves on.
    await tester.enterText(_field(_origin), '  Costco  ');
    await _pressEnter(tester);
    expect(_hasFocus(tester, _note), isTrue, reason: 'Store → Note');

    await tester.enterText(_field(_note), 'Toothpaste');
    await _pressEnter(tester);
    expect(_hasFocus(tester, _tags), isTrue, reason: 'Note → Tags');
    expect(_text(tester, _note), 'Toothpaste', reason: 'no newline inserted');
    expect(await _added(repo), isEmpty);

    await tester.enterText(_field(_tags), 'food');
    await _pressEnter(tester);
    await _settle(tester);

    expect(_sheetOpen(), isFalse, reason: 'Enter in Tags saves');
    final added = (await _added(repo)).single;
    expect(added.amountCents, 1250);
    expect(added.origin, 'Costco', reason: 'trimmed on save');
    expect(added.note, 'Toothpaste');
    expect(added.tags, ['food']);
  });

  testWidgets('Enter in Tags on an invalid form neither saves nor closes', (
    tester,
  ) async {
    final repo = await _openTransactionSheet(tester);
    await tester.enterText(_field(_tags), 'food');
    await _pressEnter(tester);
    await _settle(tester);

    expect(_sheetOpen(), isTrue);
    expect(await _added(repo), isEmpty);
  });

  testWidgets('Store opens on recents; first Enter fills, second advances', (
    tester,
  ) async {
    final repo = await _openTransactionSheet(tester);
    await tester.enterText(_field(_amount), '4');
    await _pressEnter(tester);
    await tester.pump();

    expect(_hasFocus(tester, _origin), isTrue);
    expect(find.text('Loblaws'), findsOneWidget, reason: 'recents on focus');
    expect(
      find.text('Payroll'),
      findsNothing,
      reason: 'a deposit source is not an expense store',
    );

    await _pressEnter(tester);
    expect(_text(tester, _origin), 'Loblaws');
    expect(_hasFocus(tester, _origin), isTrue, reason: 'filling is not moving');

    await _pressEnter(tester);
    expect(_hasFocus(tester, _note), isTrue);

    await _pressCtrlEnter(tester);
    final added = (await _added(repo)).single;
    expect(added.origin, 'Loblaws');
    expect(added.note, isNull, reason: 'an empty note saves as null');
  });

  testWidgets('typing filters the store list case-insensitively', (
    tester,
  ) async {
    await _openTransactionSheet(tester);
    await tester.enterText(_field(_origin), 'lOB');
    await tester.pump();
    expect(find.text('Loblaws'), findsOneWidget);

    await tester.enterText(_field(_origin), 'xyz');
    await tester.pump();
    expect(find.text('Loblaws'), findsNothing);
  });

  testWidgets('switching to Deposit clears the store and offers sources', (
    tester,
  ) async {
    final repo = await _openTransactionSheet(tester);
    await tester.enterText(_field(_amount), '900');
    await tester.enterText(_field(_origin), 'Loblaws');
    await tester.enterText(_field(_note), 'Paycheque');

    await tester.tap(find.text('Deposit'));
    await _settle(tester);

    expect(_text(tester, _origin), isEmpty);
    expect(_text(tester, _note), 'Paycheque', reason: 'only origin is cleared');
    expect(_text(tester, _amount), '900');

    await tester.tap(_field(_origin));
    await tester.pump();
    expect(find.text('Payroll'), findsOneWidget);
    expect(find.text('Loblaws'), findsNothing);

    await _pressCtrlEnter(tester);
    final added = (await _added(repo)).single;
    expect(added.type, TransactionType.deposit);
    expect(added.origin, isNull);
  });

  testWidgets('switching type closes an open store list', (tester) async {
    await _openTransactionSheet(tester);
    await tester.tap(_field(_origin));
    await tester.pump();
    expect(find.text('Loblaws'), findsOneWidget, reason: 'list is open');

    await tester.tap(find.text('Deposit'));
    await _settle(tester);

    expect(find.text('Loblaws'), findsNothing);
    expect(
      find.text('Payroll'),
      findsNothing,
      reason: 'closed, not re-offered under the new label',
    );
  });

  testWidgets('an open store list follows the ledger changing underneath it', (
    tester,
  ) async {
    final repo = await _openTransactionSheet(tester);
    await tester.tap(_field(_origin));
    await tester.pump();
    expect(find.text('Loblaws'), findsOneWidget);
    expect(find.text('Costco'), findsNothing);

    final now = utcNow();
    await repo.upsertTransaction(
      FinancialTransaction(
        id: 'seed-costco',
        createdAt: now,
        updatedAt: now,
        type: TransactionType.expense,
        amountCents: 700,
        occurredAt: DateTime(2026, 8, 2),
        origin: 'Costco',
      ),
    );
    ProviderScope.containerOf(
      tester.element(_field(_origin)),
      listen: false,
    ).invalidate(transactionsProvider);
    await _settle(tester);
    // The rebuild with the new ledger, then the deferred refresh's frame.
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Costco'), findsOneWidget, reason: 'refreshed, not stale');
    expect(find.text('Loblaws'), findsOneWidget);
  });

  testWidgets('Tab in the note moves on instead of indenting a list', (
    tester,
  ) async {
    await _openTransactionSheet(tester);
    await tester.enterText(_field(_note), '- item');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(_text(tester, _note), '- item');
    expect(_hasFocus(tester, _note), isFalse);
  });

  testWidgets('Ctrl+Enter from the note saves and closes', (tester) async {
    final repo = await _openTransactionSheet(tester);
    await tester.enterText(_field(_amount), '12.50');
    await tester.enterText(_field(_note), 'Dinner');
    expect(_hasFocus(tester, _note), isTrue);

    await _pressCtrlEnter(tester);

    expect(_sheetOpen(), isFalse);
    final added = await _added(repo);
    expect(added, hasLength(1));
    expect(added.single.amountCents, 1250);
    expect(added.single.note, 'Dinner');
  });

  testWidgets('Ctrl+Enter from Amount saves and closes', (tester) async {
    final repo = await _openTransactionSheet(tester);
    await tester.enterText(_field(_amount), '3');

    await _pressCtrlEnter(tester);

    expect(_sheetOpen(), isFalse);
    expect((await _added(repo)).single.amountCents, 300);
  });

  testWidgets('Ctrl+Enter on an invalid form neither saves nor closes', (
    tester,
  ) async {
    final repo = await _openTransactionSheet(tester);
    await tester.enterText(_field(_note), 'no amount yet');

    await _pressCtrlEnter(tester);

    expect(_sheetOpen(), isTrue);
    expect(await _added(repo), isEmpty);
    expect(
      _text(tester, _note),
      'no amount yet',
      reason: 'the claimed chord must not reach the note',
    );
  });

  testWidgets('Enter takes the tag suggestion; Ctrl+Enter skips it', (
    tester,
  ) async {
    final repo = await _openTransactionSheet(tester);
    await tester.enterText(_field(_amount), '8');
    await tester.enterText(_field(_tags), '#gro');
    await _settle(tester);
    expect(find.text('#groceries'), findsOneWidget, reason: 'popup is open');

    await _pressCtrlEnter(tester);

    expect(_sheetOpen(), isFalse);
    expect((await _added(repo)).single.tags, ['gro']);
  });

  testWidgets('bare Enter in Tags still accepts an open suggestion', (
    tester,
  ) async {
    final repo = await _openTransactionSheet(tester);
    await tester.enterText(_field(_amount), '8');
    await tester.enterText(_field(_tags), '#gro');
    await _settle(tester);

    await _pressEnter(tester);
    await _settle(tester);

    expect(_sheetOpen(), isTrue, reason: 'accepting is not saving');
    expect(_text(tester, _tags), startsWith('#groceries'));
    expect(_hasFocus(tester, _tags), isTrue);
    expect(await _added(repo), isEmpty);
  });

  testWidgets('the scope fires while a text field has focus', (tester) async {
    var submits = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CtrlEnterToSubmitScope(
            onSubmit: () => submits++,
            child: TextField(controller: controller, autofocus: true),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(submits, 0, reason: 'bare Enter is not the chord');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(submits, 2);
  });

  testWidgets('an autofocused scope fires with no field on the surface', (
    tester,
  ) async {
    var submits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CtrlEnterToSubmitScope(
            onSubmit: () => submits++,
            autofocus: true,
            child: Checkbox(value: false, onChanged: (_) {}),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(submits, 1);
  });

  // The two scopes nest, and [EnterToSubmitScope] is the inner one on the
  // dialogs that have both. Its Enter test is "no text field has focus", which
  // a focused button also passes — so without the chord check it answered
  // Ctrl+Enter with its own action and the chord never surfaced.
  testWidgets('a nested Enter scope leaves the chord alone', (tester) async {
    var submits = 0;
    var enters = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CtrlEnterToSubmitScope(
            onSubmit: () => submits++,
            child: EnterToSubmitScope(
              onSubmit: () => enters++,
              // A focusable that isn't a field: the button-focused case.
              child: const Focus(autofocus: true, child: SizedBox.shrink()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(enters, 1, reason: 'bare Enter still belongs to the inner scope');
    expect(submits, 0);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(submits, 1, reason: 'the chord reached the outer scope');
    expect(enters, 1, reason: 'and was not also taken as a bare Enter');
  });
}
