// The deck grid reads top-left to bottom-right as "least memorised first",
// so the ordering has to put unseen work ahead of learned work regardless of
// when each card happens to fall due — and it has to stay put on a day when
// nothing is studied.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_srs_engine.dart';

final _epoch = DateTime.utc(2026, 1, 1);

StudyCard _card(
  String id, {
  double interval = 0,
  int reviewCount = 0,
  Duration dueIn = Duration.zero,
}) => StudyCard(
  id: id,
  createdAt: _epoch,
  updatedAt: _epoch,
  deckId: 'deck',
  frontText: id,
  backText: id,
  interval: interval,
  reviewCount: reviewCount,
  dueAt: _epoch.add(dueIn),
);

void main() {
  group('sortStudyCardsByMastery', () {
    test('runs new, then learning, then by growing interval', () {
      final mature = _card('mature', interval: 45, reviewCount: 9);
      final young = _card('young', interval: 6, reviewCount: 3);
      final learning = _card('learning', interval: 0.4, reviewCount: 1);
      final fresh = _card('new');

      final sorted = sortStudyCardsByMastery([mature, young, learning, fresh]);

      expect(
        sorted.map((c) => c.id),
        ['new', 'learning', 'young', 'mature'],
      );
    });

    test('a long-overdue mature card still sorts after an unseen one', () {
      // Due date is the tiebreaker, never the lead: sorting on it would let a
      // well-known card jump the queue just because a day passed.
      final overdue = _card(
        'overdue',
        interval: 45,
        reviewCount: 9,
        dueIn: const Duration(days: -30),
      );
      final fresh = _card('new', dueIn: const Duration(days: 1));

      final sorted = sortStudyCardsByMastery([overdue, fresh]);

      expect(sorted.first.id, 'new');
    });

    test('cards at the same interval fall due-date first', () {
      final later = _card(
        'later',
        interval: 6,
        reviewCount: 2,
        dueIn: const Duration(days: 4),
      );
      final sooner = _card(
        'sooner',
        interval: 6,
        reviewCount: 2,
        dueIn: const Duration(days: 1),
      );

      final sorted = sortStudyCardsByMastery([later, sooner]);

      expect(sorted.map((c) => c.id), ['sooner', 'later']);
    });

    test('leaves the input list alone', () {
      final input = [_card('b', interval: 9, reviewCount: 2), _card('a')];
      sortStudyCardsByMastery(input);
      expect(input.map((c) => c.id), ['b', 'a']);
    });
  });

  group('studyDaysUntilDue', () {
    final now = DateTime(2026, 6, 10, 15, 30);

    test('counts calendar days, not elapsed hours', () {
      // Due at 9am tomorrow is "1", though it's under 24 hours away.
      final card = _card('c', dueIn: Duration.zero).copyWith(
        dueAt: DateTime(2026, 6, 11, 9).toUtc(),
      );
      expect(studyDaysUntilDue(card, now: now), 1);
    });

    test('a card due today, overdue, or never studied all read 0', () {
      final today = _card('t').copyWith(dueAt: DateTime(2026, 6, 10, 23).toUtc());
      final overdue = _card('o').copyWith(dueAt: DateTime(2026, 6, 1).toUtc());
      final fresh = _card('n').copyWith(dueAt: DateTime(2026, 6, 10, 8).toUtc());

      expect(studyDaysUntilDue(today, now: now), 0);
      expect(studyDaysUntilDue(overdue, now: now), 0);
      expect(studyDaysUntilDue(fresh, now: now), 0);
    });
  });
}
