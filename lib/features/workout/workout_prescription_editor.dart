import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/scroll_offset_isolate.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/workout_actions.dart';
import 'package:voyager/features/workout/workout_units.dart';
import 'package:voyager/features/workout/workout_wheel_pair.dart';

/// Result of the custom-sets editor.
typedef ExercisePrescriptionResult = ({
  List<SetPrescription> prescriptions,
  bool clearToInherit,
});

/// Edits a movement's set recipe — how many sets, at what numbers, and which
/// of them carry drops.
///
/// Like [showExerciseTargetEditor], this belongs to the movement rather than
/// to the day it was dropped on: a drop set is part of how the lift is
/// performed, so it follows the lift onto every day it is planned.
Future<ExercisePrescriptionResult?> showExercisePrescriptionEditor(
  BuildContext context, {
  required Exercise exercise,
  required WeightUnit unit,
}) {
  return showVoyagerModal<ExercisePrescriptionResult>(
    context: context,
    kind: VoyagerSheetKind.editor,
    builder: (ctx) =>
        _ExercisePrescriptionEditor(exercise: exercise, unit: unit),
  );
}

/// Opens the editor for [exercise] and writes back whichever of the two
/// answers it returns. Shared by the planner card's menu and the detail view,
/// so both edit the movement's one recipe.
Future<void> editExercisePrescription(
  BuildContext context,
  WidgetRef ref,
  Exercise exercise,
  WeightUnit unit,
) async {
  final result = await showExercisePrescriptionEditor(
    context,
    exercise: exercise,
    unit: unit,
  );
  if (result == null) return;
  final actions = WorkoutActions(ref);
  if (result.clearToInherit) {
    await actions.clearExercisePrescription(exercise);
  } else {
    await actions.saveExercisePrescription(
      exercise,
      prescriptions: result.prescriptions,
    );
  }
}

class _ExercisePrescriptionEditor extends StatefulWidget {
  const _ExercisePrescriptionEditor({
    required this.exercise,
    required this.unit,
  });

  final Exercise exercise;
  final WeightUnit unit;

  @override
  State<_ExercisePrescriptionEditor> createState() =>
      _ExercisePrescriptionEditorState();
}

