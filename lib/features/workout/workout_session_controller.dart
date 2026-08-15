import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Everything the island and the expanded active view render from.
@immutable
class ActiveWorkoutState {
  const ActiveWorkoutState({
    this.session,
    this.logs = const [],
    this.exercisesById = const {},
    this.cursor = 0,
    this.restEndsAt,
    this.restTotalSeconds = 0,
    this.expanded = false,
  });

  final WorkoutSession? session;

  /// Every set of the session, ordered by exercise then set index.
  final List<WorkoutSetLog> logs;
  final Map<String, Exercise> exercisesById;

  /// Index into [logs] of the set the wheels are currently dialling.
  final int cursor;

  /// Wall-clock end of the running rest countdown, or null when not resting.
  /// Stored as an instant rather than a remaining duration so the countdown
  /// stays correct across a rebuild, a page change, or the app being
  /// backgrounded.
  final DateTime? restEndsAt;
  final int restTotalSeconds;

  /// False while the workout is minimised to the floating island.
  final bool expanded;

  bool get isLive => session != null;

  WorkoutSetLog? get currentSet =>
      cursor >= 0 && cursor < logs.length ? logs[cursor] : null;

  Exercise? get currentExercise {
    final set = currentSet;
    return set == null ? null : exercisesById[set.exerciseId];
  }

  /// Every set belonging to the current set's exercise, in order.
  List<WorkoutSetLog> get currentExerciseSets {
    final set = currentSet;
    if (set == null) return const [];
    return [for (final l in logs) if (l.exerciseId == set.exerciseId) l];
  }

  /// Distinct exercises in this session, in the order they were planned.
  List<Exercise> get sessionExercises {
    final seen = <String>{};
    final result = <Exercise>[];
    for (final log in logs) {
      if (!seen.add(log.exerciseId)) continue;
      final exercise = exercisesById[log.exerciseId];
      if (exercise != null) result.add(exercise);
    }
    return result;
  }

  int get completedCount => logs.where((l) => l.completed).length;

  bool get isResting =>
      restEndsAt != null && restEndsAt!.isAfter(DateTime.now());

  ActiveWorkoutState copyWith({
    WorkoutSession? session,
    bool clearSession = false,
    List<WorkoutSetLog>? logs,
    Map<String, Exercise>? exercisesById,
    int? cursor,
    DateTime? restEndsAt,
    bool clearRest = false,
    int? restTotalSeconds,
    bool? expanded,
  }) {
    return ActiveWorkoutState(
      session: clearSession ? null : (session ?? this.session),
      logs: logs ?? this.logs,
      exercisesById: exercisesById ?? this.exercisesById,
      cursor: cursor ?? this.cursor,
      restEndsAt: clearRest ? null : (restEndsAt ?? this.restEndsAt),
      restTotalSeconds: clearRest ? 0 : (restTotalSeconds ?? this.restTotalSeconds),
      expanded: expanded ?? this.expanded,
    );
  }
}

/// Owns the live workout: which set the wheels are on, what has been logged,
/// and the rest countdown.
///
/// Every mutation writes through to the database immediately rather than
/// batching at the end. A workout is a long-lived, interruptible thing — the
/// user will navigate away mid-session, and may well close the app — so the
/// only safe place for "I hit that set" to live is the row.
class WorkoutSessionController extends StateNotifier<ActiveWorkoutState> {
  WorkoutSessionController(this._ref) : super(const ActiveWorkoutState()) {
    unawaited(_restoreActiveSession());
  }

  final Ref _ref;
  Timer? _restTimer;

  WorkoutRepository get _repo => _ref.read(workoutRepositoryProvider);

  /// Picks up a session left open by a previous launch, so a crash or a quit
  /// mid-workout doesn't silently lose the sets already logged.
  Future<void> _restoreActiveSession() async {
    final session = await _repo.getActiveSession();
    if (session == null || !mounted) return;
    await _loadSession(session, expanded: false);
  }

  Future<void> _loadSession(
    WorkoutSession session, {
    required bool expanded,
  }) async {
    final logs = await _repo.listSetLogs(sessionId: session.id);
    final exercises = await _repo.listExercises();
    if (!mounted) return;
    state = ActiveWorkoutState(
      session: session,
      logs: logs,
      exercisesById: {for (final e in exercises) e.id: e},
      cursor: _firstIncompleteIndex(logs),
      expanded: expanded,
    );
  }

  static int _firstIncompleteIndex(List<WorkoutSetLog> logs) {
    final index = logs.indexWhere((l) => !l.completed);
    return index == -1 ? (logs.isEmpty ? 0 : logs.length - 1) : index;
  }

