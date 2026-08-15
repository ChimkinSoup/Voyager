import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/workout_units.dart';

WorkoutPlan _plan({
  required WorkoutPlanMode mode,
  int cycleLength = 4,
  DateTime? anchor,
}) {
  final now = utcNow();
  return WorkoutPlan(
    id: 'plan',
    name: 'Plan',
    mode: mode,
    cycleLength: cycleLength,
    cycleAnchor: anchor ?? DateTime(2026, 1, 1),
    createdAt: now,
    updatedAt: now,
  );
}

WorkoutSetLog _log({
  required String sessionId,
  required String exerciseId,
  int exerciseOrder = 0,
  int setIndex = 0,
  double weightKg = 100,
  int reps = 8,
  double plannedWeightKg = 100,
  int plannedReps = 8,
  bool completed = true,
}) {
  final now = utcNow();
  return WorkoutSetLog(
    id: newId(),
    sessionId: sessionId,
    exerciseId: exerciseId,
    exerciseOrder: exerciseOrder,
    setIndex: setIndex,
    weightKg: weightKg,
    reps: reps,
    plannedWeightKg: plannedWeightKg,
    plannedReps: plannedReps,
    completed: completed,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('WorkoutPlan.dayIndexForDate', () {
    test('weekly plans map onto weekday, Sunday = 0', () {
      final plan = _plan(mode: WorkoutPlanMode.weekly);
      // 2026-08-09 is a Sunday.
      expect(plan.dayIndexForDate(DateTime(2026, 8, 9)), 0);
      expect(plan.dayIndexForDate(DateTime(2026, 8, 10)), 1);
      expect(plan.dayIndexForDate(DateTime(2026, 8, 15)), 6);
    });

    test('cycle plans wrap every cycleLength days from the anchor', () {
      final plan = _plan(
        mode: WorkoutPlanMode.cycle,
        cycleLength: 4,
        anchor: DateTime(2026, 8, 3),
      );
      expect(plan.dayIndexForDate(DateTime(2026, 8, 3)), 0);
      expect(plan.dayIndexForDate(DateTime(2026, 8, 5)), 2);
      expect(plan.dayIndexForDate(DateTime(2026, 8, 6)), 3);
      // Wraps back to Day 1 rather than drifting against the week.
      expect(plan.dayIndexForDate(DateTime(2026, 8, 7)), 0);
      expect(plan.dayIndexForDate(DateTime(2026, 8, 31)), 0);
    });

    test('cycle plans have no day before their anchor', () {
      final plan = _plan(
        mode: WorkoutPlanMode.cycle,
        anchor: DateTime(2026, 8, 3),
      );
      expect(plan.dayIndexForDate(DateTime(2026, 8, 2)), isNull);
    });

    test('a cycle spanning a DST boundary does not slip a day', () {
      // US DST ends 2026-11-01. A duration-based difference across it is 23 or
      // 25 hours, which truncates to the wrong whole-day count.
      final plan = _plan(
        mode: WorkoutPlanMode.cycle,
        cycleLength: 3,
        anchor: DateTime(2026, 10, 30),
      );
      expect(plan.dayIndexForDate(DateTime(2026, 10, 30)), 0);
      expect(plan.dayIndexForDate(DateTime(2026, 11, 1)), 2);
      expect(plan.dayIndexForDate(DateTime(2026, 11, 2)), 0);
    });

    test('dayCount follows the mode', () {
      expect(_plan(mode: WorkoutPlanMode.weekly).dayCount, 7);
      expect(_plan(mode: WorkoutPlanMode.cycle, cycleLength: 5).dayCount, 5);
    });
  });

  group('WorkoutSetLog', () {
    test('matching the plan is not a deviation', () {
      expect(_log(sessionId: 's', exerciseId: 'e').deviatesFromPlan, isFalse);
    });

    test('a heavier or lighter set deviates', () {
      expect(
        _log(sessionId: 's', exerciseId: 'e', weightKg: 105).deviatesFromPlan,
        isTrue,
      );
      expect(
        _log(sessionId: 's', exerciseId: 'e', reps: 6).deviatesFromPlan,
        isTrue,
      );
    });

    test('volume is weight times reps', () {
      expect(
        _log(sessionId: 's', exerciseId: 'e', weightKg: 60, reps: 5).volumeKg,
        300,
      );
    });
  });

  group('buildExerciseHistory', () {
    test('groups completed sets by session day, oldest first', () {
      final sessions = {
        'a': DateTime(2026, 8, 1),
        'b': DateTime(2026, 8, 5),
      };
      final logs = [
        _log(sessionId: 'b', exerciseId: 'e', weightKg: 105, setIndex: 0),
        _log(sessionId: 'a', exerciseId: 'e', weightKg: 100, setIndex: 0),
        _log(sessionId: 'a', exerciseId: 'e', weightKg: 100, setIndex: 1),
      ];

      final history = buildExerciseHistory(logs, sessions);

      expect(history.map((d) => d.date), [
        DateTime(2026, 8, 1),
        DateTime(2026, 8, 5),
      ]);
      expect(history.first.setWeightsKg, [100, 100]);
      expect(history.first.volumeKg, 1600);
      expect(history.last.setWeightsKg, [105]);
    });

    test('unfinished sets never count toward volume', () {
      final history = buildExerciseHistory(
        [
          _log(sessionId: 'a', exerciseId: 'e'),
          _log(sessionId: 'a', exerciseId: 'e', setIndex: 1, completed: false),
        ],
        {'a': DateTime(2026, 8, 1)},
      );
      expect(history.single.setWeightsKg, hasLength(1));
    });

    test('days the exercise was not trained are simply absent', () {
      // What makes the 30-square heatmap span "30 sessions", not 30 dates.
      final history = buildExerciseHistory(
        [
          _log(sessionId: 'a', exerciseId: 'e'),
          _log(sessionId: 'b', exerciseId: 'e'),
        ],
        {'a': DateTime(2026, 1, 1), 'b': DateTime(2026, 6, 1)},
      );
      expect(history, hasLength(2));
    });
  });

  group('weight units', () {
    test('kilograms round-trip through the pound wheel', () {
      const unit = WeightUnit.lb;
      final index = unit.wheelIndexForKilograms(poundsToKilograms(135));
      expect(unit.formatDisplay(index * unit.step), '135');
    });

    test('the wheel quantises to its own step', () {
      const unit = WeightUnit.lb;
      // 136 lb is not a wheel stop (2.5 lb steps); it snaps to the nearest.
      final index = unit.wheelIndexForKilograms(poundsToKilograms(136));
      expect(unit.formatDisplay(index * unit.step), '135');
    });

    test('formatting drops a trailing .0 but keeps a half step', () {
      const unit = WeightUnit.kg;
      expect(unit.formatDisplay(100), '100');
      expect(unit.formatDisplay(102.5), '102.5');
    });

    test('the unit label rides along with the value', () {
      expect(WeightUnit.kg.formatKilogramsWithUnit(100), '100 kg');
      expect(WeightUnit.lb.formatKilogramsWithUnit(poundsToKilograms(45)),
          '45 lb');
    });
  });

  group('workedOutTrackerValues', () {
    test('emits one true value per worked-out day and nothing else', () {
      final values = workedOutTrackerValues({
        DateTime(2026, 8, 1),
        DateTime(2026, 8, 3),
      });
      expect(values, hasLength(2));
      expect(values.every((v) => v.boolValue == true), isTrue);
      expect(values.every((v) => v.trackerId == kWorkedOutTrackerId), isTrue);
    });
  });

  group('DriftWorkoutRepository', () {
    late AppDatabase db;
    late DriftWorkoutRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftWorkoutRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('seeds both plans and the starter library, idempotently', () async {
      await repo.ensureSeeded();
      await repo.ensureSeeded();

      final plans = await repo.listPlans();
      expect(plans, hasLength(2));
      expect(
        plans.map((p) => p.mode).toSet(),
        {WorkoutPlanMode.weekly, WorkoutPlanMode.cycle},
      );
      expect(plans.where((p) => p.isActive), hasLength(1));
      expect(await repo.listExercises(), hasLength(kStarterExercises.length));
    });

    test('a cleared library is not re-seeded on the next launch', () async {
      await repo.ensureSeeded();
      for (final exercise in await repo.listExercises()) {
        await repo.softDeleteExercise(exercise.id);
      }

      await repo.ensureSeeded();

      expect(await repo.listExercises(), isEmpty);
    });

    test('setActivePlan leaves exactly one plan active', () async {
      await repo.ensureSeeded();
      await repo.setActivePlan(kCycleWorkoutPlanId);

      final plans = await repo.listPlans();
      expect(
        plans.where((p) => p.isActive).map((p) => p.id),
        [kCycleWorkoutPlanId],
      );
    });

    test('deleting an exercise takes its plan entries but not its history',
        () async {
      await repo.ensureSeeded();
      final exercise = (await repo.listExercises()).first;
      final now = utcNow();

      await repo.upsertPlanEntry(
        WorkoutPlanEntry(
          id: newId(),
          planId: kWeeklyWorkoutPlanId,
          dayIndex: 1,
          exerciseId: exercise.id,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repo.upsertSession(
        WorkoutSession(
          id: 'session',
          date: DateTime(2026, 8, 1),
          startedAt: now,
          endedAt: now,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repo.upsertSetLog(
        _log(sessionId: 'session', exerciseId: exercise.id),
      );

      await repo.softDeleteExercise(exercise.id);

      expect(await repo.listPlanEntries(kWeeklyWorkoutPlanId), isEmpty);
      expect(await repo.listSetLogs(exerciseId: exercise.id), hasLength(1));
    });

    test('getActiveSession returns only an unfinished session', () async {
      final now = utcNow();
      final session = WorkoutSession(
        id: 'live',
        date: DateTime(2026, 8, 1),
        startedAt: now,
        createdAt: now,
        updatedAt: now,
      );
      await repo.upsertSession(session);
      expect((await repo.getActiveSession())?.id, 'live');

      await repo.upsertSession(session.copyWith(endedAt: utcNow()));
      expect(await repo.getActiveSession(), isNull);
    });

    test('a movement carries its target, shared by every day it is on',
        () async {
      await repo.ensureSeeded();
      final exercise = (await repo.listExercises()).first;
      expect(exercise.targetSets, kDefaultTargetSets);
      expect(exercise.targetReps, kDefaultTargetReps);

      final now = utcNow();
      // The same lift on two different days of the plan.
      for (final dayIndex in [1, 4]) {
        await repo.upsertPlanEntry(
          WorkoutPlanEntry(
            id: newId(),
            planId: kWeeklyWorkoutPlanId,
            dayIndex: dayIndex,
            exerciseId: exercise.id,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }

      await repo.upsertExercise(
        exercise.copyWith(targetSets: 5, targetReps: 3, targetWeightKg: 60),
      );

      // One write, and both days now read 5 × 3 · 60 — there is no per-day
      // copy left that could disagree.
      final updated = (await repo.getExercise(exercise.id))!;
      expect(updated.targetSets, 5);
      expect(updated.targetReps, 3);
      expect(updated.targetWeightKg, 60);
      final entries = await repo.listPlanEntries(kWeeklyWorkoutPlanId);
      expect(entries.map((e) => e.dayIndex), unorderedEquals([1, 4]));
    });

    test('the v68 backfill carries per-day targets onto the movement',
        () async {
      // Rebuild the plan-entry table in its pre-v68 shape so the migration's
      // real statement runs against the columns it was written for.
      await db.customStatement('DROP TABLE workout_plan_entries_table');
      await db.customStatement('''
        CREATE TABLE workout_plan_entries_table (
          id TEXT NOT NULL PRIMARY KEY,
          plan_id TEXT NOT NULL,
          day_index INTEGER NOT NULL,
          exercise_id TEXT NOT NULL,
          sets INTEGER NOT NULL DEFAULT 3,
          reps INTEGER NOT NULL DEFAULT 8,
          weight_kg REAL NOT NULL DEFAULT 0,
          sort_order INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          version INTEGER NOT NULL DEFAULT 0,
          deleted_at TEXT
        )
      ''');

      final now = utcNow();
      await repo.upsertExercise(
        Exercise(
          id: 'squat',
          name: 'Back Squat',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repo.upsertExercise(
        Exercise(id: 'curl', name: 'Curl', createdAt: now, updatedAt: now),
      );

      Future<void> legacyEntry({
        required String id,
        required String exerciseId,
        required int sets,
        required int reps,
        required double weightKg,
        required String updatedAt,
        String? deletedAt,
      }) {
        return db.customStatement(
          'INSERT INTO workout_plan_entries_table (id, plan_id, day_index, '
          'exercise_id, sets, reps, weight_kg, sort_order, created_at, '
          "updated_at, version, deleted_at) VALUES (?, 'p', 0, ?, ?, ?, ?, 0, "
          '?, ?, 0, ?)',
          [
            id,
            exerciseId,
            sets,
            reps,
            weightKg,
            updatedAt,
            updatedAt,
            deletedAt,
          ],
        );
      }

      await legacyEntry(
        id: 'old',
        exerciseId: 'squat',
        sets: 3,
        reps: 10,
        weightKg: 80,
        updatedAt: '2026-08-01T00:00:00.000Z',
      );
      // Newer placement of the same lift wins the collapse to one number.
      await legacyEntry(
        id: 'new',
        exerciseId: 'squat',
        sets: 5,
        reps: 5,
        weightKg: 100,
        updatedAt: '2026-08-05T00:00:00.000Z',
      );
      // A tombstoned placement must not out-vote a live one just by being
      // newer — it is no longer part of the plan.
      await legacyEntry(
        id: 'dead',
        exerciseId: 'squat',
        sets: 1,
        reps: 1,
        weightKg: 5,
        updatedAt: '2026-08-09T00:00:00.000Z',
        deletedAt: '2026-08-09T00:00:00.000Z',
      );

      await db.customStatement(kWorkoutTargetBackfillSql);

      final squat = (await repo.getExercise('squat'))!;
      expect(squat.targetSets, 5);
      expect(squat.targetReps, 5);
      expect(squat.targetWeightKg, 100);

      // A movement that was never placed keeps its defaults rather than
      // collapsing to zero.
      final curl = (await repo.getExercise('curl'))!;
      expect(curl.targetSets, kDefaultTargetSets);
      expect(curl.targetReps, kDefaultTargetReps);
      expect(curl.targetWeightKg, 0);
    });

    test('set logs come back ordered by exercise then set', () async {
      final logs = [
        _log(sessionId: 's', exerciseId: 'b', exerciseOrder: 1, setIndex: 0),
        _log(sessionId: 's', exerciseId: 'a', exerciseOrder: 0, setIndex: 1),
        _log(sessionId: 's', exerciseId: 'a', exerciseOrder: 0, setIndex: 0),
      ];
      await repo.upsertSetLogsBatch(logs);

      final stored = await repo.listSetLogs(sessionId: 's');
      expect(
        stored.map((l) => '${l.exerciseId}${l.setIndex}'),
        ['a0', 'a1', 'b0'],
      );
    });
  });
}
