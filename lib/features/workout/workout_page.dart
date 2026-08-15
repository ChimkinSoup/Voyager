import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/layout/window_size_class.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/workout_actions.dart';
import 'package:voyager/features/workout/workout_day_column.dart';
import 'package:voyager/features/workout/workout_exercise_panel.dart';
import 'package:voyager/features/workout/workout_session_controller.dart';

/// Which plan the planner is showing. Independent of which plan is *active*:
/// you can lay out a split while your weekly plan is still the one driving
/// today's workout, and only promote it when it's ready.
final workoutPlannerModeProvider = StateProvider<WorkoutPlanMode>(
  (ref) => WorkoutPlanMode.weekly,
);

class WorkoutPage extends ConsumerWidget {
  const WorkoutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plansAsync = ref.watch(workoutPlansProvider);
    final exercisesAsync = ref.watch(exercisesProvider);

    return plansAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (plans) => exercisesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (exercises) => _Planner(plans: plans, exercises: exercises),
      ),
    );
  }
}

class _Planner extends ConsumerWidget {
  const _Planner({required this.plans, required this.exercises});

  final List<WorkoutPlan> plans;
  final List<Exercise> exercises;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(workoutPlannerModeProvider);
    final weeklyPlan =
        plans.where((p) => p.mode == WorkoutPlanMode.weekly).firstOrNull;
    final cyclePlan =
        plans.where((p) => p.mode == WorkoutPlanMode.cycle).firstOrNull;
    final plan = mode == WorkoutPlanMode.weekly ? weeklyPlan : cyclePlan;
    if (plan == null || weeklyPlan == null || cyclePlan == null) {
      // Only reachable in the frame between seeding and the plan list
      // refreshing; a spinner is more honest than an empty board.
      return const Center(child: CircularProgressIndicator());
    }

    final settings = ref.watch(settingsProvider).valueOrNull;
    final unit = settings?.weightUnit ?? WeightUnit.lb;
    final weekStartsOnMonday = settings?.weekStartsOnMonday ?? true;
    final weeklyEntries =
        ref.watch(workoutPlanEntriesProvider(weeklyPlan.id)).valueOrNull ??
            const <WorkoutPlanEntry>[];
    final cycleEntries =
        ref.watch(workoutPlanEntriesProvider(cyclePlan.id)).valueOrNull ??
            const <WorkoutPlanEntry>[];
    final exercisesById = {for (final e in exercises) e.id: e};
    final compact = context.isCompactWidth;

    final board = VoyagerCrossfadeIndex(
      index: mode == WorkoutPlanMode.weekly ? 0 : 1,
      fadeIncoming: false,
      children: [
        _DayBoard(
          plan: weeklyPlan,
          entries: weeklyEntries,
          exercisesById: exercisesById,
          unit: unit,
          weekStartsOnMonday: weekStartsOnMonday,
        ),
        _DayBoard(
          plan: cyclePlan,
          entries: cycleEntries,
          exercisesById: exercisesById,
          unit: unit,
          weekStartsOnMonday: weekStartsOnMonday,
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            VoyagerSpacing.lg,
            VoyagerSpacing.lg,
            VoyagerSpacing.lg,
            VoyagerSpacing.md,
          ),
          child: _PlannerToolbar(plan: plan, exerciseCount: exercises.length),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VoyagerSpacing.lg,
            ),
            child: compact
                ? Column(
                    children: [
                      Expanded(child: board),
                      const SizedBox(height: VoyagerSpacing.md),
                      WorkoutExercisePanel(
                        axis: Axis.horizontal,
                        exercises: exercises,
                      ),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: board),
                      const SizedBox(width: VoyagerSpacing.md),
                      WorkoutExercisePanel(
                        axis: Axis.vertical,
                        exercises: exercises,
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: VoyagerSpacing.lg),
      ],
    );
  }
}

class _PlannerToolbar extends ConsumerWidget {
  const _PlannerToolbar({required this.plan, required this.exerciseCount});

