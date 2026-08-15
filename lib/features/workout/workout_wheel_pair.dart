
import 'package:flutter/material.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/widgets/voyager_number_wheel.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/workout_units.dart';

/// The side-by-side weight and reps wheels — weight left, reps right.
///
/// [deviatesFromPlan] paints both numbers in the accent colour. That is the
/// whole point of the control: the wheels default to the planned load, and
/// the colour is what tells you at a glance that today is not the plan.
class WorkoutWheelPair extends StatelessWidget {
  const WorkoutWheelPair({
    super.key,
    required this.weightKg,
    required this.reps,
    required this.unit,
    required this.onWeightChanged,
    required this.onRepsChanged,
    this.deviatesFromPlan = false,
    this.onInteraction,
    this.itemHeight = 44,
    this.visibleItems = 5,
  });

  final double weightKg;
  final int reps;
  final WeightUnit unit;
  final ValueChanged<double> onWeightChanged;
  final ValueChanged<int> onRepsChanged;
  final bool deviatesFromPlan;
  final VoidCallback? onInteraction;
  final double itemHeight;
  final int visibleItems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final selectedColor = deviatesFromPlan ? accent : theme.colorScheme.onSurface;
    final selectedStyle = theme.textTheme.headlineSmall?.copyWith(
      color: selectedColor,
      fontWeight: FontWeight.w600,
      // Tabular figures: without them the whole column jitters sideways as
      // digits change under a flick.
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final unselectedStyle = theme.textTheme.titleMedium?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _WheelColumn(
          caption: unit.label,
          child: VoyagerNumberWheel(
            semanticLabel: 'Weight',
            width: 116,
            itemHeight: itemHeight,
            visibleItems: visibleItems,
            itemCount: unit.wheelItemCount,
            selectedIndex: unit.wheelIndexForKilograms(weightKg),
            labelForIndex: (i) => unit.formatDisplay(i * unit.step),
            onSelectedIndexChanged: (i) =>
                onWeightChanged(unit.kilogramsForWheelIndex(i)),
            onInteraction: onInteraction,
            selectedStyle: selectedStyle,
            unselectedStyle: unselectedStyle,
          ),
        ),
        const SizedBox(width: 8),
        _WheelColumn(
          caption: 'reps',
          child: VoyagerNumberWheel(
            semanticLabel: 'Reps',
            width: 84,
            itemHeight: itemHeight,
            visibleItems: visibleItems,
            itemCount: kMaxReps,
            selectedIndex: (reps - 1).clamp(0, kMaxReps - 1),
            labelForIndex: (i) => '${i + 1}',
            onSelectedIndexChanged: (i) => onRepsChanged(i + 1),
            onInteraction: onInteraction,
            selectedStyle: selectedStyle,
            unselectedStyle: unselectedStyle,
          ),
        ),
      ],
    );
  }
}

class _WheelColumn extends StatelessWidget {
  const _WheelColumn({required this.caption, required this.child});

  final String caption;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        Text(
          caption,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
  }
}
