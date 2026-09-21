// Leaving a session mid-round is not throwing it away. Every exit that is not
// "finished" — Back to deck, the X, a process death — leaves a checkpoint, and
// the next Study or Cram open over the same scope picks the round up where it
// was: same card, same undo history, same buckets. Start over is the way out,
// and finishing is the only thing that ends a checkpoint on its own.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/session_resume/session_checkpoint.dart';
import 'package:voyager/core/session_resume/session_checkpoint_store.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/study/study_cram_page.dart';
import 'package:voyager/features/study/study_grading_row.dart';
import 'package:voyager/features/study/study_session_page.dart';

import 'fakes/input_order_random.dart';

const _deckId = 'resume-deck';
const _hubSlot = 'studySession__hub';
const _deckSlot = 'studySession__deck:$_deckId';
const _cramSlot = 'studyCram__deck:$_deckId';

class _StubStudyRepository implements StudyRepository {
  _StubStudyRepository(this.cards);

  List<StudyCard> cards;

  final logRows = <String, StudyReviewLog>{};

  List<StudyReviewLog> get liveLogs =>
      logRows.values.where((log) => log.deletedAt == null).toList();

  StudyCard card(String id) => cards.firstWhere((c) => c.id == id);

  @override
  Future<List<StudyCard>> getAllCards({bool includeDeleted = true}) async =>
      cards;

  @override
  Future<StudyCard?> getCard(String id) async =>
      cards.where((c) => c.id == id).firstOrNull;

  @override
  Future<List<StudyCard>> listCards(
    String deckId, {
    bool includeDeleted = false,
  }) async => cards.where((c) => c.deckId == deckId).toList();

  @override
  Future<void> upsertCard(
    StudyCard card, {
    bool recordLocalActivity = true,
  }) async {
    cards = [
      for (final c in cards)
        if (c.id == card.id) card else c,
    ];
  }

  @override
  Future<void> logReview(
    StudyReviewLog log, {
    bool recordLocalActivity = true,
  }) async => logRows[log.id] = log;

  @override
  Future<StudyReviewLog?> getReviewLog(String id) async => logRows[id];

