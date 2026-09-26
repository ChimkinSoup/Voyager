import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
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
    this.segmentIndex = 0,
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

  /// 0 = top/main segment of [currentSet]; 1+ = drop segment index + 1.
  final int segmentIndex;

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

  /// Every set belonging to the current set's placement, in order. Keyed on
  /// the placement — the exercise *and* its position in the session — so the
  /// same lift planned twice on one day stays two groups rather than merging
  /// into one "Set 4 of 6".
  List<WorkoutSetLog> get currentExerciseSets {
    final set = currentSet;
    if (set == null) return const [];
    return [
      for (final l in logs)
        if (l.exerciseId == set.exerciseId &&
            l.exerciseOrder == set.exerciseOrder)
          l,
    ];
  }

  /// One entry per placement in this session, in the order they were
  /// planned. A movement placed twice appears twice.
  List<({int order, Exercise exercise})> get sessionExercises {
    final seen = <int>{};
    final result = <({int order, Exercise exercise})>[];
    for (final log in logs) {
      if (!seen.add(log.exerciseOrder)) continue;
      final exercise = exercisesById[log.exerciseId];
      if (exercise != null) {
        result.add((order: log.exerciseOrder, exercise: exercise));
      }
    }
    return result;
  }

  int get completedCount => logs.where((l) => l.completed).length;

  bool get isResting =>
      restEndsAt != null && restEndsAt!.isAfter(DateTime.now());

  SetSegment? get currentSegment {
    final set = currentSet;
    if (set == null) return null;
    final segments = set.allSegments;
    if (segments.isEmpty) return null;
    final index = segmentIndex.clamp(0, segments.length - 1);
    return segments[index];
  }

  ActiveWorkoutState copyWith({
    WorkoutSession? session,
    bool clearSession = false,
    List<WorkoutSetLog>? logs,
    Map<String, Exercise>? exercisesById,
    int? cursor,
    int? segmentIndex,
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
      segmentIndex: segmentIndex ?? this.segmentIndex,
      restEndsAt: clearRest ? null : (restEndsAt ?? this.restEndsAt),
      restTotalSeconds: clearRest
          ? 0
          : (restTotalSeconds ?? this.restTotalSeconds),
      expanded: expanded ?? this.expanded,
    );
  }
}

/// Owns the live workout: which set the wheels are on, what has been logged,
/// and the rest countdown.
///
/// Every mutation writes through to the database promptly rather than
/// batching at the end. A workout is a long-lived, interruptible thing — the
/// user will navigate away mid-session, and may well close the app — so the
/// only safe place for "I hit that set" to live is the row. The one exception
/// is a wheel being turned, which is debounced — see [_schedulePersist].
class WorkoutSessionController extends StateNotifier<ActiveWorkoutState> {
  WorkoutSessionController(this._ref) : super(const ActiveWorkoutState()) {
    // Also how a session left open by a previous launch is picked up: the
    // first value read is whatever is open on disk.
    _ref.listen<AsyncValue<WorkoutSession?>>(activeWorkoutSessionProvider, (
      _,
      next,
    ) {
      if (next is AsyncData<WorkoutSession?>) {
        unawaited(_onActiveSessionRead(next.value));
      }
    }, fireImmediately: true);
    PendingFlushRegistry.instance.register(_flushPending);
  }

  final Ref _ref;
  Timer? _restTimer;
  Timer? _persistTimer;

  /// Wheel edits not yet written, by set id.
  final _pendingLogs = <String, WorkoutSetLog>{};

  /// Set while [startFromPlan] runs. Its reads and writes leave a window
  /// where the state is not yet live, and a second press in it opened a
  /// second session that nothing could then finish or discard.
  bool _starting = false;

  /// Set while [finish] or [discard] runs, so neither can run twice or
  /// interleave with the other.
  bool _closing = false;

  WorkoutRepository get _repo => _ref.read(workoutRepositoryProvider);

