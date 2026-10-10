// The Study sheets that take typing: the name prompt (BUG-185), the card
// editor (BUG-186, BUG-187) and the import sheet (BUG-186's notes, BUG-189,
// BUG-190). Esc, the X and a click outside must not drop what was typed
// without asking; an empty name says why nothing happened; the card preview
// follows the text; Enter answers the "Skipped" dialog; and an import keeps
// the order it was pasted in.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_srs_engine.dart';
import 'package:voyager/features/study/study_card_editor_modal.dart';
import 'package:voyager/features/study/study_import_text_modal.dart';
import 'package:voyager/features/study/study_name_modal.dart';
import 'package:voyager/features/study/study_rich_text.dart';

import 'fakes/fake_weather_api_client.dart';

const _deckId = 'deck-1';

Future<ProviderContainer> _container() async {
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
  final now = DateTime.now().toUtc();
  await container
      .read(studyRepositoryProvider)
      .upsertDeck(
        StudyDeck(id: _deckId, name: 'Deck', createdAt: now, updatedAt: now),
      );
  return container;
}

/// A page with one "open" button that runs [open].
Future<void> _pumpLauncher(
  WidgetTester tester,
  ProviderContainer container,
  void Function(BuildContext context, WidgetRef ref) open,
) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => open(context, ref),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _esc(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

/// The card editor's Front or Back field.
Finder _field(String label) => find.descendant(
  of: find.byType(VoyagerTextField).at(label == 'Front' ? 0 : 1),
  matching: find.byType(EditableText),
);

Future<List<StudyCard>> _cards(ProviderContainer container) =>
    container.read(studyRepositoryProvider).listCards(_deckId);

void main() {
  testWidgets('BUG-185 an empty name says so and keeps the caret', (
    tester,
  ) async {
    final container = await _container();
    String? result = 'unset';
    await _pumpLauncher(tester, container, (context, _) async {
      result = await showStudyNameModal(context, title: 'New folder');
    });

    // Enter in the field, as the engine reports it.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('Name cannot be empty'), findsOneWidget);
    expect(find.text('New folder'), findsOneWidget);
    final focus = FocusManager.instance.primaryFocus;
    expect(
      focus?.context?.findAncestorWidgetOfExactType<EditableText>(),
      isNotNull,
    );

    // Typing lands in the field, clears the message, and Enter saves.
    await tester.enterText(find.byType(TextField), 'Math');
    await tester.pump();
    expect(find.text('Name cannot be empty'), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result, 'Math');
  });

  group('BUG-186 the card editor asks before dropping typing', () {
    testWidgets('a new card: Esc and the X ask; Keep editing keeps it', (
      tester,
    ) async {
      final container = await _container();
      await _pumpLauncher(
        tester,
        container,
        (context, ref) =>
            showStudyCardEditorModal(context, ref, deckId: _deckId),
      );
      await tester.enterText(_field('Front'), 'esc test unsaved front');
      await tester.pump();

      await _esc(tester);
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('New card'), findsOneWidget);
      expect(find.text('esc test unsaved front'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('New card'), findsNothing);
      expect(await _cards(container), isEmpty);
    });

    testWidgets('an existing card: unchanged closes at once, an edit asks', (
      tester,
    ) async {
      final container = await _container();
      final now = DateTime.now().toUtc();
      final card = StudyCard(
        id: 'card-1',
        deckId: _deckId,
        frontText: 'Front',
        backText: 'Back',
        dueAt: now,
        createdAt: now,
        updatedAt: now,
      );
      await container.read(studyRepositoryProvider).upsertCard(card);
      void open(BuildContext context, WidgetRef ref) =>
          showStudyCardEditorModal(
            context,
            ref,
            deckId: _deckId,
            existing: card,
          );

      await _pumpLauncher(tester, container, open);
      await _esc(tester);
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.text('Edit card'), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Front'), 'Front EDITED');
      await tester.pump();
      await _esc(tester);
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Edit card'), findsNothing);
      expect((await _cards(container)).single.frontText, 'Front');
    });

    testWidgets('the import sheet asks before dropping a paste', (
      tester,
    ) async {
      final container = await _container();
      await _pumpLauncher(
        tester,
        container,
        (context, ref) => showStudyImportTextModal(context, ref, _deckId),
      );
      await tester.enterText(find.byType(TextField), 'a|b');
      await tester.pump();

      await _esc(tester);
      expect(find.text('Discard pasted cards?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Import cards'), findsOneWidget);
      expect(find.text('a|b'), findsOneWidget);
    });
  });

  // The route's own drag pops past the sheet's PopScope, so the editors had
  // drag turned off, leaving Android's grab handle a dead control. The drag
  // is back on Android and asks first; desktop opens a dialog, which doesn't
  // drag at all.
  group('BUG-186 a drag down asks too', () {
    Future<void> dragDown(WidgetTester tester, String title) async {
      await tester.fling(find.text(title), const Offset(0, 400), 2000);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'on Android, a drag asks; Keep editing slides the sheet back',
      (tester) async {
        final container = await _container();
        await _pumpLauncher(
          tester,
          container,
          (context, ref) =>
              showStudyCardEditorModal(context, ref, deckId: _deckId),
        );
        final top = tester.getTopLeft(find.text('New card')).dy;
        await tester.enterText(_field('Front'), 'drag test unsaved front');
        await tester.pump();

        await dragDown(tester, 'New card');
        expect(find.text('Discard changes?'), findsOneWidget);
        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.text('New card')).dy, top);
        expect(find.text('drag test unsaved front'), findsOneWidget);

        await dragDown(tester, 'New card');
        await tester.tap(find.text('Discard'));
        await tester.pumpAndSettle();
        expect(find.text('New card'), findsNothing);
        expect(await _cards(container), isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'on Android, a drag closes an untouched import sheet at once',
      (tester) async {
        final container = await _container();
        await _pumpLauncher(
          tester,
          container,
          (context, ref) => showStudyImportTextModal(context, ref, _deckId),
        );
        await dragDown(tester, 'Import cards');
        expect(find.text('Discard pasted cards?'), findsNothing);
        expect(find.text('Import cards'), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'on desktop, a drag does nothing',
      (tester) async {
        final container = await _container();
        await _pumpLauncher(
          tester,
          container,
          (context, ref) => showStudyImportTextModal(context, ref, _deckId),
        );
        final top = tester.getTopLeft(find.text('Import cards')).dy;
        await dragDown(tester, 'Import cards');
        expect(find.text('Import cards'), findsOneWidget);
        expect(tester.getTopLeft(find.text('Import cards')).dy, top);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });

  group('BUG-187 the editor preview follows typing', () {
    testWidgets('a new card shows one as LaTeX is typed', (tester) async {
      final container = await _container();
      await _pumpLauncher(
        tester,
        container,
        (context, ref) =>
            showStudyCardEditorModal(context, ref, deckId: _deckId),
      );
      expect(find.byType(StudyRichText), findsNothing);

      const typed = r'What is $\int_0^1 x^2 dx$ ?';
      await tester.enterText(_field('Front'), typed);
      await tester.pump();
      expect(
        tester.widget<StudyRichText>(find.byType(StudyRichText)).text,
        typed,
      );
    });

    testWidgets('an edited card shows the new text, not the old', (
      tester,
    ) async {
      final container = await _container();
      final now = DateTime.now().toUtc();
      final card = StudyCard(
        id: 'card-1',
        deckId: _deckId,
        frontText: r'Area $\pi r^2$',
        backText: 'Back',
        dueAt: now,
        createdAt: now,
        updatedAt: now,
      );
      await container.read(studyRepositoryProvider).upsertCard(card);
      await _pumpLauncher(
        tester,
        container,
        (context, ref) => showStudyCardEditorModal(
          context,
          ref,
          deckId: _deckId,
          existing: card,
        ),
      );

      await tester.enterText(_field('Front'), r'Area $\pi r^2$ EDITED x');
      await tester.pump();
      expect(
        tester.widget<StudyRichText>(find.byType(StudyRichText)).text,
        r'Area $\pi r^2$ EDITED x',
      );
    });
  });

  testWidgets('BUG-189 Enter closes the "Skipped" dialog', (tester) async {
    final container = await _container();
    await _pumpLauncher(
      tester,
      container,
      (context, ref) => showStudyImportTextModal(context, ref, _deckId),
    );
    await tester.enterText(find.byType(TextField), 'q1|a1\nno pipe here');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Skipped 1 line'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Skipped 1 line'), findsNothing);
  });

  testWidgets('BUG-190 imported cards keep their paste order', (tester) async {
    final container = await _container();
    await _pumpLauncher(
      tester,
      container,
      (context, ref) => showStudyImportTextModal(context, ref, _deckId),
    );
    final lines = [
      for (var i = 0; i < 40; i++)
        'Bulk Q${'$i'.padLeft(3, '0')}|Bulk A${'$i'.padLeft(3, '0')}',
    ];
    await tester.enterText(find.byType(TextField), lines.join('\n'));
    await tester.pump();
    await tester.tap(find.text('Import 40 cards'));
    await tester.pumpAndSettle();

    final sorted = sortStudyCardsByMastery(await _cards(container));
    expect(
      [for (final card in sorted) card.frontText],
      [for (final line in lines) line.split('|').first],
    );
  });
}
