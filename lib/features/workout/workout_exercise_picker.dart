import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/workout_models.dart';

/// Asks for one movement from the library — for adding an unplanned exercise
/// to a session, live or past. Null when dismissed.
Future<Exercise?> showExercisePicker(BuildContext context) {
  return showVoyagerModal<Exercise>(
    context: context,
    constraints: const BoxConstraints(maxWidth: 360, maxHeight: 480),
    builder: (sheetContext) => const _ExercisePicker(),
  );
}

class _ExercisePicker extends ConsumerStatefulWidget {
  const _ExercisePicker();

  @override
  ConsumerState<_ExercisePicker> createState() => _ExercisePickerState();
}

class _ExercisePickerState extends ConsumerState<_ExercisePicker> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _filter.text.trim().toLowerCase();
    final exercises = [
      for (final e
          in ref.watch(exercisesProvider.settled).valueOrNull ??
              const <Exercise>[])
        if (e.name.toLowerCase().contains(query)) e,
    ];

    return Padding(
      padding: const EdgeInsets.all(VoyagerSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add exercise', style: theme.textTheme.titleMedium),
          const SizedBox(height: VoyagerSpacing.md),
          VoyagerTextField(
            controller: _filter,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            // Enter takes the only match, so typing a name is enough.
            onSubmitted: (_) {
              if (exercises.length == 1) {
                Navigator.of(context).pop(exercises.single);
              }
            },
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Filter',
              prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass, size: 16),
            ),
          ),
          const SizedBox(height: VoyagerSpacing.sm),
          Flexible(
            child: exercises.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(VoyagerSpacing.lg),
                    child: Text(
                      'No exercise matches',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final exercise in exercises)
                        ListTile(
                          dense: true,
                          title: Text(exercise.name),
                          onTap: () => Navigator.of(context).pop(exercise),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
