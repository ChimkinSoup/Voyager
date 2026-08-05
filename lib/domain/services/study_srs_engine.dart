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
      return StudySrsResult(interval: newInterval, ease: _clampEase(ease - 0.15));
    case StudyGrade.good:
      final newInterval = isFirstReview ? 1.0 : interval * ease;
      return StudySrsResult(interval: newInterval, ease: ease);
    case StudyGrade.easy:
      final newInterval = isFirstReview ? 3.0 : interval * ease * 1.3;
      return StudySrsResult(interval: newInterval, ease: _clampEase(ease + 0.15));
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
      Duration(milliseconds: (result.interval * Duration.millisecondsPerDay).round()),
    ),
    reviewCount: card.reviewCount + 1,
    bumpVersion: true,
  );
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
