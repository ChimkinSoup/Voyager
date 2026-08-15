import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/exercise_detail_view.dart';
import 'package:voyager/features/workout/workout_session_controller.dart';
import 'package:voyager/features/workout/workout_units.dart';
import 'package:voyager/features/workout/workout_wheel_pair.dart';

/// The expanded live workout: two wheels, the set list for the current
/// movement, and the controls to log it.
class ActiveWorkoutView extends ConsumerWidget {
  const ActiveWorkoutView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workoutSessionControllerProvider);
    final controller = ref.read(workoutSessionControllerProvider.notifier);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final unit = settings?.weightUnit ?? WeightUnit.lb;
    final theme = Theme.of(context);

    final set = state.currentSet;
    final exercise = state.currentExercise;

    return Material(
      color: theme.colorScheme.surface,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(state: state, controller: controller),
            if (set == null || exercise == null)
              const Padding(
                padding: EdgeInsets.all(VoyagerSpacing.xl),
                child: Text('Every set is done — finish when you are ready.'),
              )
            else
              Flexible(
                child: VoyagerScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    VoyagerSpacing.xl,
                    0,
                    VoyagerSpacing.xl,
                    VoyagerSpacing.xl,
                  ),
                  child: Column(
                    children: [
                      _CurrentExerciseTitle(exercise: exercise, state: state),
                      const SizedBox(height: VoyagerSpacing.md),
                      WorkoutWheelPair(
                        weightKg: set.weightKg,
                        reps: set.reps,
                        unit: unit,
                        deviatesFromPlan: set.deviatesFromPlan,
                        onInteraction: controller.cancelRest,
                        onWeightChanged: (kg) =>
                            controller.updateCurrentSet(weightKg: kg),
                        onRepsChanged: (reps) =>
                            controller.updateCurrentSet(reps: reps),
                      ),
                      if (set.deviatesFromPlan)
                        Padding(
                          padding: const EdgeInsets.only(
                            top: VoyagerSpacing.xs,
                          ),
                          child: Text(
                            'Planned '
                            '${unit.formatKilogramsWithUnit(set.plannedWeightKg)}'
                            ' × ${set.plannedReps} — just for today',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      const SizedBox(height: VoyagerSpacing.lg),
                      _SetCountField(
                        key: ValueKey(set.exerciseId),
                        count: state.currentExerciseSets.length,
                        onChanged: controller.setCurrentExerciseSetCount,
                      ),
                      const SizedBox(height: VoyagerSpacing.lg),
                      _SetRow(state: state, unit: unit, controller: controller),
                      const SizedBox(height: VoyagerSpacing.lg),
                      GlassButton(
                        icon: const Icon(PhosphorIconsFill.check, size: 16),
                        label: 'Complete set',
                        color: theme.colorScheme.primary,
                        onPressed: controller.completeCurrentSet,
                      ),
                      if (state.sessionExercises.length > 1) ...[
                        const SizedBox(height: VoyagerSpacing.lg),
                        _ExerciseStrip(state: state, controller: controller),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.controller});

  final ActiveWorkoutState state;
  final WorkoutSessionController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VoyagerSpacing.lg,
        VoyagerSpacing.md,
        VoyagerSpacing.sm,
        VoyagerSpacing.sm,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: controller.collapse,
            icon: const Icon(PhosphorIconsRegular.caretUp, size: 20),
            tooltip: 'Minimise to the island',
          ),
          Expanded(
            child: Text(
              '${state.completedCount} of ${state.logs.length} sets done',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          GlassButton(
            label: 'Finish',
            dense: true,
            color: theme.colorScheme.primary,
            onPressed: () => _finish(context),
          ),
          const SizedBox(width: VoyagerSpacing.xs),
          IconButton(
            onPressed: () => _discard(context),
            icon: const Icon(PhosphorIconsRegular.trash, size: 18),
            tooltip: 'Discard workout',
          ),
        ],
      ),
    );
  }

  Future<void> _finish(BuildContext context) async {
    final remaining = state.logs.length - state.completedCount;
    if (remaining > 0) {
      final confirmed = await showConfirmDialog(
        context,
        title: 'Finish with $remaining set${remaining == 1 ? '' : 's'} left?',
        message:
            'Unfinished sets stay unfinished — they will not count toward '
            'your volume.',
        confirmLabel: 'Finish',
      );
      if (!confirmed) return;
    }
    await controller.finish();
  }

  Future<void> _discard(BuildContext context) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Discard this workout?',
      message:
          'Everything logged in this session is removed, and the day will not '
          'be marked as worked out.',
    );
    if (!confirmed) return;
    await controller.discard();
  }
}

/// The movement being lifted. Tapping it opens the same zoomed analytics page
/// a card in the planner does — "tap an exercise, get its history" holds
/// everywhere, including mid-set.
class _CurrentExerciseTitle extends StatelessWidget {
  const _CurrentExerciseTitle({required this.exercise, required this.state});

