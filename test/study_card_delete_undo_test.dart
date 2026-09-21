// The undo toast on a flashcard deleted mid-study.
//
// A review session and a cram round both work from an in-memory arrangement of
// cards taken when they opened, and both prune it against the live card list on
// every build. That makes the restore a two-step move: the row has to be back
// in the provider *before* the card is put back into the arrangement, or the
// very next build drops it again — permanently, since neither the queue nor the
// bucket map can ever re-admit a card it has lost.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_cram_page.dart';
import 'package:voyager/features/study/study_session_page.dart';

import 'fakes/fake_weather_api_client.dart';
import 'fakes/input_order_random.dart';
import 'fakes/memory_session_checkpoints.dart';

const _deckId = 'study-delete-deck';

/// Seeds a deck of [count] cards, all due now so a session queues every one.
Future<AppDatabase> _seedDeck(int count) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftStudyRepository(db);
  final now = DateTime.now().toUtc();
  await repo.upsertDeck(
    StudyDeck(id: _deckId, name: 'Deck', createdAt: now, updatedAt: now),
  );
  for (var i = 0; i < count; i++) {
    await repo.upsertCard(
      StudyCard(
        id: 'card-$i',
        deckId: _deckId,
        frontText: 'Front $i',
        backText: 'Back $i',
        dueAt: now.subtract(const Duration(days: 1)),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
  return db;
}

Future<void> _pump(WidgetTester tester, AppDatabase db, Widget page) async {
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      memorySessionCheckpoints(),
      noSessionShuffle,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: page),
    ),
  );
  await _settle(tester);
}

/// Neither page settles: the flip card and the cram spring keep tickers alive.
Future<void> _settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Right-clicks the card on screen and deletes it, confirming the dialog.
Future<void> _deleteShownCard(WidgetTester tester, String front) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text(front).first),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await _settle(tester);

  await tester.tap(find.text('Delete'));
  await _settle(tester);
  expect(find.text('Delete this card?'), findsOneWidget);
  await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
  await _settle(tester);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('undo puts the deleted card back in front of the session', (
    tester,
  ) async {
    final db = await _seedDeck(3);
    await _pump(
      tester,
      db,
      const StudySessionPage(cardIds: {'card-0', 'card-1', 'card-2'}),
    );

    expect(find.text('Front 0'), findsOneWidget);
    await _deleteShownCard(tester, 'Front 0');

    expect(find.text('Front 0'), findsNothing);
    expect(find.text('Deleted "Front 0"'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await _settle(tester);

    expect(
      find.text('Front 0'),
      findsOneWidget,
      reason: 'undo brings the session back to the card it was taken off',
    );
    final restored = (await DriftStudyRepository(
      db,
    ).listCards(_deckId)).where((c) => c.id == 'card-0');
    expect(restored, hasLength(1));
    expect(restored.single.deletedAt, isNull);
  });

  testWidgets('undo puts the deleted card back in front of the cram round', (
    tester,
  ) async {
    final db = await _seedDeck(3);
    await _pump(tester, db, const StudyCramPage(deckId: _deckId));

    expect(find.text('Front 0'), findsOneWidget);
    await _deleteShownCard(tester, 'Front 0');

    expect(find.text('Front 0'), findsNothing);

    await tester.tap(find.text('Undo'));
    await _settle(tester);

    expect(
      find.text('Front 0'),
      findsOneWidget,
      reason: 'undo brings cram back to the card it was taken off',
    );
  });
}
