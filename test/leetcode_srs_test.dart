import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/leetcode_srs_engine.dart';

final _now = DateTime.utc(2026, 8, 9, 12);

LeetCodeProblem _problem({
  String id = 'p1',
  double interval = 0,
  double ease = 2.5,
  DateTime? dueAt,
  int reviewCount = 0,
  DateTime? solvedAt,
}) {
  return LeetCodeProblem(
    id: id,
    createdAt: _now,
    updatedAt: _now,
    title: 'Two Sum',
    difficulty: LeetCodeDifficulty.easy,
    solvedAt: solvedAt ?? _now,
    interval: interval,
    ease: ease,
    dueAt: dueAt,
    reviewCount: reviewCount,
  );
}

void main() {
  group('isDue', () {
    test('a never-reviewed problem is due now', () {
      expect(_problem().isDue(now: _now), isTrue);
    });

    test('a scheduled problem is not due until its date arrives', () {
      final scheduled = _problem(dueAt: _now.add(const Duration(days: 3)));
      expect(scheduled.isDue(now: _now), isFalse);
      expect(scheduled.isDue(now: _now.add(const Duration(days: 3))), isTrue);
    });
  });

  group('gradeLeetCodeProblem', () {
    test('the first Good grade schedules one day out', () {
      final graded = gradeLeetCodeProblem(_problem(), StudyGrade.good, now: _now);
      expect(graded.interval, 1);
      expect(graded.ease, 2.5);
      expect(graded.reviewCount, 1);
      expect(graded.dueAt, _now.add(const Duration(days: 1)));
    });

    test('a second Good grade multiplies by ease', () {
      final graded = gradeLeetCodeProblem(
        _problem(interval: 4, reviewCount: 1),
        StudyGrade.good,
        now: _now,
      );
      expect(graded.interval, 10);
      expect(graded.dueAt, _now.add(const Duration(days: 10)));
    });

    test('Fail drops the ease and re-queues the problem for today', () {
      final graded = gradeLeetCodeProblem(
        _problem(interval: 10, ease: 2.5, reviewCount: 3),
        StudyGrade.fail,
        now: _now,
      );
      expect(graded.interval, 0);
      expect(graded.ease, closeTo(2.3, 1e-9));
      expect(graded.isDue(now: _now), isTrue);
    });

    test('grading leaves the problem content alone', () {
      final graded = gradeLeetCodeProblem(_problem(), StudyGrade.easy, now: _now);
      expect(graded.title, 'Two Sum');
      expect(graded.difficulty, LeetCodeDifficulty.easy);
      expect(graded.solvedAt, _now);
    });
  });

  test('resetLeetCodeProblemSrs returns a problem to never-reviewed', () {
    final reset = resetLeetCodeProblemSrs(
      _problem(interval: 40, ease: 2.9, reviewCount: 7),
      now: _now,
    );
    expect(reset.interval, 0);
    expect(reset.ease, 2.5);
    expect(reset.reviewCount, 0);
    expect(reset.isNew, isTrue);
    expect(reset.isDue(now: _now), isTrue);
  });

  group('leetCodeDaysUntilDue', () {
    test('counts whole calendar days ahead', () {
      final problem = _problem(dueAt: _now.add(const Duration(days: 5)));
      expect(leetCodeDaysUntilDue(problem, now: _now), 5);
    });

    test('an overdue or unscheduled problem reads zero', () {
      expect(leetCodeDaysUntilDue(_problem(), now: _now), 0);
      expect(
        leetCodeDaysUntilDue(
          _problem(dueAt: _now.subtract(const Duration(days: 9))),
          now: _now,
        ),
        0,
      );
    });
  });

  test('dueLeetCodeProblems skips the scheduled and leads with the oldest', () {
    final fresh = _problem(id: 'fresh', solvedAt: _now);
    final old = _problem(
      id: 'old',
      solvedAt: _now.subtract(const Duration(days: 200)),
    );
    final overdue = _problem(
      id: 'overdue',
      dueAt: _now.subtract(const Duration(days: 1)),
      interval: 2,
      reviewCount: 1,
    );
    final later = _problem(
      id: 'later',
      dueAt: _now.add(const Duration(days: 4)),
      interval: 4,
      reviewCount: 1,
    );

    final queue = dueLeetCodeProblems([fresh, later, old, overdue], now: _now);
    expect(queue.map((p) => p.id), ['old', 'overdue', 'fresh']);
  });

  test('sortLeetCodeProblemsByMastery puts the least-known first', () {
    final untouched = _problem(id: 'new');
    final learning = _problem(
      id: 'learning',
      interval: 0.5,
      reviewCount: 2,
      dueAt: _now,
    );
    final young = _problem(
      id: 'young',
      interval: 4,
      reviewCount: 3,
      dueAt: _now.add(const Duration(days: 4)),
    );
    final mature = _problem(
      id: 'mature',
      interval: 60,
      reviewCount: 9,
      dueAt: _now.add(const Duration(days: 60)),
    );

    final sorted = sortLeetCodeProblemsByMastery([
      mature,
      young,
      untouched,
      learning,
    ]);
    expect(sorted.map((p) => p.id), ['new', 'learning', 'young', 'mature']);
  });

  test('SRS state survives a JSON round trip', () {
    final graded = gradeLeetCodeProblem(_problem(), StudyGrade.easy, now: _now);
    final restored = LeetCodeProblem.fromJson(graded.toJson());
    expect(restored.interval, graded.interval);
    expect(restored.ease, graded.ease);
    expect(restored.dueAt, graded.dueAt);
    expect(restored.reviewCount, graded.reviewCount);
  });

  test('a pre-SRS problem decodes to never-reviewed', () {
    final legacy = {
      'id': 'p1',
      'createdAt': _now.toIso8601String(),
      'updatedAt': _now.toIso8601String(),
      'title': 'Two Sum',
      'difficulty': 'easy',
      'solvedAt': _now.toIso8601String(),
    };
    final problem = LeetCodeProblem.fromJson(legacy);
    expect(problem.interval, 0);
    expect(problem.ease, 2.5);
    expect(problem.dueAt, isNull);
    expect(problem.reviewCount, 0);
    expect(problem.isDue(now: _now), isTrue);
  });
}