  final WorkoutPlan plan;
  final int exerciseCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);
    final mode = ref.watch(workoutPlannerModeProvider);

    return Wrap(
      spacing: VoyagerSpacing.sm,
      runSpacing: VoyagerSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // The mode toggle: one capsule, two halves, the active one filled.
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: colors.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in WorkoutPlanMode.values) ...[
                if (option != WorkoutPlanMode.values.first)
                  const SizedBox(width: 3),
                SelectorPill(
                  label: option == WorkoutPlanMode.weekly ? 'Week' : 'Split',
                  isActive: mode == option,
                  fillWhenActive: true,
                  dense: true,
                  onTap: () => ref
                      .read(workoutPlannerModeProvider.notifier)
                      .state = option,
                ),
              ],
            ],
          ),
        ),
        if (plan.isActive)
          Chip(
            avatar: Icon(
              PhosphorIconsFill.circle,
              size: 10,
              color: theme.colorScheme.primary,
            ),
            label: const Text('Active plan'),
            visualDensity: VisualDensity.compact,
          )
        else
          GlassButton(
            dense: true,
            label: 'Make active',
            tooltip: 'Use this plan for today\'s workout, the calendar and '
                'the analytics stat',
            onPressed: () => WorkoutActions(ref).setActivePlan(plan.id),
          ),
        if (plan.mode == WorkoutPlanMode.cycle) ...[
          _CycleLengthControl(plan: plan),
          _CycleAnchorControl(plan: plan),
        ],
        AddExerciseButton(exerciseCount: exerciseCount),
        _StartTodayButton(plan: plan),
      ],
    );
  }
}

/// How many days one repetition of the split covers.
class _CycleLengthControl extends ConsumerWidget {
  const _CycleLengthControl({required this.plan});

  final WorkoutPlan plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);

    Future<void> setLength(int length) async {
      final clamped = length.clamp(2, 14);
      if (clamped == plan.cycleLength) return;
      await WorkoutActions(ref).savePlan(plan.copyWith(cycleLength: clamped));
      // Entries parked on a day that no longer exists are left alone rather
      // than deleted: lengthening the cycle again brings them straight back.
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: colors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () => setLength(plan.cycleLength - 1),
            icon: const Icon(PhosphorIconsRegular.minus, size: 14),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            tooltip: 'Shorter cycle',
          ),
          Text(
            '${plan.cycleLength}-day',
            style: theme.textTheme.labelMedium,
          ),
          IconButton(
            onPressed: () => setLength(plan.cycleLength + 1),
            icon: const Icon(PhosphorIconsRegular.plus, size: 14),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            tooltip: 'Longer cycle',
          ),
        ],
      ),
    );
  }
}

/// Which calendar date is Day 1. Without it a repeating split has no way to
/// know which of its days today is.
class _CycleAnchorControl extends ConsumerWidget {
  const _CycleAnchorControl({required this.plan});

  final WorkoutPlan plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final anchor = workoutDayKey(plan.cycleAnchor);
    return Builder(
      builder: (buttonContext) => GlassButton(
        dense: true,
        icon: const Icon(PhosphorIconsRegular.calendarBlank, size: 14),
        label: 'Day 1: ${anchor.month}/${anchor.day}',
        tooltip: 'The date the cycle starts counting from',
        onPressed: () async {
          final range = await showContextualPopover<DateTimeRange>(
            context: buttonContext,
            buttonContext: buttonContext,
            width: 320,
            height: 380,
            accentColor: Theme.of(buttonContext).colorScheme.primary,
            builder: (_) => DateSelectorPopover(
              initialStartDate: anchor,
              initialEndDate: anchor,
              singleDateMode: true,
              accentColor: Theme.of(buttonContext).colorScheme.primary,
            ),
          );
          if (range == null) return;
          final start = range.start;
          await WorkoutActions(ref).savePlan(
            plan.copyWith(
              cycleAnchor: DateTime(start.year, start.month, start.day),
            ),
          );
        },
      ),
    );
  }
}

/// Starts today's workout from whichever plan is active — not necessarily the
/// one on screen, which is why it reads the active plan rather than [plan].
class _StartTodayButton extends ConsumerWidget {
  const _StartTodayButton({required this.plan});

  final WorkoutPlan plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(
      workoutSessionControllerProvider.select((s) => s.isLive),
    );
    if (live) {
      return GlassButton(
        dense: true,
        icon: const Icon(PhosphorIconsFill.barbell, size: 15),
        label: 'Resume workout',
        color: Theme.of(context).colorScheme.primary,
        onPressed: () =>
            ref.read(workoutSessionControllerProvider.notifier).expand(),
      );
    }

    final active = ref.watch(activeWorkoutPlanProvider) ?? plan;
    final today = DateTime.now();
    final dayIndex = active.dayIndexForDate(today);

