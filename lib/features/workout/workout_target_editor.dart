import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/workout_wheel_pair.dart';

/// What the user dialled in for a movement.
typedef ExerciseTarget = ({int sets, int reps, double weightKg});

/// Edits one movement's target sets, reps and weight.
///
/// The target belongs to the movement, not to the day it was dropped on, so
/// saving here changes every placement of it across both plans at once. The
/// sheet says so out loud — a global edit that looks local is the kind of
/// thing you only discover after it has quietly rewritten your week.
///
/// Reps and weight get the wheels; sets is a typed field, as the spec asks —
/// it is the one number you nearly always know exactly and rarely nudge.
Future<ExerciseTarget?> showExerciseTargetEditor(
  BuildContext context, {
  required Exercise exercise,
  required WeightUnit unit,
}) {
  return showVoyagerSheet<ExerciseTarget>(
    context: context,
    builder: (ctx) => _ExerciseTargetEditor(exercise: exercise, unit: unit),
  );
}

class _ExerciseTargetEditor extends StatefulWidget {
  const _ExerciseTargetEditor({required this.exercise, required this.unit});

  final Exercise exercise;
  final WeightUnit unit;

  @override
  State<_ExerciseTargetEditor> createState() => _ExerciseTargetEditorState();
}

class _ExerciseTargetEditorState extends State<_ExerciseTargetEditor> {
  late final TextEditingController _setsController = TextEditingController(
    text: '${widget.exercise.targetSets}',
  );
  late int _reps = widget.exercise.targetReps;
  late double _weightKg = widget.exercise.targetWeightKg;

  @override
  void dispose() {
    _setsController.dispose();
    super.dispose();
  }

  void _submit() {
    final sets =
        int.tryParse(_setsController.text.trim()) ?? widget.exercise.targetSets;
    Navigator.of(context).pop((
      sets: sets.clamp(1, kMaxSets),
      reps: _reps,
      weightKg: _weightKg,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: VoyagerSpacing.xl,
        right: VoyagerSpacing.xl,
        top: VoyagerSpacing.xl,
        bottom: VoyagerSpacing.xl + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.exercise.name,
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: VoyagerSpacing.xs),
          Text(
            'Applies to every day this movement is planned on',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: VoyagerSpacing.lg),
          WorkoutWheelPair(
            weightKg: _weightKg,
            reps: _reps,
            unit: widget.unit,
            onWeightChanged: (kg) => setState(() => _weightKg = kg),
            onRepsChanged: (reps) => setState(() => _reps = reps),
          ),
          const SizedBox(height: VoyagerSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Sets', style: theme.textTheme.labelLarge),
              const SizedBox(width: VoyagerSpacing.md),
              SizedBox(
                width: 88,
                child: VoyagerTextField(
                  controller: _setsController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: (_) => _submit(),
                ),
              ),
            ],
          ),
          const SizedBox(height: VoyagerSpacing.xl),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GlassButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(),
                dense: true,
              ),
              const SizedBox(width: VoyagerSpacing.sm),
              GlassButton(
                label: 'Save',
                onPressed: _submit,
                color: theme.colorScheme.primary,
                dense: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