  @override
  Future<void> softDeleteReviewLog(String id) async {
    final current = logRows[id];
    if (current == null || current.deletedAt != null) return;
    logRows[id] = current.deleted();
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

StudyCard _card(int i, {DateTime? dueAt}) {
  final now = DateTime.utc(2026, 8, 9, 12);
  return StudyCard(
    id: 'card-$i',
    createdAt: now,
    updatedAt: now,
    deckId: _deckId,
    frontText: 'Front $i',
    backText: 'Back $i',
    dueAt: dueAt ?? now,
  );
}

List<StudyCard> _cards(int count) => [for (var i = 0; i < count; i++) _card(i)];

/// Opens [page] over [repo], sharing [store] so a second open sees what the
/// first one left behind.
Future<void> _open(
  WidgetTester tester, {
  required _StubStudyRepository repo,
  required MemorySessionCheckpointStore store,
  required Widget page,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        studyRepositoryProvider.overrideWithValue(repo),
        remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
        sessionCheckpointStoreProvider.overrideWithValue(store),
        noSessionShuffle,
      ],
      child: MaterialApp(home: page),
    ),
  );
  // Not pumpAndSettle: a cram card keeps a spring ticker alive, so settling
  // can outrun the timeout. A few frames is enough for the cards, the
  // checkpoint slot and the resume toast to land.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Every exit that is not a finish: the route goes, the page disposes, and
/// what it was holding is flushed.
Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> _reveal(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.space);
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _grade(WidgetTester tester, String label) async {
  await _reveal(tester);
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('a study session survives leaving', () {
    testWidgets('it comes back on the card it was left on', (tester) async {
      final repo = _StubStudyRepository(_cards(3));
      final store = MemorySessionCheckpointStore();
      final page = const StudySessionPage(
        cardIds: {'card-0', 'card-1', 'card-2'},
        frameDeckId: _deckId,
      );

      await _open(tester, repo: repo, store: store, page: page);
      await _grade(tester, 'Good');
      expect(find.text('Front 1'), findsOneWidget);
      await _leave(tester);

      await _open(tester, repo: repo, store: store, page: page);

      expect(
        find.text('Resuming your previous session · 2 left'),
        findsOneWidget,
      );
      expect(find.text('Front 1'), findsOneWidget);
      // Front, whichever face the session was left showing — so the grading
      // buttons are still behind the flip.
      expect(
        tester.widget<StudyGradingRow>(find.byType(StudyGradingRow)).enabled,
        isFalse,
      );
    });

    testWidgets('undo after a resume reverses the grade it was left with', (
      tester,
    ) async {
      final repo = _StubStudyRepository(_cards(2));
      final store = MemorySessionCheckpointStore();
      const page = StudySessionPage(
        cardIds: {'card-0', 'card-1'},
        frameDeckId: _deckId,
      );

      await _open(tester, repo: repo, store: store, page: page);
      await _grade(tester, 'Good');
      expect(repo.card('card-0').reviewCount, 1);
      expect(repo.liveLogs, hasLength(1));
      await _leave(tester);

      await _open(tester, repo: repo, store: store, page: page);
      await _press(tester, LogicalKeyboardKey.keyU);

      // The schedule and the review log both go back to where the grade
      // found them, a process death ago.
      expect(find.text('Front 0'), findsOneWidget);
      expect(repo.card('card-0').reviewCount, 0);
      expect(repo.liveLogs, isEmpty);

      await _press(tester, LogicalKeyboardKey.keyR);
      expect(repo.card('card-0').reviewCount, 1);
      expect(repo.liveLogs, hasLength(1));
    });

    testWidgets('a card that came due while it was away joins the end', (
      tester,
    ) async {
      final repo = _StubStudyRepository([
        _card(0),
        _card(1),
        // Not due when the session opened, and so not in it.
        _card(2, dueAt: DateTime.utc(2027)),
      ]);
      final store = MemorySessionCheckpointStore();
      const page = StudySessionPage(
        cardIds: {'card-0', 'card-1', 'card-2'},
        frameDeckId: _deckId,
      );

      await _open(tester, repo: repo, store: store, page: page);
      expect(find.text('Front 0'), findsOneWidget);
      await _leave(tester);

      repo.cards = [repo.card('card-0'), repo.card('card-1'), _card(2)];
      await _open(tester, repo: repo, store: store, page: page);

      // Behind the two the round already had, not shuffled in among them.
      expect(find.text('Front 0'), findsOneWidget);
      await _grade(tester, 'Good');
      expect(find.text('Front 1'), findsOneWidget);
      await _grade(tester, 'Good');
      expect(find.text('Front 2'), findsOneWidget);
    });

    testWidgets('a card deleted while it was away is skipped', (tester) async {
      final repo = _StubStudyRepository(_cards(2));
      final store = MemorySessionCheckpointStore();
      const page = StudySessionPage(
        cardIds: {'card-0', 'card-1'},
        frameDeckId: _deckId,
      );

      await _open(tester, repo: repo, store: store, page: page);
      await _leave(tester);

      repo.cards = [repo.card('card-1')];
      await _open(tester, repo: repo, store: store, page: page);

      expect(find.text('Front 1'), findsOneWidget);
      expect(find.text('Front 0'), findsNothing);
    });

    testWidgets('Start over rebuilds the round from what is eligible now', (
      tester,
    ) async {
      final repo = _StubStudyRepository(_cards(2));
      final store = MemorySessionCheckpointStore();
      const page = StudySessionPage(
        cardIds: {'card-0', 'card-1'},
        frameDeckId: _deckId,
      );

      await _open(tester, repo: repo, store: store, page: page);
      await _grade(tester, 'Good');
      await _leave(tester);

      await _open(tester, repo: repo, store: store, page: page);
      await tester.tap(find.text('Start over'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Card 0 was graded to a later day, so a fresh round is card 1 alone —
      // with no history behind it to step back into.
      expect(find.text('Front 1'), findsOneWidget);
      final saved = store.checkpoints[_deckSlot]!;
      expect(saved.remainingQueue, ['card-1']);
      expect(saved.graded, isEmpty);
      // The grade it replaced stays on disk: Start over is a new round, not
      // an undo.
      expect(repo.card('card-0').reviewCount, 1);
    });

    testWidgets('finishing leaves nothing to come back to', (tester) async {
      final repo = _StubStudyRepository(_cards(1));
      final store = MemorySessionCheckpointStore();
      const page = StudySessionPage(cardIds: {'card-0'}, frameDeckId: _deckId);

      await _open(tester, repo: repo, store: store, page: page);
      await _grade(tester, 'Good');
      expect(find.text('Session complete'), findsOneWidget);
      await _leave(tester);

      expect(store.checkpoints[_deckSlot], isNull);
    });

    testWidgets('the Hub and a deck never offer each other their rounds', (
      tester,
    ) async {
      final repo = _StubStudyRepository(_cards(2));
      final store = MemorySessionCheckpointStore();

      await _open(
        tester,
        repo: repo,
        store: store,
        page: const StudySessionPage(
          cardIds: {'card-0', 'card-1'},
          frameDeckId: _deckId,
        ),
      );
      await _grade(tester, 'Good');
      await _leave(tester);

      await _open(
        tester,
        repo: repo,
        store: store,
        page: const StudySessionPage(cardIds: {'card-0', 'card-1'}),
      );

      expect(find.textContaining('Resuming'), findsNothing);
      expect(store.checkpoints[_deckSlot], isNotNull);
    });

    testWidgets('a flashcard round writes no scratch of its own', (
      tester,
    ) async {
      final repo = _StubStudyRepository(_cards(2));
      final store = MemorySessionCheckpointStore();

      await _open(
        tester,
        repo: repo,
        store: store,
        page: const StudySessionPage(
          cardIds: {'card-0', 'card-1'},
          frameDeckId: _deckId,
        ),
      );
      await _grade(tester, 'Good');
      await _leave(tester);

      expect(store.checkpoints[_deckSlot]!.scratch, isNull);
    });
  });

  group('a cram run survives leaving', () {
    testWidgets('the buckets come back, and so does undo', (tester) async {
      final repo = _StubStudyRepository(_cards(3));
      final store = MemorySessionCheckpointStore();
      const page = StudyCramPage(deckId: _deckId);

      await _open(tester, repo: repo, store: store, page: page);
      // Right is a pass: card 0 moves up to bucket 1.
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('Front 1'), findsOneWidget);
      await _leave(tester);

      await _open(tester, repo: repo, store: store, page: page);
      expect(find.textContaining('Resuming'), findsOneWidget);
      expect(find.text('Front 1'), findsOneWidget);

      final saved = store.checkpoints[_cramSlot]!;
      expect(saved.buckets!.bucket0, ['card-1', 'card-2']);
      expect(saved.buckets!.bucket1, ['card-0']);

      // The decision it was left with is still one it can step back off.
      await _press(tester, LogicalKeyboardKey.keyU);
      expect(find.text('Front 0'), findsOneWidget);
      await _press(tester, LogicalKeyboardKey.keyR);
      expect(find.text('Front 1'), findsOneWidget);
    });

    testWidgets('a card added while it was away starts in bucket 0', (
      tester,
    ) async {
      final repo = _StubStudyRepository(_cards(2));
      final store = MemorySessionCheckpointStore();
      const page = StudyCramPage(deckId: _deckId);

      await _open(tester, repo: repo, store: store, page: page);
      await _press(tester, LogicalKeyboardKey.arrowRight);
      await _leave(tester);

      repo.cards = [...repo.cards, _card(9)];
      await _open(tester, repo: repo, store: store, page: page);

      final saved = store.checkpoints[_cramSlot]!;
      expect(saved.buckets!.bucket0, ['card-1', 'card-9']);
      expect(saved.buckets!.bucket1, ['card-0']);
    });

    testWidgets('mastering every card leaves nothing to come back to', (
      tester,
    ) async {
      final repo = _StubStudyRepository(_cards(1));
      final store = MemorySessionCheckpointStore();
      const page = StudyCramPage(deckId: _deckId);

      await _open(tester, repo: repo, store: store, page: page);
      await _press(tester, LogicalKeyboardKey.arrowRight);
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('All cards mastered'), findsOneWidget);
      await _leave(tester);

      expect(store.checkpoints[_cramSlot], isNull);
    });
  });

  test('checkpoints are device-local, with nothing to sync', () {
    // No version vector, no remote id, no user: a half-finished round belongs
    // to the machine it was left on.
    final json = SessionCheckpoint(
      kind: SessionCheckpointKind.studySession,
      scopeKey: 'hub',
      sessionId: 's1',
      startedAt: DateTime.utc(2026, 9, 20),
      updatedAt: DateTime.utc(2026, 9, 20),
    ).toJson();

    expect(json.keys, isNot(contains('userId')));
    expect(json.keys, isNot(contains('remoteId')));
    expect(json.keys, isNot(contains('deletedAt')));
  });

  test('the Hub slot is not the deck slot', () {
    expect(_hubSlot, isNot(_deckSlot));
  });
}
