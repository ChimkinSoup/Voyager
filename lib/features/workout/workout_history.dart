import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/workout/workout_exercise_picker.dart';
import 'package:voyager/features/workout/workout_segment_fields.dart';
import 'package:voyager/features/workout/workout_session_controller.dart';
import 'package:voyager/features/workout/workout_units.dart';

/// Opens the list of finished workouts, where one can be opened to fix its
/// sets or date, deleted, or a workout done without the app logged after the
/// fact.
Future<void> openWorkoutHistory(BuildContext context) {
  final screenSize = MediaQuery.sizeOf(context);
  return showVoyagerModal<void>(
    context: context,
    kind: VoyagerSheetKind.editor,
    constraints: BoxConstraints(
      maxWidth: math.min(640, screenSize.width * 0.96),
      maxHeight: screenSize.height * 0.9,
    ),
    builder: (sheetContext) =>
        _WorkoutHistory(onClose: () => Navigator.of(sheetContext).pop()),
  );
}

/// The toolbar's way in to [openWorkoutHistory].
class WorkoutHistoryButton extends StatelessWidget {
  const WorkoutHistoryButton({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassButton(
      dense: true,
      icon: const Icon(PhosphorIconsRegular.clockCounterClockwise, size: 15),
      label: 'History',
      onPressed: () => openWorkoutHistory(context),
    );
  }
}

/// Every finished session, the day it counts toward first, newest first.
///
/// Rebuilt whenever the session list is, which every workout write and every
/// pull invalidates.
final _historyProvider = FutureProvider.autoDispose<List<WorkoutSession>>((
  ref,
) async {
  final sessions = await ref.watch(workoutSessionsProvider.future);
  return [
    for (final session in sessions)
      if (session.endedAt != null) session,
  ]..sort((a, b) {
    final byDate = workoutCalendarDate(
      b.date,
    ).compareTo(workoutCalendarDate(a.date));
    return byDate != 0 ? byDate : b.startedAt.compareTo(a.startedAt);
  });
});

/// One session's live sets, read only while its row is on screen so the list
/// never loads every set ever logged. Re-read on the same invalidation as
/// the list.
final _historyLogsProvider = FutureProvider.autoDispose
    .family<List<WorkoutSetLog>, String>((ref, sessionId) {
      ref.watch(workoutSessionsProvider.settled);
      return ref
          .watch(workoutRepositoryProvider)
          .listSetLogs(sessionId: sessionId);
    });

/// Deleted movements included: a past session keeps its sets, and its name
/// should still read.
final _allExercisesProvider = FutureProvider.autoDispose<Map<String, Exercise>>(
  (ref) async {
    ref.watch(exercisesProvider.settled);
    final all = await ref
        .watch(workoutRepositoryProvider)
        .listExercises(includeDeleted: true);
    return {for (final e in all) e.id: e};
  },
);

enum _View { list, log, session }

class _WorkoutHistory extends StatefulWidget {
  const _WorkoutHistory({required this.onClose});

  final VoidCallback onClose;

  @override
  State<_WorkoutHistory> createState() => _WorkoutHistoryState();
}

class _WorkoutHistoryState extends State<_WorkoutHistory> {
  var _view = _View.list;
  String? _sessionId;

  void _open(String sessionId) => setState(() {
    _sessionId = sessionId;
    _view = _View.session;
  });

  void _back() => setState(() => _view = _View.list);

  @override
  Widget build(BuildContext context) {
    return switch (_view) {
      _View.list => _SessionList(
        onClose: widget.onClose,
        onOpen: _open,
        onLogPast: () => setState(() => _view = _View.log),
      ),
      _View.log => _LogPastWorkout(onBack: _back, onCreated: _open),
      _View.session => _SessionEditor(
        key: ValueKey(_sessionId),
        sessionId: _sessionId!,
        onBack: _back,
      ),
    };
  }
}

/// Title row shared by the three views: a back arrow or nothing, the title,
/// then whatever [actions] the view carries.
class _Header extends StatelessWidget {
  const _Header({required this.title, this.onBack, this.actions = const []});

