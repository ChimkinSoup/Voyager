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

/// The Monday a weekly value is stored under, given the `periodStart` it was
/// written with — which, from before [kTrackerStorageWeekStartsMonday], may be
/// a Sunday, or an hour off it across DST. A value already on its Monday comes
/// back as the same instant.
DateTime weeklyTrackerStorageAnchor(DateTime periodStart) {
  final day = _nearestLocalDay(periodStart);

  // Through the following day: that picks the Monday-anchored week holding
  // six of the old Sunday-anchored week's seven days, which is also the
  // week each row's id was already derived from.
  final shifted = addCalendarDays(day, 1);
  return addCalendarDays(shifted, -(shifted.weekday - DateTime.monday));
}

/// Whether a weekly value pulled from another device should be left where it
/// is: its nearest local day is already a Monday.
///
/// By calendar date rather than by instant, because Monday midnight is a
/// different instant in every time zone. Comparing instants had two devices
/// a zone apart each move the other's values onto their own Monday and
/// re-upload them, back and forth on every pull. The cost is that a row an
/// hour off its Monday across DST is left as it is when it arrives from the
/// cloud; this device's own such rows are still moved by the schema
/// migration.
bool isOnWeeklyTrackerMonday(DateTime periodStart) =>
    _nearestLocalDay(periodStart).weekday == DateTime.monday;

/// Nearest local midnight, not the floor: a DST-corrupted row sits an hour
/// *before* the date it means, and flooring would keep it there.
DateTime _nearestLocalDay(DateTime instant) {
  final local = instant.toLocal();
  final floor = DateTime(local.year, local.month, local.day);
  final ceil = addCalendarDays(floor, 1);
  return local.difference(floor).abs() <= ceil.difference(local).abs()
      ? floor
      : ceil;
}

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
            .map((e) => e.entryDate.toLocal())
            .map((d) => DateTime(d.year, d.month, d.day))
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
