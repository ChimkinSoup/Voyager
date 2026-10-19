import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/services/periodic_prompt_service.dart';

/// Where one period of a series stands (PHOTO_SERIES_HLD.md §8).
enum PhotoPeriodState { done, missed, due }

/// A series' periods, streaks and counts, from plain fields only — so all of
/// it shows while the vault is locked.
class PhotoSeriesStats {
  const PhotoSeriesStats({
    required this.periods,
    required this.states,
    required this.checkIns,
    required this.photos,
    required this.currentStreak,
    required this.bestStreak,
    required this.missed,
    this.first,
    this.latest,
  });

  /// Every period start from the series' first period to the current one,
  /// oldest first. The last is the current period.
  final List<DateTime> periods;

  /// In step with [periods].
  final List<PhotoPeriodState> states;

  final int checkIns;
  final int photos;
  final int currentStreak;
  final int bestStreak;
  final int missed;

  /// The earliest and latest check-in dates, null with none.
  final DateTime? first;
  final DateTime? latest;

  DateTime get currentPeriod => periods.last;
  bool get currentDone => states.last == PhotoPeriodState.done;
}

/// The start of the period holding [date], weeks from Monday as trackers'.
DateTime photoPeriodStart(DateTime date, TrackerCadence cadence) =>
    PeriodicPromptService().trackerPeriodStartFor(date, cadence);

/// The start of the period after the one starting at [start].
DateTime nextPhotoPeriod(DateTime start, TrackerCadence cadence) =>
    switch (cadence) {
      TrackerCadence.daily => addCalendarDays(start, 1),
      TrackerCadence.weekly => addCalendarDays(start, 7),
      TrackerCadence.monthly => DateTime(start.year, start.month + 1),
      TrackerCadence.yearly => DateTime(start.year + 1),
    };

/// [series]' stats at [now], from its live [checkIns] and the live [images]
/// of those. Rows of other series are ignored.
PhotoSeriesStats photoSeriesStats({
  required PhotoSeries series,
  required Iterable<PhotoCheckIn> checkIns,
  required Iterable<PhotoCheckInImage> images,
  required DateTime now,
}) {
  final cadence = series.cadence;
  final ownCheckIns = [
    for (final checkIn in checkIns)
      if (checkIn.seriesId == series.id && checkIn.deletedAt == null) checkIn,
  ];
  final ids = {for (final checkIn in ownCheckIns) checkIn.id};
  final photosByCheckIn = <String, int>{};
  for (final image in images) {
    if (image.deletedAt != null || !ids.contains(image.checkInId)) continue;
    photosByCheckIn.update(image.checkInId, (n) => n + 1, ifAbsent: () => 1);
  }

  final done = <DateTime>{};
  DateTime? first;
  DateTime? latest;
  for (final checkIn in ownCheckIns) {
    final day = checkIn.takenOn;
    if (first == null || day.isBefore(first)) first = day;
    if (latest == null || day.isAfter(latest)) latest = day;
    if ((photosByCheckIn[checkIn.id] ?? 0) > 0) {
      done.add(photoPeriodStart(day, cadence));
    }
  }

  final current = photoPeriodStart(now, cadence);
  var start = photoPeriodStart(series.createdAt.toLocal(), cadence);
  if (first != null) {
    final earliest = photoPeriodStart(first, cadence);
    if (earliest.isBefore(start)) start = earliest;
  }
  // A check-in dated ahead of today doesn't stretch the strip past now.
  if (start.isAfter(current)) start = current;

  final periods = <DateTime>[];
  final states = <PhotoPeriodState>[];
  for (var p = start; !p.isAfter(current); p = nextPhotoPeriod(p, cadence)) {
    periods.add(p);
    states.add(
      done.contains(p)
          ? PhotoPeriodState.done
          : p == current
          ? PhotoPeriodState.due
          : PhotoPeriodState.missed,
    );
  }

  var best = 0;
  var run = 0;
  for (final state in states) {
    run = state == PhotoPeriodState.done ? run + 1 : 0;
    if (run > best) best = run;
  }
  // A running period not yet done doesn't break the streak.
  var streak = 0;
  for (var i = states.length - 1; i >= 0; i--) {
    if (states[i] == PhotoPeriodState.done) {
      streak++;
    } else if (states[i] != PhotoPeriodState.due) {
      break;
    }
  }

  return PhotoSeriesStats(
    periods: periods,
    states: states,
    // A check-in counts once it has a photo (§3).
    checkIns: photosByCheckIn.length,
    photos: photosByCheckIn.values.fold(0, (sum, n) => sum + n),
    currentStreak: streak,
    bestStreak: best,
    missed: states.where((s) => s == PhotoPeriodState.missed).length,
    first: first,
    latest: latest,
  );
}
