// The counter statistic (COUNTER_STATISTIC_HLD.md): a running total kept as
// per-device daily changes, derived into a per-period series for the
// sparkline.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';

StatisticTracker _counter({
  TrackerCadence cadence = TrackerCadence.daily,
  DateTime? createdAt,
}) {
  final created = createdAt ?? DateTime(2026, 10, 1, 12);
  return StatisticTracker(
    id: 'counter-1',
    createdAt: created,
    updatedAt: created,
    name: 'Pushups',
    type: TrackerType.counter,
    cadence: cadence,
  );
}

CounterAdjustment _change(
  DateTime day,
  int delta, {
  String deviceId = 'device-a',
  int version = 1,
  DateTime? updatedAt,
  DateTime? deletedAt,
}) {
  final stamp = updatedAt ?? DateTime.utc(2026, 10, 3);
  return CounterAdjustment(
    id: counterAdjustmentId('counter-1', day, deviceId),
    createdAt: stamp,
    updatedAt: stamp,
    version: version,
    deletedAt: deletedAt,
    trackerId: 'counter-1',
    day: day,
    deviceId: deviceId,
    delta: delta,
  );
}

RemoteSyncService _service(AppDatabase db, InMemorySyncRepository server) =>
    RemoteSyncService(
      syncRepository: server,
      journalRepository: DriftJournalRepository(db),
      dreamRepository: DriftDreamRepository(db),
      todoRepository: DriftTodoRepository(db),
      leetCodeRepository: DriftLeetCodeRepository(db),
      studyRepository: DriftStudyRepository(db),
      workoutRepository: DriftWorkoutRepository(db),
      jobRepository: DriftJobRepository(db),
      rankingRepository: DriftRankingRepository(db),
      calendarRepository: DriftCalendarRepository(db),
      trackerRepository: DriftTrackerRepository(db),
      financeRepository: DriftFinanceRepository(db),
      notificationRepository: DriftNotificationRepository(db),
      reminderRepository: DriftReminderRepository(db),
      bucketListRepository: DriftBucketListRepository(db),
      mediaRepository: DriftMediaRepository(db),
      settingsRepository: DriftSettingsRepository(db),
      syncEngine: SyncEngine(
        syncRepository: server,
        deviceId: 'device-b',
        debouncer: Debouncer(delay: Duration.zero),
      ),
      deviceId: 'device-b',
      uploadDebounceDelay: Duration.zero,
    );

List<(DateTime, double?)> _points(List<TrackerValue> series) => [
  for (final value in series) (value.periodStart, value.intValue),
];

