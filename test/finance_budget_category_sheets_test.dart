// Fixes from the Phase 13–14 finance pass: budgets match tags ignoring case
// and refuse a second budget for a tag (BUG-115), the budget and category
// sheets keep keyboard focus
// through chip clicks and a refused Enter (BUG-117), a tag can be in one
// category only (BUG-118), every view files an expense under the category of
// its first tag (BUG-119), deleting a category offers Undo (BUG-120), and
// expense amounts stay readable in Light (BUG-114).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/features/finance/finance_budget_modal.dart';
import 'package:voyager/features/finance/finance_category_modal.dart';
import 'package:voyager/features/finance/finance_page.dart';
import 'package:voyager/features/finance/finance_search.dart';

import 'fakes/fake_weather_api_client.dart';

FinancialTransaction _expense(
  String id,
  int cents,
  List<String> tags, {
  DateTime? at,
}) {
  final now = utcNow();
  return FinancialTransaction(
    id: id,
    createdAt: now,
    updatedAt: now,
    type: TransactionType.expense,
    amountCents: cents,
    occurredAt: at ?? DateTime.now(),
    tags: tags,
  );
}

FinanceCategory _category(String id, String name, List<String> tags) {
  final now = utcNow();
  return FinanceCategory(
    id: id,
    createdAt: now,
    updatedAt: now,
    name: name,
    tags: tags,
  );
}

/// Pumps [home] over an in-memory database seeded through [seed], and returns
/// the repository for checking what was written.
Future<DriftFinanceRepository> _pump(
  WidgetTester tester, {
  required Future<void> Function(DriftFinanceRepository repo) seed,
  required Widget Function() home,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftFinanceRepository(db);
  await seed(repo);

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
  await container.read(budgetsProvider.future);
  await container.read(financeCategoriesProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme,
        home: Scaffold(body: home()),
      ),
    ),
  );
  await _settle(tester);
  return repo;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// A button that opens a sheet through [open], for [_pump]'s `home`.
