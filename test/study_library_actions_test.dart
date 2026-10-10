// BUG-188: deleting a Study folder or deck had no Undo toast — only the trash
// could bring it back — while a card delete and an unlink both offer one.
// The Undo goes through the trash, so it brings back exactly what the delete
// took: subfolders, decks and their cards.
//
// BUG-189: once a deck was open, no key led back to the library.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_actions.dart';
import 'package:voyager/features/study/study_card_editor_modal.dart';
import 'package:voyager/features/study/study_deck_workbench_page.dart';
import 'package:voyager/features/study/study_page.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.utc(2026, 10, 1);

StudyFolder _folder(String id, String name, {String? parent}) => StudyFolder(
  id: id,
  name: name,
  parentFolderId: parent,
  createdAt: _now,
  updatedAt: _now,
);

StudyDeck _deck(String id, String name, {String? parent}) => StudyDeck(
  id: id,
  name: name,
  parentFolderId: parent,
  createdAt: _now,
  updatedAt: _now,
);

StudyCard _card(String id, String deckId) => StudyCard(
  id: id,
  deckId: deckId,
  frontText: id,
  backText: id,
  dueAt: _now,
  createdAt: _now,
  updatedAt: _now,
);

/// Math holds deck Calc (1 card) and subfolder Algebra, which holds deck
/// Nested (2 cards).
Future<ProviderContainer> _seeded() async {
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
  final repo = container.read(studyRepositoryProvider);
  await repo.upsertFolder(_folder('math', 'Math'));
  await repo.upsertFolder(_folder('algebra', 'Algebra', parent: 'math'));
  await repo.upsertDeck(_deck('calc', 'Calc', parent: 'math'));
  await repo.upsertDeck(_deck('nested', 'Nested', parent: 'algebra'));
  await repo.upsertCard(_card('c1', 'calc'));
  await repo.upsertCard(_card('n1', 'nested'));
  await repo.upsertCard(_card('n2', 'nested'));
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget home,
) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: home)),
    ),
  );
  await _settle(tester);
}

/// Not pumpAndSettle: the toast keeps a timer running for its dwell.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _launch(
  WidgetTester tester,
  ProviderContainer container,
  Future<void> Function(BuildContext context, WidgetRef ref) action,
) => _pump(
  tester,
  container,
  Consumer(
    builder: (context, ref, _) => TextButton(
      onPressed: () => action(context, ref),
      child: const Text('delete'),
    ),
  ),
);

/// Every row the folder delete takes, live (true) or deleted (false).
Future<Map<String, bool>> _live(ProviderContainer container) async {
  final repo = container.read(studyRepositoryProvider);
  return {
    for (final id in ['math', 'algebra'])
      id: (await repo.getFolder(id))?.deletedAt == null,
    for (final id in ['calc', 'nested'])
      id: (await repo.getDeck(id))?.deletedAt == null,
    for (final id in ['c1', 'n1', 'n2'])
      id: (await repo.getCard(id))?.deletedAt == null,
  };
}

