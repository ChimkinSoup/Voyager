import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';

/// Solve counts per difficulty for the LeetCode activity sparkline and
/// calendar, kept pure so the bucketing edges — UTC timestamps landing on a
/// local date, days with nothing solved — can be unit tested without pumping a
/// widget tree.

/// How many days the dashboard sparkline covers, today inclusive.
const int kLeetCodeActivityWindowDays = 30;

/// One solve attributed to a day — kept on [LeetCodeDayCounts] so a debug
/// hover can name what the counters are counting without a second pass.
class LeetCodeDaySolve {
  const LeetCodeDaySolve({
    required this.title,
    required this.difficulty,
    required this.solvedAt,
  });

  final String title;
  final LeetCodeDifficulty difficulty;

  /// UTC, same as [LeetCodeProblem.solvedAt].
  final DateTime solvedAt;
}

/// How many problems of each difficulty a single day accounts for.
class LeetCodeDayCounts {
  const LeetCodeDayCounts({
    this.easy = 0,
    this.medium = 0,
    this.hard = 0,
    this.solves = const [],
  });

  final int easy;
  final int medium;
  final int hard;

  /// Every solve that contributed to the counts, in encounter order.
  final List<LeetCodeDaySolve> solves;

  static const zero = LeetCodeDayCounts();

  int get total => easy + medium + hard;

  int countFor(LeetCodeDifficulty difficulty) => switch (difficulty) {
    LeetCodeDifficulty.easy => easy,
    LeetCodeDifficulty.medium => medium,
    LeetCodeDifficulty.hard => hard,
  };

  List<LeetCodeDaySolve> solvesFor(LeetCodeDifficulty difficulty) => [
    for (final solve in solves)
      if (solve.difficulty == difficulty) solve,
  ];

  LeetCodeDayCounts withSolve(LeetCodeDaySolve solve) {
    final nextSolves = [...solves, solve];
    return switch (solve.difficulty) {
      LeetCodeDifficulty.easy => LeetCodeDayCounts(
        easy: easy + 1,
        medium: medium,
        hard: hard,
        solves: nextSolves,
      ),
      LeetCodeDifficulty.medium => LeetCodeDayCounts(
        easy: easy,
        medium: medium + 1,
        hard: hard,
        solves: nextSolves,
      ),
      LeetCodeDifficulty.hard => LeetCodeDayCounts(
        easy: easy,
        medium: medium,
        hard: hard + 1,
        solves: nextSolves,
      ),
    };
  }
}

/// Every day that has at least one solve, keyed by local date at midnight.
///
/// [LeetCodeProblem.solvedAt] is stored in UTC, so it is converted to local
/// time before the date is taken — otherwise anything solved late in the
/// evening west of UTC would land on tomorrow's square.
Map<DateTime, LeetCodeDayCounts> leetCodeCountsByDay(
  Iterable<LeetCodeProblem> problems,
) {
  final byDay = <DateTime, LeetCodeDayCounts>{};
  for (final problem in problems) {
    final local = problem.solvedAt.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    byDay[day] = (byDay[day] ?? LeetCodeDayCounts.zero).withSolve(
      LeetCodeDaySolve(
        title: problem.title,
        difficulty: problem.difficulty,
        solvedAt: problem.solvedAt,
      ),
    );
  }
  return byDay;
}

/// The last [days] days ending on [today], oldest first, with a zero entry for
/// every day nothing was solved — the sparkline reads a flat 0 there rather
/// than interpolating across the gap.
List<({DateTime date, LeetCodeDayCounts counts})> leetCodeActivityWindow({
  required Map<DateTime, LeetCodeDayCounts> byDay,
  required DateTime today,
  int days = kLeetCodeActivityWindowDays,
}) {
  final start = DateTime(today.year, today.month, today.day);
  return [
    for (var i = days - 1; i >= 0; i--)
      (
        date: addCalendarDays(start, -i),
        counts: byDay[addCalendarDays(start, -i)] ?? LeetCodeDayCounts.zero,
      ),
  ];
}

/// The busiest day in [year], used as the heatmap's top of scale so a quiet
/// year still shows contrast instead of one barely-tinted square.
///
/// [difficulty] narrows both the count and the scale to one tier, so a
/// filtered heatmap rebases on its own busiest day rather than fading to
/// nothing against a year dominated by another tier.
int leetCodeBusiestDayInYear(
  Map<DateTime, LeetCodeDayCounts> byDay,
  int year, {
  LeetCodeDifficulty? difficulty,
}) {
  var max = 0;
  for (final entry in byDay.entries) {
    if (entry.key.year != year) continue;
    final count = difficulty == null
        ? entry.value.total
        : entry.value.countFor(difficulty);
    if (count > max) max = count;
  }
  return max;
}
