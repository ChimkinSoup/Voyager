// A resumed round, and the keys and toast around a live session, measured
// against what else happened while it was away or covered: a grade made in
// another session (BUG-192), a linked subset sharing the parent's slot
// (BUG-193), the card editor over the session (BUG-194), the resume toast
// outliving its page (BUG-196), and a card restored from the Trash after a
// mid-session delete (BUG-197).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/session_resume/session_checkpoint_store.dart';
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

const _deckId = 'resume-scope-deck';
const _deckSlot = 'studySession__deck:$_deckId';

class _Harness {
  _Harness(this.db, this.container, this.store);

  final AppDatabase db;
  final ProviderContainer container;
  final MemorySessionCheckpointStore store;
  Widget? next;

  DriftStudyRepository get repo => DriftStudyRepository(db);

  /// Pushes [page] over the launcher, the way the deck's buttons do.
  Future<void> open(WidgetTester tester, Widget page) async {
    next = page;
    await tester.tap(find.text('open'));
    await _settle(tester);
  }

  /// Back to the launcher: the route goes and the page disposes.
  Future<void> leave(WidgetTester tester) async {
    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await _settle(tester);
  }

  /// What a write made somewhere else needs before a session sees it.
  void refresh() => container.invalidate(studyAllCardsProvider);
}

Future<_Harness> _pump(WidgetTester tester, int count) async {
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
  final store = MemorySessionCheckpointStore();
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      memorySessionCheckpoints(store),
      noSessionShuffle,
    ],
  );
  addTearDown(container.dispose);
  final harness = _Harness(db, container, store);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      // A navigator of its own under the root one, as the shell's branches
      // have: the session is pushed there, while the card editor and the
      // delete confirm open on the root navigator and leave the session's
      // route current behind them (BUG-194).
      child: MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => harness.next!),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  return harness;
}

/// Neither page settles: the flip card and the cram spring keep tickers alive.
Future<void> _settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _gradeGood(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.space);
  await _settle(tester, 8);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
  await _settle(tester, 8);
}

Future<void> _rightClick(WidgetTester tester, String front) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text(front).first),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await _settle(tester);
}