void main() {
  testWidgets('BUG-188 a folder delete offers Undo, which brings it all back', (
    tester,
  ) async {
    final container = await _seeded();
    final folder = (await container
        .read(studyRepositoryProvider)
        .getFolder('math'))!;
    await _launch(
      tester,
      container,
      (context, ref) => deleteStudyFolder(context, ref, folder),
    );

    await tester.tap(find.text('delete'));
    await _settle(tester);
    // The confirm counts the cards it takes too.
    expect(
      find.textContaining('1 subfolder, 2 decks, 3 cards'),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete'));
    await _settle(tester);

    expect(find.text('Deleted "Math"'), findsOneWidget);
    expect(
      (await tester.runAsync(() => _live(container)))!.values,
      everyElement(isFalse),
    );

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    expect(
      (await tester.runAsync(() => _live(container)))!.values,
      everyElement(isTrue),
    );
  });

  testWidgets(
    'BUG-188 a deck delete offers Undo, which brings its cards back',
    (tester) async {
      final container = await _seeded();
      final deck = (await container
          .read(studyRepositoryProvider)
          .getDeck('nested'))!;
      await _launch(
        tester,
        container,
        (context, ref) => deleteStudyDeck(context, ref, deck),
      );

      await tester.tap(find.text('delete'));
      await _settle(tester);
      await tester.tap(find.text('Delete'));
      await _settle(tester);
      expect(find.text('Deleted "Nested"'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await _settle(tester);
      final live = (await tester.runAsync(() => _live(container)))!;
      expect([live['nested'], live['n1'], live['n2']], [true, true, true]);
    },
  );

  testWidgets('BUG-188 a card synced in while the confirm is up goes too', (
    tester,
  ) async {
    final container = await _seeded();
    final repo = container.read(studyRepositoryProvider);
    final folder = (await repo.getFolder('math'))!;
    await _launch(
      tester,
      container,
      (context, ref) => deleteStudyFolder(context, ref, folder),
    );

    await tester.tap(find.text('delete'));
    await _settle(tester);
    await tester.runAsync(() => repo.upsertCard(_card('late', 'calc')));
    await tester.tap(find.text('Delete'));
    await _settle(tester);

    final late = (await tester.runAsync(() => repo.getCard('late')))!;
    expect(late.deletedAt, isNotNull);
  });

  testWidgets(
    'BUG-188 a deck delete takes a card synced in during the confirm',
    (tester) async {
      final container = await _seeded();
      final repo = container.read(studyRepositoryProvider);
      final deck = (await repo.getDeck('calc'))!;
      await _launch(
        tester,
        container,
        (context, ref) => deleteStudyDeck(context, ref, deck),
      );

      await tester.tap(find.text('delete'));
      await _settle(tester);
      await tester.runAsync(() => repo.upsertCard(_card('late', 'calc')));
      await tester.tap(find.text('Delete'));
      await _settle(tester);

      final late = (await tester.runAsync(() => repo.getCard('late')))!;
      expect(late.deletedAt, isNotNull);
    },
  );

  testWidgets('BUG-188 an Undo whose folder went since says where it put it', (
    tester,
  ) async {
    final container = await _seeded();
    final repo = container.read(studyRepositoryProvider);
    final deck = (await repo.getDeck('nested'))!;
    await _launch(
      tester,
      container,
      (context, ref) => deleteStudyDeck(context, ref, deck),
    );
    await tester.tap(find.text('delete'));
    await _settle(tester);
    await tester.tap(find.text('Delete'));
    await _settle(tester);

    // Its folder goes while the toast stands — from another pane or device.
    await tester.runAsync(
      () => repo.softDeleteFolder('algebra', at: DateTime.now().toUtc()),
    );
    await tester.tap(find.text('Undo'));
    await _settle(tester);

    expect(find.textContaining('"Nested" to Study'), findsOneWidget);
    final restored = (await tester.runAsync(() => repo.getDeck('nested')))!;
    expect(restored.deletedAt, isNull);
    expect(restored.parentFolderId, isNull);
  });

  for (final (name, press) in <(String, Future<void> Function(WidgetTester))>[
    ('Esc', (tester) => tester.sendKeyEvent(LogicalKeyboardKey.escape)),
    (
      'Alt+Left',
      (tester) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      },
    ),
  ]) {
    testWidgets('BUG-189 $name leaves a deck for the library', (tester) async {
      final container = await _seeded();
      await container
          .read(studyRepositoryProvider)
          .upsertDeck(_deck('root-deck', 'Root deck'));
      await _pump(tester, container, const StudyPage());

      await tester.tap(find.text('Root deck'));
      await _settle(tester);
      expect(find.byType(StudyDeckWorkbenchPage), findsOneWidget);

      await press(tester);
      await _settle(tester);
      expect(find.byType(StudyDeckWorkbenchPage), findsNothing);
      expect(find.text('Math'), findsOneWidget);
    });
  }

  testWidgets(
    'BUG-189 Esc in the card editor over a deck closes only the editor',
    (tester) async {
      final container = await _seeded();
      final repo = container.read(studyRepositoryProvider);
      await repo.upsertDeck(_deck('root-deck', 'Root deck'));
      final card = _card('r1', 'root-deck');
      await repo.upsertCard(card);
      // The page in a navigator of its own, as in the app's shell: the editor
      // goes on the root one, so the page's route stays current under it.
      await _pump(
        tester,
        container,
        Navigator(
          onGenerateRoute: (_) =>
              MaterialPageRoute<void>(builder: (_) => const StudyPage()),
        ),
      );
      await tester.tap(find.text('Root deck'));
      await _settle(tester);

      final workbench = tester.element(find.byType(StudyDeckWorkbenchPage));
      unawaited(
        showStudyCardEditorModal(
          workbench,
          workbench as WidgetRef,
          deckId: 'root-deck',
          existing: card,
        ),
      );
      await _settle(tester);
      expect(find.text('Edit card'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('Edit card'), findsNothing);
      expect(find.byType(StudyDeckWorkbenchPage), findsOneWidget);
    },
  );

  // The right-click menu is an overlay entry, not a route, so the checks
  // above don't see it.
  testWidgets('BUG-189 Esc over a card\'s right-click menu closes only it', (
    tester,
  ) async {
    final container = await _seeded();
    final repo = container.read(studyRepositoryProvider);
    await repo.upsertDeck(_deck('root-deck', 'Root deck'));
    await repo.upsertCard(_card('r1', 'root-deck'));
    await _pump(tester, container, const StudyPage());
    await tester.tap(find.text('Root deck'));
    await _settle(tester);

    await tester.tap(find.text('r1').first, buttons: kSecondaryButton);
    await _settle(tester);
    expect(find.text('Reverse'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.text('Reverse'), findsNothing);
    expect(find.byType(StudyDeckWorkbenchPage), findsOneWidget);
  });
}
