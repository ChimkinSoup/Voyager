import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/workout_models.dart';

/// Save/delete helpers shared by the planner, the exercise panel and the
/// detail view. Each one does the same three things in the same order — write
/// locally, push to Firestore, invalidate the read providers — so no call site
/// can forget the third and leave the UI showing stale numbers.
class WorkoutActions {
  const WorkoutActions(this._ref);

  final WidgetRef _ref;

  Future<void> saveExercise(Exercise exercise) async {
    await _ref.read(workoutRepositoryProvider).upsertExercise(exercise);
    _ref.read(remoteSyncServiceProvider).pushExercise(exercise);
    invalidateWorkoutProvidersFrom(_ref);
  }

  /// Writes a movement's target. One row changes, and every day of every plan
  /// that references it follows — that is the whole point of the target living
  /// on the exercise.
  Future<void> saveExerciseTarget(
    Exercise exercise, {
    required int sets,
    required int reps,
    required double weightKg,
  }) {
    return saveExercise(
      exercise.copyWith(
        targetSets: sets,
        targetReps: reps,
        targetWeightKg: weightKg,
      ),
    );
  }

  /// Saves an explicit set recipe (varying sets and/or drops) on the movement.
  /// Like the target above, it applies everywhere the movement is planned.
  Future<void> saveExercisePrescription(
    Exercise exercise, {
    required List<SetPrescription> prescriptions,
  }) {
    return saveExercise(
      exercise.copyWith(
        prescriptionMode: WorkoutPrescriptionMode.custom,
        setPrescriptions: prescriptions,
      ),
    );
  }

  /// Drops the explicit recipe so the movement falls back to its uniform
  /// sets × reps × weight target.
  Future<void> clearExercisePrescription(Exercise exercise) {
    return saveExercise(
      exercise.copyWith(
        prescriptionMode: WorkoutPrescriptionMode.inherit,
        setPrescriptions: const [],
      ),
    );
  }

  Future<Exercise> createExercise(String name, {int sortOrder = 0}) async {
    final now = utcNow();
    final exercise = Exercise(
      id: newId(),
      name: name.trim(),
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
    );
    await saveExercise(exercise);
    return exercise;
  }

  Future<void> savePlan(WorkoutPlan plan) async {
    await _ref.read(workoutRepositoryProvider).upsertPlan(plan);
    _ref.read(remoteSyncServiceProvider).pushWorkoutPlan(plan);
    invalidateWorkoutProvidersFrom(_ref);
  }

  Future<void> setActivePlan(String planId) async {
    final repo = _ref.read(workoutRepositoryProvider);
    await repo.setActivePlan(planId);
    final sync = _ref.read(remoteSyncServiceProvider);
    for (final plan in await repo.listPlans()) {
      sync.pushWorkoutPlan(plan);
    }
    invalidateWorkoutProvidersFrom(_ref);
  }

  Future<void> savePlanEntry(WorkoutPlanEntry entry) async {
    await _ref.read(workoutRepositoryProvider).upsertPlanEntry(entry);
    _ref.read(remoteSyncServiceProvider).pushWorkoutPlanEntry(entry);
    invalidateWorkoutProvidersFrom(_ref);
  }

