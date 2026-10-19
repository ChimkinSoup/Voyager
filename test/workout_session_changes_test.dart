// GAPS.md, Workout: sessions changed while live (add, skip, reorder), the
// "last time" numbers beside a set, and finished sessions deleted to the trash
// and brought back.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/restore_contract.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/trash/trash_service.dart';
import 'package:voyager/features/workout/workout_history.dart';
import 'package:voyager/features/workout/workout_session_controller.dart';

class _RecordingSync implements RemoteSyncService {
  final sessions = <WorkoutSession>[];
  final setLogs = <WorkoutSetLog>[];

  @override
  void pushWorkoutSession(WorkoutSession session) => sessions.add(session);

  @override
  void pushWorkoutSetLog(WorkoutSetLog log) => setLogs.add(log);

  @override
  Future<void> pushWorkoutSetLogsBatch(List<WorkoutSetLog> logs) async =>
      setLogs.addAll(logs);

  @override
  noSuchMethod(Invocation invocation) => null;
}

/// Holds the next read of a session's sets once its rows are taken, so a
/// write can land while the read is out and the read still predate it.
class _HeldReadRepository extends DriftWorkoutRepository {
  _HeldReadRepository(super.db);

  var _armed = false;
  final _release = Completer<void>();
  final _reached = Completer<void>();

  /// Arms the hold; the returned future completes once a read is held.
  Future<void> holdNextRead() {
    _armed = true;
    return _reached.future;
  }

  void release() => _release.complete();

  @override
  Future<List<WorkoutSetLog>> listSetLogs({
    String? sessionId,
    String? exerciseId,
    bool includeDeleted = false,
  }) async {
    final logs = await super.listSetLogs(
      sessionId: sessionId,
      exerciseId: exerciseId,
      includeDeleted: includeDeleted,
    );
    if (_armed && sessionId != null) {
      _armed = false;
      _reached.complete();
      await _release.future;
    }
    return logs;
  }
}

class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<AppSettings> getSettings() async => const AppSettings();

  @override
  noSuchMethod(Invocation invocation) => null;
}

