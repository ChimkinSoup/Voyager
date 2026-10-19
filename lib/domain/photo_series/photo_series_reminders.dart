import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/photo_series/photo_series_periods.dart';
import 'package:voyager/domain/services/reminder_schedule.dart';

// =============================================================================
// A series' check-in reminder (PHOTO_SERIES_HLD.md §13): one occurrence per
// period, on the series' reminder day at its reminder time, device-local.
//
// An occurrence only counts inside its own period. Once the period ends its
// reminder is gone, missed or not, and a period that is done (§8) has none —
// that is the auto-acknowledge: nothing is written, the occurrence just stops
// existing, here and on every device that sees the check-in.
// =============================================================================

/// The local instant [series]' reminder fires in the period starting at
/// [period].
DateTime photoReminderFireAt(PhotoSeries series, DateTime period) {
  final day = switch (series.cadence) {
    TrackerCadence.daily => period,
    TrackerCadence.weekly => addCalendarDays(
      period,
      series.reminderWeekday - DateTime.monday,
    ),
    TrackerCadence.monthly => _clampedDay(
      period.year,
      period.month,
      series.reminderMonthDay,
    ),
    TrackerCadence.yearly => _clampedDay(
      period.year,
      series.reminderMonth,
      series.reminderMonthDay,
    ),
  };
  return atLocalMinutes(day, series.reminderMinutes);
}

/// [day] of [month], or the month's last day when it is shorter.
DateTime _clampedDay(int year, int month, int day) {
  final length = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day > length ? length : day);
}

/// Whether [series]' period starting at [period] holds a live check-in with a
/// live photo — the same test [photoSeriesStats] marks a period done with.
bool photoPeriodDone(
  PhotoSeriesSnapshot snapshot,
  PhotoSeries series,
  DateTime period,
) {
  final inPeriod = {
    for (final checkIn in snapshot.checkIns)
      if (checkIn.seriesId == series.id &&
          checkIn.deletedAt == null &&
          photoPeriodStart(checkIn.takenOn, series.cadence) == period)
        checkIn.id,
  };
  return snapshot.images.any(
    (image) => image.deletedAt == null && inPeriod.contains(image.checkInId),
  );
}

ReminderOccurrence _occurrence(DateTime fireAt) =>
    ReminderOccurrence(fireAt: fireAt, key: reminderOccurrenceKey(fireAt));

/// The current period's occurrence once it has fired, or null — before the
/// reminder time, once the period is done ([currentDone]), and for a time
/// before the series existed, so a series made at noon doesn't raise this
/// morning's.
ReminderOccurrence? latestPhotoSeriesOccurrence(
  PhotoSeries series,
  DateTime now, {
  required bool currentDone,
}) {
  if (currentDone) return null;
  final fireAt = photoReminderFireAt(
    series,
    photoPeriodStart(now, series.cadence),
  );
  if (fireAt.isAfter(now) || fireAt.isBefore(series.createdAt.toLocal())) {
    return null;
  }
  return _occurrence(fireAt);
}

/// The first occurrence strictly after [after], skipping the period starting
/// at [donePeriod] — a check-in made before the reminder time cancels that
/// period's alert.
ReminderOccurrence? nextPhotoSeriesFire(
  PhotoSeries series,
  DateTime after, {
  DateTime? donePeriod,
}) {
  final created = series.createdAt.toLocal();
  var period = photoPeriodStart(after, series.cadence);
  // The period holding [after], the one after it, and one more for a series
  // created after the next one's fire time.
  for (var i = 0; i < 3; i++) {
    final fireAt = photoReminderFireAt(series, period);
    if (period != donePeriod &&
        fireAt.isAfter(after) &&
        !fireAt.isBefore(created)) {
      return _occurrence(fireAt);
    }
    period = nextPhotoPeriod(period, series.cadence);
  }
  return null;
}
