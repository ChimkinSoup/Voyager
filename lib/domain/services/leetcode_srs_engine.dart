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

/// The problems due for review right now, earliest due date first — the queue
/// a Study session works through.
List<LeetCodeProblem> dueLeetCodeProblems(
  Iterable<LeetCodeProblem> problems, {
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now().toUtc();
  final due = problems.where((p) => p.isDue(now: effectiveNow)).toList();
  // Never-reviewed problems share a null due date, so they fall back to the
  // order they were solved in — oldest first, since that's the one you're
  // least likely to still remember.
  due.sort((a, b) {
    final byDue = (a.dueAt ?? a.solvedAt).compareTo(b.dueAt ?? b.solvedAt);
    return byDue != 0 ? byDue : a.solvedAt.compareTo(b.solvedAt);
  });
  return due;
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
