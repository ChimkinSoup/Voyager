import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';

/// The week start every *stored* tracker value is filed under, independent of
/// the `weekStartsOnMonday` display setting.
///
/// A weekly value's row id and `periodStart` are both derived from its week
/// start (see `trackerValueId`), and every lookup matches on that exact date.
/// Letting a per-device display preference move the anchor therefore
/// repartitions stored data: flipping the setting made every historical
/// weekly value vanish from the heatmap, the sparkline and the detail
/// calendar at once, and re-entering a week wrote a *second* row beside the
/// first rather than updating it.
///
/// So storage pins to Monday and the setting decides only which column a
/// calendar draws first — the same split [WorkoutPlan.dayIndexForDate] already
/// makes for planner day slots.
const bool kTrackerStorageWeekStartsMonday = true;

class PeriodicPromptService {
  DateTime periodStartFor(
    DateTime date,
    TrackerCadence cadence, {
    bool weekStartsMonday = true,
  }) {
    switch (cadence) {
      case TrackerCadence.daily:
        return DateTime(date.year, date.month, date.day);
      case TrackerCadence.weekly:
        final weekday = date.weekday;
        final startOffset = weekStartsMonday
            ? weekday - DateTime.monday
            : weekday % 7;
        // Calendar days, not elapsed time — a Duration-based subtraction
        // lands at 23:00 the previous day across a DST spring-forward, and
        // every downstream y/m/d read then floors the week start onto the
        // wrong date. See [addCalendarDays].
        return addCalendarDays(
          DateTime(date.year, date.month, date.day),
          -startOffset,
        );
      case TrackerCadence.monthly:
        return DateTime(date.year, date.month, 1);
      case TrackerCadence.yearly:
        return DateTime(date.year, 1, 1);
    }
  }

  /// [periodStartFor] with the storage anchor applied — the form every read
  /// or write of a `TrackerValue` must go through, so the heatmap, the
  /// sparkline and the detail calendars all address the same row for a given
  /// week. See [kTrackerStorageWeekStartsMonday].
  DateTime trackerPeriodStartFor(DateTime date, TrackerCadence cadence) =>
      periodStartFor(
        date,
        cadence,
        weekStartsMonday: kTrackerStorageWeekStartsMonday,
      );

  bool isDue({
    required TrackerCadence cadence,
    required DateTime now,
    required DateTime? lastCompleted,
    bool weekStartsMonday = true,
  }) {
    final currentStart = periodStartFor(
      now,
      cadence,
      weekStartsMonday: weekStartsMonday,
    );
    if (lastCompleted == null) return true;
    final lastStart = periodStartFor(
      lastCompleted,
      cadence,
      weekStartsMonday: weekStartsMonday,
    );
    return currentStart.isAfter(lastStart);
  }

  List<DateTime> missedPeriods({
    required TrackerCadence cadence,
    required DateTime now,
    required DateTime? lastCompleted,
    bool weekStartsMonday = true,
  }) {
    if (lastCompleted == null) {
      return [periodStartFor(now, cadence, weekStartsMonday: weekStartsMonday)];
    }

    final periods = <DateTime>[];
    var cursor = _nextPeriod(
      lastCompleted,
      cadence,
      weekStartsMonday: weekStartsMonday,
    );
    final current = periodStartFor(
      now,
      cadence,
      weekStartsMonday: weekStartsMonday,
    );

    while (!cursor.isAfter(current)) {
      periods.add(cursor);
      cursor = _nextPeriod(cursor, cadence, weekStartsMonday: weekStartsMonday);
    }
    return periods;
  }

  DateTime _nextPeriod(
    DateTime start,
    TrackerCadence cadence, {
    bool weekStartsMonday = true,
  }) {
    switch (cadence) {
      // Calendar days for the same reason as [periodStartFor]'s weekly
      // branch: this walks forward from one period start to the next, so a
      // 24h-per-day Duration drifts to 23:00 across a DST transition and
      // floors [missedPeriods] onto the day before.
      case TrackerCadence.daily:
        return addCalendarDays(start, 1);
      case TrackerCadence.weekly:
        return addCalendarDays(start, 7);
      case TrackerCadence.monthly:
        return DateTime(start.year, start.month + 1, 1);
      case TrackerCadence.yearly:
        return DateTime(start.year + 1, 1, 1);
    }
  }

  int longestJournalStreak(List<JournalEntry> entries) {
    if (entries.isEmpty) return 0;
    final days =
        entries
            .map(
              (e) => DateTime(
                e.entryDate.year,
                e.entryDate.month,
                e.entryDate.day,
              ),
            )
            .toSet()
            .toList()
          ..sort();
    var best = 1;
    var current = 1;
    for (var i = 1; i < days.length; i++) {
      if (days[i].difference(days[i - 1]).inDays == 1) {
        current++;
        best = current > best ? current : best;
      } else {
        current = 1;
      }
    }
    return best;
  }
}
