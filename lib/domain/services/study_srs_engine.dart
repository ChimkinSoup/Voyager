import 'package:voyager/domain/models/study_models.dart';

const double kStudyBaseEase = 2.5;
const double kStudyMinEase = 1.3;

class StudySrsResult {
  const StudySrsResult({required this.interval, required this.ease});

  final double interval;
  final double ease;
}

/// SM-2-style grading. `interval <= 0` marks a card that has never had a
/// successful review — the multiplicative step (`interval * ease`) would
/// otherwise stay at zero forever, so the first successful grade uses a flat
/// base interval instead and the multiplicative formula only takes over from
/// the second review onward.
StudySrsResult applyStudyGrade({
  required double interval,
  required double ease,
  required StudyGrade grade,
}) {
  final isFirstReview = interval <= 0;
  switch (grade) {
    case StudyGrade.fail:
      return StudySrsResult(interval: 0, ease: _clampEase(ease - 0.2));
    case StudyGrade.hard:
      final newInterval = isFirstReview ? 1.0 : interval * 1.2;
      return StudySrsResult(
        interval: newInterval,
        ease: _clampEase(ease - 0.15),
      );
    case StudyGrade.good:
      final newInterval = isFirstReview ? 1.0 : interval * ease;
      return StudySrsResult(interval: newInterval, ease: ease);
    case StudyGrade.easy:
      final newInterval = isFirstReview ? 3.0 : interval * ease * 1.3;
      return StudySrsResult(
        interval: newInterval,
        ease: _clampEase(ease + 0.15),
      );
  }
}

double _clampEase(double ease) => ease < kStudyMinEase ? kStudyMinEase : ease;

/// Applies [grade] to [card] and returns the graded copy — `dueAt` moves
/// forward by the new interval, `reviewCount` increments. Callers decide
/// whether to persist it and log a [StudyReviewLog] entry (real SRS mode) or
/// discard it after the session (cram mode never calls this at all).
StudyCard gradeStudyCard(StudyCard card, StudyGrade grade, {DateTime? now}) {
  final result = applyStudyGrade(
    interval: card.interval,
    ease: card.ease,
    grade: grade,
  );
  final effectiveNow = now ?? DateTime.now().toUtc();
  return card.copyWith(
    interval: result.interval,
    ease: result.ease,
    dueAt: effectiveNow.add(
      Duration(
        milliseconds: (result.interval * Duration.millisecondsPerDay).round(),
      ),
    ),
    reviewCount: card.reviewCount + 1,
    bumpVersion: true,
  );
}

/// Puts [snapshot]'s review state back on [card] — undoing a grade, or
/// re-applying the one that was undone. Only the SRS fields travel, so a card
/// whose text was edited after it was graded keeps the new text.
StudyCard restoreStudyCardSrs(StudyCard card, StudyCard snapshot) {
  return card.copyWith(
    interval: snapshot.interval,
    ease: snapshot.ease,
    dueAt: snapshot.dueAt,
    reviewCount: snapshot.reviewCount,
  );
}

/// Sends [card] back to never-reviewed: baseline ease, no interval, due
/// immediately. The card's own text is untouched — this only forgets how well
/// you know it.
StudyCard resetStudyCardSrs(StudyCard card, {DateTime? now}) {
  return card.copyWith(
    interval: 0,
    ease: kStudyBaseEase,
    dueAt: now ?? DateTime.now().toUtc(),
    reviewCount: 0,
  );
}

/// Whole calendar days from today until [card] comes due, floored at zero —
/// a card that is due today, overdue, or has never been studied all read 0.
/// Compared in local time because "due in 3 days" is a claim about the user's
/// calendar, not about UTC.
int studyDaysUntilDue(StudyCard card, {DateTime? now}) {
  final today = _dateOnly((now ?? DateTime.now()).toLocal());
  final due = _dateOnly(card.dueAt.toLocal());
  final days = due.difference(today).inDays;
  return days < 0 ? 0 : days;
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Where a card sits on the "how well do I know this" scale: never studied,
/// still in the sub-day learning phase, or holding a real interval.
int _studyMasteryRank(StudyCard card) {
  if (card.isNew) return 0;
  if (card.isLearning) return 1;
  return 2;
}

/// Deck-view order: least memorised first, so the cards most in need of a
/// review lead and "studiedness" grows as you read down the grid. New cards
/// come before learning cards before scheduled ones; within a band the
/// shorter interval leads, then the earlier due date. Sorting on interval
/// rather than due date keeps the board still — it only rearranges when a
/// card is actually studied, not merely because a day passed.
List<StudyCard> sortStudyCardsByMastery(List<StudyCard> cards) {
  final sorted = [...cards];
  sorted.sort((a, b) {
    final byRank = _studyMasteryRank(a).compareTo(_studyMasteryRank(b));
    if (byRank != 0) return byRank;
    final byInterval = a.interval.compareTo(b.interval);
    if (byInterval != 0) return byInterval;
    final byDue = a.dueAt.compareTo(b.dueAt);
    if (byDue != 0) return byDue;
    return a.createdAt.compareTo(b.createdAt);
  });
  return sorted;
}

/// Renders the button-preview text shown above each grading button, e.g.
/// "<1m", "4d", "3mo", "1.2y".
String formatStudyInterval(double days) {
  if (days <= 0) return '<1m';
  if (days < 1) {
    final minutes = (days * 24 * 60).round();
    if (minutes < 1) return '<1m';
    if (minutes < 60) return '${minutes}m';
    final hours = (days * 24).round();
    return '${hours}h';
  }
  if (days < 30) return '${days.round()}d';
  if (days < 365) return '${(days / 30).round()}mo';
  return '${(days / 365).toStringAsFixed(1)}y';
}
