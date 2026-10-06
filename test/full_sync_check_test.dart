// The whole-account check that stands between a device and a wipe: it has to
// find every record the cloud lacks or holds at an older version, and refuse
// to vouch for a collection it could not read from the server.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/dev/full_sync_check.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';

List<BackupCollection> _collectionsFor(AppDatabase db) =>
    buildBackupCollections(
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
    );

/// A server whose listings for [cachedCollections] come from the local cache.
class _PartlyOfflineSync extends InMemorySyncRepository {
  final cachedCollections = <String>{};

  @override
  Future<
    ({
      List<({String id, Map<String, dynamic> data})> documents,
      DateTime? newestWrite,
      bool fromServer,
    })
  >
  listChangedDocuments(String collection, {DateTime? since}) async {
    final listed = await super.listChangedDocuments(collection, since: since);
    return (
      documents: listed.documents,
      newestWrite: listed.newestWrite,
      fromServer: !cachedCollections.contains(collection),
    );
  }
}

void main() {
  late AppDatabase db;
  late _PartlyOfflineSync server;
  late List<BackupCollection> collections;
  late DriftTrackerRepository trackers;
  late FullSyncCheck check;

  final now = DateTime.utc(2026, 9, 1);

  StatisticTracker tracker(String id, {int version = 0, DateTime? deletedAt}) =>
      StatisticTracker(
        id: id,
        createdAt: now,
        updatedAt: now,
        version: version,
        deletedAt: deletedAt,
        name: id,
        type: TrackerType.integer,
        cadence: TrackerCadence.daily,
      );

  Future<void> upload(StatisticTracker t) => server.upsertDocument(
    FirestoreCollections.trackers,
    t.id,
    trackerToFirestore(t),
  );

  setUp(() async {
    db = AppDatabase.inMemory();
    server = _PartlyOfflineSync();
    collections = _collectionsFor(db);
    trackers = DriftTrackerRepository(db);
    check = FullSyncCheck(collections: collections, syncRepository: server);

    // Whatever a fresh database seeds for itself starts out in the cloud, so
    // each test sees only the gap it makes.
    for (final collection in collections) {
      for (final record in await collection.read()) {
        await server.upsertDocument(
          collection.name,
          firestoreDocumentIdForLocal(collection.name, record.id),
          record.data,
        );
      }
    }
  });

  tearDown(() => db.close());

  test('a device the cloud fully holds is safe to wipe', () async {
    await trackers.upsertTracker(tracker('t1'));
    await upload(tracker('t1'));

    final report = await check.run();

    expect(report.gaps, isEmpty);
    expect(report.unreadable, isEmpty);
    expect(report.safeToWipe, isTrue);
  });

  test('a record the cloud never received is a gap', () async {
    await trackers.upsertTracker(tracker('t1'));

    final report = await check.run();

    expect(report.safeToWipe, isFalse);
    expect(report.gaps.single.collection, FirestoreCollections.trackers);
    expect(report.gaps.single.id, 't1');
    expect(report.gaps.single.reason, 'not in cloud');
  });

  test('a record the cloud holds at an older version is a gap', () async {
    await upload(tracker('t1', version: 2));
    await trackers.upsertTracker(tracker('t1', version: 3));

    final report = await check.run();

    expect(report.gaps.single.reason, 'local v3, cloud v2');
  });

  test('cloud-only records and never-uploaded tombstones are not gaps', () async {
    await upload(tracker('cloud-only'));
    await trackers.upsertTracker(tracker('gone', deletedAt: now));

    final report = await check.run();

    expect(report.safeToWipe, isTrue);
  });

  test('untouched seeds are not gaps, edited ones are', () async {
    final jobs = DriftJobRepository(db);
    await jobs.ensureSeeded();

    expect((await check.run()).safeToWipe, isTrue);

    final applied = (await jobs.listStages()).firstWhere(
      (s) => s.id == jobSeedStageId('Applied'),
    );
    await jobs.upsertStage(applied.copyWith(name: 'Sent'));

    final report = await check.run();

    expect(report.gaps.single.id, applied.id);
  });

  test('untouched starter exercises are not gaps, edited ones are', () async {
    final workouts = DriftWorkoutRepository(db);
    await workouts.ensureSeeded();
    // The plans seeded alongside are not what this test is about.
    for (final plan in await workouts.listPlans()) {
      await server.upsertDocument(
        FirestoreCollections.workoutPlans,
        plan.id,
        workoutPlanToFirestore(plan),
      );
    }

    expect((await check.run()).safeToWipe, isTrue);

    final bench = (await workouts.listExercises()).first;
    await workouts.upsertExercise(bench.copyWith(targetSets: 5));

    final report = await check.run();

    expect(report.gaps.single.id, bench.id);
  });

  test('untouched built-in plans are not gaps, edited ones are', () async {
    final workouts = DriftWorkoutRepository(db);
    await workouts.ensureSeeded();

    expect((await check.run()).safeToWipe, isTrue);

    final cycle = (await workouts.listPlans()).firstWhere(
      (p) => p.id == kCycleWorkoutPlanId,
    );
    await workouts.upsertPlan(cycle.copyWith(cycleLength: 5));

    final report = await check.run();

    expect(report.gaps.single.id, kCycleWorkoutPlanId);
  });

  test('a collection answered from the cache is not vouched for', () async {
    server.cachedCollections.add(FirestoreCollections.trackers);

    final report = await check.run();

    expect(report.unreadable.keys, [FirestoreCollections.trackers]);
    expect(report.safeToWipe, isFalse);
  });

  test('every synced collection is checked', () async {
    final checked = {
      for (final c in collections)
        if (FirestoreCollections.records.contains(c.name)) c.name,
    };
    expect(checked, FirestoreCollections.records);
  });

  test('the change counter moves with every committed write', () async {
    final dir = await Directory.systemTemp.createTemp('sync_check_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/voyager.sqlite');
    final onDisk = AppDatabase(NativeDatabase(file));
    final repository = DriftTrackerRepository(onDisk);

    await repository.upsertTracker(tracker('a'));
    final before = await databaseChangeCounter(file);
    await repository.upsertTracker(tracker('b'));
    final after = await databaseChangeCounter(file);
    await onDisk.close();

    expect(before, isNotNull);
    expect(after, isNot(before));
    expect(await databaseChangeCounter(file), after);
  });
}