  /// Starts a workout from one day of a plan, materialising a set log per
  /// planned set so the wheels have planned numbers to default to.
  ///
  /// Returns false when the day has nothing planned — there is no such thing
  /// as an empty workout, and starting one would strand the island with
  /// nothing to show.
  Future<bool> startFromPlan({
    required WorkoutPlan plan,
    required int dayIndex,
    required DateTime date,
  }) async {
    final entries = await _repo.listPlanEntries(plan.id);
    final exercisesById = {
      for (final e in await _repo.listExercises()) e.id: e,
    };
    // An entry whose movement is gone (deleted on another device before its
    // tombstone arrived) has no target to materialise from, so it is skipped
    // rather than logged as an unnamed 0 × 0.
    final dayEntries =
        entries
            .where(
              (e) =>
                  e.dayIndex == dayIndex &&
                  exercisesById.containsKey(e.exerciseId),
            )
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    if (dayEntries.isEmpty) return false;

    final now = utcNow();
    final session = WorkoutSession(
      id: newId(),
      planId: plan.id,
      dayIndex: dayIndex,
      date: workoutDayKey(date),
      startedAt: now,
      createdAt: now,
      updatedAt: now,
    );

    final logs = <WorkoutSetLog>[];
    for (var order = 0; order < dayEntries.length; order++) {
      final entry = dayEntries[order];
      final exercise = exercisesById[entry.exerciseId]!;
      for (var setIndex = 0; setIndex < exercise.targetSets; setIndex++) {
        logs.add(
          WorkoutSetLog(
            id: newId(),
            sessionId: session.id,
            exerciseId: entry.exerciseId,
            exerciseOrder: order,
            setIndex: setIndex,
            weightKg: exercise.targetWeightKg,
            reps: exercise.targetReps,
            plannedWeightKg: exercise.targetWeightKg,
            plannedReps: exercise.targetReps,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
    }

    await _repo.upsertSession(session);
    await _repo.upsertSetLogsBatch(logs);
    _pushSession(session);
    _pushSetLogs(logs);
    _invalidate();
    await _loadSession(session, expanded: true);
    return true;
  }

  void expand() {
    if (!state.isLive || state.expanded) return;
    state = state.copyWith(expanded: true);
  }

  void collapse() {
    if (!state.expanded) return;
    state = state.copyWith(expanded: false);
  }

  /// Moves the wheels to a specific set — used by the exercise strip in the
  /// expanded view and by tapping a set row.
  void focusSet(String logId) {
    final index = state.logs.indexWhere((l) => l.id == logId);
    if (index == -1 || index == state.cursor) return;
    state = state.copyWith(cursor: index);
  }

  /// Applies a wheel change to the current set. Only touches this session's
  /// log — the plan entry it came from is deliberately left alone, which is
  /// what makes a heavy or light day a one-off dip rather than a new baseline.
  Future<void> updateCurrentSet({double? weightKg, int? reps}) async {
    final set = state.currentSet;
    if (set == null) return;
    if (weightKg == null && reps == null) return;

    final updated = set.copyWith(weightKg: weightKg, reps: reps);
    _replaceLog(updated);
    await _repo.upsertSetLog(updated);
    _ref.read(remoteSyncServiceProvider).pushWorkoutSetLog(updated);
  }

  /// Marks the current set done and advances. Saves the weight and reps that
  /// were actually on the wheels at that moment.
  Future<void> completeCurrentSet() async {
    final set = state.currentSet;
    if (set == null || set.completed) return;

    final updated = set.copyWith(completed: true, completedAt: utcNow());
    _replaceLog(updated);
    await _repo.upsertSetLog(updated);
    _ref.read(remoteSyncServiceProvider).pushWorkoutSetLog(updated);
    _invalidate();

    final next = _firstIncompleteIndex(state.logs);
    state = state.copyWith(cursor: next);

    final settings = _ref.read(settingsProvider).valueOrNull;
    if (settings != null &&
        settings.workoutRestTimerEnabled &&
        settings.workoutRestSeconds > 0 &&
        state.logs.any((l) => !l.completed)) {
      startRest(settings.workoutRestSeconds);
    }
  }

  Future<void> uncompleteSet(String logId) async {
    final index = state.logs.indexWhere((l) => l.id == logId);
    if (index == -1) return;
    final updated = state.logs[index].copyWith(
      completed: false,
      clearCompletedAt: true,
    );
    _replaceLog(updated);
    await _repo.upsertSetLog(updated);
    _ref.read(remoteSyncServiceProvider).pushWorkoutSetLog(updated);
    _invalidate();
  }

  /// Changes how many sets the current exercise has in *this* session.
  /// Growing appends sets seeded from the last one; shrinking drops trailing
  /// sets, refusing to discard any that are already logged as done.
  Future<void> setCurrentExerciseSetCount(int count) async {
    final current = state.currentSet;
    if (current == null) return;
    final target = count.clamp(1, 20);
    final sets = state.currentExerciseSets;
    if (sets.isEmpty || sets.length == target) return;

    if (target > sets.length) {
      final template = sets.last;
      final now = utcNow();
      final added = [
        for (var i = sets.length; i < target; i++)
          WorkoutSetLog(
            id: newId(),
            sessionId: template.sessionId,
            exerciseId: template.exerciseId,
            exerciseOrder: template.exerciseOrder,
            setIndex: i,
            weightKg: template.weightKg,
            reps: template.reps,
            plannedWeightKg: template.plannedWeightKg,
            plannedReps: template.plannedReps,
            createdAt: now,
            updatedAt: now,
          ),
      ];
      await _repo.upsertSetLogsBatch(added);
      _pushSetLogs(added);
      _sortIntoLogs(added);
    } else {
      final removable = sets.sublist(target).where((s) => !s.completed).toList();
      for (final set in removable) {
        await _repo.softDeleteSetLog(set.id);
      }
      final removedIds = {for (final s in removable) s.id};
      final remaining = [
        for (final l in state.logs)
          if (!removedIds.contains(l.id)) l,
      ];
      state = state.copyWith(
        logs: remaining,
        cursor: _firstIncompleteIndex(remaining),
      );
    }
    _invalidate();
  }

  void startRest(int seconds) {
    _restTimer?.cancel();
    state = state.copyWith(
      restEndsAt: DateTime.now().add(Duration(seconds: seconds)),
      restTotalSeconds: seconds,
    );
    // A single one-shot timer clears the countdown when it runs out; the
    // second-by-second text and the draining border are animated by the
    // island itself, so nothing ticks state 60 times a minute.
    _restTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted) return;
      state = state.copyWith(clearRest: true);
    });
  }