Widget _opener(void Function(BuildContext context, WidgetRef ref) open) =>
    Consumer(
      builder: (context, ref, _) => TextButton(
        onPressed: () => open(context, ref),
        child: const Text('open'),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await _settle(tester);
}

Finder _field(int index) => find.byType(EditableText).at(index);

bool _hasFocus(WidgetTester tester, int index) =>
    tester.widget<EditableText>(_field(index)).focusNode.hasFocus;

String _text(WidgetTester tester, int index) =>
    tester.widget<EditableText>(_field(index)).controller.text;

Future<void> _pressCtrlEnter(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await _settle(tester);
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  group('BUG-115 budgets and tag case', () {
    test('a budget counts its tag in any case', () {
      final now = DateTime(2026, 10, 7);
      final spent = budgetSpentCents(
        [
          _expense('a', 4000, ['groceries'], at: now),
          _expense('b', 7000, ['Groceries'], at: now),
          _expense('c', 500, ['food'], at: now),
        ],
        'groceries',
        now,
      );
      expect(spent, 11000);
    });

    testWidgets('a second budget for a tag is refused, not overwritten', (
      tester,
    ) async {
      final repo = await _pump(
        tester,
        seed: (repo) async {
          final now = utcNow();
          await repo.upsertBudget(
            Budget(
              id: 'b1',
              createdAt: now,
              updatedAt: now,
              tag: 'groceries',
              limitCents: 10000,
            ),
          );
        },
        home: () => _opener((context, ref) => showBudgetModal(context, ref)),
      );
      await _open(tester);

      await tester.enterText(_field(0), 'Groceries');
      await tester.enterText(_field(1), '200');
      await tester.pump();
      expect(
        find.text('#groceries already has a budget. Edit that one instead.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Add'));
      await _pressCtrlEnter(tester);
      final budgets = await repo.listBudgets();
      expect(budgets, hasLength(1));
      expect(budgets.single.tag, 'groceries');
      expect(budgets.single.limitCents, 10000);
    });
  });

  test('BUG-115 the budget expense list counts what its bar counts', () {
    final upper = _expense('a', 7000, ['Groceries']);
    final lower = _expense('b', 4000, ['groceries']);
    const budget = FinanceLedgerFilter.budget('groceries');
    expect(budget.matches(upper, const []), isTrue);
    expect(budget.matches(lower, const []), isTrue);
    // A Tag breakdown slice keeps the spellings apart, and so does its filter.
    const slice = FinanceLedgerFilter.tag('groceries');
    expect(slice.matches(upper, const []), isFalse);
    expect(slice.matches(lower, const []), isTrue);
  });

  group('BUG-117 sheets keep keyboard focus', () {
    Future<void> seedTags(DriftFinanceRepository repo) async {
      await repo.upsertTransaction(_expense('t1', 500, ['groceries']));
      await repo.upsertTransaction(_expense('t2', 500, ['travel']));
    }

    testWidgets(
      'clicking a budget tag chip moves on to the limit',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        await _pump(
          tester,
          seed: seedTags,
          home: () => _opener((context, ref) => showBudgetModal(context, ref)),
        );
        await _open(tester);
        await tester.enterText(_field(0), 'gro');
        await tester.pump();

        await tester.tap(
          find.text('#groceries'),
          kind: PointerDeviceKind.mouse,
        );
        await _settle(tester);
        expect(_text(tester, 0), 'groceries');
        expect(_hasFocus(tester, 1), isTrue, reason: 'Monthly limit');
      },
    );

    testWidgets('Enter on a refused limit keeps the caret there', (
      tester,
    ) async {
      await _pump(
        tester,
        seed: seedTags,
        home: () => _opener((context, ref) => showBudgetModal(context, ref)),
      );
      await _open(tester);
      await tester.enterText(_field(0), 'groceries');
      await tester.showKeyboard(_field(1));
      await tester.enterText(_field(1), '0');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester);

      expect(find.text(r'Enter a limit over $0.00'), findsOneWidget);
      expect(_hasFocus(tester, 1), isTrue);
    });

    testWidgets(
      'Ctrl+Enter still adds a category after clicking its tag chips',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final repo = await _pump(
          tester,
          seed: seedTags,
          home: () =>
              _opener((context, ref) => showCategoryModal(context, ref)),
        );
        await _open(tester);
        await tester.enterText(_field(0), 'Transit');
        for (final chip in ['#travel', '#groceries']) {
          await tester.tap(find.text(chip), kind: PointerDeviceKind.mouse);
          await _settle(tester);
          expect(_hasFocus(tester, 0), isTrue, reason: chip);
        }

        await _pressCtrlEnter(tester);
        final saved = (await repo.listCategories()).single;
        expect(saved.name, 'Transit');
        expect(saved.tags, ['groceries', 'travel']);
      },
    );
  });

  testWidgets('BUG-118 a tag already in another category is refused', (
    tester,
  ) async {
    final repo = await _pump(
      tester,
      seed: (repo) async {
        await repo.upsertTransaction(_expense('t1', 500, ['food']));
        await repo.upsertTransaction(_expense('t2', 500, ['travel']));
        await repo.upsertCategory(_category('c1', 'Food', ['Food']));
      },
      home: () => _opener((context, ref) => showCategoryModal(context, ref)),
    );
    await _open(tester);
    await tester.enterText(_field(0), 'Transit');
    await tester.tap(find.text('#food'));
    await tester.tap(find.text('#travel'));
    await tester.pump();
    expect(
      find.text(
        '#food is already in "Food". A tag can be in one category '
        'only.',
      ),
      findsNothing,
      reason: 'a later valid pick clears the warning',
    );
    await tester.tap(find.text('#food'));
    await tester.pump();
    expect(
      find.text(
        '#food is already in "Food". A tag can be in one category '
        'only.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Add'));
    await _settle(tester);
    final transit = (await repo.listCategories()).firstWhere(
      (c) => c.name == 'Transit',
    );
    expect(transit.tags, ['travel']);
  });

  testWidgets('BUG-118 a tag taken after the sheet opened is refused at save', (
    tester,
  ) async {
    final repo = await _pump(
      tester,
      seed: (repo) => repo.upsertTransaction(_expense('t1', 500, ['food'])),
      home: () => _opener((context, ref) => showCategoryModal(context, ref)),
    );
    await _open(tester);
    // Written behind the sheet's back: its list of categories is now stale,
    // so the chip lets #food through.
    await repo.upsertCategory(_category('c1', 'Food', ['food']));
    await tester.enterText(_field(0), 'Transit');
    await tester.tap(find.text('#food'));
    await tester.pump();

    await tester.tap(find.text('Add'));
    await _settle(tester);
    expect(
      find.text(
        '#food is already in "Food". A tag can be in one category only.',
      ),
      findsOneWidget,
    );
    expect((await repo.listCategories()).map((c) => c.name), ['Food']);
  });

  test('BUG-119 an expense belongs to the category of its first tag', () {
    final food = _category('c1', 'Zfood', ['food', 'thai']);
    final transit = _category('c2', 'Transit', ['travel']);
    final categories = [transit, food];
    expect(categoryForTags(['travel', 'food'], categories), same(transit));
    expect(categoryForTags(['Food', 'travel'], categories), same(food));
    expect(categoryForTags(['misc', 'food'], categories), isNull);
    expect(categoryForTags(const [], categories), isNull);
  });

  testWidgets('BUG-120 deleting a category offers Undo, which restores it', (
    tester,
  ) async {
    final category = _category('c1', 'Transit', ['travel']);
    final repo = await _pump(
      tester,
      seed: (repo) => repo.upsertCategory(category),
      home: () => _opener(
        (context, ref) => showCategoryModal(context, ref, existing: category),
      ),
    );
    await _open(tester);

    await tester.tap(find.byTooltip('Delete'));
    await _settle(tester);
    expect(find.text('Deleted "Transit"'), findsOneWidget);
    expect(await repo.listCategories(), isEmpty);

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    final restored = (await repo.listCategories()).single;
    expect(restored.name, 'Transit');
    expect(restored.tags, ['travel']);
  });

  testWidgets('BUG-120 Undo leaves out a tag another category took meanwhile', (
    tester,
  ) async {
    final category = _category('c1', 'Transit', ['travel', 'bus']);
    final repo = await _pump(
      tester,
      seed: (repo) => repo.upsertCategory(category),
      home: () => _opener(
        (context, ref) => showCategoryModal(context, ref, existing: category),
      ),
    );
    await _open(tester);
    await tester.tap(find.byTooltip('Delete'));
    await _settle(tester);
    await repo.upsertCategory(_category('c2', 'Trips', ['Travel']));

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    final restored = (await repo.listCategories()).firstWhere(
      (c) => c.id == 'c1',
    );
    expect(restored.tags, ['bus']);
  });

  testWidgets('BUG-114 expense amounts and UPCOMING read on cream in Light', (
    tester,
  ) async {
    final theme = VoyagerTheme.light();
    await _pump(
      tester,
      theme: theme,
      seed: (repo) async {
        final today = DateTime.now();
        await repo.upsertTransaction(_expense('t1', 400, const []));
        await repo.upsertTransaction(
          _expense(
            'future',
            900,
            const [],
            at: DateTime(today.year, today.month, today.day + 5),
          ),
        );
      },
      home: () => const FinancePage(),
    );

    final cream = theme.scaffoldBackgroundColor;
    for (final label in [r'-$4.00', 'UPCOMING']) {
      final color = tester.widget<Text>(find.text(label).first).style!.color!;
      expect(_contrast(color, cream), greaterThanOrEqualTo(4.5), reason: label);
    }
  });
}
