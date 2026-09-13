import 'dart:math';

import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_srs_engine.dart';

/// Scheduling for the LeetCode Review Deck. The arithmetic itself is the
/// study page's — [applyStudyGrade] is pure and takes raw interval/ease — so
/// a problem and a flashcard graded "Good" on the same day come back on the
/// same day. Only the plumbing around it is LeetCode's, because a problem
/// carries its review state on the problem row rather than on a card.

/// Applies [grade] to [problem] and returns the graded copy. The caller
/// persists it (Study mode) or throws it away (Cram mode never calls this).
LeetCodeProblem gradeLeetCodeProblem(
  LeetCodeProblem problem,
  StudyGrade grade, {
  DateTime? now,
}) {
  final result = applyStudyGrade(
    interval: problem.interval,
    ease: problem.ease,
    grade: grade,
  );
  final effectiveNow = now ?? DateTime.now().toUtc();
  return problem.copyWith(
    interval: result.interval,
    ease: result.ease,
    dueAt: effectiveNow.add(
      Duration(
        milliseconds: (result.interval * Duration.millisecondsPerDay).round(),
      ),
    ),
    reviewCount: problem.reviewCount + 1,
  );
}

/// Puts [snapshot]'s review state back on [problem] — undoing a grade, or
/// re-applying the one that was undone. Only the SRS fields travel, so a
/// problem edited after it was graded keeps the edit.
///
/// Written out in full rather than through `copyWith`, which cannot put a null
/// [LeetCodeProblem.dueAt] back: undoing the very first grade of a
/// never-reviewed problem has to restore exactly that null.
LeetCodeProblem restoreLeetCodeProblemSrs(
  LeetCodeProblem problem,
  LeetCodeProblem snapshot,
) {
  return LeetCodeProblem(
    id: problem.id,
    createdAt: problem.createdAt,
    updatedAt: DateTime.now().toUtc(),
    version: problem.version + 1,
    deletedAt: problem.deletedAt,
    title: problem.title,
    questionId: problem.questionId,
    questionFrontendId: problem.questionFrontendId,
    titleSlug: problem.titleSlug,
    difficulty: problem.difficulty,
    tags: problem.tags,
    description: problem.description,
    examples: problem.examples,
    solutions: problem.solutions,
    solvedAt: problem.solvedAt,
    interval: snapshot.interval,
    ease: snapshot.ease,
    dueAt: snapshot.dueAt,
    reviewCount: snapshot.reviewCount,
  );
}

/// Sends [problem] back to never-reviewed: baseline ease, no interval, due
/// immediately. The problem's own content (code, notes, tags) is untouched —
/// this only forgets how well you know it.
LeetCodeProblem resetLeetCodeProblemSrs(
  LeetCodeProblem problem, {
  DateTime? now,
}) {
  return problem.copyWith(
    interval: 0,
    ease: kStudyBaseEase,
    dueAt: now ?? DateTime.now().toUtc(),
    reviewCount: 0,
  );
}

/// Whole calendar days from today until [problem] comes due, floored at zero,
/// exactly as [studyDaysUntilDue] counts them for a flashcard. A problem that
/// has never been reviewed is due now, so it reads 0.
int leetCodeDaysUntilDue(LeetCodeProblem problem, {DateTime? now}) {
  final dueAt = problem.dueAt;
  if (dueAt == null) return 0;
  final today = _dateOnly((now ?? DateTime.now()).toLocal());
  final due = _dateOnly(dueAt.toLocal());
  final days = due.difference(today).inDays;
  return days < 0 ? 0 : days;
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Local calendar day used to bucket a problem in the review queue. Never-
/// reviewed problems have a null [LeetCodeProblem.dueAt], so they fall back
/// to [LeetCodeProblem.solvedAt] — older solve days still lead, same-day
/// solves get shuffled together.
DateTime _reviewQueueDay(LeetCodeProblem problem) =>
    _dateOnly((problem.dueAt ?? problem.solvedAt).toLocal());

/// Review-session order: earlier local due (or solve) days lead, and problems
/// that share a calendar day are shuffled. Call once when the session opens.
List<LeetCodeProblem> orderLeetCodeReviewQueue(
  List<LeetCodeProblem> problems, {
  Random? random,
}) {
  final rng = random ?? Random();
  final byDay = <DateTime, List<LeetCodeProblem>>{};
  for (final problem in problems) {
    final day = _reviewQueueDay(problem);
    (byDay[day] ??= []).add(problem);
  }
  final days = byDay.keys.toList()..sort();
  final ordered = <LeetCodeProblem>[];
  for (final day in days) {
    final bucket = byDay[day]!;
    bucket.shuffle(rng);
    ordered.addAll(bucket);
  }
  return ordered;
}

/// Cram-session order: a full shuffle. Cram ignores due dates.
List<LeetCodeProblem> orderLeetCodeCramQueue(
  List<LeetCodeProblem> problems, {
  Random? random,
}) {
  final ordered = [...problems];
  ordered.shuffle(random ?? Random());
  return ordered;
}

/// The problems due for review right now, ordered for a Study session —
/// earlier local due days first, shuffled within each day.
List<LeetCodeProblem> dueLeetCodeProblems(
  Iterable<LeetCodeProblem> problems, {
  DateTime? now,
  Random? random,
}) {
  final effectiveNow = now ?? DateTime.now().toUtc();
  return orderLeetCodeReviewQueue([
    for (final p in problems)
      if (p.isDue(now: effectiveNow)) p,
  ], random: random);
}

int _masteryRank(LeetCodeProblem problem) {
  if (problem.isNew) return 0;
  if (problem.isLearning) return 1;
  return 2;
}

/// Grid order: least memorised first, matching the study deck's grid. Sorting
/// on interval rather than due date keeps the board still — it rearranges
/// when a problem is actually reviewed, not merely because a day passed.
List<LeetCodeProblem> sortLeetCodeProblemsByMastery(
  List<LeetCodeProblem> problems,
) {
  final sorted = [...problems];
  sorted.sort((a, b) {
    final byRank = _masteryRank(a).compareTo(_masteryRank(b));
    if (byRank != 0) return byRank;
    final byInterval = a.interval.compareTo(b.interval);
    if (byInterval != 0) return byInterval;
    final byDue = (a.dueAt ?? a.solvedAt).compareTo(b.dueAt ?? b.solvedAt);
    if (byDue != 0) return byDue;
    return compareLeetCodeProblemsNewestFirst(a, b);
  });
  return sorted;
}
