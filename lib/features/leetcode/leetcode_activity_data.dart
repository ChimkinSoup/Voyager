import 'package:flutter/material.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';

/// Solve counts per difficulty, and reviews graded, for the LeetCode activity
/// sparkline and calendar — kept pure so the bucketing edges (UTC timestamps
/// landing on a local date, days with nothing on them) can be unit tested
/// without pumping a widget tree.

/// How many days the dashboard sparkline covers, today inclusive.
const int kLeetCodeActivityWindowDays = 30;

/// One line on the activity chart: the three difficulty tiers a day's solves
/// are split across, plus the reviews graded that day.
///
/// Reviewed is not a fourth difficulty — it counts a different event
/// entirely — but it is drawn on the same axes, keyed by the same day and
/// filtered by the same legend, so the surfaces below take one of these rather
/// than a difficulty and a bool.
enum LeetCodeActivitySeries {
  easy(LeetCodeDifficulty.easy),
  medium(LeetCodeDifficulty.medium),
  hard(LeetCodeDifficulty.hard),

  /// Problems graded in a Review Deck session. Null difficulty: a review is
  /// counted whatever tier the problem it went over sits in.
  reviewed(null);

  const LeetCodeActivitySeries(this.difficulty);

  final LeetCodeDifficulty? difficulty;

  static LeetCodeActivitySeries forDifficulty(LeetCodeDifficulty difficulty) =>
      switch (difficulty) {
        LeetCodeDifficulty.easy => LeetCodeActivitySeries.easy,
        LeetCodeDifficulty.medium => LeetCodeActivitySeries.medium,
        LeetCodeDifficulty.hard => LeetCodeActivitySeries.hard,
      };
}

/// The colour [series] is drawn in wherever it appears — curve, legend
/// capsule, bubble row, calendar tint.
///
/// The three tiers keep LeetCode's own colours. Reviewed takes the app's
/// accent instead: it is the one series that isn't a difficulty, and borrowing
/// a fourth arbitrary hue would have read as one.
Color colorForLeetCodeActivitySeries(
  BuildContext context,
  LeetCodeActivitySeries series,
) {
  final difficulty = series.difficulty;
  return difficulty == null
      ? Theme.of(context).colorScheme.primary
      : colorForLeetCodeDifficulty(difficulty);
}

String labelForLeetCodeActivitySeries(LeetCodeActivitySeries series) {
  final difficulty = series.difficulty;
  return difficulty == null
      ? 'Reviewed'
      : labelForLeetCodeDifficulty(difficulty);
}

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
    this.reviews = 0,
    this.solves = const [],
  });

  final int easy;
  final int medium;
  final int hard;

  /// Problems graded in a Review Deck session that day, re-reviews included —
  /// this counts events, not distinct problems.
  final int reviews;

  /// Every solve that contributed to the counts, in encounter order.
  final List<LeetCodeDaySolve> solves;

  static const zero = LeetCodeDayCounts();

  /// Problems *solved* that day. Reviews are deliberately out: this is what
  /// tints the unfiltered calendar, where the question is how much new ground
  /// the day covered.
  int get total => easy + medium + hard;

  int countFor(LeetCodeDifficulty difficulty) => switch (difficulty) {
    LeetCodeDifficulty.easy => easy,
    LeetCodeDifficulty.medium => medium,
    LeetCodeDifficulty.hard => hard,
  };

  int countForSeries(LeetCodeActivitySeries series) =>
      series == LeetCodeActivitySeries.reviewed
      ? reviews
      : countFor(series.difficulty!);

  LeetCodeDayCounts withReviews(int reviews) => LeetCodeDayCounts(
    easy: easy,
    medium: medium,
    hard: hard,
    reviews: reviews,
    solves: solves,
  );

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
        reviews: reviews,
        solves: nextSolves,
      ),
      LeetCodeDifficulty.medium => LeetCodeDayCounts(
        easy: easy,
        medium: medium + 1,
        hard: hard,
        reviews: reviews,
        solves: nextSolves,
      ),
      LeetCodeDifficulty.hard => LeetCodeDayCounts(
        easy: easy,
        medium: medium,
        hard: hard + 1,
        reviews: reviews,
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

/// Reviews graded per local day, keyed the way [leetCodeCountsByDay] keys
/// solves — [LeetCodeReviewLog.reviewedAt] is UTC, so it is converted to local
/// time before the date is taken.
///
/// Tombstoned rows are the caller's to exclude; the repository's
/// `listReviewLogs` already has.
Map<DateTime, int> leetCodeReviewsByDay(Iterable<LeetCodeReviewLog> logs) {
  final byDay = <DateTime, int>{};
  for (final log in logs) {
    final local = log.reviewedAt.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    byDay.update(day, (count) => count + 1, ifAbsent: () => 1);
  }
  return byDay;
}

/// Solves and reviews folded into one map, so every surface below reads a day
/// from a single place.
///
/// A day that was nothing but review work has no solves to key it, so it is
/// added here rather than being dropped.
Map<DateTime, LeetCodeDayCounts> leetCodeActivityByDay({
  required Iterable<LeetCodeProblem> problems,
  required Iterable<LeetCodeReviewLog> logs,
}) {
  final byDay = leetCodeCountsByDay(problems);
  for (final entry in leetCodeReviewsByDay(logs).entries) {
    byDay[entry.key] = (byDay[entry.key] ?? LeetCodeDayCounts.zero).withReviews(
      entry.value,
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
/// [series] narrows both the count and the scale to one line, so a filtered
/// heatmap rebases on its own busiest day rather than fading to nothing
/// against a year dominated by another tier — or, for
/// [LeetCodeActivitySeries.reviewed], against a year of solving.
int leetCodeBusiestDayInYear(
  Map<DateTime, LeetCodeDayCounts> byDay,
  int year, {
  LeetCodeActivitySeries? series,
}) {
  var max = 0;
  for (final entry in byDay.entries) {
    if (entry.key.year != year) continue;
    final count = series == null
        ? entry.value.total
        : entry.value.countForSeries(series);
    if (count > max) max = count;
  }
  return max;
}