  void cancelRest() {
    _restTimer?.cancel();
    _restTimer = null;
    if (state.restEndsAt == null) return;
    state = state.copyWith(clearRest: true);
  }

  /// Ends the workout. Sets left unfinished stay unfinished — they simply
  /// never count toward volume, which is more honest than silently marking
  /// them done.
  Future<void> finish() async {
    final session = state.session;
    if (session == null) return;
    _restTimer?.cancel();
    _restTimer = null;

    final ended = session.copyWith(endedAt: utcNow());
    await _repo.upsertSession(ended);
    _pushSession(ended);
    state = const ActiveWorkoutState();
    _invalidate();
  }

  /// Abandons the workout and removes it from history entirely — for a
  /// session started by mistake, which should not leave a "worked out" mark
  /// on the calendar.
  Future<void> discard() async {
    final session = state.session;
    if (session == null) return;
    _restTimer?.cancel();
    _restTimer = null;

    await _repo.softDeleteSession(session.id);
    final deleted = await _repo.getSession(session.id);
    if (deleted != null) _pushSession(deleted);
    state = const ActiveWorkoutState();
    _invalidate();
  }

  void _replaceLog(WorkoutSetLog updated) {
    state = state.copyWith(
      logs: [
        for (final log in state.logs)
          if (log.id == updated.id) updated else log,
      ],
    );
  }

  void _sortIntoLogs(List<WorkoutSetLog> added) {
    final logs = [...state.logs, ...added]
      ..sort((a, b) {
        final byExercise = a.exerciseOrder.compareTo(b.exerciseOrder);
        return byExercise != 0 ? byExercise : a.setIndex.compareTo(b.setIndex);
      });
    state = state.copyWith(logs: logs);
  }

  void _pushSession(WorkoutSession session) {
    _ref.read(remoteSyncServiceProvider).pushWorkoutSession(session);
  }

  void _pushSetLogs(List<WorkoutSetLog> logs) {
    unawaited(
      _ref.read(remoteSyncServiceProvider).pushWorkoutSetLogsBatch(logs),
    );
  }

  void _invalidate() => invalidateWorkoutProviders(_ref);

  @override
  void dispose() {
    _restTimer?.cancel();
    super.dispose();
  }
}

final workoutSessionControllerProvider =
    StateNotifierProvider<WorkoutSessionController, ActiveWorkoutState>((ref) {
      ref.keepAlive();
      return WorkoutSessionController(ref);
    });
