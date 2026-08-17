import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_activity_data.dart';

LeetCodeProblem _problem(LeetCodeDifficulty difficulty, DateTime solvedAt) {
  final now = DateTime.utc(2026, 1, 1);
  return LeetCodeProblem(
    id: '${difficulty.name}-${solvedAt.toIso8601String()}',
    createdAt: now,
    updatedAt: now,
    title: 'Two Sum',
    difficulty: difficulty,
    solvedAt: solvedAt,
  );
}

void main() {
  group('leetCodeCountsByDay', () {
    test('buckets by the local date of solvedAt, not the UTC one', () {
      // A UTC instant, bucketed by whatever local date it falls on — the two
      // differ for most of the world, and the calendar squares are local days.
      final instant = DateTime.utc(2026, 8, 14, 23, 30);
      final local = instant.toLocal();

      final byDay = leetCodeCountsByDay([
        _problem(LeetCodeDifficulty.medium, instant),
      ]);

      expect(byDay.keys, [DateTime(local.year, local.month, local.day)]);
    });

    test('counts each difficulty separately on the same day', () {
      final day = DateTime(2026, 8, 10, 9).toUtc();
      final byDay = leetCodeCountsByDay([
        _problem(LeetCodeDifficulty.easy, day),
        _problem(LeetCodeDifficulty.easy, day.add(const Duration(hours: 1))),
        _problem(LeetCodeDifficulty.hard, day.add(const Duration(hours: 2))),
      ]);

      final counts = byDay[DateTime(2026, 8, 10)]!;
      expect(counts.easy, 2);
      expect(counts.medium, 0);
      expect(counts.hard, 1);
      expect(counts.total, 3);
      expect(counts.solves, hasLength(3));
      expect(
        counts.solvesFor(LeetCodeDifficulty.easy).map((s) => s.solvedAt),
        [day, day.add(const Duration(hours: 1))],
      );
    });
  });

  group('leetCodeActivityWindow', () {
    test('is 30 days ending today, oldest first', () {
      final window = leetCodeActivityWindow(
        byDay: const {},
        today: DateTime(2026, 8, 15),
      );

      expect(window.length, 30);
      expect(window.first.date, DateTime(2026, 7, 17));
      expect(window.last.date, DateTime(2026, 8, 15));
    });

    test('reads zero on days with nothing solved', () {
      final window = leetCodeActivityWindow(
        byDay: {DateTime(2026, 8, 15): const LeetCodeDayCounts(medium: 2)},
        today: DateTime(2026, 8, 15),
      );

      expect(window.last.counts.medium, 2);
      expect(window[window.length - 2].counts.total, 0);
      expect(window.first.counts.total, 0);
    });

    test('drops days that fall outside the window', () {
      final window = leetCodeActivityWindow(
        byDay: {DateTime(2026, 7, 16): const LeetCodeDayCounts(hard: 5)},
        today: DateTime(2026, 8, 15),
      );

      expect(window.every((day) => day.counts.total == 0), isTrue);
    });
  });

  group('leetCodeBusiestDayInYear', () {
    test('ignores days in other years', () {
      final byDay = {
        DateTime(2025, 12, 31): const LeetCodeDayCounts(easy: 9),
        DateTime(2026, 3, 2): const LeetCodeDayCounts(easy: 1, hard: 2),
        DateTime(2026, 3, 3): const LeetCodeDayCounts(medium: 2),
      };

      expect(leetCodeBusiestDayInYear(byDay, 2026), 3);
      expect(leetCodeBusiestDayInYear(byDay, 2025), 9);
      expect(leetCodeBusiestDayInYear(byDay, 2024), 0);
    });
  });
}