    return GlassButton(
      dense: true,
      icon: const Icon(PhosphorIconsFill.play, size: 14),
      label: 'Start today',
      color: Theme.of(context).colorScheme.primary,
      onPressed: dayIndex == null
          ? null
          : () => startWorkoutForDay(
              context,
              ref,
              plan: active,
              dayIndex: dayIndex,
              date: today,
            ),
    );
  }
}

/// Shared entry point for every "start this workout" affordance. Reports the
/// empty-day case rather than silently doing nothing.
Future<void> startWorkoutForDay(
  BuildContext context,
  WidgetRef ref, {
  required WorkoutPlan plan,
  required int dayIndex,
  required DateTime date,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final started = await ref
      .read(workoutSessionControllerProvider.notifier)
      .startFromPlan(plan: plan, dayIndex: dayIndex, date: date);
  if (started) return;
  messenger?.showSnackBar(
    const SnackBar(
      content: Text('Nothing is planned for that day yet'),
    ),
  );
}

/// The seven-column week, or the horizontally scrolling Day 1..N split.
class _DayBoard extends ConsumerWidget {
  const _DayBoard({
    required this.plan,
    required this.entries,
    required this.exercisesById,
    required this.unit,
    required this.weekStartsOnMonday,
  });

  final WorkoutPlan plan;
  final List<WorkoutPlanEntry> entries;
  final Map<String, Exercise> exercisesById;
  final WeightUnit unit;
  final bool weekStartsOnMonday;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(
      workoutSessionControllerProvider.select((s) => s.isLive),
    );
    final today = DateTime.now();
    final todayIndex = plan.dayIndexForDate(today);

    Widget columnFor(int dayIndex) {
      final dayEntries = [
        for (final entry in entries)
          if (entry.dayIndex == dayIndex) entry,
      ];
      return WorkoutDayColumn(
        planId: plan.id,
        dayIndex: dayIndex,
        title: _titleFor(dayIndex),
        subtitle: _subtitleFor(dayIndex, dayEntries.length),
        entries: dayEntries,
        allEntries: entries,
        exercisesById: exercisesById,
        unit: unit,
        isToday: plan.isActive && dayIndex == todayIndex,
        onStart: dayEntries.isEmpty || live
            ? null
            : () => startWorkoutForDay(
                context,
                ref,
                plan: plan,
                dayIndex: dayIndex,
                date: _dateForDay(dayIndex, today),
              ),
      );
    }

    if (plan.mode == WorkoutPlanMode.weekly) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final dayIndex in _weekOrder) ...[
            if (dayIndex != _weekOrder.first)
              const SizedBox(width: VoyagerSpacing.sm),
            Expanded(child: columnFor(dayIndex)),
          ],
        ],
      );
    }

    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: plan.dayCount,
      separatorBuilder: (_, _) => const SizedBox(width: VoyagerSpacing.sm),
      itemBuilder: (context, dayIndex) =>
          SizedBox(width: 190, child: columnFor(dayIndex)),
    );
  }

  /// Stored day indices are 0 = Sunday. The visual order is the only thing
  /// `weekStartsOnMonday` changes, so flipping the setting never re-points an
  /// entry at a different weekday.
  List<int> get _weekOrder =>
      weekStartsOnMonday ? const [1, 2, 3, 4, 5, 6, 0] : const [0, 1, 2, 3, 4, 5, 6];

  static const _weekdayNames = [
    'Sun',
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
  ];

  String _titleFor(int dayIndex) => plan.mode == WorkoutPlanMode.weekly
      ? _weekdayNames[dayIndex]
      : 'Day ${dayIndex + 1}';

  String? _subtitleFor(int dayIndex, int count) =>
      count == 0 ? null : '$count exercise${count == 1 ? '' : 's'}';

  /// The concrete date a column stands for, used as the started session's day.
  ///
  /// Weekly columns resolve to that weekday in the current week; split
  /// columns to the next occurrence of that slot, today included — starting
  /// Day 3 on a Day 1 means you are doing Day 3's workout today, so today is
  /// what gets recorded.
  DateTime _dateForDay(int dayIndex, DateTime today) {
    if (plan.mode != WorkoutPlanMode.weekly) return today;
    final delta = dayIndex - (today.weekday % 7);
    // Day arithmetic through the constructor, not `add(Duration(days:))`:
    // the latter adds 24h of real time and lands an hour off across a DST
    // boundary, which can spill the session onto the neighbouring date.
    return DateTime(today.year, today.month, today.day + delta);
  }
}
