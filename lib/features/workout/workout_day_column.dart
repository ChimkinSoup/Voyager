import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/exercise_detail_view.dart';
import 'package:voyager/features/workout/workout_actions.dart';
import 'package:voyager/features/workout/workout_target_editor.dart';
import 'package:voyager/features/workout/workout_exercise_panel.dart';
import 'package:voyager/features/workout/workout_units.dart';

/// An entry being dragged off one day toward another.
class PlanEntryDragData {
  const PlanEntryDragData(this.entry);

  final WorkoutPlanEntry entry;
}

/// One day slot of a plan: a drop target with the exercises planned on it.
///
/// Used unchanged by both planner modes — the week grid lays seven of these
/// out in a row, the split timeline scrolls N of them horizontally. Only the
/// header text differs, which is why it comes in as a parameter rather than
/// being derived here.
class WorkoutDayColumn extends ConsumerStatefulWidget {
  const WorkoutDayColumn({
    super.key,
    required this.planId,
    required this.dayIndex,
    required this.title,
    this.subtitle,
    required this.entries,
    required this.allEntries,
    required this.exercisesById,
    required this.unit,
    this.isToday = false,
    this.onStart,
  });

  final String planId;
  final int dayIndex;
  final String title;
  final String? subtitle;

  /// Entries on this day, already ordered.
  final List<WorkoutPlanEntry> entries;

  /// Every entry in the plan — needed to work out the next sort order on the
  /// receiving day when something is dropped.
  final List<WorkoutPlanEntry> allEntries;

  final Map<String, Exercise> exercisesById;
  final WeightUnit unit;
  final bool isToday;

  /// Null when this day can't be started right now (nothing planned, or a
  /// workout is already live).
  final VoidCallback? onStart;

  @override
  ConsumerState<WorkoutDayColumn> createState() => _WorkoutDayColumnState();
}

class _WorkoutDayColumnState extends ConsumerState<WorkoutDayColumn> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);
    final accent = theme.colorScheme.primary;

    return DragTarget<Object>(
      onWillAcceptWithDetails: (details) {
        final data = details.data;
        return data is ExerciseDragData || data is PlanEntryDragData;
      },
      onAcceptWithDetails: (details) => _accept(details.data),
      onMove: (_) {
        if (!_hovering) setState(() => _hovering = true);
      },
      onLeave: (_) {
        if (_hovering) setState(() => _hovering = false);
      },
      builder: (context, candidate, rejected) {
        final active = _hovering && candidate.isNotEmpty;
        return AnimatedContainer(
          duration: VoyagerMotion.reduced(context)
              ? Duration.zero
              : const Duration(milliseconds: 160),
          curve: VoyagerSpring.snappyCurve,
          padding: const EdgeInsets.all(VoyagerSpacing.sm),
          decoration: BoxDecoration(
            color: active
                ? accent.withValues(alpha: 0.10)
                : theme.colorScheme.surface.withValues(alpha: 0.32),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active
                  ? accent.withValues(alpha: 0.75)
                  : widget.isToday
                  ? accent.withValues(alpha: 0.4)
                  : colors.hairline,
              width: active ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(theme, accent),
              const SizedBox(height: VoyagerSpacing.sm),
              Expanded(
                child: widget.entries.isEmpty
                    ? _EmptyDayHint(active: active)
                    : ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: widget.entries.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: VoyagerSpacing.xs),
                        itemBuilder: (context, i) => _PlanEntryCard(
                          entry: widget.entries[i],
                          exercise:
                              widget.exercisesById[widget.entries[i].exerciseId],
                          unit: widget.unit,
                          allEntries: widget.allEntries,
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(ThemeData theme, Color accent) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: widget.isToday
                      ? accent
                      : theme.colorScheme.onSurface.withValues(alpha: 0.85),
                  fontWeight: widget.isToday ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
              if (widget.subtitle != null)
                Text(
                  widget.subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                  ),
                ),
            ],
          ),
        ),
        if (widget.onStart != null)
          IconButton(
            onPressed: widget.onStart,
            icon: const Icon(PhosphorIconsFill.play, size: 15),
            color: accent,
            tooltip: 'Start this workout',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
      ],
    );
  }

  Future<void> _accept(Object data) async {
    setState(() => _hovering = false);
    final actions = WorkoutActions(ref);
    if (data is ExerciseDragData) {
      await actions.addExerciseToDay(
        planId: widget.planId,
        dayIndex: widget.dayIndex,
        exerciseId: data.exercise.id,
        existing: widget.allEntries,
      );
    } else if (data is PlanEntryDragData) {
      await actions.movePlanEntry(
        entry: data.entry,
        dayIndex: widget.dayIndex,
        existing: widget.allEntries,
      );
    }
  }
}

class _EmptyDayHint extends StatelessWidget {
  const _EmptyDayHint({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        active ? 'Drop here' : 'Rest',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(
            alpha: active ? 0.8 : 0.32,
          ),
        ),
      ),
    );
  }
}

class _PlanEntryCard extends ConsumerWidget {
  const _PlanEntryCard({
    required this.entry,
    required this.exercise,
    required this.unit,
    required this.allEntries,
  });

  final WorkoutPlanEntry entry;

  /// Null if the exercise was deleted out from under the entry on another
  /// device before its tombstone arrived.
  final Exercise? exercise;
  final WeightUnit unit;
  final List<WorkoutPlanEntry> allEntries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = exercise;
    if (resolved == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);

    final card = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VoyagerSpacing.sm,
        vertical: VoyagerSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            resolved.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${resolved.targetSets} × ${resolved.targetReps}'
            '${resolved.targetWeightKg > 0 ? ' · ${unit.formatKilogramsWithUnit(resolved.targetWeightKg)}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );

    return ContextMenuRegion(
      itemsBuilder: () => [
        ContextMenuItem(
          label: 'Edit target everywhere',
          icon: PhosphorIconsRegular.slidersHorizontal,
          onTap: () => _edit(context, ref, resolved),
        ),
        ContextMenuItem(
          label: 'Remove from day',
          icon: PhosphorIconsRegular.trash,
          isDestructive: true,
          onTap: () => WorkoutActions(ref).deletePlanEntry(entry.id),
        ),
      ],
      child: Builder(
        builder: (cardContext) => Draggable<PlanEntryDragData>(
          data: PlanEntryDragData(entry),
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: _EntryDragFeedback(label: resolved.name),
          childWhenDragging: Opacity(opacity: 0.3, child: card),
          child: GestureDetector(
            onTap: () => openExerciseDetailView(
              cardContext,
              resolved,
              anchorRectFor(cardContext),
            ),
            onLongPress: () => _edit(cardContext, ref, resolved),
            child: card,
          ),
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Exercise resolved,
  ) async {
    final result = await showExerciseTargetEditor(
      context,
      exercise: resolved,
      unit: unit,
    );
    if (result == null) return;
    await WorkoutActions(ref).saveExerciseTarget(
      resolved,
      sets: result.sets,
      reps: result.reps,
      weightKg: result.weightKg,
    );
  }
}

class _EntryDragFeedback extends StatelessWidget {
  const _EntryDragFeedback({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);
    return Transform.translate(
      offset: const Offset(-56, -18),
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: VoyagerSpacing.md,
            vertical: VoyagerSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
            boxShadow: colors.surfaceShadow(blurRadius: 16),
          ),
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
      ),
    );
  }
}
