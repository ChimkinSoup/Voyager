// Schema 89 repairs two things earlier versions wrote into the tracker tables.
//
//  * Rows filed under a virtual tracker's id. Those trackers are derived at
//    display time and their ids are short-circuited before the table is ever
//    queried, so the rows the sparkline editor wrote for them could never be
//    read back — and `purgeExpiredDeleted` only removes rows carrying a
//    `deletedAt`, which these do not have.
//  * Weekly values filed on a Sunday, from when the storage anchor followed
//    the `weekStartsOnMonday` display setting, and weekly values filed at
//    23:00 the day before, from `periodStartFor`'s old elapsed-time
//    subtraction across a DST spring-forward.
//
// The test rewinds `user_version` and reopens, so the real `onUpgrade` path
// runs rather than a hand-written approximation of it.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';

Future<void> _rewindToSchema88(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.customStatement('PRAGMA user_version = 88');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_tracker_migration_test');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  final now = DateTime.utc(2026, 8, 14, 9);

  StatisticTracker tracker({
    required String id,
    required TrackerCadence cadence,
  }) => StatisticTracker(
    id: id,
    name: id,
    type: TrackerType.integer,
    cadence: cadence,
    createdAt: now,
    updatedAt: now,
  );

  test('88→89 deletes values filed under a virtual tracker id', () async {
    final seed = AppDatabase(NativeDatabase(file));
    final trackers = DriftTrackerRepository(seed);
    await trackers.upsertTracker(
      tracker(id: 'tracker-1', cadence: TrackerCadence.daily),
    );
    await trackers.upsertValue(
      TrackerValue(
        id: 'value-real',
        trackerId: 'tracker-1',
        periodStart: DateTime(2026, 8, 14),
        intValue: 40,
        createdAt: now,
        updatedAt: now,
      ),
    );
    // What tapping the "Best Streak" or "Words" chart used to write.
    for (final virtualId in [
      kStreakTrackerId,
      kWordCountTrackerId,
      kJournalEntriesTrackerId,
      kDreamLoggedTrackerId,
      kWorkedOutTrackerId,
    ]) {
      await trackers.upsertValue(
        TrackerValue(
          id: '${virtualId}_2026-08-14',
          trackerId: virtualId,
          periodStart: DateTime(2026, 8, 14),
          intValue: 7,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    await seed.close();

    await _rewindToSchema88(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    final remaining = await upgraded.customSelect(
      'SELECT tracker_id FROM tracker_values_table',
    ).get();
    await upgraded.close();

    expect(
      remaining.map((row) => row.read<String>('tracker_id')),
      ['tracker-1'],
    );
  });

  test('88→89 re-anchors Sunday-filed weekly values onto Monday', () async {
    final seed = AppDatabase(NativeDatabase(file));
    final trackers = DriftTrackerRepository(seed);
    await trackers.upsertTracker(
      tracker(id: 'weekly-1', cadence: TrackerCadence.weekly),
    );
    // Sunday-anchored, as a device with "week starts on Monday" switched off
    // recorded it.
    await trackers.upsertValue(
      TrackerValue(
        id: 'weekly-1_2026-10-19',
        trackerId: 'weekly-1',
        periodStart: DateTime(2026, 10, 18),
        intValue: 3,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await seed.close();

    await _rewindToSchema88(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    final values = await DriftTrackerRepository(
      upgraded,
    ).listValues('weekly-1');
    await upgraded.close();

    expect(values.single.periodStart, DateTime(2026, 10, 19));
    expect(values.single.periodStart.weekday, DateTime.monday);
    // Bumped, so the repair outranks the stale copy still on the server rather
    // than being reverted by the next pull.
    expect(values.single.version, greaterThan(0));
    expect(values.single.intValue, 3);
  });

  test('88→89 repairs a weekly value the DST bug filed at 23:00', () async {
    final seed = AppDatabase(NativeDatabase(file));
    final trackers = DriftTrackerRepository(seed);
    await trackers.upsertTracker(
      tracker(id: 'weekly-1', cadence: TrackerCadence.weekly),
    );
    // What `.subtract(Duration(days: 6))` produced across the 2026-03-08
    // spring-forward: an hour short, so it floors onto the Saturday. The row's
    // own id already said which week it meant.
    await trackers.upsertValue(
      TrackerValue(
        id: 'weekly-1_2026-03-09',
        trackerId: 'weekly-1',
        periodStart: DateTime(2026, 3, 7, 23),
        intValue: 5,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await seed.close();

    await _rewindToSchema88(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    final values = await DriftTrackerRepository(
      upgraded,
    ).listValues('weekly-1');
    await upgraded.close();

    expect(values.single.periodStart, DateTime(2026, 3, 9));
    expect(values.single.intValue, 5);
  });

  test('88→89 leaves Monday-filed weekly values where they are', () async {
    final seed = AppDatabase(NativeDatabase(file));
    final trackers = DriftTrackerRepository(seed);
    await trackers.upsertTracker(
      tracker(id: 'weekly-1', cadence: TrackerCadence.weekly),
    );
    await trackers.upsertValue(
      TrackerValue(
        id: 'weekly-1_2026-10-19',
        trackerId: 'weekly-1',
        periodStart: DateTime(2026, 10, 19),
        intValue: 3,
        version: 4,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await seed.close();

    await _rewindToSchema88(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    final values = await DriftTrackerRepository(
      upgraded,
    ).listValues('weekly-1');
    await upgraded.close();

    expect(values.single.periodStart, DateTime(2026, 10, 19));
    // Untouched, so an already-correct row costs no sync traffic.
    expect(values.single.version, 4);
  });

  test('88→89 leaves the other cadences alone', () async {
    final seed = AppDatabase(NativeDatabase(file));
    final trackers = DriftTrackerRepository(seed);
    await trackers.upsertTracker(
      tracker(id: 'daily-1', cadence: TrackerCadence.daily),
    );
    // A Sunday, which the weekly repair would have moved.
    await trackers.upsertValue(
      TrackerValue(
        id: 'daily-1_2026-10-18',
        trackerId: 'daily-1',
        periodStart: DateTime(2026, 10, 18),
        intValue: 1,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await seed.close();

    await _rewindToSchema88(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    final values = await DriftTrackerRepository(upgraded).listValues('daily-1');
    await upgraded.close();

    expect(values.single.periodStart, DateTime(2026, 10, 18));
  });
}
