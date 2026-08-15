import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/exercise_detail_view.dart';
import 'package:voyager/features/workout/workout_actions.dart';
import 'package:voyager/features/workout/workout_name_modal.dart';

/// What a drag from the library carries. Wrapped in a type of its own so a
/// day column can tell "a new exercise from the panel" apart from "an entry
/// being moved off another day" without inspecting payload shape.
class ExerciseDragData {
  const ExerciseDragData(this.exercise);

  final Exercise exercise;
}

/// The persistent library. Vertical rail on desktop, horizontal strip on a
/// phone — the same cards either way, since what matters is that they are
/// always reachable while a day is in view.
class WorkoutExercisePanel extends ConsumerWidget {
  const WorkoutExercisePanel({
    super.key,
    required this.axis,
    required this.exercises,
  });

  final Axis axis;
  final List<Exercise> exercises;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);
    final horizontal = axis == Axis.horizontal;

    final header = Row(
      children: [
        Expanded(
          child: Text(
            'Exercises',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
        IconButton(
          onPressed: () => _createExercise(context, ref),
          icon: const Icon(PhosphorIconsRegular.plus, size: 18),
          tooltip: 'Add exercise',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );

    final cards = [
      for (final exercise in exercises)
        Padding(
          padding: horizontal
              ? const EdgeInsets.only(right: VoyagerSpacing.sm)
              : const EdgeInsets.only(bottom: VoyagerSpacing.sm),
          child: _DraggableExerciseCard(exercise: exercise),
        ),
    ];

    return Container(
      width: horizontal ? null : 208,
      padding: const EdgeInsets.all(VoyagerSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.hairline),
      ),
      child: horizontal
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                const SizedBox(height: VoyagerSpacing.sm),
                SizedBox(
                  height: 64,
                  child: exercises.isEmpty
                      ? const _EmptyLibraryHint()
                      : ListView(
                          scrollDirection: Axis.horizontal,
                          children: cards,
                        ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                const SizedBox(height: VoyagerSpacing.sm),
                Expanded(
                  child: exercises.isEmpty
                      ? const _EmptyLibraryHint()
                      : ListView(children: cards),
                ),
              ],
            ),
    );
  }

  Future<void> _createExercise(BuildContext context, WidgetRef ref) async {
    final name = await showWorkoutNameModal(
      context,
      title: 'New exercise',
      hintText: 'Bench Press',
    );
    if (name == null) return;
    await WorkoutActions(ref).createExercise(name, sortOrder: exercises.length);
  }
}

class _EmptyLibraryHint extends StatelessWidget {
  const _EmptyLibraryHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        'No exercises yet',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

class _DraggableExerciseCard extends ConsumerWidget {
  const _DraggableExerciseCard({required this.exercise});

  final Exercise exercise;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = ExerciseChip(exercise: exercise);
    return ContextMenuRegion(
      items: [
        ContextMenuItem(
          label: 'Rename',
          icon: PhosphorIconsRegular.pencilSimple,
          onTap: () => _rename(context, ref),
        ),
        ContextMenuItem(
          label: 'Delete',
          icon: PhosphorIconsRegular.trash,
          isDestructive: true,
          onTap: () => _delete(context, ref),
        ),
      ],
      child: Builder(
        builder: (cardContext) => Draggable<ExerciseDragData>(
          data: ExerciseDragData(exercise),
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: _DragFeedback(label: exercise.name),
          childWhenDragging: Opacity(opacity: 0.35, child: card),
          child: GestureDetector(
            onTap: () => openExerciseDetailView(
              cardContext,
              exercise,
              anchorRectFor(cardContext),
            ),
            child: card,
          ),
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await showWorkoutNameModal(
      context,
      title: 'Rename exercise',
      initialValue: exercise.name,
    );
    if (name == null) return;
    await WorkoutActions(ref).saveExercise(exercise.copyWith(name: name));
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete ${exercise.name}?',
      message:
          'It will be removed from every planned day. Sets you have already '
          'logged are kept, so its history stays intact.',
    );
    if (!confirmed) return;
    await WorkoutActions(ref).deleteExercise(exercise.id);
  }
}

/// The library's card face — also used as the drag feedback so the thing
/// under the pointer is the thing you picked up.
class ExerciseChip extends StatelessWidget {
  const ExerciseChip({super.key, required this.exercise});

  final Exercise exercise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);
    final tint = exercise.colorValue == null
        ? theme.colorScheme.primary
        : Color(exercise.colorValue!);

    return Container(
      constraints: const BoxConstraints(minWidth: 120),
      padding: const EdgeInsets.symmetric(
        horizontal: VoyagerSpacing.md,
        vertical: VoyagerSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 3,
            height: 18,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: VoyagerSpacing.sm),
          Flexible(
            child: Text(
              exercise.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);
    // Offset from the pointer so the card isn't hidden under the finger on a
    // touch screen; pointerDragAnchorStrategy puts the origin at the pointer.
    return Transform.translate(
      offset: const Offset(-60, -22),
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: VoyagerSpacing.md,
            vertical: VoyagerSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
            boxShadow: colors.surfaceShadow(blurRadius: 18),
          ),
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
      ),
    );
  }
}

/// Button that opens the "add exercise" flow from outside the panel.
class AddExerciseButton extends ConsumerWidget {
  const AddExerciseButton({super.key, required this.exerciseCount});

  final int exerciseCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GlassButton(
      dense: true,
      icon: const Icon(PhosphorIconsRegular.plus, size: 16),
      label: 'Exercise',
      onPressed: () async {
        final name = await showWorkoutNameModal(
          context,
          title: 'New exercise',
          hintText: 'Bench Press',
        );
        if (name == null) return;
        await WorkoutActions(ref).createExercise(name, sortOrder: exerciseCount);
      },
    );
  }
}