/// Deletes the card on screen from its menu and waits out the toast's Undo.
Future<void> _deleteLettingUndoLapse(WidgetTester tester, String front) async {
  await _rightClick(tester, front);
  await tester.tap(find.text('Delete'));
  await _settle(tester);
  await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
  await _settle(tester);
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

/// Settings → Data → Trash → Restore, as far as the row is concerned.
Future<void> _restoreFromTrash(_Harness h, String id) async {
  final deleted = (await h.repo.listCards(
    _deckId,
    includeDeleted: true,
  )).firstWhere((c) => c.id == id);
  await h.repo.upsertCard(
    StudyCard(
      id: deleted.id,
      createdAt: deleted.createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: deleted.version + 1,
      deckId: deleted.deckId,
      frontText: deleted.frontText,
      backText: deleted.backText,
      dueAt: deleted.dueAt,
    ),
  );
  h.refresh();
}

const _deckRound = StudySessionPage(
  cardIds: {'card-0', 'card-1', 'card-2'},
  frameDeckId: _deckId,
);

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('BUG-192 a card graded elsewhere meanwhile leaves the resumed '
      'round', (tester) async {
    final h = await _pump(tester, 3);
    await h.open(tester, _deckRound);
    expect(find.text('Front 0'), findsOneWidget);
    await h.leave(tester);

    // Graded Good in another session sharing the card: due tomorrow now.
    final card = (await h.repo.getCard('card-0'))!;
    await h.repo.upsertCard(
      card.copyWith(
        interval: 1,
        reviewCount: 1,
        dueAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      ),
    );
    h.refresh();

    await h.open(tester, _deckRound);
    expect(
      find.text('Resuming your previous session · 2 left'),
      findsOneWidget,
    );
    expect(find.text('Front 1'), findsOneWidget);
    expect(find.text('Front 0'), findsNothing);
  });

  testWidgets('BUG-193 a linked subset has its own slot and leaves the '
      "parent's round alone", (tester) async {
    final h = await _pump(tester, 3);
    await h.open(tester, _deckRound);
    await h.leave(tester);
    expect(h.store.checkpoints[_deckSlot], isNotNull);

    await h.open(
      tester,
      const StudySessionPage(
        cardIds: {'card-0'},
        frameDeckId: _deckId,
        checkpointScope: 'subset:$_deckId:child',
      ),
    );
    expect(find.textContaining('Resuming'), findsNothing);
    await _gradeGood(tester);
    expect(find.text('Session complete'), findsOneWidget);
    await h.leave(tester);

    // The parent's round is still there to resume, less the card the subset
    // just graded.
    await h.open(tester, _deckRound);
    expect(
      find.text('Resuming your previous session · 2 left'),
      findsOneWidget,
    );
    expect(find.text('Front 1'), findsOneWidget);
  });

  testWidgets('BUG-194 keys typed with the card editor open stay out of the '
      'session behind it', (tester) async {
    final h = await _pump(tester, 2);
    await h.open(
      tester,
      const StudySessionPage(cardIds: {'card-0', 'card-1'}, frameDeckId: _deckId),
    );
    await _rightClick(tester, 'Front 0');
    await tester.tap(find.text('Edit…'));
    await _settle(tester);
    expect(find.text('Edit card'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _settle(tester, 8);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await _settle(tester, 8);

    expect((await h.repo.getCard('card-0'))!.reviewCount, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.text('Edit card'), findsNothing);
    expect(find.text('Front 0'), findsOneWidget);
  });

  testWidgets('BUG-194 arrows with the card editor open do not decide the cram '
      'card behind it', (tester) async {
    final h = await _pump(tester, 2);
    await h.open(tester, const StudyCramPage(deckId: _deckId));
    expect(find.text('Front 0'), findsOneWidget);
    await _rightClick(tester, 'Front 0');
    await tester.tap(find.text('Edit…'));
    await _settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);

    expect(find.text('Front 0'), findsOneWidget);
  });

  testWidgets('BUG-196 the resume toast goes with its session', (tester) async {
    final h = await _pump(tester, 2);
    const page = StudySessionPage(
      cardIds: {'card-0', 'card-1'},
      frameDeckId: _deckId,
    );
    await h.open(tester, page);
    await h.leave(tester);

    await h.open(tester, page);
    expect(find.text('Start over'), findsOneWidget);
    await h.leave(tester);
    await _settle(tester, 20);

    expect(find.text('Start over'), findsNothing);
    expect(h.store.checkpoints[_deckSlot], isNotNull);
  });

  testWidgets('BUG-197 a card deleted mid-round and restored from the Trash '
      'rejoins it', (tester) async {
    final h = await _pump(tester, 3);
    await h.open(tester, _deckRound);
    await _deleteLettingUndoLapse(tester, 'Front 0');
    await h.leave(tester);
    await _restoreFromTrash(h, 'card-0');
    h.refresh();

    await h.open(tester, _deckRound);
    expect(
      find.text('Resuming your previous session · 3 left'),
      findsOneWidget,
    );
    await _gradeGood(tester);
    await _gradeGood(tester);
    expect(find.text('Front 0'), findsOneWidget);
  });

  testWidgets('a card deleted mid-cram and restored from the Trash rejoins the '
      'run', (tester) async {
    final h = await _pump(tester, 3);
    const page = StudyCramPage(deckId: _deckId);
    await h.open(tester, page);
    expect(find.text('Front 0'), findsOneWidget);
    await _deleteLettingUndoLapse(tester, 'Front 0');
    await h.leave(tester);
    await _restoreFromTrash(h, 'card-0');

    await h.open(tester, page);
    expect(
      find.text('Resuming your previous session · 3 left'),
      findsOneWidget,
    );
  });

  // Code-review follow-ups to BUG-192 / BUG-197.

  testWidgets('an undo after a resume does not bring back a card graded '
      'elsewhere', (tester) async {
    final h = await _pump(tester, 3);
    await h.open(tester, _deckRound);
    await _gradeGood(tester);
    expect(find.text('Front 1'), findsOneWidget);
    await h.leave(tester);
    await _gradeElsewhere(h, 'card-1');

    await h.open(tester, _deckRound);
    expect(
      find.text('Resuming your previous session · 1 left'),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await _settle(tester);
    expect(find.text('Front 0'), findsOneWidget);
    await _gradeGood(tester);

    // The round the undo stepped back into, less the card graded elsewhere.
    expect(find.text('Front 2'), findsOneWidget);
    expect(find.text('Front 1'), findsNothing);
  });

  testWidgets("an undo after a resume leaves alone a card graded elsewhere "
      'since this round graded it', (tester) async {
    final h = await _pump(tester, 2);
    await h.open(tester, _deckRound);
    await _gradeGood(tester);
    await h.leave(tester);
    await _gradeElsewhere(h, 'card-0');
    final elsewhere = (await h.repo.getCard('card-0'))!;

    await h.open(tester, _deckRound);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await _settle(tester);

    final after = (await h.repo.getCard('card-0'))!;
    expect(after.reviewCount, elsewhere.reviewCount);
    expect(after.dueAt, elsewhere.dueAt);
  });

  testWidgets('a card a pull deletes mid-round and the Trash restores later '
      'rejoins it', (tester) async {
    final h = await _pump(tester, 3);
    await h.open(tester, _deckRound);
    expect(find.text('Front 0'), findsOneWidget);
    // Not from the card's menu: the way a delete from another device lands.
    await h.repo.softDeleteCard('card-0');
    h.refresh();
    await _settle(tester);
    expect(find.text('Front 0'), findsNothing);
    await h.leave(tester);
    await _restoreFromTrash(h, 'card-0');

    await h.open(tester, _deckRound);
    expect(
      find.text('Resuming your previous session · 3 left'),
      findsOneWidget,
    );
  });

  for (final (name, page, slot) in [
    ('session', _deckRound as Widget, _deckSlot),
    (
      'cram',
      const StudyCramPage(deckId: _deckId) as Widget,
      'studyCram__deck:$_deckId',
    ),
  ]) {
    testWidgets('a $name card brought back by the toast\'s Undo is known '
        'again', (tester) async {
      final h = await _pump(tester, 3);
      await h.open(tester, page);
      await _rightClick(tester, 'Front 0');
      await tester.tap(find.text('Delete'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
      await _settle(tester);
      await tester.tap(find.text('Undo'));
      await _settle(tester);
      expect(find.text('Front 0'), findsOneWidget);
      await h.leave(tester);

      // Graded and left, it must not come back as a newcomer when due again.
      expect(h.store.checkpoints[slot]!.sourceIds, contains('card-0'));
    });
  }
}

/// A Good grade from another session sharing the card — the Hub, or a deck
/// that links this one: due a day out, one review more.
Future<void> _gradeElsewhere(_Harness h, String id) async {
  final card = (await h.repo.getCard(id))!;
  await h.repo.upsertCard(
    card.copyWith(
      interval: 1,
      reviewCount: card.reviewCount + 1,
      dueAt: DateTime.now().toUtc().add(const Duration(days: 1)),
    ),
  );
  h.refresh();
}
