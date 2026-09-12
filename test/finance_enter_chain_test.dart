// Finance sheets walk their text fields on Enter and commit on Ctrl+Enter
// (CTRL_ENTER_SUBMIT_HLD.md §5). The transaction sheet is the one that gets
// the full treatment here because it is the awkward one: its last field is
// multiline, so Enter there must stay a newline, and its Tags field sits behind
// a completion popup that bare Enter belongs to but Ctrl+Enter must not.
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

Future<DriftFinanceRepository> _openTransactionSheet(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftFinanceRepository(db);
  // One tagged row, so `#gro` has something to complete to.
  final now = utcNow();
  await repo.upsertTransaction(
    FinancialTransaction(
      id: 'seed',
      createdAt: now,
      updatedAt: now,
      type: TransactionType.expense,
      amountCents: 500,
      occurredAt: DateTime(2026, 8, 1),
      tags: const ['groceries'],
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

/// Amount, Tags, Note — the sheet's text fields in visual order.
Finder _field(int index) => find.byType(EditableText).at(index);

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
    (await repo.listTransactions()).where((t) => t.id != 'seed').toList();

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('Enter walks Amount → Tags → Note without saving', (
    tester,
  ) async {
    final repo = await _openTransactionSheet(tester);
    expect(_hasFocus(tester, 0), isTrue, reason: 'Amount autofocuses');

    await tester.enterText(_field(0), '12.50');
    await _pressEnter(tester);
    expect(_hasFocus(tester, 1), isTrue, reason: 'Amount → Tags');
    expect(_sheetOpen(), isTrue);

    await tester.enterText(_field(1), 'food');
    await _pressEnter(tester);
    expect(_hasFocus(tester, 2), isTrue, reason: 'Tags → Note');

    await _pressEnter(tester, multiline: true);
    await _settle(tester);
    expect(_sheetOpen(), isTrue, reason: 'Enter in the multiline note');
    expect(_hasFocus(tester, 2), isTrue);
    expect(await _added(repo), isEmpty);
  });

  testWidgets('Ctrl+Enter from the note saves and closes', (tester) async {
    final repo = await _openTransactionSheet(tester);
    await tester.enterText(_field(0), '12.50');
    await tester.enterText(_field(2), 'Dinner');
    expect(_hasFocus(tester, 2), isTrue);

    await _pressCtrlEnter(tester);

    expect(_sheetOpen(), isFalse);
    final added = await _added(repo);
    expect(added, hasLength(1));
    expect(added.single.amountCents, 1250);
    expect(added.single.note, 'Dinner');
  });

  testWidgets('Ctrl+Enter from Amount saves and closes', (tester) async {
    final repo = await _openTransactionSheet(tester);
    await tester.enterText(_field(0), '3');

    await _pressCtrlEnter(tester);

    expect(_sheetOpen(), isFalse);
    expect((await _added(repo)).single.amountCents, 300);
  });

  testWidgets('Ctrl+Enter on an invalid form neither saves nor closes', (
    tester,
  ) async {
    final repo = await _openTransactionSheet(tester);
    await tester.enterText(_field(2), 'no amount yet');

    await _pressCtrlEnter(tester);

    expect(_sheetOpen(), isTrue);
    expect(await _added(repo), isEmpty);
    expect(
      tester.widget<EditableText>(_field(2)).controller.text,
      'no amount yet',
      reason: 'the claimed chord must not reach the note as a newline',
    );
  });

  testWidgets('Enter takes the tag suggestion; Ctrl+Enter skips it', (
    tester,
  ) async {
    final repo = await _openTransactionSheet(tester);
    await tester.enterText(_field(0), '8');
    await tester.enterText(_field(1), '#gro');
    await _settle(tester);
    expect(find.text('#groceries'), findsOneWidget, reason: 'popup is open');

    await _pressCtrlEnter(tester);

    expect(_sheetOpen(), isFalse);
    expect((await _added(repo)).single.tags, ['gro']);
  });

  testWidgets('bare Enter in Tags still accepts an open suggestion', (
    tester,
  ) async {
    await _openTransactionSheet(tester);
    await tester.enterText(_field(1), '#gro');
    await _settle(tester);

    await _pressEnter(tester);

    expect(
      tester.widget<EditableText>(_field(1)).controller.text,
      startsWith('#groceries'),
    );
    expect(_hasFocus(tester, 1), isTrue, reason: 'accepting is not advancing');
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