  /// Brings the live view in line with the active session on disk each time
  /// it is re-read — at launch, and after every pull, which invalidates the
  /// workout providers. Without it a workout finished or discarded on another
  /// device stayed live here, and finishing it wrote this device's stale copy
  /// back over the other's tombstone.
  Future<void> _onActiveSessionRead(WorkoutSession? active) async {
    if (_starting || _closing) return;
    final live = state.session;

    if (live == null) {
      if (active == null) return;
      // Re-read: the value may predate this device closing that session.
      final current = await _repo.getSession(active.id);
      if (current == null || !current.isActive) return;
      if (!mounted || _starting || _closing || state.isLive) return;
      await _loadSession(current, expanded: false);
      return;
    }

    if (active?.id == live.id) {
      if (active!.version <= live.version) return;
      await _flushPending();
      final (:logs, :exercisesById) = await _readSession(live.id);
      if (!mounted || state.session?.id != live.id) return;
      final kept = logs.indexWhere((l) => l.id == state.currentSet?.id);
      state = state.copyWith(
        session: active,
        logs: logs,
        exercisesById: exercisesById,
        cursor: kept == -1 ? _firstIncompleteIndex(logs) : kept,
      );
      return;
    }

    // Nothing open on disk, or some other session: confirm this one really
    // is closed before dropping it, since the read may predate its own start.
    final current = await _repo.getSession(live.id);
    if (!mounted || _starting || _closing || state.session?.id != live.id) {
      return;
    }
    if (current != null && current.isActive) return;
    _restTimer?.cancel();
    _restTimer = null;
    _persistTimer?.cancel();
    _pendingLogs.clear();
    state = const ActiveWorkoutState();
    if (active != null) await _onActiveSessionRead(active);
  }

  Future<void> _loadSession(
    WorkoutSession session, {
    required bool expanded,
  }) async {
    final (:logs, :exercisesById) = await _readSession(session.id);
    if (!mounted) return;
    state = ActiveWorkoutState(
      session: session,
      logs: logs,
      exercisesById: exercisesById,
      cursor: _firstIncompleteIndex(logs),
      expanded: expanded,
    );
  }

  /// Deleted movements included: one deleted mid-workout, here or on another
  /// device, still has sets in this session, and without its row they
  /// rendered as "every set is done" with the Complete button gone.
  Future<({List<WorkoutSetLog> logs, Map<String, Exercise> exercisesById})>
  _readSession(String sessionId) async {
    final logs = await _repo.listSetLogs(sessionId: sessionId);
    final exercises = await _repo.listExercises(includeDeleted: true);
    return (logs: logs, exercisesById: {for (final e in exercises) e.id: e});
  }

  static int _firstIncompleteIndex(List<WorkoutSetLog> logs) {
    final index = logs.indexWhere((l) => !l.completed);
    return index == -1 ? (logs.isEmpty ? 0 : logs.length - 1) : index;
  }

  /// Starts a workout from one day of a plan, materialising a set log per
  /// planned set so the wheels have planned numbers to default to.
  ///
  /// Returns false only when the day has nothing planned — there is no such
  /// thing as an empty workout, and starting one would strand the island with
  /// nothing to show.
  Future<bool> startFromPlan({
    required WorkoutPlan plan,
    required int dayIndex,
    required DateTime date,
  }) async {
    if (_starting || _closing || state.isLive) return true;
    _starting = true;
    try {
      // Checked on disk, not just in memory: a session still being restored,
      // or one started on another device, is resumed rather than joined by a
      // rival that nothing could close.
      final existing = await _repo.getActiveSession();
      if (existing != null) {
        await _loadSession(existing, expanded: true);
        return true;
      }
      return await _startNew(plan: plan, dayIndex: dayIndex, date: date);
    } finally {
      _starting = false;
    }
  }

  Future<bool> _startNew({
    required WorkoutPlan plan,
    required int dayIndex,
    required DateTime date,
  }) async {
    final planned = await plannedExercisesForDay(
      _repo,
      planId: plan.id,
      dayIndex: dayIndex,
    );
    if (planned.isEmpty) return false;

    final now = utcNow();
    final session = WorkoutSession(
      id: newId(),
      planId: plan.id,
      dayIndex: dayIndex,
      date: workoutStoredDate(date),
      startedAt: now,
      createdAt: now,
      updatedAt: now,
    );
    final logs = [
      for (final (order, exercise) in planned.indexed)
        ...materialiseSetLogs(
          sessionId: session.id,
          exercise: exercise,
          order: order,
          now: now,
        ),
    ];

    await _repo.createSessionWithLogs(session, logs);
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
    if (index == -1) return;
    if (index == state.cursor && state.segmentIndex == 0) return;
    state = state.copyWith(cursor: index, segmentIndex: 0);
  }

  /// Focuses a segment within the current set (0 = top, 1+ = drops).
  void focusSegment(int segmentIndex) {
    final set = state.currentSet;
    if (set == null) return;
    final max = set.allSegments.length - 1;
    final next = segmentIndex.clamp(0, max < 0 ? 0 : max);
    if (next == state.segmentIndex) return;
    state = state.copyWith(segmentIndex: next);
  }