class _ExercisePrescriptionEditorState
    extends State<_ExercisePrescriptionEditor> {
  late List<SetPrescription> _prescriptions;
  late int _focusedSet;
  late int _focusedSegment;

  /// Identity that survives a reorder. A `ReorderableListView` child has to
  /// keep the same key as it moves, and a [SetPrescription] has no id of its
  /// own — nor would one help, since two sets can hold identical numbers.
  late List<int> _setKeys;
  var _nextSetKey = 0;

  @override
  void initState() {
    super.initState();
    _prescriptions = widget.exercise.isCustomPrescription
        ? [
            for (final p in widget.exercise.setPrescriptions)
              SetPrescription(segments: [...p.segments]),
          ]
        : seedPrescriptionsFromExercise(widget.exercise);
    _setKeys = [for (final _ in _prescriptions) _nextSetKey++];
    _focusedSet = 0;
    _focusedSegment = 0;
  }

  SetSegment get _focused {
    final set = _prescriptions[_focusedSet];
    return set.segments[_focusedSegment.clamp(0, set.segments.length - 1)];
  }

  void _replaceFocused(SetSegment segment) {
    setState(() {
      final set = _prescriptions[_focusedSet];
      final segments = [...set.segments];
      // Clamped like [_focused], which is the segment the wheels are showing.
      segments[_focusedSegment.clamp(0, segments.length - 1)] = segment;
      _prescriptions[_focusedSet] = SetPrescription(segments: segments);
    });
  }

  void _addSet() {
    if (_prescriptions.length >= kMaxSets) return;
    final template = _prescriptions.isEmpty
        ? SetSegment(
            weightKg: widget.exercise.targetWeightKg,
            reps: widget.exercise.targetReps,
          )
        : _prescriptions.last.top;
    setState(() {
      _prescriptions = [
        ..._prescriptions,
        SetPrescription(segments: [template]),
      ];
      _setKeys = [..._setKeys, _nextSetKey++];
      _focusedSet = _prescriptions.length - 1;
      _focusedSegment = 0;
    });
  }

  void _removeSet(int index) {
    if (_prescriptions.length <= 1) return;
    setState(() {
      _prescriptions = [
        for (var i = 0; i < _prescriptions.length; i++)
          if (i != index) _prescriptions[i],
      ];
      _setKeys = [
        for (var i = 0; i < _setKeys.length; i++)
          if (i != index) _setKeys[i],
      ];
      // Removing a set above the focused one shifts it down by one; without
      // this the focus stays on an index that is now a different set.
      _focusedSet = (_focusedSet > index ? _focusedSet - 1 : _focusedSet).clamp(
        0,
        _prescriptions.length - 1,
      );
      _focusedSegment = 0;
    });
  }

  /// Drag-to-reorder. Wired to `onReorderItem`, which already accounts for the
  /// row being lifted out at [oldIndex], so [newIndex] needs no correction.
  void _reorderSet(int oldIndex, int newIndex) {
    if (newIndex == oldIndex) return;
    setState(() {
      _prescriptions.insert(newIndex, _prescriptions.removeAt(oldIndex));
      _setKeys.insert(newIndex, _setKeys.removeAt(oldIndex));
      // The wheels are dialling one particular set, and it has just moved:
      // follow it rather than leaving them pointed at whatever slid in.
      if (_focusedSet == oldIndex) {
        _focusedSet = newIndex;
      } else if (_focusedSet > oldIndex && _focusedSet <= newIndex) {
        _focusedSet -= 1;
      } else if (_focusedSet < oldIndex && _focusedSet >= newIndex) {
        _focusedSet += 1;
      }
    });
  }

  void _addDrop(int setIndex) {
    final set = _prescriptions[setIndex];
    if (set.drops.length >= kMaxDropsPerSet) return;
    final prev = set.segments.last;
    setState(() {
      _prescriptions[setIndex] = SetPrescription(
        segments: [...set.segments, nextDropSegment(prev, widget.unit)],
      );
      _focusedSet = setIndex;
      _focusedSegment = _prescriptions[setIndex].segments.length - 1;
    });
  }

  void _removeDrop(int setIndex, int segmentIndex) {
    if (segmentIndex <= 0) return;
    final set = _prescriptions[setIndex];
    setState(() {
      _prescriptions[setIndex] = SetPrescription(
        segments: [
          for (var i = 0; i < set.segments.length; i++)
            if (i != segmentIndex) set.segments[i],
        ],
      );
      if (_focusedSet == setIndex && _focusedSegment >= segmentIndex) {
        _focusedSegment = (_focusedSegment - 1).clamp(
          0,
          set.segments.length - 2,
        );
      }
    });
  }

  void _submit() {
    Navigator.of(context).pop((
      prescriptions: [
        for (final p in _prescriptions)
          SetPrescription(segments: [...p.segments]),
      ],
      clearToInherit: false,
    ));
  }

  Future<void> _clearToInherit() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Use the uniform target instead?',
      message:
          'This movement’s custom sets and drops will be discarded. It will go '
          'back to its plain sets × reps × weight target, everywhere it is '
          'planned.',
      confirmLabel: 'Use target',
    );
    if (!confirmed || !mounted) return;
    Navigator.of(
      context,
    ).pop((prescriptions: <SetPrescription>[], clearToInherit: true));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final focused = _focused;
    final sheet = Padding(
      padding: EdgeInsets.only(
        left: VoyagerSpacing.xl,
        right: VoyagerSpacing.xl,
        top: VoyagerSpacing.xl,
        bottom: VoyagerSpacing.xl + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (voyagerSheetDrags(VoyagerSheetKind.editor))
              const VoyagerSheetHandle(),
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
              weightKg: focused.weightKg,
              reps: focused.reps,
              unit: widget.unit,
              onWeightChanged: (kg) =>
                  _replaceFocused(focused.copyWith(weightKg: kg)),
              onRepsChanged: (reps) =>
                  _replaceFocused(focused.copyWith(reps: reps)),
            ),
            const SizedBox(height: VoyagerSpacing.md),
            Flexible(
              child: ScrollOffsetIsolate(
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  // The set card is one big tap target — every segment row picks
                  // the wheels' focus — so the whole tile can't also be the drag
                  // handle. The grip in each header is.
                  buildDefaultDragHandles: false,
                  itemCount: _prescriptions.length,
                  onReorderItem: _reorderSet,
                  itemBuilder: (context, setIndex) => _SetPrescriptionCard(
                    key: ValueKey(_setKeys[setIndex]),
                    index: setIndex,
                    prescription: _prescriptions[setIndex],
                    unit: widget.unit,
                    focusedSet: _focusedSet,
                    focusedSegment: _focusedSegment,
                    canReorder: _prescriptions.length > 1,
                    onFocus: (segment) => setState(() {
                      _focusedSet = setIndex;
                      _focusedSegment = segment;
                    }),
                    onAddDrop: () => _addDrop(setIndex),
                    onRemoveDrop: (segment) => _removeDrop(setIndex, segment),
                    onRemoveSet: () => _removeSet(setIndex),
                    canRemoveSet: _prescriptions.length > 1,
                  ),
                ),
              ),
            ),
            const SizedBox(height: VoyagerSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: GlassButton(
                icon: const Icon(PhosphorIconsRegular.plus, size: 14),
                label: 'Add set',
                dense: true,
                onPressed: _prescriptions.length >= kMaxSets ? null : _addSet,
              ),
            ),
            const SizedBox(height: VoyagerSpacing.lg),
            Row(
              children: [
                if (widget.exercise.isCustomPrescription)
                  GlassButton(
                    label: 'Use target',
                    dense: true,
                    onPressed: _clearToInherit,
                  ),
                const Spacer(),
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
      ),
    );
    return CtrlEnterToSubmitScope(onSubmit: _submit, child: sheet);
  }
}

