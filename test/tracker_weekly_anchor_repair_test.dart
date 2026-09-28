// Weekly tracker values the server still holds on a Sunday are moved to their
// Monday after a pull, and the move is uploaded.
//
// Schema step 89 moved them once, locally, and never uploaded the result, so
// a device restored from the cloud got the Sunday copies back — where every
// lookup, matching on the Monday, missed them.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/services/periodic_prompt_service.dart';

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

void main() {
  final sunday = DateTime(2026, 3, 29);
  final monday = DateTime(2026, 3, 30);

  group('weeklyTrackerStorageAnchor', () {
    test('moves a Sunday onto the following Monday', () {
      expect(weeklyTrackerStorageAnchor(sunday), monday);
    });

    test('leaves a Monday where it is', () {
      expect(weeklyTrackerStorageAnchor(monday), monday);
    });

    test('rounds an hour-early DST row onto the Monday it meant', () {
      final hourEarly = monday.subtract(const Duration(hours: 1));
      expect(weeklyTrackerStorageAnchor(hourEarly), monday);
    });
  });

  group('isOnWeeklyTrackerMonday', () {
    test('a local Monday is', () {
      expect(isOnWeeklyTrackerMonday(monday), isTrue);
    });

    test("another time zone's Monday midnight is", () {
      // Monday 00:00 three zones west of here reads as Monday 03:00.
      expect(
        isOnWeeklyTrackerMonday(monday.add(const Duration(hours: 3))),
        isTrue,
      );
    });

    test('a Sunday is not', () {
      expect(isOnWeeklyTrackerMonday(sunday), isFalse);
    });
  });

  group('after a pull', () {
    late InMemorySyncRepository server;
    late AppDatabase db;
    late RemoteSyncService sync;
    final now = DateTime.utc(2026, 8, 1);
    const trackerId = 'weekly-1';
    final valueId = trackerValueId(trackerId, monday);

    setUp(() async {
      server = InMemorySyncRepository();
      db = AppDatabase.inMemory();
      sync = _service(db, server);

      await server.upsertDocument(
        FirestoreCollections.trackers,
        trackerId,
        trackerToFirestore(
          StatisticTracker(
            id: trackerId,
            createdAt: now,
            updatedAt: now,
            name: 'Weekly',
            type: TrackerType.integer,
            cadence: TrackerCadence.weekly,
          ),
        ),
      );
      await server.upsertDocument(
        FirestoreCollections.trackerValues,
        valueId,
        trackerValueToFirestore(
          TrackerValue(
            id: valueId,
            createdAt: now,
            updatedAt: now,
            trackerId: trackerId,
            periodStart: sunday,
            intValue: 3,
          ),
        ),
      );
    });

    tearDown(() => db.close());

    test('a Sunday value from the server lands on its Monday, here and '
        'there', () async {
      await sync.pullAll();

      final local = await DriftTrackerRepository(db).getValue(valueId);
      expect(local!.periodStart.isAtSameMomentAs(monday), isTrue);
      expect(local.version, 1);
      expect(local.intValue, 3);

      final remote = await server.getDocument(
        FirestoreCollections.trackerValues,
        valueId,
      );
      expect(
        parseFirestoreDate(remote!['periodStart'])!.isAtSameMomentAs(monday),
        isTrue,
      );
      expect(remote['version'], 1);
    });

    test('a Sunday value whose Monday already holds another value stays put, '
        'rather than duplicating that week everywhere', () async {
      const otherId = 'weekly-1_monday-row';
      await server.upsertDocument(
        FirestoreCollections.trackerValues,
        otherId,
        trackerValueToFirestore(
          TrackerValue(
            id: otherId,
            createdAt: now,
            updatedAt: now,
            trackerId: trackerId,
            periodStart: monday,
            intValue: 5,
          ),
        ),
      );

      await sync.pullAll();

      final local = await DriftTrackerRepository(db).getValue(valueId);
      expect(local!.periodStart.isAtSameMomentAs(sunday), isTrue);
      expect(local.version, 0);
      final remote = await server.getDocument(
        FirestoreCollections.trackerValues,
        valueId,
      );
      expect(remote!['version'] ?? 0, 0);
    });

    Future<void> replaceServerValue(
      DateTime periodStart, {
      DateTime? deletedAt,
    }) => server.upsertDocument(
      FirestoreCollections.trackerValues,
      valueId,
      trackerValueToFirestore(
        TrackerValue(
          id: valueId,
          createdAt: now,
          updatedAt: now,
          deletedAt: deletedAt,
          trackerId: trackerId,
          periodStart: periodStart,
          intValue: 3,
        ),
      ),
    );

    test("a value on another time zone's Monday is left alone, so two devices "
        "zones apart don't move it back and forth", () async {
      final elsewhereMonday = monday.add(const Duration(hours: 3));
      await replaceServerValue(elsewhereMonday);

      await sync.pullAll();

      final local = await DriftTrackerRepository(db).getValue(valueId);
      expect(local!.periodStart.isAtSameMomentAs(elsewhereMonday), isTrue);
      expect(local.version, 0);
      final remote = await server.getDocument(
        FirestoreCollections.trackerValues,
        valueId,
      );
      expect(remote!['version'] ?? 0, 0);
    });

    test('a deleted Sunday value is not moved or re-uploaded', () async {
      await replaceServerValue(sunday, deletedAt: now);

      await sync.pullAll();

      final local = await DriftTrackerRepository(db).getValue(valueId);
      expect(local!.periodStart.isAtSameMomentAs(sunday), isTrue);
      expect(local.version, 0);
    });

    test('a second pull leaves the repaired value alone', () async {
      await sync.pullAll();
      await sync.pullAll();

      final local = await DriftTrackerRepository(db).getValue(valueId);
      expect(local!.version, 1);
    });
  });
}