  /// Applies a wheel change to the focused segment of the current set.
  void updateCurrentSet({double? weightKg, int? reps}) {
    final set = state.currentSet;
    if (set == null) return;
    if (weightKg == null && reps == null) return;

    // One version bump per debounced write, not one per wheel row passed.
    final bump = !_pendingLogs.containsKey(set.id);
    // Clamped the way [ActiveWorkoutState.currentSegment] clamps: those are
    // the numbers on the wheels, so an index left over from a set with more
    // drops has to edit the segment being shown rather than drop the turn.
    final segment = state.segmentIndex.clamp(0, set.allSegments.length - 1);
    late final WorkoutSetLog updated;
    if (segment <= 0) {
      updated = set.copyWith(weightKg: weightKg, reps: reps, bumpVersion: bump);
    } else {
      final drops = [...set.dropSegments];
      final dropIndex = segment - 1;
      if (dropIndex >= drops.length) return;
      final current = drops[dropIndex];
      drops[dropIndex] = SetSegment(
        weightKg: weightKg ?? current.weightKg,
        reps: reps ?? current.reps,
      );
      updated = set.copyWith(dropSegments: drops, bumpVersion: bump);
    }
    _replaceLog(updated);
    _schedulePersist(updated);
  }

  /// Wheel edits reach [state] on every row the wheel passes, but the
  /// database and Firestore only on a trailing debounce: a flick from 0 to
  /// 200 lb passes some 80 rows, and each was its own write, version bump and
  /// queued upload.
  void _schedulePersist(WorkoutSetLog log) {
    _pendingLogs[log.id] = log;
    _persistTimer?.cancel();
    _persistTimer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_flushPending()),
    );
  }

  /// Writes any debounced wheel edits. Awaited before every other write —
  /// those build on the in-memory set, and the older pending copy landing
  /// after them would undo them — and run on window close through
  /// [PendingFlushRegistry].
  Future<void> _flushPending() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    if (_pendingLogs.isEmpty) return;
    final logs = [..._pendingLogs.values];
    _pendingLogs.clear();
    for (final log in logs) {
      await _repo.upsertSetLog(log);
      _ref.read(remoteSyncServiceProvider).pushWorkoutSetLog(log);
    }
  }

  /// Appends a drop to the current set, seeded from the last segment − X.
  Future<void> addDropToCurrentSet(WeightUnit unit) async {
    await _flushPending();
    final set = state.currentSet;
    if (set == null || set.dropSegments.length >= kMaxDropsPerSet) return;
    final prev = set.allSegments.last;
    final updated = set.copyWith(
      dropSegments: [...set.dropSegments, nextDropSegment(prev, unit)],
    );
    _replaceLog(updated);
    state = state.copyWith(segmentIndex: updated.allSegments.length - 1);
    await _repo.upsertSetLog(updated);
    _ref.read(remoteSyncServiceProvider).pushWorkoutSetLog(updated);
  }

  /// Removes a drop segment (1-based into [WorkoutSetLog.dropSegments]).
  Future<void> removeDropFromCurrentSet(int dropIndex) async {
    await _flushPending();
    final set = state.currentSet;
    if (set == null) return;
    if (dropIndex < 0 || dropIndex >= set.dropSegments.length) return;
    final drops = [
      for (var i = 0; i < set.dropSegments.length; i++)
        if (i != dropIndex) set.dropSegments[i],
    ];
    final updated = set.copyWith(dropSegments: drops);
    final nextSegment = state.segmentIndex > dropIndex + 1
        ? state.segmentIndex - 1
        : state.segmentIndex.clamp(0, updated.allSegments.length - 1);
    _replaceLog(updated);
    state = state.copyWith(segmentIndex: nextSegment);
    await _repo.upsertSetLog(updated);
    _ref.read(remoteSyncServiceProvider).pushWorkoutSetLog(updated);
  }

  /// Marks the current set done and advances. Saves the weight and reps that
  /// were actually on the wheels at that moment.
  Future<void> completeCurrentSet() async {
    await _flushPending();
    final set = state.currentSet;
    if (set == null || set.completed) return;

    final updated = set.copyWith(completed: true, completedAt: utcNow());
    _replaceLog(updated);
    await _repo.upsertSetLog(updated);
    _ref.read(remoteSyncServiceProvider).pushWorkoutSetLog(updated);
    _invalidateSets(set.exerciseId);

    final next = _firstIncompleteIndex(state.logs);
    state = state.copyWith(cursor: next, segmentIndex: 0);

    final settings = _ref.read(settingsProvider).valueOrNull;
    if (settings != null &&
        settings.workoutRestTimerEnabled &&
        settings.workoutRestSeconds > 0 &&
        state.logs.any((l) => !l.completed)) {
      startRest(settings.workoutRestSeconds);
    }
  }

  Future<void> uncompleteSet(String logId) async {
    await _flushPending();
    final index = state.logs.indexWhere((l) => l.id == logId);
    if (index == -1) return;
    final updated = state.logs[index].copyWith(
      completed: false,
      clearCompletedAt: true,
    );
    _replaceLog(updated);
    await _repo.upsertSetLog(updated);
    _ref.read(remoteSyncServiceProvider).pushWorkoutSetLog(updated);
    _invalidateSets(updated.exerciseId);
  }

  /// Changes how many sets the current exercise has in *this* session.
  /// Growing appends sets seeded from the last one; shrinking drops trailing
  /// sets, refusing to discard any that are already logged as done.
  Future<void> setCurrentExerciseSetCount(int count) async {
    await _flushPending();
    final current = state.currentSet;
    if (current == null) return;
    final target = count.clamp(1, 20);
    final sets = state.currentExerciseSets;
    if (sets.isEmpty || sets.length == target) return;

    if (target > sets.length) {
      final template = sets.last;
      // After the highest index, not at the count: a shrink that had to keep
      // a completed trailing set leaves a gap, and the count then collided
      // with an index already in use.
      final nextIndex = sets.map((s) => s.setIndex).reduce(math.max) + 1;
      final now = utcNow();
      final added = [
        for (var i = 0; i < target - sets.length; i++)
          WorkoutSetLog(
            id: newId(),
            sessionId: template.sessionId,
            exerciseId: template.exerciseId,
            exerciseOrder: template.exerciseOrder,
            setIndex: nextIndex + i,
            weightKg: template.weightKg,
            reps: template.reps,
            plannedWeightKg: template.plannedWeightKg,
            plannedReps: template.plannedReps,
            dropSegments: template.dropSegments,
            plannedDropSegments: template.plannedDropSegments,
            createdAt: now,
            updatedAt: now,
          ),
      ];
      await _repo.upsertSetLogsBatch(added);
      _pushSetLogs(added);
      _sortIntoLogs(added);
    } else {
      final removable = sets
          .sublist(target)
          .where((s) => !s.completed)
          .toList();
      await _removeSets(removable);
      final removedIds = {for (final s in removable) s.id};
      final remaining = [
        for (final l in state.logs)
          if (!removedIds.contains(l.id)) l,
      ];
      // Stays on this exercise — its first set still to do, else its last —
      // rather than jumping to the session's first incomplete set, which
      // pulled the wheels onto an earlier, skipped exercise mid-edit. The
      // group is never empty: the first [target] sets are always kept.
      final group = [
        for (final l in remaining)
          if (l.exerciseId == current.exerciseId &&
              l.exerciseOrder == current.exerciseOrder)
            l,
      ];
      final landing = group.firstWhere(
        (l) => !l.completed,
        orElse: () => group.last,
      );
      state = state.copyWith(
        logs: remaining,
        cursor: remaining.indexOf(landing),
        segmentIndex: 0,
      );
    }
    _invalidateSets(current.exerciseId);
  }

  /// Adds [exercise] after everything else in this session, with the sets its
  /// target prescribes, and moves the wheels onto it. The plan is untouched.
  Future<void> addExercise(Exercise exercise) async {
    await _flushPending();
    final session = state.session;
    if (session == null) return;
    final order = state.logs.isEmpty
        ? 0
        : state.logs.map((l) => l.exerciseOrder).reduce(math.max) + 1;
    final added = materialiseSetLogs(
      sessionId: session.id,
      exercise: exercise,
      order: order,
      now: utcNow(),
    );
    if (added.isEmpty) return;
    await _repo.upsertSetLogsBatch(added);
    _pushSetLogs(added);
    _sortIntoLogs(added);
    state = state.copyWith(
      exercisesById: {...state.exercisesById, exercise.id: exercise},
      cursor: state.logs.indexWhere((l) => l.id == added.first.id),
      segmentIndex: 0,
    );
    _invalidateSets(exercise.id);
  }

  /// Takes the unfinished sets of the placement at [order] out of this
  /// session. Sets already logged stay, so skipping the rest of an exercise
  /// part-way through keeps what was lifted. The plan is untouched.
  Future<void> skipExercise(int order) async {
    await _flushPending();
    if (state.session == null) return;
    final removable = [
      for (final l in state.logs)
        if (l.exerciseOrder == order && !l.completed) l,
    ];
    if (removable.isEmpty) return;
    await _removeSets(removable);
    final removedIds = {for (final s in removable) s.id};
    final remaining = [
      for (final l in state.logs)
        if (!removedIds.contains(l.id)) l,
    ];
    final kept = remaining.indexWhere((l) => l.id == state.currentSet?.id);
    state = state.copyWith(
      logs: remaining,
      cursor: kept == -1 ? _firstIncompleteIndex(remaining) : kept,
      segmentIndex: kept == -1 ? 0 : state.segmentIndex,
    );
    _invalidateSets(removable.first.exerciseId);
  }

  /// Moves the placement at position [from] among this session's exercises to
  /// position [to], renumbering every placement's order to match. The plan is
  /// untouched.
  Future<void> moveExercise(int from, int to) async {
    await _flushPending();
    // The positions the exercise strip shows.
    final shown = [for (final p in state.sessionExercises) p.order];
    if (from == to ||
        from < 0 ||
        to < 0 ||
        from >= shown.length ||
        to >= shown.length) {
      return;
    }
    shown.insert(to, shown.removeAt(from));
    // A placement the strip leaves out (its movement isn't loaded) keeps its
    // slot, and every placement is renumbered, so no two share an order.
    final visible = shown.toSet();
    final moved = shown.iterator;
    final orders = [
      for (final order in {for (final l in state.logs) l.exerciseOrder})
        if (visible.contains(order)) (moved..moveNext()).current else order,
    ];
    final renumbered = {
      for (final (index, order) in orders.indexed) order: index,
    };
    final changed = <WorkoutSetLog>[];
    final logs = <WorkoutSetLog>[];
    for (final l in state.logs) {
      final order = renumbered[l.exerciseOrder] ?? l.exerciseOrder;
      if (order == l.exerciseOrder) {
        logs.add(l);
        continue;
      }
      final moved = l.copyWith(exerciseOrder: order);
      changed.add(moved);
      logs.add(moved);
    }
    logs.sort(_bySessionPosition);
    final currentId = state.currentSet?.id;
    state = state.copyWith(
      logs: logs,
      cursor: logs.indexWhere((l) => l.id == currentId),
    );
    await _repo.upsertSetLogsBatch(changed);
    _pushSetLogs(changed);
    final sessionId = state.session?.id;
    if (sessionId != null) _ref.invalidate(workoutSetLogsProvider(sessionId));
  }

  /// Tombstones [sets] and uploads the tombstones — or every other device,
  /// and this one after a re-pull, brings them back as incomplete.
  Future<void> _removeSets(List<WorkoutSetLog> sets) async {
    final tombstones = <WorkoutSetLog>[];
    for (final set in sets) {
      await _repo.softDeleteSetLog(set.id);
      final tombstone = await _repo.getSetLog(set.id);
      if (tombstone != null) tombstones.add(tombstone);
    }
    _pushSetLogs(tombstones);
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
    if (session == null || _closing) return;
    _closing = true;
    _restTimer?.cancel();
    _restTimer = null;
    // Cleared before the first await so the buttons go with it.
    state = const ActiveWorkoutState();
    try {
      await _flushPending();
      // Built from the row on disk rather than the copy held since the start:
      // if another device already finished or discarded this workout, that
      // stands, instead of this device's stale copy outranking it.
      final current = await _repo.getSession(session.id);
      if (current == null || !current.isActive) return;
      final ended = current.copyWith(endedAt: utcNow());
      await _repo.upsertSession(ended);
      _pushSession(ended);
    } finally {
      _closing = false;
      _invalidate();
    }
  }

  /// Abandons the workout and removes it from history entirely — for a
  /// session started by mistake, which should not leave a "worked out" mark
  /// on the calendar.
  Future<void> discard() async {
    final session = state.session;
    if (session == null || _closing) return;
    _closing = true;
    _restTimer?.cancel();
    _restTimer = null;
    // Edits to sets about to be deleted have nowhere left to go.
    _persistTimer?.cancel();
    _pendingLogs.clear();
    state = const ActiveWorkoutState();
    try {
      // Ended as well as deleted, so bringing it back from the trash restores
      // a finished workout rather than a second live one.
      final current = await _repo.getSession(session.id);
      if (current != null && current.isActive) {
        await _repo.upsertSession(current.copyWith(endedAt: utcNow()));
      }
      await _repo.softDeleteSession(session.id);
      final deleted = await _repo.getSession(session.id);
      if (deleted != null) _pushSession(deleted);
      // The delete cascades into the sets locally; their tombstones have to
      // be uploaded as well, or every other device keeps them live.
      final logs = await _repo.listSetLogs(
        sessionId: session.id,
        includeDeleted: true,
      );
      _pushSetLogs([
        for (final log in logs)
          if (log.deletedAt != null) log,
      ]);
    } finally {
      _closing = false;
      _invalidate();
    }
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
    final logs = [...state.logs, ...added]..sort(_bySessionPosition);
    state = state.copyWith(logs: logs);
  }

  static int _bySessionPosition(WorkoutSetLog a, WorkoutSetLog b) {
    final byExercise = a.exerciseOrder.compareTo(b.exerciseOrder);
    return byExercise != 0 ? byExercise : a.setIndex.compareTo(b.setIndex);
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

  /// What a set change can affect — this session's sets and the history of
  /// the movement — rather than every workout table, which each tap otherwise
  /// reloaded in full.
  void _invalidateSets(String exerciseId) {
    final sessionId = state.session?.id;
    if (sessionId != null) _ref.invalidate(workoutSetLogsProvider(sessionId));
    _ref.invalidate(exerciseSetLogsProvider(exerciseId));
  }

  @override
  void dispose() {
    // No flush here: the provider is app-scoped, so this only runs as the
    // container is torn down — after the window-close flush has already
    // written anything pending — and the ref it would write through is no
    // longer usable by then.
    PendingFlushRegistry.instance.unregister(_flushPending);
    _restTimer?.cancel();
    _persistTimer?.cancel();
    super.dispose();
  }
}

