// The card editor wrote both faces from the form, so a face another device
// changed while it was open was reverted on Save (BUG-233). Only a face
// edited here is written now.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_card_editor_modal.dart';

import 'fakes/fake_weather_api_client.dart';

const _deckId = 'deck-1';

void main() {
  testWidgets('saving a front edit keeps a back changed elsewhere meanwhile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    final now = DateTime.now().toUtc();
    await repo.upsertDeck(
      StudyDeck(id: _deckId, name: 'Deck', createdAt: now, updatedAt: now),
    );
    final card = StudyCard(
      id: 'card-1',
      deckId: _deckId,
      frontText: 'Front',
      backText: 'Back',
      dueAt: now,
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertCard(card);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showStudyCardEditorModal(
                  context,
                  ref,
                  deckId: _deckId,
                  existing: card,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Another device rewrites the back while the editor is open.
    await repo.upsertCard(card.copyWith(backText: 'Back from elsewhere'));

    await tester.enterText(
      find.descendant(
        of: find.byType(VoyagerTextField).first,
        matching: find.byType(EditableText),
      ),
      'Front edited',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final stored = await repo.getCard('card-1');
    expect(stored!.frontText, 'Front edited');
    expect(stored.backText, 'Back from elsewhere');
  });
}
