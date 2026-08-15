import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
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

  Future<void> deleteExercise(String id) async {
    final repo = _ref.read(workoutRepositoryProvider);
    await repo.softDeleteExercise(id);
    // Re-read rather than constructing the tombstone here: softDeleteExercise
    // also tombstones the plan entries that referenced it, and both halves
    // have to reach the other device or it keeps rendering orphan cards.
    final deleted = await repo.getExercise(id);
    final sync = _ref.read(remoteSyncServiceProvider);
    if (deleted != null) sync.pushExercise(deleted);
    for (final entry in await repo.getAllPlanEntries()) {
      if (entry.exerciseId == id && entry.deletedAt != null) {
        sync.pushWorkoutPlanEntry(entry);
      }
    }
    invalidateWorkoutProvidersFrom(_ref);
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
    await savePlanEntry(entry.copyWith(dayIndex: dayIndex, sortOrder: nextOrder));
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
