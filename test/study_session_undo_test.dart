// Stepping back through a session. A review session's undo has to put the
// card's schedule back exactly as it stood — including the review count that
// decides whether the card still reads as new — and a redo has to give back
// the rating that was taken off rather than asking for a new one. Cram holds
// no rating at all, so there the same keys only move between cards.
//
// The review log is deliberately left alone by an undo: it is append-only and
// has no delete path through sync, so a redo must not write a second one.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/study/study_cram_page.dart';
import 'package:voyager/features/study/study_flip_card.dart';
import 'package:voyager/features/study/study_session_page.dart';

const _deckId = 'session-deck';

class _RecordingStudyRepository implements StudyRepository {
  _RecordingStudyRepository(this.cards);

  List<StudyCard> cards;

  /// Every card written back, in order.
  final saved = <StudyCard>[];
  final logs = <StudyReviewLog>[];

  @override
  Future<List<StudyCard>> getAllCards({bool includeDeleted = true}) async =>
      cards;

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
    saved.add(card);
    cards = [
      for (final c in cards)
        if (c.id == card.id) card else c,
    ];
  }

  @override
  Future<void> logReview(StudyReviewLog log) async => logs.add(log);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

List<StudyCard> _cards(int count) {
  final now = DateTime.utc(2026, 8, 9, 12);
  return [
    for (var i = 0; i < count; i++)
      StudyCard(
        id: 'card-$i',
        createdAt: now,
        updatedAt: now,
        deckId: _deckId,
        frontText: 'Front $i',
        backText: 'Back $i',
        dueAt: now,
      ),
  ];
}

Future<_RecordingStudyRepository> _pump(
  WidgetTester tester,
  List<StudyCard> cards,
  Widget page,
) async {
  final repo = _RecordingStudyRepository(cards);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        studyRepositoryProvider.overrideWithValue(repo),
        remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
      ],
      child: MaterialApp(home: page),
    ),
  );
  // Not pumpAndSettle: a cram card keeps a spring ticker alive, so settling
  // can outrun the timeout. A few frames is enough for the provider to
  // resolve.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  return repo;
}

Future<void> _reveal(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.space);
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _grade(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Steps back or forward through the session's history and waits for the
/// write and the card swap to land.
Future<void> _stepHistory(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('undo puts the card and its schedule back, redo re-applies it', (
    tester,
  ) async {
    final repo = await _pump(
      tester,
      _cards(1),
      const StudySessionPage(cardIds: {'card-0'}),
    );

    await _reveal(tester);
    await _grade(tester, 'Good');
    expect(find.text('Session complete'), findsOneWidget);
    expect(repo.logs, hasLength(1));

    await _stepHistory(tester, LogicalKeyboardKey.arrowLeft);

    expect(find.text('Front 0'), findsOneWidget);
    expect(find.text('New 1'), findsOneWidget);
    final restored = repo.saved.last;
    expect(restored.interval, 0);
    expect(restored.reviewCount, 0);
    expect(restored.dueAt, DateTime.utc(2026, 8, 9, 12));

    await _stepHistory(tester, LogicalKeyboardKey.arrowRight);

    expect(repo.saved.last.interval, 1);
    expect(repo.saved.last.reviewCount, 1);
    expect(find.text('Session complete'), findsOneWidget);
    expect(
      repo.logs,
      hasLength(1),
      reason: 'the log the grade wrote was never removed, so a redo must not '
          'write a second one',
    );
  });

  testWidgets('U works as well as the left arrow, and R as the right', (
    tester,
  ) async {
    final repo = await _pump(
      tester,
      _cards(1),
      const StudySessionPage(cardIds: {'card-0'}),
    );

    await _reveal(tester);
    await _grade(tester, 'Good');

    await _stepHistory(tester, LogicalKeyboardKey.keyU);
    expect(repo.saved.last.reviewCount, 0);

    await _stepHistory(tester, LogicalKeyboardKey.keyR);
    expect(repo.saved.last.reviewCount, 1);
  });

  testWidgets('cram steps between cards without touching their SRS state', (
    tester,
  ) async {
    final repo = await _pump(
      tester,
      _cards(2),
      const StudyCramPage(deckId: _deckId),
    );
    expect(find.text('Front 0'), findsOneWidget);

    // The arrows still decide in cram — right is a pass.
    await _stepHistory(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('Front 1'), findsOneWidget);

    await _stepHistory(tester, LogicalKeyboardKey.keyU);
    expect(find.text('Front 0'), findsOneWidget);

    await _stepHistory(tester, LogicalKeyboardKey.keyR);
    expect(find.text('Front 1'), findsOneWidget);

    // Nothing beyond the furthest card reached to step forward into.
    await _stepHistory(tester, LogicalKeyboardKey.keyR);
    expect(find.text('Front 1'), findsOneWidget);
    expect(repo.saved, isEmpty);
    expect(find.byType(StudyFlipCard), findsOneWidget);
  });
}