void main() {
  group('counterSeriesValues', () {
    test('daily: one running total per day, carried across quiet days', () {
      final series = counterSeriesValues(_counter(), [
        _change(DateTime(2026, 10, 1), 5),
        _change(DateTime(2026, 10, 3), 2),
      ], today: DateTime(2026, 10, 4, 9));
      expect(_points(series), [
        (DateTime(2026, 10, 1), 5.0),
        (DateTime(2026, 10, 2), 5.0),
        (DateTime(2026, 10, 3), 7.0),
        (DateTime(2026, 10, 4), 7.0),
      ]);
    });

    test('a change before creation starts the series earlier', () {
      final series = counterSeriesValues(_counter(), [
        _change(DateTime(2026, 9, 29), 1),
      ], today: DateTime(2026, 10, 1));
      expect(series.first.periodStart, DateTime(2026, 9, 29));
      expect(series.map((v) => v.intValue), [1.0, 1.0, 1.0]);
    });

    test('totals can go negative', () {
      final series = counterSeriesValues(_counter(), [
        _change(DateTime(2026, 10, 1), -3),
      ], today: DateTime(2026, 10, 1));
      expect(series.single.intValue, -3.0);
    });

    test('weekly: Monday-anchored, valued at the week end or today', () {
      // Thu 1 Oct 2026 sits in the week of Mon 28 Sep.
      final series = counterSeriesValues(
        _counter(cadence: TrackerCadence.weekly),
        [
          _change(DateTime(2026, 10, 1), 2),
          _change(DateTime(2026, 10, 6), 3), // Tue, next week
          _change(DateTime(2026, 10, 9), 4), // Fri, after today
        ],
        today: DateTime(2026, 10, 7),
      );
      expect(_points(series), [
        (DateTime(2026, 9, 28), 2.0),
        // The current week stops at today, so Friday's change isn't in it.
        (DateTime(2026, 10, 5), 5.0),
      ]);
    });

    test('monthly and yearly: one point per period through today', () {
      final changes = [
        _change(DateTime(2026, 10, 1), 1),
        _change(DateTime(2026, 12, 31), 1),
        _change(DateTime(2027, 2, 2), 1),
      ];
      final tracker = _counter();
      final monthly = counterSeriesValues(
        _counter(cadence: TrackerCadence.monthly),
        changes,
        today: DateTime(2027, 2, 10),
      );
      expect(_points(monthly), [
        (DateTime(2026, 10), 1.0),
        (DateTime(2026, 11), 1.0),
        (DateTime(2026, 12), 2.0),
        (DateTime(2027, 1), 2.0),
        (DateTime(2027, 2), 3.0),
      ]);
      final yearly = counterSeriesValues(
        StatisticTracker(
          id: tracker.id,
          createdAt: tracker.createdAt,
          updatedAt: tracker.updatedAt,
          name: tracker.name,
          type: TrackerType.counter,
          cadence: TrackerCadence.yearly,
        ),
        changes,
        today: DateTime(2027, 2, 10),
      );
      expect(_points(yearly), [(DateTime(2026), 2.0), (DateTime(2027), 3.0)]);
    });

    test('erased rows are ignored', () {
      final series = counterSeriesValues(_counter(), [
        _change(DateTime(2026, 10, 1), 4),
        _change(
          DateTime(2026, 10, 1),
          9,
          deviceId: 'device-b',
          deletedAt: DateTime.utc(2026, 10, 2),
        ),
      ], today: DateTime(2026, 10, 1));
      expect(series.single.intValue, 4.0);
    });
  });

  group('repository', () {
    late AppDatabase db;
    late DriftTrackerRepository repo;
    final day = DateTime(2026, 10, 3);

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftTrackerRepository(db);
    });
    tearDown(() => db.close());

    Future<void> tap(int delta, {String deviceId = 'device-a'}) =>
        repo.adjustCounter(
          trackerId: 'counter-1',
          day: day,
          deviceId: deviceId,
          delta: delta,
        );

    test('a burst of concurrent taps loses none', () async {
      await Future.wait([for (var i = 0; i < 40; i++) tap(1)]);
      await Future.wait([for (var i = 0; i < 15; i++) tap(-1)]);
      final rows = await repo.listAdjustments('counter-1');
      expect(rows.single.delta, 25);
      expect(rows.single.version, 55);
    });

    test('a tap on an erased row starts again from that tap', () async {
      // Erased by a device on an older version, which tombstoned rows.
      await repo.upsertAdjustment(
        _change(day, 2, version: 3, deletedAt: DateTime.utc(2026, 10, 4)),
      );
      expect(await repo.listAdjustments('counter-1'), isEmpty);

      await tap(-1);
      final row = (await repo.listAdjustments('counter-1')).single;
      expect(row.delta, -1);
      expect(row.deletedAt, isNull);
    });

    test(
      "erasing a day offsets it in this device's row, leaving others' alone",
      () async {
        await tap(2);
        await tap(3, deviceId: 'device-b');
        await repo.adjustCounter(
          trackerId: 'counter-1',
          day: DateTime(2026, 10, 2),
          deviceId: 'device-a',
          delta: 1,
        );

        final erased = await repo.eraseCounterDay(
          'counter-1',
          day,
          deviceId: 'device-a',
        );

        expect(erased, 5);
        final rows = await repo.listAdjustments('counter-1');
        expect(counterDailyChanges(rows)[day], 0);
        expect(counterDailyChanges(rows)[DateTime(2026, 10, 2)], 1);
        final b = rows.singleWhere((a) => a.deviceId == 'device-b');
        expect((b.delta, b.version), (3, 1), reason: "B's row is untouched");
      },
    );

    test('undoing an erase adds the erased amount back', () async {
      await tap(2);
      await tap(3, deviceId: 'device-b');
      final erased = await repo.eraseCounterDay(
        'counter-1',
        day,
        deviceId: 'device-a',
      );

      await tap(1);
      await tap(erased);

      final rows = await repo.listAdjustments('counter-1');
      expect(counterDailyChanges(rows)[day], 6, reason: 'the tap stands');
    });

    test('erasing a day with no net change writes nothing', () async {
      await tap(2);
      await tap(-2, deviceId: 'device-b');
      final before = await repo.listAdjustments('counter-1');

      expect(
        await repo.eraseCounterDay('counter-1', day, deviceId: 'device-a'),
        0,
      );
      expect(
        (await repo.listAdjustments('counter-1')).map((a) => a.version),
        before.map((a) => a.version),
      );
    });

    test('a starting value is written on the creation day', () async {
      final tracker = _counter(createdAt: DateTime(2026, 10, 3, 15));
      await repo.createCounter(tracker, startingValue: 7, deviceId: 'device-a');

      expect((await repo.getTracker(tracker.id))?.type, TrackerType.counter);
      final row = (await repo.listAdjustments(tracker.id)).single;
      expect(row.delta, 7);
      expect(row.day, DateTime(2026, 10, 3));
    });

    test(
      'creating a counter notifies only after its transaction commits',
      () async {
        // An upload started from the notifier runs in the zone it was started
        // from; one that touched the database once the transaction had closed
        // failed with "Transaction used after it was closed".
        final notified = <String>[];
        final later = <Future<void>>[];
        final syncedWrites = SyncedWriteNotifier()
          ..onWrite = (collection, records) {
            notified.add(collection);
            later.add(
              Future<void>.delayed(
                Duration.zero,
                () => db.select(db.pendingUploadsTable).get(),
              ),
            );
          };
        repo = DriftTrackerRepository(db, syncedWrites: syncedWrites);

        await repo.createCounter(_counter(), startingValue: 7, deviceId: 'a');
        await Future.wait(later);

        expect(notified, [
          FirestoreCollections.trackers,
          FirestoreCollections.counterAdjustments,
        ]);
      },
    );

    test('a starting value of 0 writes no row', () async {
      final tracker = _counter();
      await repo.createCounter(tracker, startingValue: 0, deviceId: 'device-a');
      expect(await repo.getTracker(tracker.id), isNotNull);
      expect(
        await repo.listAdjustments(tracker.id, includeDeleted: true),
        isEmpty,
      );
    });
  });

  group('sync', () {
    test('a day survives the round trip as the same calendar date', () {
      final change = _change(DateTime(2026, 10, 3), 2);
      final data = counterAdjustmentToFirestore(change);
      expect(data['day'], '2026-10-03');
      final back = mergeCounterAdjustmentFromRemote(data, change.id);
      expect(back.day, DateTime(2026, 10, 3));
      expect(back.delta, 2);
      expect(back.deviceId, 'device-a');
    });

    test('two devices tapping the same day offline both count', () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final server = InMemorySyncRepository();
      final repo = DriftTrackerRepository(db);
      final day = DateTime(2026, 10, 3);

      // This device (B) tapped twice while offline; A's row arrives by pull.
      await repo.adjustCounter(
        trackerId: 'counter-1',
        day: day,
        deviceId: 'device-b',
        delta: 1,
      );
      await repo.adjustCounter(
        trackerId: 'counter-1',
        day: day,
        deviceId: 'device-b',
        delta: 1,
      );
      final fromA = _change(day, 3);
      await server.upsertDocument(
        FirestoreCollections.counterAdjustments,
        fromA.id,
        counterAdjustmentToFirestore(fromA),
      );

      await _service(db, server).pullCounterAdjustments();

      final rows = await repo.listAdjustments('counter-1');
      expect(rows, hasLength(2));
      expect(counterTotalThrough(rows, day), 5);
    });

    test(
      "another device's erase and this device's offline tap both hold",
      () async {
        final db = AppDatabase.inMemory();
        addTearDown(db.close);
        final server = InMemorySyncRepository();
        final repo = DriftTrackerRepository(db);
        final day = DateTime(2026, 10, 3);

        // This device (A) had +1 on D, which B saw and erased with -1 in its
        // own row. A, still offline, tapped D again.
        await repo.upsertAdjustment(_change(day, 1));
        await repo.adjustCounter(
          trackerId: 'counter-1',
          day: day,
          deviceId: 'device-a',
          delta: 1,
        );
        final eraseFromB = _change(day, -1, deviceId: 'device-b');
        await server.upsertDocument(
          FirestoreCollections.counterAdjustments,
          eraseFromB.id,
          counterAdjustmentToFirestore(eraseFromB),
        );

        await _service(db, server).pullCounterAdjustments();

        final rows = await repo.listAdjustments('counter-1');
        expect(rows, hasLength(2));
        expect(counterDailyChanges(rows)[day], 1, reason: 'only the new tap');
      },
    );

    test('an erase and a tap at the same version: the later one wins', () {
      final day = DateTime(2026, 10, 3);
      final erasedByB = _change(
        day,
        2,
        version: 3,
        updatedAt: DateTime.utc(2026, 10, 3, 10),
        deletedAt: DateTime.utc(2026, 10, 3, 10),
      );
      final tappedByA = _change(
        day,
        3,
        version: 3,
        updatedAt: DateTime.utc(2026, 10, 3, 11),
      );
      final onA = mergeCounterAdjustmentFromRemote(
        counterAdjustmentToFirestore(erasedByB),
        erasedByB.id,
        local: tappedByA,
      );
      expect(onA.deletedAt, isNull);
      expect(onA.delta, 3);

      final onB = mergeCounterAdjustmentFromRemote(
        counterAdjustmentToFirestore(tappedByA),
        tappedByA.id,
        local: erasedByB,
      );
      expect(onB.deletedAt, isNull);
      expect(onB.delta, 3);
    });

    test("a weekly counter's rows keep their days through a pull", () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final server = InMemorySyncRepository();
      final now = DateTime.utc(2026, 10, 3);
      final tracker = _counter(cadence: TrackerCadence.weekly);
      await server.upsertDocument(
        FirestoreCollections.trackers,
        tracker.id,
        trackerToFirestore(tracker),
      );
      // A Wednesday — the weekly tracker-value repair would move a value on
      // it to the Monday.
      final wednesday = _change(DateTime(2026, 9, 30), 4, updatedAt: now);
      await server.upsertDocument(
        FirestoreCollections.counterAdjustments,
        wednesday.id,
        counterAdjustmentToFirestore(wednesday),
      );

      final sync = _service(db, server);
      await sync.pullTrackers();
      await sync.pullTrackerValues();
      await sync.pullCounterAdjustments();

      final rows = await DriftTrackerRepository(db).listAdjustments(tracker.id);
      expect(rows.single.day, DateTime(2026, 9, 30));
      final remote = await server.getDocument(
        FirestoreCollections.counterAdjustments,
        wednesday.id,
      );
      expect(remote?['day'], '2026-09-30');
    });
  });
}