class _SetPrescriptionCard extends StatelessWidget {
  const _SetPrescriptionCard({
    super.key,
    required this.index,
    required this.prescription,
    required this.unit,
    required this.focusedSet,
    required this.focusedSegment,
    required this.onFocus,
    required this.onAddDrop,
    required this.onRemoveDrop,
    required this.onRemoveSet,
    required this.canRemoveSet,
    required this.canReorder,
  });

  final int index;
  final SetPrescription prescription;
  final WeightUnit unit;
  final int focusedSet;
  final int focusedSegment;
  final ValueChanged<int> onFocus;
  final VoidCallback onAddDrop;
  final ValueChanged<int> onRemoveDrop;
  final VoidCallback onRemoveSet;
  final bool canRemoveSet;
  final bool canReorder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: VoyagerSpacing.md),
      child: DecoratedBox(
        decoration: BoxDecoration(
          // Opaque: a reordering row is lifted onto its own Material, and a
          // transparent card would show the list sliding underneath it.
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(VoyagerSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (canReorder)
                    ReorderableDragStartListener(
                      index: index,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Padding(
                          padding: const EdgeInsets.only(
                            right: VoyagerSpacing.xs,
                          ),
                          child: Icon(
                            PhosphorIconsRegular.dotsSixVertical,
                            size: 16,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.45,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Text('Set ${index + 1}', style: theme.textTheme.labelLarge),
                  const Spacer(),
                  if (canRemoveSet)
                    IconButton(
                      onPressed: onRemoveSet,
                      icon: const Icon(PhosphorIconsRegular.trash, size: 16),
                      tooltip: 'Remove set',
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              for (var seg = 0; seg < prescription.segments.length; seg++)
                _SegmentRow(
                  label: seg == 0 ? 'Top' : 'Drop $seg',
                  segment: prescription.segments[seg],
                  unit: unit,
                  selected: focusedSet == index && focusedSegment == seg,
                  onTap: () => onFocus(seg),
                  onRemove: seg == 0 ? null : () => onRemoveDrop(seg),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: prescription.drops.length >= kMaxDropsPerSet
                      ? null
                      : onAddDrop,
                  icon: const Icon(PhosphorIconsRegular.caretDown, size: 14),
                  label: const Text('Add drop'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentRow extends StatelessWidget {
  const _SegmentRow({
    required this.label,
    required this.segment,
    required this.unit,
    required this.selected,
    required this.onTap,
    this.onRemove,
  });

  final String label;
  final SetSegment segment;
  final WeightUnit unit;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: VoyagerSpacing.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: VoyagerSpacing.sm,
          vertical: VoyagerSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? accent : Colors.transparent),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              child: Text(label, style: theme.textTheme.labelMedium),
            ),
            Expanded(
              child: Text(
                '${unit.formatKilogramsWithUnit(segment.weightKg)}'
                ' × ${segment.reps}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (onRemove != null)
              IconButton(
                onPressed: onRemove,
                icon: const Icon(PhosphorIconsRegular.x, size: 14),
                tooltip: 'Remove drop',
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    );
  }
}