  final Exercise exercise;
  final ActiveWorkoutState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sets = state.currentExerciseSets;
    final position = sets.indexWhere((s) => s.id == state.currentSet?.id) + 1;

    return Builder(
      builder: (titleContext) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openExerciseDetailView(
          titleContext,
          exercise,
          anchorRectFor(titleContext),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VoyagerSpacing.sm,
            vertical: VoyagerSpacing.xs,
          ),
          child: Column(
            children: [
              Text(exercise.name, style: theme.textTheme.headlineSmall),
              Text(
                'Set $position of ${sets.length}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sets is the one number that stays typed — the spec is explicit, and it is
/// the value you either know exactly or don't touch at all.
class _SetCountField extends StatefulWidget {
  const _SetCountField({
    super.key,
    required this.count,
    required this.onChanged,
  });

  final int count;
  final ValueChanged<int> onChanged;

  @override
  State<_SetCountField> createState() => _SetCountFieldState();
}

class _SetCountFieldState extends State<_SetCountField> {
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.count}',
  );

  @override
  void didUpdateWidget(covariant _SetCountField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only reflect an external change (a set added, or a shrink refused
    // because a set was already logged) — never overwrite what is being typed.
    if (widget.count != oldWidget.count &&
        _controller.text != '${widget.count}') {
      _controller.text = '${widget.count}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = int.tryParse(_controller.text.trim());
    if (value == null || value < 1) {
      _controller.text = '${widget.count}';
      return;
    }
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('Sets', style: theme.textTheme.labelLarge),
        const SizedBox(width: VoyagerSpacing.md),
        SizedBox(
          width: 76,
          child: VoyagerTextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: VoyagerSpacing.sm),
        IconButton(
          onPressed: _submit,
          icon: const Icon(PhosphorIconsRegular.check, size: 16),
          tooltip: 'Apply set count',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

/// One chip per set of the current exercise. Completed sets show what was
/// actually lifted, so glancing down answers "what did I just do?".
class _SetRow extends StatelessWidget {
  const _SetRow({
    required this.state,
    required this.unit,
    required this.controller,
  });

  final ActiveWorkoutState state;
  final WeightUnit unit;
  final WorkoutSessionController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);
    final accent = theme.colorScheme.primary;
    final currentId = state.currentSet?.id;

    return Wrap(
      spacing: VoyagerSpacing.sm,
      runSpacing: VoyagerSpacing.sm,
      alignment: WrapAlignment.center,
      children: [
        for (final (index, set) in state.currentExerciseSets.indexed)
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => set.completed
                ? controller.uncompleteSet(set.id)
                : controller.focusSet(set.id),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: VoyagerSpacing.md,
                vertical: VoyagerSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: set.completed
                    ? accent.withValues(alpha: 0.16)
                    : theme.colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.5,
                      ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  // Same focus outline sidebar rows and calendar bars use for
                  // "this is the one you're on", carried at 1.5px so it still
                  // outweighs the hairline on the sets either side.
                  color: set.id == currentId
                      ? VoyagerListItemSurface.focusBorderColor(context)
                      : colors.hairline,
                  width: set.id == currentId ? 1.5 : 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    set.completed
                        ? PhosphorIconsFill.checkCircle
                        : PhosphorIconsRegular.circle,
                    size: 14,
                    color: set.completed
                        ? accent
                        : theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                  const SizedBox(width: VoyagerSpacing.xs),
                  Text(
                    set.completed
                        ? '${unit.formatKilograms(set.weightKg)} × ${set.reps}'
                        : 'Set ${index + 1}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: set.deviatesFromPlan && set.completed
                          ? accent
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Jump between the movements planned for this session.
class _ExerciseStrip extends StatelessWidget {
  const _ExerciseStrip({required this.state, required this.controller});

  final ActiveWorkoutState state;
  final WorkoutSessionController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);
    final currentExerciseId = state.currentSet?.exerciseId;

    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final exercise in state.sessionExercises)
            Padding(
              padding: const EdgeInsets.only(right: VoyagerSpacing.sm),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () {
                  // Land on the first set of that exercise still to be done,
                  // falling back to its first set once it's all logged.
                  final sets = state.logs.where(
                    (l) => l.exerciseId == exercise.id,
                  );
                  if (sets.isEmpty) return;
                  final target = sets.firstWhere(
                    (l) => !l.completed,
                    orElse: () => sets.first,
                  );
                  controller.focusSet(target.id);
                },
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(
                    horizontal: VoyagerSpacing.md,
                  ),
                  decoration: BoxDecoration(
                    color: exercise.id == currentExerciseId
                        ? theme.colorScheme.primary.withValues(alpha: 0.14)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: exercise.id == currentExerciseId
                          ? theme.colorScheme.primary.withValues(alpha: 0.6)
                          : colors.hairline,
                    ),
                  ),
                  child: Text(
                    exercise.name,
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