/// The movements planned on [dayIndex] of [planId], in planned order.
///
/// An entry whose movement is gone (deleted on another device before its
/// tombstone arrived) has no target to materialise from, so it is skipped
/// rather than logged as an unnamed 0 × 0.
Future<List<Exercise>> plannedExercisesForDay(
  WorkoutRepository repo, {
  required String planId,
  required int dayIndex,
}) async {
  final entries = await repo.listPlanEntries(planId);
  final exercisesById = {for (final e in await repo.listExercises()) e.id: e};
  final dayEntries =
      entries
          .where(
            (e) =>
                e.dayIndex == dayIndex &&
                exercisesById.containsKey(e.exerciseId),
          )
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return [for (final e in dayEntries) exercisesById[e.exerciseId]!];
}

/// One set log per set [exercise] prescribes, as placement [order] of
/// [sessionId], with the planned numbers copied in so the wheels have
/// something to default to.
List<WorkoutSetLog> materialiseSetLogs({
  required String sessionId,
  required Exercise exercise,
  required int order,
  required DateTime now,
}) {
  WorkoutSetLog log(int setIndex, SetSegment top, List<SetSegment> drops) {
    // The reps wheel bottoms out at 1, so a 0 here showed a rep that was
    // then logged as none.
    final reps = top.reps.clamp(1, kMaxReps);
    return WorkoutSetLog(
      id: newId(),
      sessionId: sessionId,
      exerciseId: exercise.id,
      exerciseOrder: order,
      setIndex: setIndex,
      weightKg: top.weightKg,
      reps: reps,
      plannedWeightKg: top.weightKg,
      plannedReps: reps,
      dropSegments: drops,
      plannedDropSegments: drops,
      createdAt: now,
      updatedAt: now,
    );
  }

  if (exercise.isCustomPrescription) {
    return [
      for (final (setIndex, prescription) in exercise.setPrescriptions.indexed)
        log(setIndex, prescription.top, prescription.drops),
    ];
  }
  final top = SetSegment(
    weightKg: exercise.targetWeightKg,
    reps: exercise.targetReps,
  );
  return [
    for (var setIndex = 0; setIndex < exercise.targetSets; setIndex++)
      log(setIndex, top, const []),
  ];
}

final workoutSessionControllerProvider =
    StateNotifierProvider<WorkoutSessionController, ActiveWorkoutState>((ref) {
      ref.keepAlive();
      return WorkoutSessionController(ref);
    });
