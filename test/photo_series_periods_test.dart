// Photo Series' periods, streaks and missed marks (PHOTO_SERIES_HLD.md §8).

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/photo_series/photo_series_periods.dart';

void main() {
  final created = DateTime(2026, 9, 1, 12);

  PhotoSeries series(TrackerCadence cadence, {DateTime? createdAt}) =>
      PhotoSeries(
        id: 's',
        name: 'Progress',
        cadence: cadence,
        createdAt: (createdAt ?? created).toUtc(),
        updatedAt: (createdAt ?? created).toUtc(),
      );

  var n = 0;
  final checkIns = <PhotoCheckIn>[];
  final images = <PhotoCheckInImage>[];

  /// A check-in on [day], with [photos] photos.
  void checkIn(DateTime day, {int photos = 1, String seriesId = 's'}) {
    final id = 'c${n++}';
    checkIns.add(
      PhotoCheckIn(
        id: id,
        seriesId: seriesId,
        takenOn: day,
        createdAt: created,
        updatedAt: created,
      ),
    );
    for (var i = 0; i < photos; i++) {
      images.add(
        PhotoCheckInImage(
          id: '$id-$i',
          checkInId: id,
          angleId: 'a$i',
          blobId: 'b$id$i',
          createdAt: created,
          updatedAt: created,
        ),
      );
    }
  }

  PhotoSeriesStats stats(PhotoSeries s, DateTime now) =>
      photoSeriesStats(series: s, checkIns: checkIns, images: images, now: now);

  setUp(() {
    checkIns.clear();
    images.clear();
  });

  test('weeks start on Monday', () {
    // Sunday 2026-10-18 belongs to the week of Monday 2026-10-12.
    expect(
      photoPeriodStart(DateTime(2026, 10, 18), TrackerCadence.weekly),
      DateTime(2026, 10, 12),
    );
    expect(
      photoPeriodStart(DateTime(2026, 10, 19), TrackerCadence.weekly),
      DateTime(2026, 10, 19),
    );
  });

  test('next period for every cadence, months of any length', () {
    expect(
      nextPhotoPeriod(DateTime(2026, 2, 28), TrackerCadence.daily),
      DateTime(2026, 3, 1),
    );
    expect(
      nextPhotoPeriod(DateTime(2026, 10, 12), TrackerCadence.weekly),
      DateTime(2026, 10, 19),
    );
    expect(
      nextPhotoPeriod(DateTime(2026, 1, 1), TrackerCadence.monthly),
      DateTime(2026, 2, 1),
    );
    expect(
      nextPhotoPeriod(DateTime(2026, 12, 1), TrackerCadence.monthly),
      DateTime(2027, 1, 1),
    );
    expect(
      nextPhotoPeriod(DateTime(2026, 1, 1), TrackerCadence.yearly),
      DateTime(2027, 1, 1),
    );
  });

  test('a running period is due, never missed, and keeps the streak', () {
    final s = series(TrackerCadence.daily, createdAt: DateTime(2026, 10, 15));
    checkIn(DateTime(2026, 10, 15));
    checkIn(DateTime(2026, 10, 16));
    checkIn(DateTime(2026, 10, 17));

    final result = stats(s, DateTime(2026, 10, 18, 8));
    expect(result.periods.length, 4);
    expect(result.states.last, PhotoPeriodState.due);
    expect(result.missed, 0);
    expect(result.currentStreak, 3);
    expect(result.bestStreak, 3);
    expect(result.currentDone, isFalse);
  });

  test('a past period without a photo is missed and breaks the streak', () {
    final s = series(TrackerCadence.daily, createdAt: DateTime(2026, 10, 14));
    checkIn(DateTime(2026, 10, 14));
    checkIn(DateTime(2026, 10, 15));
    // 16th missed.
    checkIn(DateTime(2026, 10, 17));
    checkIn(DateTime(2026, 10, 18));

    final result = stats(s, DateTime(2026, 10, 18, 20));
    expect(result.missed, 1);
    expect(result.currentStreak, 2);
    expect(result.bestStreak, 2);
    expect(result.currentDone, isTrue);
  });

  test('a check-in without a photo does not count', () {
    final s = series(TrackerCadence.weekly, createdAt: DateTime(2026, 10, 5));
    checkIn(DateTime(2026, 10, 6), photos: 0);

    final result = stats(s, DateTime(2026, 10, 18));
    expect(result.checkIns, 0);
    // The weeks of Oct 5 and Oct 12, the second still running.
    expect(result.states, [PhotoPeriodState.missed, PhotoPeriodState.due]);
  });

  test('a backdated import fills a missed period and extends the strip', () {
    final s = series(TrackerCadence.monthly, createdAt: DateTime(2026, 9, 1));
    checkIn(DateTime(2026, 10, 2));
    expect(stats(s, DateTime(2026, 10, 18)).missed, 1);

    checkIn(DateTime(2026, 9, 20));
    checkIn(DateTime(2026, 7, 4));
    final result = stats(s, DateTime(2026, 10, 18));
    // July, August, September, October.
    expect(result.periods.first, DateTime(2026, 7, 1));
    expect(result.periods.length, 4);
    expect(result.missed, 1);
    expect(result.first, DateTime(2026, 7, 4));
    expect(result.latest, DateTime(2026, 10, 2));
  });

  test('several check-ins in one period count once for the streak', () {
    final s = series(TrackerCadence.weekly, createdAt: DateTime(2026, 10, 12));
    checkIn(DateTime(2026, 10, 12), photos: 2);
    checkIn(DateTime(2026, 10, 14), photos: 3);

    final result = stats(s, DateTime(2026, 10, 18));
    expect(result.periods.length, 1);
    expect(result.checkIns, 2);
    expect(result.photos, 5);
    expect(result.currentStreak, 1);
  });

  test('yearly periods, and other series ignored', () {
    final s = series(TrackerCadence.yearly, createdAt: DateTime(2024, 3, 1));
    checkIn(DateTime(2024, 6, 1));
    checkIn(DateTime(2026, 1, 9));
    checkIn(DateTime(2025, 5, 5), seriesId: 'other');

    final result = stats(s, DateTime(2026, 10, 18));
    expect(result.periods, [DateTime(2024), DateTime(2025), DateTime(2026)]);
    expect(result.states, [
      PhotoPeriodState.done,
      PhotoPeriodState.missed,
      PhotoPeriodState.done,
    ]);
    expect(result.currentStreak, 1);
  });

  test('deleted check-ins and photos are ignored', () {
    final s = series(TrackerCadence.daily, createdAt: DateTime(2026, 10, 18));
    checkIn(DateTime(2026, 10, 18));
    images[0] = images[0].copyWith(deletedAt: DateTime.utc(2026, 10, 18));

    expect(stats(s, DateTime(2026, 10, 18, 12)).currentDone, isFalse);
  });
}