  /// Places [exerciseId] on [dayIndex] of [planId], appended after whatever is
  /// already there.
  Future<void> addExerciseToDay({
    required String planId,
    required int dayIndex,
    required String exerciseId,
    required List<WorkoutPlanEntry> existing,
  }) async {
    final onDay = existing.where((e) => e.dayIndex == dayIndex);
    final nextOrder = onDay.isEmpty
        ? 0
        : onDay.map((e) => e.sortOrder).reduce((a, b) => a > b ? a : b) + 1;
    final now = utcNow();
    await savePlanEntry(
      WorkoutPlanEntry(
        id: newId(),
        planId: planId,
        dayIndex: dayIndex,
        exerciseId: exerciseId,
        sortOrder: nextOrder,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Moves an already-placed entry to another day. Dropping it back on the day
  /// it came from is a no-op.
  Future<void> movePlanEntry({
    required WorkoutPlanEntry entry,
    required int dayIndex,
    required List<WorkoutPlanEntry> existing,
  }) async {
    if (entry.dayIndex == dayIndex) return;
    final onDay = existing.where(
      (e) => e.dayIndex == dayIndex && e.id != entry.id,
    );
    final nextOrder = onDay.isEmpty
        ? 0
        : onDay.map((e) => e.sortOrder).reduce((a, b) => a > b ? a : b) + 1;
    await savePlanEntry(
      entry.copyWith(dayIndex: dayIndex, sortOrder: nextOrder),
    );
  }

  Future<void> deletePlanEntry(String id) async {
    final repo = _ref.read(workoutRepositoryProvider);
    await repo.softDeletePlanEntry(id);
    final deleted = await repo.getPlanEntry(id);
    if (deleted != null) {
      _ref.read(remoteSyncServiceProvider).pushWorkoutPlanEntry(deleted);
    }
    invalidateWorkoutProvidersFrom(_ref);
  }
}

/// An exercise and the plan entries that were tombstoned with it, as they
/// stood the instant before a delete — everything [restoreExercise] needs.
class ExerciseDeletion {
  const ExerciseDeletion({required this.exercise, required this.planEntries});

  final Exercise exercise;

  /// Deleting a movement pulls it out of every planned day, so the undo has to
  /// put those rows back too — otherwise the exercise returns to the library
  /// having quietly vanished from the plan it was in.
  final List<WorkoutPlanEntry> planEntries;
}

/// Soft-deletes an exercise and returns what it takes to put it back.
///
/// Takes a [ProviderContainer] rather than a `WidgetRef` because the undo the
/// toast offers is pressed seconds after the card that asked for the delete has
/// unmounted, and a `WidgetRef` throws once its widget is gone.
Future<ExerciseDeletion> softDeleteExercise(
  ProviderContainer container,
  String id,
) async {
  final repo = container.read(workoutRepositoryProvider);
  // Snapshotted before the delete: `softDeleteExercise` cascades into the plan
  // entries, and once it has run there is no way to tell which of them it took
  // from the ones that were already gone.
  final exercise = await repo.getExercise(id);
  final planEntries = [
    for (final entry in await repo.getAllPlanEntries())
      if (entry.exerciseId == id && entry.deletedAt == null) entry,
  ];

  await repo.softDeleteExercise(id);
  // Re-read rather than constructing the tombstone here: softDeleteExercise
  // also tombstones the plan entries that referenced it, and both halves
  // have to reach the other device or it keeps rendering orphan cards.
  final deleted = await repo.getExercise(id);
  final sync = container.read(remoteSyncServiceProvider);
  if (deleted != null) sync.pushExercise(deleted);
  for (final entry in await repo.getAllPlanEntries()) {
    if (entry.exerciseId == id && entry.deletedAt != null) {
      sync.pushWorkoutPlanEntry(entry);
    }
  }
  invalidateWorkoutProvidersIn(container);

  return ExerciseDeletion(
    exercise: exercise ?? _missingExercise(id),
    planEntries: planEntries,
  );
}

/// Undoes [softDeleteExercise].
///
/// Both halves are rebuilt field by field rather than `copyWith`'d, because
/// `copyWith` reads `deletedAt ?? this.deletedAt` and so cannot clear a
/// tombstone.
Future<void> restoreExercise(
  ProviderContainer container,
  ExerciseDeletion deletion,
) async {
  final repo = container.read(workoutRepositoryProvider);
  final sync = container.read(remoteSyncServiceProvider);
  final exercise = deletion.exercise;

  // The versions below are resolved against disk rather than against the
  // snapshot — see [restoreVersionFrom].
  final currentExercise = await repo.getExercise(exercise.id);
  abortIfAlreadyRestored(
    found: currentExercise != null,
    deletedAt: currentExercise?.deletedAt,
  );
  final restored = Exercise(
    id: exercise.id,
    createdAt: exercise.createdAt,
    updatedAt: utcNow(),
    version: restoreVersionFrom(
      preDeleteVersion: exercise.version,
      currentVersion: currentExercise?.version,
    ),
    name: exercise.name,
    formCues: exercise.formCues,
    colorValue: exercise.colorValue,
    sortOrder: exercise.sortOrder,
    targetSets: exercise.targetSets,
    targetReps: exercise.targetReps,
    targetWeightKg: exercise.targetWeightKg,
    prescriptionMode: exercise.prescriptionMode,
    setPrescriptions: exercise.setPrescriptions,
  );
  await repo.upsertExercise(restored);
  sync.pushExercise(restored);

  for (final entry in deletion.planEntries) {
    // Not aborted on individually: the exercise is what the undo is for, and a
    // plan entry a pull happened to bring back on its own is put back to the
    // same state anyway.
    final current = await repo.getPlanEntry(entry.id);
    final row = WorkoutPlanEntry(
      id: entry.id,
      createdAt: entry.createdAt,
      updatedAt: utcNow(),
      version: restoreVersionFrom(
        preDeleteVersion: entry.version,
        currentVersion: current?.version,
      ),
      planId: entry.planId,
      dayIndex: entry.dayIndex,
      exerciseId: entry.exerciseId,
      sortOrder: entry.sortOrder,
    );
    await repo.upsertPlanEntry(row);
    sync.pushWorkoutPlanEntry(row);
  }
  invalidateWorkoutProvidersIn(container);
}

/// Stand-in for an exercise that was already gone by the time the delete ran.
/// Restoring it is a no-op in practice — there is nothing on screen to undo —
/// but it keeps [ExerciseDeletion.exercise] non-nullable for every caller.
Exercise _missingExercise(String id) {
  final now = utcNow();
  return Exercise(id: id, createdAt: now, updatedAt: now, name: '');
}
