import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/workout/workout_session_controller.dart';
import 'package:voyager/features/workout/workout_units.dart';

/// Regression tests for the workout audit (AUDIT.md).

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

Future<void> _seed(
  DriftWorkoutRepository repo, {
  List<String> day = const ['bench', 'squat'],
  int sets = 3,
}) async {
  final now = utcNow();
  await repo.upsertPlan(_plan);
  for (final id in {...day}) {
    await repo.upsertExercise(
      Exercise(
        id: id,
        name: id,
        targetSets: sets,
        targetReps: 8,
        targetWeightKg: 60,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
  for (var i = 0; i < day.length; i++) {
    await repo.upsertPlanEntry(
      WorkoutPlanEntry(
        id: 'entry$i',
        planId: 'plan',
        dayIndex: 1,
        exerciseId: day[i],
        sortOrder: i,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
}

void main() {
  late AppDatabase db;
  late DriftWorkoutRepository repo;
  late _RecordingSync sync;
  late ProviderContainer container;

  WorkoutSessionController controller() =>
      container.read(workoutSessionControllerProvider.notifier);
  ActiveWorkoutState state() =>
      container.read(workoutSessionControllerProvider);

  Future<void> start() async {
    await controller().startFromPlan(
      plan: _plan,
      dayIndex: 1,
      date: DateTime.now(),
    );
  }

  setUp(() async {
    db = AppDatabase.inMemory();
    repo = DriftWorkoutRepository(db);
    sync = _RecordingSync();
    container = ProviderContainer(
      overrides: [
        workoutRepositoryProvider.overrideWithValue(repo),
        remoteSyncServiceProvider.overrideWithValue(sync),
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
      ],
    );
    // Instantiates the controller, whose first read of the active session
    // has to settle before a test starts pressing things.
    controller();
    await pumpEventQueue();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('starting', () {
    test('a double press opens one session', () async {
      await _seed(repo);
      await Future.wait([start(), start()]);

      expect(await repo.listSessions(), hasLength(1));
      expect(state().isLive, isTrue);
    });

    test('an open session on disk is resumed, not joined by a rival', () async {
      await _seed(repo);
      await start();
      final first = state().session!;

      // A fresh controller that has not yet restored the session.
      container.invalidate(workoutSessionControllerProvider);
      await start();

      expect(await repo.listSessions(), hasLength(1));
      expect(state().session!.id, first.id);
    });

    test('a zero-rep target is started as one rep', () async {
      await _seed(repo);
      final bench = (await repo.getExercise('bench'))!;
      await repo.upsertExercise(bench.copyWith(targetReps: 0));
      await start();

      expect(
        state().logs.where((l) => l.exerciseId == 'bench'),
        everyElement(
          isA<WorkoutSetLog>()
              .having((l) => l.reps, 'reps', 1)
              .having((l) => l.plannedReps, 'plannedReps', 1),
        ),
      );
    });

    test('the session date is stored as a zone-free calendar date', () async {
      await _seed(repo);
      await controller().startFromPlan(
        plan: _plan,
        dayIndex: 1,
        date: DateTime(2026, 9, 23, 22, 30),
      );
      final session = state().session!;
      expect(session.date, DateTime.utc(2026, 9, 23));
      expect(workoutCalendarDate(session.date), DateTime(2026, 9, 23));
    });
  });

  group('sync reaching the live view', () {
    test('a workout discarded elsewhere leaves the live view', () async {
      await _seed(repo);
      await start();
      final id = state().session!.id;

      // Another device's tombstone lands through a pull, which invalidates
      // the workout providers.
      await repo.softDeleteSession(id);
      container.invalidate(activeWorkoutSessionProvider);
      await pumpEventQueue();

      expect(state().isLive, isFalse);
      final stored = (await repo.getSession(id))!;
      expect(stored.deletedAt, isNotNull);
      expect(stored.endedAt, isNull);
    });

    test(
      'finishing a workout discarded elsewhere keeps it discarded',
      () async {
        await _seed(repo);
        await start();
        final id = state().session!.id;

        // The tombstone arrives, but the view has not been told yet.
        await repo.softDeleteSession(id);
        await controller().finish();

        final stored = (await repo.getSession(id))!;
        expect(stored.deletedAt, isNotNull);
        expect(stored.endedAt, isNull);
        expect(
          sync.sessions.where((s) => s.id == id && s.endedAt != null),
          isEmpty,
        );
      },
    );

    test('a session started on another device appears here', () async {
      await _seed(repo);
      final now = utcNow();
      await repo.upsertSession(
        WorkoutSession(
          id: 'remote',
          date: workoutStoredDate(now),
          startedAt: now,
          createdAt: now,
          updatedAt: now,
        ),
      );
      container.invalidate(activeWorkoutSessionProvider);
      await pumpEventQueue();

      expect(state().session?.id, 'remote');
      expect(state().expanded, isFalse);
    });
  });

  group('soft deletes', () {
    test('every workout soft delete bumps the version', () async {
      await _seed(repo);
      await start();
      final session = state().session!;
      final log = state().logs.first;

      await repo.softDeleteSetLog(log.id);
      expect((await repo.getSetLog(log.id))!.version, log.version + 1);

      await repo.softDeleteSession(session.id);
      expect((await repo.getSession(session.id))!.version, session.version + 1);

      final entry = (await repo.getPlanEntry('entry1'))!;
      await repo.softDeletePlanEntry(entry.id);
      expect((await repo.getPlanEntry(entry.id))!.version, entry.version + 1);

      final squat = (await repo.getExercise('squat'))!;
      await repo.softDeleteExercise(squat.id);
      expect((await repo.getExercise(squat.id))!.version, squat.version + 1);
    });

    test('removing sets mid-workout uploads their tombstones', () async {
      await _seed(repo, day: const ['bench']);
      await start();
      sync.setLogs.clear();

      await controller().setCurrentExerciseSetCount(1);

      expect(sync.setLogs, hasLength(2));
      expect(sync.setLogs.every((l) => l.deletedAt != null), isTrue);
    });

    test('discarding uploads every set tombstone', () async {
      await _seed(repo);
      await start();
      final count = state().logs.length;
      sync.setLogs.clear();

      await controller().discard();

      expect(sync.setLogs, hasLength(count));
      expect(sync.setLogs.every((l) => l.deletedAt != null), isTrue);
    });
  });

  group('the live view', () {
    test(
      'an exercise deleted mid-workout still resolves after a restart',
      () async {
        await _seed(repo);
        await start();
        await repo.softDeleteExercise('bench');

        container.invalidate(workoutSessionControllerProvider);
        controller();
        await pumpEventQueue();

        expect(state().isLive, isTrue);
        expect(state().currentExercise?.id, 'bench');
      },
    );

    test('a wheel flick writes once, with one version bump', () async {
      await _seed(repo, day: const ['bench']);
      await start();
      final set = state().currentSet!;
      sync.setLogs.clear();

      for (var i = 1; i <= 80; i++) {
        controller().updateCurrentSet(weightKg: 60 + i * 1.25);
      }
      expect((await repo.getSetLog(set.id))!.weightKg, 60);
      expect(sync.setLogs, isEmpty);

      await controller().completeCurrentSet();

      final stored = (await repo.getSetLog(set.id))!;
      expect(stored.weightKg, 160);
      expect(stored.completed, isTrue);
      // One bump for the debounced edits, one for completing.
      expect(stored.version, set.version + 2);
      expect(sync.setLogs, hasLength(2));
    });

    test('the same lift planned twice stays two groups', () async {
      await _seed(repo, day: const ['bench', 'bench'], sets: 2);
      await start();

      expect(state().currentExerciseSets, hasLength(2));
      expect(state().sessionExercises.map((p) => (p.order, p.exercise.id)), [
        (0, 'bench'),
        (1, 'bench'),
      ]);

      await controller().setCurrentExerciseSetCount(3);
      final group = state().currentExerciseSets;
      expect(group.map((l) => l.setIndex), [0, 1, 2]);
      expect(group.every((l) => l.exerciseOrder == 0), isTrue);
      expect(state().logs.where((l) => l.exerciseOrder == 1), hasLength(2));
    });

    test('growing after a kept trailing set does not reuse an index', () async {
      await _seed(repo, day: const ['bench']);
      await start();
      final last = state().logs.last;
      controller().focusSet(last.id);
      await controller().completeCurrentSet();

      // Only the middle set can go; the completed third one is kept.
      await controller().setCurrentExerciseSetCount(1);
      expect(state().logs.map((l) => l.setIndex), [0, 2]);

      await controller().setCurrentExerciseSetCount(3);
      expect(state().logs.map((l) => l.setIndex), [0, 2, 3]);
    });

    test('shrinking keeps the wheels on the current exercise', () async {
      await _seed(repo);
      await start();
      // Skip bench entirely and go to squat.
      final squat = state().logs.firstWhere((l) => l.exerciseId == 'squat');
      controller().focusSet(squat.id);

      await controller().setCurrentExerciseSetCount(2);

      expect(state().currentSet!.exerciseId, 'squat');
    });

    test('finish runs once however often it is pressed', () async {
      await _seed(repo);
      await start();
      final session = state().session!;
      await controller().completeCurrentSet();

      await Future.wait([controller().finish(), controller().finish()]);

      final stored = (await repo.getSession(session.id))!;
      expect(stored.endedAt, isNotNull);
      expect(stored.version, session.version + 1);
      expect(sync.sessions.where((s) => s.endedAt != null), hasLength(1));
    });
  });

  group('providers', () {
    test(
      'a finished session with no completed set is not a workout day',
      () async {
        await _seed(repo);
        await start();
        await controller().finish();
        expect(await container.read(workoutDaysProvider.future), isEmpty);

        await start();
        await controller().completeCurrentSet();
        await controller().finish();
        container.invalidate(workoutDaysProvider);
        final today = DateTime.now();
        expect(await container.read(workoutDaysProvider.future), {
          DateTime(today.year, today.month, today.day),
        });
      },
    );

    test('with two plans active, the most recently changed one wins', () async {
      // The seeded weekly plan is active and comes first in row order.
      await repo.ensureSeeded();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final newer = WorkoutPlan(
        id: 'other',
        name: 'Other',
        mode: WorkoutPlanMode.cycle,
        cycleAnchor: DateTime.utc(2026, 1, 1),
        isActive: true,
        createdAt: utcNow(),
        updatedAt: utcNow(),
      );
      await repo.upsertPlan(newer);

      await container.read(workoutPlansProvider.future);
      expect(container.read(activeWorkoutPlanProvider)?.id, 'other');
    });
  });

  group('models', () {
    test('reps of 0 are read as 1', () {
      expect(SetSegment.fromJson({'weightKg': 50, 'reps': 0}).reps, 1);
      expect(SetSegment.fromJson({'weightKg': 50}).reps, 1);
      expect(SetPrescription.fromJson(const {'segments': []}).top.reps, 1);
    });

    test('a weight planned in kg does not deviate on the lb wheel', () {
      final now = utcNow();
      final log = WorkoutSetLog(
        id: 'x',
        sessionId: 's',
        exerciseId: 'e',
        exerciseOrder: 0,
        setIndex: 0,
        // 132.5 lb, the lb wheel stop nearest 60 kg.
        weightKg: WeightUnit.lb.kilogramsForWheelIndex(53),
        reps: 8,
        plannedWeightKg: 60,
        plannedReps: 8,
        createdAt: now,
        updatedAt: now,
      );
      expect(log.deviatesFromPlanIn(WeightUnit.lb), isFalse);
      expect(log.deviatesFromPlanIn(WeightUnit.kg), isFalse);
      expect(
        log
            .copyWith(weightKg: WeightUnit.lb.kilogramsForWheelIndex(54))
            .deviatesFromPlanIn(WeightUnit.lb),
        isTrue,
      );
    });

    test('stored dates resolve to their calendar day in any zone', () {
      // Written by this build.
      expect(
        workoutCalendarDate(DateTime.utc(2026, 9, 23)),
        DateTime(2026, 9, 23),
      );
      // Local midnight as written by older builds, in UTC+9 and UTC−7.
      expect(
        workoutCalendarDate(DateTime.utc(2026, 9, 22, 15)),
        DateTime(2026, 9, 23),
      );
      expect(
        workoutCalendarDate(DateTime.utc(2026, 9, 23, 7)),
        DateTime(2026, 9, 23),
      );
    });

    test('a day of two sessions plots sets in the order they were lifted', () {
      final now = utcNow();
      WorkoutSetLog set(String session, int index, double kg, int minute) =>
          WorkoutSetLog(
            id: '$session$index',
            sessionId: session,
            exerciseId: 'e',
            exerciseOrder: 0,
            setIndex: index,
            weightKg: kg,
            reps: 5,
            plannedWeightKg: kg,
            plannedReps: 5,
            completed: true,
            completedAt: DateTime.utc(2026, 9, 23, 10, minute),
            createdAt: now,
            updatedAt: now,
          );
      final history = buildExerciseHistory(
        [set('a', 0, 100, 0), set('a', 1, 110, 5), set('b', 0, 50, 30)],
        {'a': DateTime.utc(2026, 9, 23), 'b': DateTime.utc(2026, 9, 23)},
      );
      expect(history.single.setWeightsKg, [100, 110, 50]);
    });
  });
}