  final String title;
  final VoidCallback? onBack;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (onBack != null)
          IconButton(
            onPressed: onBack,
            icon: const Icon(PhosphorIconsRegular.arrowLeft, size: 18),
            tooltip: 'Back',
          ),
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        ...actions,
      ],
    );
  }
}

class _SessionList extends ConsumerWidget {
  const _SessionList({
    required this.onClose,
    required this.onOpen,
    required this.onLogPast,
  });

  final VoidCallback onClose;
  final ValueChanged<String> onOpen;
  final VoidCallback onLogPast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final unit =
        ref.watch(settingsProvider.settled).valueOrNull?.weightUnit ??
        WeightUnit.lb;
    final sessions = ref.watch(_historyProvider.settled).valueOrNull;
    final exercises =
        ref.watch(_allExercisesProvider.settled).valueOrNull ??
        const <String, Exercise>{};
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
    );

    return Padding(
      padding: const EdgeInsets.all(VoyagerSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            title: 'Workout history',
            actions: [
              GlassButton(
                dense: true,
                icon: const Icon(PhosphorIconsRegular.plus, size: 14),
                label: 'Log past workout',
                onPressed: onLogPast,
              ),
              IconButton(
                onPressed: onClose,
                icon: const Icon(PhosphorIconsRegular.x, size: 20),
                tooltip: 'Close',
              ),
            ],
          ),
          const SizedBox(height: VoyagerSpacing.md),
          if (sessions == null)
            const Center(child: CircularProgressIndicator())
          else if (sessions.isEmpty)
            Padding(
              padding: const EdgeInsets.all(VoyagerSpacing.xl),
              child: Text(
                'No finished workouts yet',
                textAlign: TextAlign.center,
                style: muted,
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: sessions.length,
                itemBuilder: (context, index) => _SessionRow(
                  session: sessions[index],
                  exercises: exercises,
                  unit: unit,
                  muted: muted,
                  onOpen: onOpen,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SessionRow extends ConsumerWidget {
  const _SessionRow({
    required this.session,
    required this.exercises,
    required this.unit,
    required this.muted,
    required this.onOpen,
  });

  final WorkoutSession session;
  final Map<String, Exercise> exercises;
  final WeightUnit unit;
  final TextStyle? muted;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref
        .watch(_historyLogsProvider(session.id).settled)
        .valueOrNull;
    final done = logs?.where((l) => l.completed).toList() ?? const [];
    final volume = done.fold<double>(0, (sum, l) => sum + l.volumeKg);
    final names = <String>[];
    for (final log in logs ?? const <WorkoutSetLog>[]) {
      final name = exercises[log.exerciseId]?.name;
      if (name != null && !names.contains(name)) names.add(name);
    }
    return ListTile(
      onTap: () => onOpen(session.id),
      title: Text(
        DateFormat.yMMMEd().format(workoutCalendarDate(session.date)),
      ),
      // Blank until the sets arrive, so the row doesn't change height.
      subtitle: Text(
        logs == null
            ? ''
            : names.isEmpty
            ? 'No sets'
            : names.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: muted,
      ),
      trailing: logs == null
          ? null
          : Text(
              '${done.length} of ${logs.length} sets · '
              '${NumberFormat.decimalPattern().format(unit.fromKilograms(volume).round())} '
              '${unit.label}',
              style: muted,
            ),
    );
  }
}

const _weekdayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/// Local midnight today — the latest day a workout can count toward.
DateTime get _today {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

/// Logs a workout done without the app: a date, then the plan day it
/// followed. The session is created finished, with the day's sets as planned
/// and none ticked, and opens in the editor to tick off and adjust.
class _LogPastWorkout extends ConsumerStatefulWidget {
  const _LogPastWorkout({required this.onBack, required this.onCreated});

  final VoidCallback onBack;
  final ValueChanged<String> onCreated;

  @override
  ConsumerState<_LogPastWorkout> createState() => _LogPastWorkoutState();
}

class _LogPastWorkoutState extends ConsumerState<_LogPastWorkout> {
  late DateTime _date = _today;
  WorkoutPlanMode? _mode;
  int? _dayIndex;
  var _creating = false;

  Future<void> _pickDate(BuildContext buttonContext) async {
    final accent = Theme.of(buttonContext).colorScheme.primary;
    final range = await showContextualPopover<DateTimeRange>(
      context: buttonContext,
      buttonContext: buttonContext,
      width: 320,
      height: 380,
      accentColor: accent,
      builder: (_) => DateSelectorPopover(
        initialStartDate: _date,
        initialEndDate: _date,
        singleDateMode: true,
        accentColor: accent,
      ),
    );
    if (range == null) return;
    // The plan day follows the date until one is picked for it.
    setState(() {
      _date = range.start;
      _dayIndex = null;
    });
  }

  Future<void> _create(WorkoutPlan plan, int dayIndex) async {
    setState(() => _creating = true);
    final repo = ref.read(workoutRepositoryProvider);
    final sync = ref.read(remoteSyncServiceProvider);
    // A failed write gives the button back rather than leaving it disabled.
    try {
      final planned = await plannedExercisesForDay(
        repo,
        planId: plan.id,
        dayIndex: dayIndex,
      );
      if (planned.isEmpty) return;
      final now = utcNow();
      final session = WorkoutSession(
        id: newId(),
        planId: plan.id,
        dayIndex: dayIndex,
        date: workoutStoredDate(_date),
        startedAt: now,
        endedAt: now,
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
      await repo.createSessionWithLogs(session, logs);
      sync.pushWorkoutSession(session);
      unawaited(sync.pushWorkoutSetLogsBatch(logs));
      if (!mounted) return;
      invalidateWorkoutProvidersFrom(ref);
      widget.onCreated(session.id);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
    );
    final plans =
        ref.watch(workoutPlansProvider.settled).valueOrNull ?? const [];
    final active = ref.watch(activeWorkoutPlanProvider);
    final mode = _mode ?? active?.mode ?? WorkoutPlanMode.weekly;
    final plan = plans.where((p) => p.mode == mode).firstOrNull;
    final weekStartsOnMonday =
        ref.watch(settingsProvider.settled).valueOrNull?.weekStartsOnMonday ??
        true;
    final dayIndex = plan == null
        ? null
        : (_dayIndex ?? plan.dayIndexForDate(_date) ?? 0);
    final entries = plan == null
        ? const <WorkoutPlanEntry>[]
        : ref.watch(workoutPlanEntriesProvider(plan.id).settled).valueOrNull ??
              const <WorkoutPlanEntry>[];
    final exercises = {
      for (final e
          in ref.watch(exercisesProvider.settled).valueOrNull ?? const [])
        e.id: e,
    };
    final planned = [
      for (final e in [
        ...entries,
      ]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
        if (e.dayIndex == dayIndex && exercises.containsKey(e.exerciseId))
          exercises[e.exerciseId]!.name,
    ];
    final future = _date.isAfter(_today);
    final days = plan == null
        ? const <int>[]
        : plan.mode == WorkoutPlanMode.weekly
        ? (weekStartsOnMonday
              ? const [1, 2, 3, 4, 5, 6, 0]
              : const [0, 1, 2, 3, 4, 5, 6])
        : [for (var i = 0; i < plan.dayCount; i++) i];

    return Padding(
      padding: const EdgeInsets.all(VoyagerSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(title: 'Log past workout', onBack: widget.onBack),
          const SizedBox(height: VoyagerSpacing.lg),
          Text('Date', style: theme.textTheme.labelLarge),
          const SizedBox(height: VoyagerSpacing.sm),
          Builder(
            builder: (buttonContext) => GlassButton(
              dense: true,
              icon: const Icon(PhosphorIconsRegular.calendarBlank, size: 14),
              label: DateFormat.yMMMEd().format(_date),
              onPressed: () => _pickDate(buttonContext),
            ),
          ),
          const SizedBox(height: VoyagerSpacing.lg),
          Text('Plan day', style: theme.textTheme.labelLarge),
          const SizedBox(height: VoyagerSpacing.sm),
          Wrap(
            spacing: VoyagerSpacing.xs,
            runSpacing: VoyagerSpacing.xs,
            children: [
              for (final option in WorkoutPlanMode.values)
                SelectorPill(
                  label: option == WorkoutPlanMode.weekly ? 'Week' : 'Split',
                  isActive: mode == option,
                  fillWhenActive: true,
                  dense: true,
                  onTap: () => setState(() {
                    _mode = option;
                    _dayIndex = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: VoyagerSpacing.sm),
          Wrap(
            spacing: VoyagerSpacing.xs,
            runSpacing: VoyagerSpacing.xs,
            children: [
              for (final day in days)
                SelectorPill(
                  label: plan!.mode == WorkoutPlanMode.weekly
                      ? _weekdayNames[day]
                      : 'Day ${day + 1}',
                  isActive: day == dayIndex,
                  dense: true,
                  onTap: () => setState(() => _dayIndex = day),
                ),
            ],
          ),
          const SizedBox(height: VoyagerSpacing.md),
          Text(
            planned.isEmpty
                ? 'Nothing is planned for that day'
                : planned.join(' · '),
            style: muted,
          ),
          const SizedBox(height: VoyagerSpacing.xl),
          Row(
            children: [
              Expanded(
                child: Text(
                  future
                      ? "Can't log a workout in the future"
                      : 'Tick off the sets you did next.',
                  style: muted,
                ),
              ),
              GlassButton(
                label: 'Create',
                color: theme.colorScheme.primary,
                onPressed:
                    plan == null ||
                        dayIndex == null ||
                        planned.isEmpty ||
                        future ||
                        _creating
                    ? null
                    : () => _create(plan, dayIndex),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One logged set's fields while it is being edited.
class _EditSet {
  _EditSet(this.log, this.fields);

  WorkoutSetLog log;
  final List<SegmentFields> fields;

  List<SetSegment> get segments => [for (final f in fields) f.segment];
}

/// A finished session, edited where it is shown: the date, each set's
/// numbers and whether it was done, sets and exercises added or removed, or
/// the whole workout deleted.
///
/// Typed numbers write through on a pause, as the exercise detail view's do;
/// everything else writes at once.
class _SessionEditor extends ConsumerStatefulWidget {
  const _SessionEditor({
    super.key,
    required this.sessionId,
    required this.onBack,
  });

  final String sessionId;
  final VoidCallback onBack;

  @override
  ConsumerState<_SessionEditor> createState() => _SessionEditorState();
}

class _SessionEditorState extends ConsumerState<_SessionEditor> {
  static const _saveDebounce = Duration(milliseconds: 600);

  // Captured up front: the flush on dispose can't use the ref any more.
  late final WorkoutRepository _repo;
  late final RemoteSyncService _sync;
  late final void Function() _invalidate;
  late final WeightUnit _unit;
  late final Future<void> Function() _lifecycleFlushCallback;

  WorkoutSession? _session;
  Map<String, Exercise> _exercises = const {};
  final _sets = <_EditSet>[];
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(workoutRepositoryProvider);
    _sync = ref.read(remoteSyncServiceProvider);
    _invalidate = ref.read(workoutCacheInvalidatorProvider);
    _unit = ref.read(settingsProvider).valueOrNull?.weightUnit ?? WeightUnit.lb;
    _lifecycleFlushCallback = _lifecycleFlush;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
    unawaited(_load());
  }

  Future<void> _load() async {
    final session = await _repo.getSession(widget.sessionId);
    final logs = await _repo.listSetLogs(sessionId: widget.sessionId);
    final exercises = await _repo.listExercises(includeDeleted: true);
    if (!mounted) return;
    setState(() {
      _session = session;
      _exercises = {for (final e in exercises) e.id: e};
      _sets.addAll([for (final log in logs) _newSet(log)]);
    });
  }

  @override
  void dispose() {
    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
    _saveTimer?.cancel();
    unawaited(_flush());
    for (final set in _sets) {
      for (final fields in set.fields) {
        fields.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _lifecycleFlush() async {
    _saveTimer?.cancel();
    await _flush();
  }

  _EditSet _newSet(WorkoutSetLog log) {
    final set = _EditSet(log, []);
    for (final segment in log.allSegments) {
      set.fields.add(_newFields(segment));
    }
    return set;
  }

  SegmentFields _newFields(SetSegment segment) {
    final fields = SegmentFields(segment, _unit);
    // Leaving a field rewrites it to what is stored — a typed 99 reps lands
    // as $kMaxReps, and the field should say so.
    void onBlur() {
      if (fields.weightFocus.hasFocus || fields.repsFocus.hasFocus) return;
      fields.normalize(_unit);
      unawaited(_flush());
    }

    fields.weightFocus.addListener(onBlur);
    fields.repsFocus.addListener(onBlur);
    return fields;
  }

  void _onEdited(SegmentFields fields) {
    fields.parse(_unit);
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () => unawaited(_flush()));
  }

  /// Writes every set whose numbers differ from what is stored.
  Future<void> _flush() async {
    _saveTimer?.cancel();
    final changed = <WorkoutSetLog>[];
    for (final set in _sets) {
      final segments = set.segments;
      if (_sameSegments(segments, set.log.allSegments)) continue;
      set.log = set.log.copyWith(
        weightKg: segments.first.weightKg,
        reps: segments.first.reps,
        dropSegments: segments.sublist(1),
      );
      changed.add(set.log);
    }
    await _write(changed);
  }

  static bool _sameSegments(List<SetSegment> a, List<SetSegment> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _write(List<WorkoutSetLog> logs) async {
    if (logs.isEmpty) return;
    await _repo.upsertSetLogsBatch(logs);
    unawaited(_sync.pushWorkoutSetLogsBatch(logs));
    _invalidate();
  }

  Future<void> _toggleDone(_EditSet set) async {
    await _flush();
    final done = !set.log.completed;
    setState(
      () => set.log = set.log.copyWith(
        completed: done,
        completedAt: done ? utcNow() : null,
        clearCompletedAt: !done,
      ),
    );
    await _write([set.log]);
  }

  /// Appends a set to the placement at [order], seeded from its last set.
  Future<void> _addSet(int order) async {
    await _flush();
    final group = [
      for (final s in _sets)
        if (s.log.exerciseOrder == order) s.log,
    ];
    if (group.isEmpty || group.length >= kMaxSets) return;
    final template = group.last;
    final now = utcNow();
    final added = WorkoutSetLog(
      id: newId(),
      sessionId: template.sessionId,
      exerciseId: template.exerciseId,
      exerciseOrder: order,
      setIndex: group.map((s) => s.setIndex).reduce(math.max) + 1,
      weightKg: template.weightKg,
      reps: template.reps,
      plannedWeightKg: template.plannedWeightKg,
      plannedReps: template.plannedReps,
      dropSegments: template.dropSegments,
      plannedDropSegments: template.plannedDropSegments,
      createdAt: now,
      updatedAt: now,
    );
    final at = _sets.lastIndexWhere((s) => s.log.exerciseOrder == order) + 1;
    setState(() => _sets.insert(at, _newSet(added)));
    await _write([added]);
  }

  Future<void> _removeSet(_EditSet set) async {
    await _flush();
    setState(() => _sets.remove(set));
    _disposeAfterFrame(set.fields);
    await _repo.softDeleteSetLog(set.log.id);
    final tombstone = await _repo.getSetLog(set.log.id);
    if (tombstone != null) _sync.pushWorkoutSetLog(tombstone);
    _invalidate();
  }

  void _addDrop(_EditSet set) {
    if (set.fields.length - 1 >= kMaxDropsPerSet) return;
    setState(
      () => set.fields.add(
        _newFields(nextDropSegment(set.fields.last.segment, _unit)),
      ),
    );
    unawaited(_flush());
  }

  void _removeDrop(_EditSet set, int segment) {
    final removed = set.fields.removeAt(segment);
    setState(() {});
    _disposeAfterFrame([removed]);
    unawaited(_flush());
  }

  /// The removed row's fields are still mounted until the rebuild lands.
  void _disposeAfterFrame(List<SegmentFields> removed) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final fields in removed) {
        fields.dispose();
      }
    });
  }

  Future<void> _addExercise() async {
    final exercise = await showExercisePicker(context);
    if (exercise == null || !mounted) return;
    await _flush();
    final added = materialiseSetLogs(
      sessionId: widget.sessionId,
      exercise: exercise,
      order: _sets.isEmpty
          ? 0
          : _sets.map((s) => s.log.exerciseOrder).reduce(math.max) + 1,
      now: utcNow(),
    );
    setState(() {
      _exercises = {..._exercises, exercise.id: exercise};
      _sets.addAll([for (final log in added) _newSet(log)]);
    });
    await _write(added);
  }

  Future<void> _pickDate(BuildContext buttonContext) async {
    final session = _session;
    if (session == null) return;
    final accent = Theme.of(buttonContext).colorScheme.primary;
    final current = workoutCalendarDate(session.date);
    final range = await showContextualPopover<DateTimeRange>(
      context: buttonContext,
      buttonContext: buttonContext,
      width: 320,
      height: 380,
      accentColor: accent,
      builder: (_) => DateSelectorPopover(
        initialStartDate: current,
        initialEndDate: current,
        singleDateMode: true,
        accentColor: accent,
      ),
    );
    if (range == null || !mounted) return;
    if (range.start.isAfter(_today)) {
      showVoyagerToast(
        context,
        message: "Can't move a workout into the future",
      );
      return;
    }
    final updated = session.copyWith(date: workoutStoredDate(range.start));
    setState(() => _session = updated);
    await _repo.upsertSession(updated);
    _sync.pushWorkoutSession(updated);
    _invalidate();
  }

  Future<void> _delete() async {
    final session = _session;
    if (session == null) return;
    // Captured before the confirm: the delete takes this view away, and the
    // toast offering the undo has to outlive it.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete this workout?',
      message:
          'It and its sets move to the trash, and the day is no longer '
          'marked as worked out.',
    );
    if (!confirmed || !mounted) return;
    _saveTimer?.cancel();
    await _flush();
    widget.onBack();
    await softDeleteWithUndo(
      overlay: overlay,
      message: deletedMessage(
        DateFormat.yMMMEd().format(workoutCalendarDate(session.date)),
        fallback: 'workout',
      ),
      delete: () => deleteWorkoutSession(container, session.id),
      restore: () => restoreWorkoutSession(container, session.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = _session;
    final muted = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
    );
    final orders = <int>[];
    for (final set in _sets) {
      if (!orders.contains(set.log.exerciseOrder)) {
        orders.add(set.log.exerciseOrder);
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(VoyagerSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            title: 'Workout',
            onBack: widget.onBack,
            actions: [
              if (session != null)
                Builder(
                  builder: (buttonContext) => GlassButton(
                    dense: true,
                    icon: const Icon(
                      PhosphorIconsRegular.calendarBlank,
                      size: 14,
                    ),
                    label: DateFormat.yMMMEd().format(
                      workoutCalendarDate(session.date),
                    ),
                    tooltip: 'The day this workout counts toward',
                    onPressed: () => _pickDate(buttonContext),
                  ),
                ),
              if (session != null) const SizedBox(width: VoyagerSpacing.sm),
              IconButton(
                onPressed: session == null ? null : _delete,
                icon: const Icon(PhosphorIconsRegular.trash, size: 18),
                tooltip: 'Delete workout',
              ),
            ],
          ),
          const SizedBox(height: VoyagerSpacing.lg),
          for (final order in orders) ...[
            _exerciseHeader(theme, order),
            for (final set in _sets.where((s) => s.log.exerciseOrder == order))
              for (var seg = 0; seg < set.fields.length; seg++)
                _segmentRow(theme, muted, set, seg, order),
            const SizedBox(height: VoyagerSpacing.lg),
          ],
          TextButton.icon(
            onPressed: session == null ? null : _addExercise,
            icon: const Icon(PhosphorIconsRegular.plus, size: 14),
            label: const Text('Add exercise'),
          ),
        ],
      ),
    );
  }

  Widget _exerciseHeader(ThemeData theme, int order) {
    final first = _sets.firstWhere((s) => s.log.exerciseOrder == order);
    final count = _sets.where((s) => s.log.exerciseOrder == order).length;
    return Row(
      children: [
        Expanded(
          child: Text(
            _exercises[first.log.exerciseId]?.name ?? 'Exercise',
            style: theme.textTheme.labelLarge,
          ),
        ),
        IconButton(
          onPressed: count >= kMaxSets ? null : () => _addSet(order),
          icon: const Icon(PhosphorIconsRegular.plus, size: 14),
          tooltip: 'Add set',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _segmentRow(
    ThemeData theme,
    TextStyle? muted,
    _EditSet set,
    int seg,
    int order,
  ) {
    final position =
        _sets.where((s) => s.log.exerciseOrder == order).toList().indexOf(set) +
        1;
    final fields = set.fields[seg];
    return Padding(
      key: ObjectKey(fields),
      padding: const EdgeInsets.only(bottom: VoyagerSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: seg == 0
                ? Checkbox(
                    value: set.log.completed,
                    onChanged: (_) => _toggleDone(set),
                    visualDensity: VisualDensity.compact,
                  )
                : null,
          ),
          SizedBox(
            width: 72,
            child: Text(
              seg == 0 ? 'Set $position' : '  ↳ Drop $seg',
              style: muted,
            ),
          ),
          SegmentNumberField(
            controller: fields.weight,
            focusNode: fields.weightFocus,
            onChanged: (_) => _onEdited(fields),
            width: 104,
            hintText: '—',
            suffixText: _unit.label,
            formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: VoyagerSpacing.sm),
            child: Text('×', style: muted),
          ),
          SegmentNumberField(
            controller: fields.reps,
            focusNode: fields.repsFocus,
            onChanged: (_) => _onEdited(fields),
            width: 80,
            suffixText: 'reps',
            formatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          const SizedBox(width: VoyagerSpacing.sm),
          if (seg == 0) ...[
            IconButton(
              onPressed: set.fields.length - 1 >= kMaxDropsPerSet
                  ? null
                  : () => _addDrop(set),
              icon: const Icon(PhosphorIconsRegular.caretDown, size: 14),
              tooltip: 'Add drop',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              onPressed: () => _removeSet(set),
              icon: const Icon(PhosphorIconsRegular.trash, size: 14),
              tooltip: 'Remove set',
              visualDensity: VisualDensity.compact,
            ),
          ] else
            IconButton(
              onPressed: () => _removeDrop(set, seg),
              icon: const Icon(PhosphorIconsRegular.x, size: 14),
              tooltip: 'Remove drop',
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

/// Soft-deletes a finished session and its sets with one stamp, so the trash
/// lists them as one workout, and uploads every tombstone.
///
/// Takes a [ProviderContainer] because the undo is pressed after the editor
/// that asked for the delete has gone.
Future<void> deleteWorkoutSession(
  ProviderContainer container,
  String id,
) async {
  final repo = container.read(workoutRepositoryProvider);
  final sync = container.read(remoteSyncServiceProvider);
  await repo.softDeleteSession(id);
  final deleted = await repo.getSession(id);
  if (deleted != null) sync.pushWorkoutSession(deleted);
  final logs = await repo.listSetLogs(sessionId: id, includeDeleted: true);
  unawaited(
    sync.pushWorkoutSetLogsBatch([
      for (final log in logs)
        if (log.deletedAt != null) log,
    ]),
  );
  invalidateWorkoutProvidersIn(container);
}

/// Undoes [deleteWorkoutSession] through the trash, which brings back the
/// session and exactly the sets its delete took.
Future<void> restoreWorkoutSession(
  ProviderContainer container,
  String id,
) async {
  final trash = container.read(trashServiceProvider);
  final item = (await trash.list())
      .where(
        (i) =>
            i.kind.collection == FirestoreCollections.workoutSessions &&
            i.id == id,
      )
      .firstOrNull;
  if (item == null) throw const RestoreSuperseded();
  await trash.restore(item);
  invalidateWorkoutProvidersIn(container);
}