final _plan = WorkoutPlan(
  id: 'plan',
  name: 'Plan',
  mode: WorkoutPlanMode.weekly,
  cycleAnchor: DateTime.utc(2026, 1, 1),
  isActive: true,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

Exercise _exercise(String id, {int sets = 3}) {
  final now = utcNow();
  return Exercise(
    id: id,
    name: id,
    targetSets: sets,
    targetReps: 8,
    targetWeightKg: 60,
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> _seed(DriftWorkoutRepository repo) async {
  final now = utcNow();
  await repo.upsertPlan(_plan);
  for (final id in ['bench', 'squat', 'row']) {
    await repo.upsertExercise(_exercise(id, sets: id == 'row' ? 2 : 3));
  }
  for (final (i, id) in ['bench', 'squat'].indexed) {
    await repo.upsertPlanEntry(
      WorkoutPlanEntry(
        id: 'entry$i',
        planId: 'plan',
        dayIndex: 1,
        exerciseId: id,
        sortOrder: i,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
}

WorkoutSession _session(
  String id, {
  required DateTime date,
  DateTime? startedAt,
  bool ended = true,
}) {
  final started = startedAt ?? DateTime.utc(2026, 9, 1);
  return WorkoutSession(
    id: id,
    date: workoutStoredDate(date),
    startedAt: started,
    endedAt: ended ? started : null,
    createdAt: started,
    updatedAt: started,
  );
}

WorkoutSetLog _log(
  String id,
  String sessionId, {
  int order = 0,
  int setIndex = 0,
  double weightKg = 60,
  bool completed = true,
}) {
  final now = DateTime.utc(2026, 9, 1);
  return WorkoutSetLog(
    id: id,
    sessionId: sessionId,
    exerciseId: 'bench',
    exerciseOrder: order,
    setIndex: setIndex,
    weightKg: weightKg,
    reps: 8,
    plannedWeightKg: 60,
    plannedReps: 8,
    completed: completed,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  late AppDatabase db;
  late _HeldReadRepository repo;
  late _RecordingSync sync;
  late ProviderContainer container;

  WorkoutSessionController controller() =>
      container.read(workoutSessionControllerProvider.notifier);
  ActiveWorkoutState state() =>
      container.read(workoutSessionControllerProvider);

  Future<void> start() => controller().startFromPlan(
    plan: _plan,
    dayIndex: 1,
    date: DateTime.now(),
  );

  setUp(() async {
    db = AppDatabase.inMemory();
    repo = _HeldReadRepository(db);
    sync = _RecordingSync();
    container = ProviderContainer(
      overrides: [
        workoutRepositoryProvider.overrideWithValue(repo),
        remoteSyncServiceProvider.overrideWithValue(sync),
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
        trashServiceProvider.overrideWith(
          (ref) => TrashService(
            db: db,
            collections: buildBackupCollections(
              journalRepository: DriftJournalRepository(db),
              dreamRepository: DriftDreamRepository(db),
              todoRepository: DriftTodoRepository(db),
              leetCodeRepository: DriftLeetCodeRepository(db),
              studyRepository: DriftStudyRepository(db),
              workoutRepository: repo,
              jobRepository: DriftJobRepository(db),
              rankingRepository: DriftRankingRepository(db),
              calendarRepository: DriftCalendarRepository(db),
              trackerRepository: DriftTrackerRepository(db),
              financeRepository: DriftFinanceRepository(db),
              notificationRepository: DriftNotificationRepository(db),
              reminderRepository: DriftReminderRepository(db),
              bucketListRepository: DriftBucketListRepository(db),
              mediaRepository: DriftMediaRepository(db),
              photoSeriesRepository: DriftPhotoSeriesRepository(db),
              settingsRepository: DriftSettingsRepository(db),
            ),
            push: (_, _) async {},
          ),
        ),
      ],
    );
    controller();
    await pumpEventQueue();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  // BUG-252: two devices pressing Start before either heard of the other's
  // session each made one, and logged sets only into their own.
  group('starting the same day on two devices', () {
    test("the day's first workout has ids every device derives", () async {
      await _seed(repo);
      final date = DateTime.now();
      await controller().startFromPlan(plan: _plan, dayIndex: 1, date: date);

      final session = state().session!;
      expect(session.id, workoutDaySessionId('plan', 1, date));
      final logs = await repo.listSetLogs(sessionId: session.id);
      expect(logs.map((l) => l.id).toSet(), {
        for (final (order, sets) in [(0, 3), (1, 3)])
          for (var set = 0; set < sets; set++) '${session.id}_${order}_$set',
      });
      // The controller's re-read of the active session, before teardown.
      await pumpEventQueue();
    });

    test(
      'one already arrived under that id is joined, not rewritten',
      () async {
        await _seed(repo);
        final date = DateTime.now();
        final id = workoutDaySessionId('plan', 1, date);
        await repo.createSessionWithLogs(
          _session(id, date: date, ended: false).copyWith(planId: 'plan'),
          [_log('${id}_0_0', id)],
        );

        await controller().startFromPlan(plan: _plan, dayIndex: 1, date: date);

        expect(state().session!.id, id);
        expect(await repo.listSetLogs(sessionId: id), hasLength(1));
        // The controller's re-read of the active session, before teardown.
        await pumpEventQueue();
      },
    );

    test('a second workout that day is a session of its own', () async {
      await _seed(repo);
      final date = DateTime.now();
      await controller().startFromPlan(plan: _plan, dayIndex: 1, date: date);
      final first = state().session!.id;
      await controller().finish();

      await controller().startFromPlan(plan: _plan, dayIndex: 1, date: date);

      expect(state().session!.id, isNot(first));
      expect((await repo.getSession(first))!.endedAt, isNotNull);
      // The controller's re-read of the active session, before teardown.
      await pumpEventQueue();
    });
  });

  group('changing the live session', () {
    test(
      'an added exercise goes last, with its target sets, and is focused',
      () async {
        await _seed(repo);
        await start();

        await controller().addExercise((await repo.getExercise('row'))!);

        expect(state().sessionExercises.map((p) => p.exercise.id), [
          'bench',
          'squat',
          'row',
        ]);
        expect(state().currentSet!.exerciseId, 'row');
        final stored = await repo.listSetLogs(sessionId: state().session!.id);
        expect(stored.where((l) => l.exerciseId == 'row'), hasLength(2));
        expect(
          await repo.listPlanEntries('plan'),
          hasLength(2),
          reason: 'the plan is untouched',
        );
      },
    );

    test('skipping keeps logged sets and tombstones the rest', () async {
      await _seed(repo);
      await start();
      await controller().completeCurrentSet();
      sync.setLogs.clear();

      await controller().skipExercise(0);

      final bench = state().logs.where((l) => l.exerciseId == 'bench');
      expect(bench, hasLength(1));
      expect(bench.single.completed, isTrue);
      expect(sync.setLogs, hasLength(2));
      expect(sync.setLogs.every((l) => l.deletedAt != null), isTrue);
      expect(state().currentSet!.exerciseId, 'squat');
    });

    test('reordering renumbers the placements and stays on the set', () async {
      await _seed(repo);
      await start();
      final current = state().currentSet!;

      await controller().moveExercise(0, 1);

      expect(state().sessionExercises.map((p) => (p.order, p.exercise.id)), [
        (0, 'squat'),
        (1, 'bench'),
      ]);
      expect(state().currentSet!.id, current.id);
      final stored = await repo.listSetLogs(sessionId: state().session!.id);
      expect(stored.first.exerciseId, 'squat');
    });

    test('reordering keeps a placement the strip leaves out apart', () async {
      await _seed(repo);
      await start();
      await controller().addExercise((await repo.getExercise('row'))!);
      // Its row gone outright, so the strip can't show it.
      await (db.delete(
        db.exercisesTable,
      )..where((t) => t.id.equals('squat'))).go();
      container.invalidate(workoutSessionControllerProvider);
      controller();
      await pumpEventQueue();
      expect(state().sessionExercises.map((p) => p.exercise.id), [
        'bench',
        'row',
      ]);

      await controller().moveExercise(1, 0);

      final stored = await repo.listSetLogs(sessionId: state().session!.id);
      expect(
        {for (final l in stored) l.exerciseId: l.exerciseOrder},
        {'row': 0, 'squat': 1, 'bench': 2},
      );
    });

    test('a set added while a re-read is out stays in the live view', () async {
      await _seed(repo);
      await start();
      final held = repo.holdNextRead();
      container.invalidate(activeWorkoutSessionProvider);
      await held;

      await controller().addExercise((await repo.getExercise('row'))!);
      repo.release();
      await pumpEventQueue();

      expect(state().logs.where((l) => l.exerciseId == 'row'), hasLength(2));
      expect(state().currentSet!.exerciseId, 'row');
    });

    test('a set removed while a re-read is out stays removed', () async {
      await _seed(repo);
      await start();
      await controller().completeCurrentSet();
      final current = state().currentSet!;
      final held = repo.holdNextRead();
      container.invalidate(activeWorkoutSessionProvider);
      await held;

      await controller().skipExercise(1);
      repo.release();
      await pumpEventQueue();

      expect(state().logs.where((l) => l.exerciseId == 'squat'), isEmpty);
      expect(state().currentSet!.id, current.id);
    });

    test('a discarded workout is ended as well as deleted', () async {
      await _seed(repo);
      await start();
      final id = state().session!.id;

      await controller().discard();

      final stored = (await repo.getSession(id))!;
      expect(stored.deletedAt, isNotNull);
      expect(stored.endedAt, isNotNull);
    });
  });

  group('lastPerformedSets', () {
    test('comes from the latest finished session by calendar date', () {
      final sessions = [
        _session('old', date: DateTime(2026, 9, 1)),
        // Logged after the fact: started later, but for an earlier day.
        _session(
          'backfilled',
          date: DateTime(2026, 8, 20),
          startedAt: DateTime.utc(2026, 9, 10),
        ),
        _session('newest', date: DateTime(2026, 9, 5)),
        _session('live', date: DateTime(2026, 9, 12), ended: false),
      ];
      final logs = [
        _log('a', 'old', weightKg: 50),
        _log('b', 'backfilled', weightKg: 55),
        _log('c', 'newest', setIndex: 1, weightKg: 72.5),
        _log('d', 'newest', weightKg: 70),
        _log('e', 'newest', setIndex: 2, completed: false),
        _log('f', 'live', weightKg: 90),
      ];

      expect(
        lastPerformedSets(
          logs,
          sessions,
        ).map((placement) => [for (final l in placement) l.id]),
        [
          ['d', 'c'],
        ],
      );
    });

    test('keeps a movement placed twice as two placements', () {
      final sessions = [_session('s', date: DateTime(2026, 9, 1))];
      final logs = [
        _log('a', 's', weightKg: 60),
        _log('b', 's', setIndex: 1, weightKg: 60),
        _log('c', 's', order: 2, weightKg: 40),
      ];

      expect(
        lastPerformedSets(
          logs,
          sessions,
        ).map((placement) => [for (final l in placement) l.id]),
        [
          ['a', 'b'],
          ['c'],
        ],
      );
    });

    test('is empty for a movement never finished', () {
      expect(
        lastPerformedSets(
          [_log('a', 'live')],
          [_session('live', date: DateTime(2026, 9, 1), ended: false)],
        ),
        isEmpty,
      );
    });
  });

  group('deleting a finished session', () {
    test('goes to the trash with its sets and comes back with them', () async {
      final session = _session('s', date: DateTime(2026, 9, 1));
      await repo.createSessionWithLogs(session, [
        _log('a', 's'),
        _log('b', 's', setIndex: 1),
      ]);
      // Removed from the session earlier: not part of the delete.
      // Stamped outright: two deletes back to back can share a clock tick,
      // which would make this set look like part of the workout's delete.
      await repo.upsertSetLog(
        _log(
          'c',
          's',
          setIndex: 2,
        ).copyWith(deletedAt: DateTime.utc(2026, 9, 2)),
      );

      await deleteWorkoutSession(container, 's');

      final trash = await container.read(trashServiceProvider).list();
      expect(trash, hasLength(1));
      expect(trash.single.summary, '2 sets');

      await restoreWorkoutSession(container, 's');

      expect((await repo.getSession('s'))!.deletedAt, isNull);
      expect((await repo.listSetLogs(sessionId: 's')).map((l) => l.id), [
        'a',
        'b',
      ]);
      await expectLater(
        restoreWorkoutSession(container, 's'),
        throwsA(isA<RestoreSuperseded>()),
      );
    });
  });
}
