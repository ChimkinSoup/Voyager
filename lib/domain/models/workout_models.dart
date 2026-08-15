import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

export 'package:voyager/domain/models/enums.dart'
    show WorkoutPlanMode, WeightUnit;

/// Weight is stored in kilograms everywhere — table columns, Firestore
/// payloads, sparkline points — and converted only at the display edge. The
/// alternative (storing whatever unit was active at the time) would silently
/// rewrite history's meaning the moment the user flips the unit toggle.
const double kPoundsPerKilogram = 2.20462262185;

double kilogramsToPounds(double kg) => kg * kPoundsPerKilogram;

double poundsToKilograms(double lb) => lb / kPoundsPerKilogram;

/// Targets a brand-new movement starts life with.
const int kDefaultTargetSets = 3;
const int kDefaultTargetReps = 8;

/// Local calendar day an instant belongs to.
///
/// Drift stores every `DateTime` as UTC ISO-8601 text and hands it back in
/// UTC, so reading `.year/.month/.day` straight off a stored value silently
/// shifts the day for anyone west of Greenwich. Everything here that keys on a
/// day goes through this.
DateTime workoutDayKey(DateTime instant) {
  final local = instant.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// A movement in the library — the thing a "Bench Press" card refers to.
///
/// Every set the user ever performs points back at one of these, which is
/// what lets the detail view aggregate a single movement's whole history
/// regardless of which plan or day the set was logged under.
///
/// The movement also owns its target sets/reps/weight. That is deliberately
/// *not* per placement: pull-ups are pull-ups, so raising their weight has to
/// raise it on every day of every plan at once rather than on the one card the
/// user happened to right-click.
class Exercise extends SoftDeletable {
  const Exercise({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.formCues = '',
    this.colorValue,
    this.sortOrder = 0,
    this.targetSets = kDefaultTargetSets,
    this.targetReps = kDefaultTargetReps,
    this.targetWeightKg = 0,
  });

  final String name;

  /// Free-form pointers the user writes for themselves ("elbows tucked,
  /// pause on the chest"). Shown at the bottom of the detail view.
  final String formCues;
  final int? colorValue;
  final int sortOrder;

  /// What the user intends to lift for this movement, everywhere it appears.
  /// A session copies these onto its set logs at materialisation time, so
  /// editing them later never rewrites what past workouts were aiming at.
  final int targetSets;
  final int targetReps;
  final double targetWeightKg;

  Exercise copyWith({
    String? name,
    String? formCues,
    int? colorValue,
    bool clearColorValue = false,
    int? sortOrder,
    int? targetSets,
    int? targetReps,
    double? targetWeightKg,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return Exercise(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      formCues: formCues ?? this.formCues,
      colorValue: clearColorValue ? null : (colorValue ?? this.colorValue),
      sortOrder: sortOrder ?? this.sortOrder,
      targetSets: targetSets ?? this.targetSets,
      targetReps: targetReps ?? this.targetReps,
      targetWeightKg: targetWeightKg ?? this.targetWeightKg,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'formCues': formCues,
    'colorValue': colorValue,
    'sortOrder': sortOrder,
    'targetSets': targetSets,
    'targetReps': targetReps,
    'targetWeightKg': targetWeightKg,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
  };

  factory Exercise.fromJson(Map<String, dynamic> json) {
    return Exercise(
      id: json['id'] as String,
      name: json['name'] as String,
      formCues: json['formCues'] as String? ?? '',
      colorValue: json['colorValue'] as int?,
      sortOrder: json['sortOrder'] as int? ?? 0,
      targetSets: json['targetSets'] as int? ?? kDefaultTargetSets,
      targetReps: json['targetReps'] as int? ?? kDefaultTargetReps,
      targetWeightKg: (json['targetWeightKg'] as num?)?.toDouble() ?? 0,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null
          ? DateTime.parse(json['deletedAt'] as String).toUtc()
          : null,
    );
  }
}

/// A training plan. Exactly two exist — one [WorkoutPlanMode.weekly] and one
/// [WorkoutPlanMode.cycle] — and the planner's segmented pill switches which
/// one is on screen. [isActive] is the separate question of which one decides
/// what "today's workout" is for the island, the calendar icon and the
/// analytics stat; only one plan carries it at a time.
class WorkoutPlan extends SoftDeletable {
  const WorkoutPlan({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    required this.mode,
    this.cycleLength = 4,
    required this.cycleAnchor,
    this.isActive = false,
  });

  final String name;
  final WorkoutPlanMode mode;

  /// Number of days in one repetition of a [WorkoutPlanMode.cycle] plan.
  /// Ignored by weekly plans, which always have seven slots.
  final int cycleLength;

  /// Local calendar date that is Day 1 of the cycle. A cycle plan cannot
  /// resolve "which day is today" without one — see [dayIndexForDate].
  final DateTime cycleAnchor;
  final bool isActive;

  /// Number of day slots the planner renders for this plan.
  int get dayCount => mode == WorkoutPlanMode.weekly ? 7 : cycleLength;

  /// Which day slot [date] falls on, or null when the date precedes a cycle
  /// plan's anchor (nothing was planned yet, so nothing is due).
  ///
  /// Weekly plans index 0 = Sunday .. 6 = Saturday, matching
  /// `DateTime.weekday % 7`. Which column that lands in on screen is a
  /// presentation choice driven by `weekStartsOnMonday`, deliberately kept out
  /// of the stored index so flipping that setting never re-points existing
  /// plan entries at different weekdays.
  int? dayIndexForDate(DateTime date) {
    final day = workoutDayKey(date);
    if (mode == WorkoutPlanMode.weekly) return day.weekday % 7;
    final anchor = workoutDayKey(cycleAnchor);
    // Differenced as UTC calendar dates, not as local instants: a DST
    // boundary anywhere between anchor and today makes the local span 23 or
    // 25 hours, which truncates to the wrong whole-day count and slides the
    // entire cycle by a day.
    final elapsed = DateTime.utc(day.year, day.month, day.day)
        .difference(DateTime.utc(anchor.year, anchor.month, anchor.day))
        .inDays;
    if (elapsed < 0) return null;
    final length = cycleLength < 1 ? 1 : cycleLength;
    return elapsed % length;
  }

  WorkoutPlan copyWith({
    String? name,
    WorkoutPlanMode? mode,
    int? cycleLength,
    DateTime? cycleAnchor,
    bool? isActive,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return WorkoutPlan(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      mode: mode ?? this.mode,
      cycleLength: cycleLength ?? this.cycleLength,
      cycleAnchor: cycleAnchor ?? this.cycleAnchor,
      isActive: isActive ?? this.isActive,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mode': mode.name,
    'cycleLength': cycleLength,
    'cycleAnchor': cycleAnchor.toUtc().toIso8601String(),
    'isActive': isActive,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
  };

  factory WorkoutPlan.fromJson(Map<String, dynamic> json) {
    return WorkoutPlan(
      id: json['id'] as String,
      name: json['name'] as String,
      mode: WorkoutPlanMode.values.byName(json['mode'] as String? ?? 'weekly'),
      cycleLength: json['cycleLength'] as int? ?? 4,
      cycleAnchor: DateTime.parse(json['cycleAnchor'] as String).toUtc(),
      isActive: json['isActive'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null
          ? DateTime.parse(json['deletedAt'] as String).toUtc()
          : null,
    );
  }
}

/// One exercise placed on one day of a plan.
///
/// Purely a placement: which movement, which day, in what order. The
/// sets/reps/weight live on the [Exercise] itself so they stay global — this
/// row deliberately has no numbers of its own to fall out of step with them.
class WorkoutPlanEntry extends SoftDeletable {
  const WorkoutPlanEntry({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.planId,
    required this.dayIndex,
    required this.exerciseId,
    this.sortOrder = 0,
  });

  final String planId;
  final int dayIndex;
  final String exerciseId;
  final int sortOrder;

  WorkoutPlanEntry copyWith({
    String? planId,
    int? dayIndex,
    String? exerciseId,
    int? sortOrder,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return WorkoutPlanEntry(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      planId: planId ?? this.planId,
      dayIndex: dayIndex ?? this.dayIndex,
      exerciseId: exerciseId ?? this.exerciseId,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'planId': planId,
    'dayIndex': dayIndex,
    'exerciseId': exerciseId,
    'sortOrder': sortOrder,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
  };

  factory WorkoutPlanEntry.fromJson(Map<String, dynamic> json) {
    return WorkoutPlanEntry(
      id: json['id'] as String,
      planId: json['planId'] as String,
      dayIndex: json['dayIndex'] as int? ?? 0,
      exerciseId: json['exerciseId'] as String,
      sortOrder: json['sortOrder'] as int? ?? 0,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null
          ? DateTime.parse(json['deletedAt'] as String).toUtc()
          : null,
    );
  }
}

/// One performed (or in-progress) workout. A session with a null [endedAt] is
/// the live one — persisting it rather than holding it in memory is what lets
/// the floating island survive an app restart mid-workout.
class WorkoutSession extends SoftDeletable {
  const WorkoutSession({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    this.planId,
    this.dayIndex,
    required this.date,
    required this.startedAt,
    this.endedAt,
  });

  final String? planId;
  final int? dayIndex;

  /// Local calendar day the workout counts toward (midnight-normalised). Held
  /// separately from [startedAt] so a session started at 11pm and finished
  /// after midnight still lands on the day it belongs to.
  final DateTime date;
  final DateTime startedAt;
  final DateTime? endedAt;

  bool get isActive => endedAt == null && deletedAt == null;

  WorkoutSession copyWith({
    String? planId,
    bool clearPlanId = false,
    int? dayIndex,
    bool clearDayIndex = false,
    DateTime? date,
    DateTime? startedAt,
    DateTime? endedAt,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return WorkoutSession(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      planId: clearPlanId ? null : (planId ?? this.planId),
      dayIndex: clearDayIndex ? null : (dayIndex ?? this.dayIndex),
      date: date ?? this.date,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'planId': planId,
    'dayIndex': dayIndex,
    'date': date.toUtc().toIso8601String(),
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt?.toUtc().toIso8601String(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
  };

  factory WorkoutSession.fromJson(Map<String, dynamic> json) {
    return WorkoutSession(
      id: json['id'] as String,
      planId: json['planId'] as String?,
      dayIndex: json['dayIndex'] as int?,
      date: DateTime.parse(json['date'] as String).toUtc(),
      startedAt: DateTime.parse(json['startedAt'] as String).toUtc(),
      endedAt: json['endedAt'] != null
          ? DateTime.parse(json['endedAt'] as String).toUtc()
          : null,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null
          ? DateTime.parse(json['deletedAt'] as String).toUtc()
          : null,
    );
  }
}

/// One set within a session. Materialised up-front from the plan (so the
/// wheels have something to default to) and marked [completed] as the user
/// works through them.
///
/// [plannedWeightKg]/[plannedReps] are copied in at materialisation time
/// rather than read back through [WorkoutPlanEntry]: the plan can be edited
/// months later, and a past session's "did I hit my numbers?" has to stay
/// answerable against the numbers that were actually planned that day.
class WorkoutSetLog extends SoftDeletable {
  const WorkoutSetLog({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.sessionId,
    required this.exerciseId,
    required this.exerciseOrder,
    required this.setIndex,
    required this.weightKg,
    required this.reps,
    required this.plannedWeightKg,
    required this.plannedReps,
    this.completed = false,
    this.completedAt,
  });

  final String sessionId;
  final String exerciseId;

  /// Position of this set's exercise within the session, so the active view
  /// walks exercises in the order they were planned.
  final int exerciseOrder;
  final int setIndex;
  final double weightKg;
  final int reps;
  final double plannedWeightKg;
  final int plannedReps;
  final bool completed;
  final DateTime? completedAt;

  /// Whether the user moved off the planned numbers for this set — the
  /// condition the active view paints in the accent colour.
  bool get deviatesFromPlan =>
      (weightKg - plannedWeightKg).abs() > 0.001 || reps != plannedReps;

  double get volumeKg => weightKg * reps;

  WorkoutSetLog copyWith({
    double? weightKg,
    int? reps,
    bool? completed,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return WorkoutSetLog(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      sessionId: sessionId,
      exerciseId: exerciseId,
      exerciseOrder: exerciseOrder,
      setIndex: setIndex,
      weightKg: weightKg ?? this.weightKg,
      reps: reps ?? this.reps,
      plannedWeightKg: plannedWeightKg,
      plannedReps: plannedReps,
      completed: completed ?? this.completed,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'exerciseId': exerciseId,
    'exerciseOrder': exerciseOrder,
    'setIndex': setIndex,
    'weightKg': weightKg,
    'reps': reps,
    'plannedWeightKg': plannedWeightKg,
    'plannedReps': plannedReps,
    'completed': completed,
    'completedAt': completedAt?.toUtc().toIso8601String(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
  };

  factory WorkoutSetLog.fromJson(Map<String, dynamic> json) {
    return WorkoutSetLog(
      id: json['id'] as String,
      sessionId: json['sessionId'] as String,
      exerciseId: json['exerciseId'] as String,
      exerciseOrder: json['exerciseOrder'] as int? ?? 0,
      setIndex: json['setIndex'] as int? ?? 0,
      weightKg: (json['weightKg'] as num?)?.toDouble() ?? 0,
      reps: json['reps'] as int? ?? 0,
      plannedWeightKg: (json['plannedWeightKg'] as num?)?.toDouble() ?? 0,
      plannedReps: json['plannedReps'] as int? ?? 0,
      completed: json['completed'] as bool? ?? false,
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String).toUtc()
          : null,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null
          ? DateTime.parse(json['deletedAt'] as String).toUtc()
          : null,
    );
  }
}

/// One day's worth of a single exercise, as the detail view's heatmap and
/// sparkline consume it. Built by `buildExerciseHistory` from completed sets.
class ExerciseDaySummary {
  const ExerciseDaySummary({
    required this.date,
    required this.setWeightsKg,
    required this.volumeKg,
  });

  final DateTime date;

  /// Weight of every completed set that day, in performed order — the
  /// sparkline plots these points directly rather than a daily average, since
  /// the spec asks for per-set weight.
  final List<double> setWeightsKg;

  /// Σ weight × reps across the day's completed sets.
  final double volumeKg;
}

/// Groups [logs] (completed sets for one exercise) into per-day summaries,
/// oldest first.
///
/// Days the exercise wasn't performed are absent by construction, which is
/// exactly what the "last 30 days *of doing this exercise*" heatmap wants —
/// a 4-day split touching this movement once per cycle spans ~120 calendar
/// days across 30 squares.
List<ExerciseDaySummary> buildExerciseHistory(
  List<WorkoutSetLog> logs,
  Map<String, DateTime> sessionDates,
) {
  final byDay = <DateTime, List<WorkoutSetLog>>{};
  for (final log in logs) {
    if (!log.completed || log.deletedAt != null) continue;
    final sessionDate = sessionDates[log.sessionId];
    if (sessionDate == null) continue;
    (byDay[workoutDayKey(sessionDate)] ??= []).add(log);
  }

  final days = byDay.keys.toList()..sort();
  return [
    for (final day in days)
      () {
        final sets = byDay[day]!
          ..sort((a, b) {
            final byExercise = a.exerciseOrder.compareTo(b.exerciseOrder);
            return byExercise != 0
                ? byExercise
                : a.setIndex.compareTo(b.setIndex);
          });
        return ExerciseDaySummary(
          date: day,
          setWeightsKg: [for (final s in sets) s.weightKg],
          volumeKg: sets.fold<double>(0, (sum, s) => sum + s.volumeKg),
        );
      }(),
  ];
}
