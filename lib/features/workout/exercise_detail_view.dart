import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/chart_hover_bubble.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/workout/workout_units.dart';

/// How many performed days the volume heatmap shows. Days the exercise wasn't
/// trained are absent, so on a 4-day split this row spans roughly four months
/// of calendar time — which is the point.
const int kVolumeHeatmapDays = 30;

/// Width of the set rows — label, weight, reps and both row buttons — which is
/// what the sets column is held to when the charts sit beside it.
const double _setsColumnWidth = 400;

/// Narrowest the charts column may get before it moves below the sets instead.
const double _minChartsWidth = 360;

/// Widest the modal gets — room for the sets and charts side by side, and no
/// more, so it reads as a popup over the planner rather than a page.
const double _sheetMaxWidth = 960;

/// Opens a movement's analytics in a floating modal over a darkened
/// backdrop — the same chrome as tracking a LeetCode problem, sized to its
/// content instead of the window.
Future<void> openExerciseDetailView(BuildContext context, Exercise exercise) {
  final screenSize = MediaQuery.sizeOf(context);
  return showVoyagerModal<void>(
    context: context,
    kind: VoyagerSheetKind.editor,
    constraints: BoxConstraints(
      maxWidth: math.min(_sheetMaxWidth, screenSize.width * 0.96),
      maxHeight: screenSize.height * 0.9,
    ),
    // Closing is what saves here — every field on the card flushes on
    // dispose — so the chord closes the modal the same way the × does. The
    // scope holds focus itself: nothing on the card autofocuses, and with
    // nothing focused below it the chord would never reach the scope.
    builder: (sheetContext) => CtrlEnterToSubmitScope(
      onSubmit: () => Navigator.of(sheetContext).pop(),
      autofocus: true,
      child: _ExerciseDetailCard(
        exercise: exercise,
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
    ),
  );
}

class _ExerciseDetailCard extends ConsumerStatefulWidget {
  const _ExerciseDetailCard({required this.exercise, required this.onClose});

  final Exercise exercise;
  final VoidCallback onClose;

  @override
  ConsumerState<_ExerciseDetailCard> createState() =>
      _ExerciseDetailCardState();
}

class _ExerciseDetailCardState extends ConsumerState<_ExerciseDetailCard> {
  late final TextEditingController _cuesController = TextEditingController(
    text: widget.exercise.formCues,
  );

  // Captured up front, not read in dispose: WidgetRef is no longer usable by
  // then, and the last few keystrokes still have to reach the database.
  //
  // Assigned in initState rather than by a `late final` initialiser, which
  // only runs on first *use* — and the first use can be a flush triggered by
  // a child's dispose, which unmounts before this state does. Reading the ref
  // there throws.
  late final WorkoutRepository _repository;
  late final RemoteSyncService _sync;
  late final void Function() _invalidate;

  late Exercise _exercise = widget.exercise;
  Timer? _saveTimer;

  /// Closing the window runs `PendingFlushRegistry.flushAll()` and then
  /// destroys it, so a widget that only flushes from `dispose` never gets the
  /// chance: alt-F4 within the debounce discarded the edit before it had
  /// reached SQLite, let alone Firestore.
  late final Future<void> Function() _lifecycleFlushCallback;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(workoutRepositoryProvider);
    _sync = ref.read(remoteSyncServiceProvider);
    _invalidate = ref.read(workoutCacheInvalidatorProvider);
    _lifecycleFlushCallback = _lifecycleFlush;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
  }

  @override
  void dispose() {
    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
    _saveTimer?.cancel();
    // Unawaited here — `dispose` cannot await — but awaited from
    // [_lifecycleFlush], which is the path that has to finish before the
    // window is destroyed.
    unawaited(_flushCues());
    _cuesController.dispose();
    super.dispose();
  }

  Future<void> _lifecycleFlush() async {
    _saveTimer?.cancel();
    await _flushCues();
  }

  void _onCuesChanged(String _) {
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(_flushCues()),
    );
  }

  Future<void> _flushCues() async {
    final text = _cuesController.text;
    if (text == _exercise.formCues) return;
    await _save(_exercise.copyWith(formCues: text));
  }

  /// Writes the movement's planned sets — everywhere it is planned, since
  /// they live on the movement rather than on the day it was dropped on.
  ///
  /// Identical sets with no drops store as the plain uniform target, anything
  /// else as a custom recipe. The user only ever sees the list; which shape it
  /// is kept in follows from what is in it, so the planner card keeps reading
  /// "3 × 8" for a plain movement.
  ///
  /// Deliberately does no `setState`: the fields hold their own text while
  /// they are being typed in, and rebuilding the section under the caret would
  /// fight the user for the cursor.
  Future<void> _saveSets(List<SetPrescription> sets) {
    final first = sets.first.top;
    final uniform = sets.every((set) => !set.hasDrops && set.top == first);
    return _save(
      uniform
          ? _exercise.copyWith(
              prescriptionMode: WorkoutPrescriptionMode.inherit,
              setPrescriptions: const [],
              targetSets: sets.length,
              targetReps: first.reps,
              targetWeightKg: first.weightKg,
            )
          : _exercise.copyWith(
              prescriptionMode: WorkoutPrescriptionMode.custom,
              setPrescriptions: sets,
            ),
    );
  }

  /// Persists and pushes an edited copy of the movement. Deliberately does no
  /// `setState` of its own — [_flushCues] calls it from `dispose`, where that
  /// would throw.
  ///
  /// Returns the write rather than firing and forgetting it, so a flush at
  /// window-close can wait for it to land.
  Future<void> _save(Exercise updated) async {
    _exercise = updated;
    await _repository.upsertExercise(updated);
    _sync.pushExercise(updated);
    _invalidate();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final unit = settings?.weightUnit ?? WeightUnit.lb;
    final logsAsync = ref.watch(exerciseSetLogsProvider(widget.exercise.id));
    final sessionsAsync = ref.watch(workoutSessionsProvider);

    final history = () {
      final logs = logsAsync.valueOrNull;
      final sessions = sessionsAsync.valueOrNull;
      if (logs == null || sessions == null) return const <ExerciseDaySummary>[];
      return buildExerciseHistory(logs, {
        for (final s in sessions) s.id: s.date,
      });
    }();

    // Sized to its content: the modal hugs a short card and only scrolls once
    // the sets outgrow the height it is allowed.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(VoyagerSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _exercise.name,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(PhosphorIconsRegular.x, size: 20),
                tooltip: 'Close',
              ),
            ],
          ),
          const SizedBox(height: VoyagerSpacing.xs),
          _SummaryLine(history: history, unit: unit),
          const SizedBox(height: VoyagerSpacing.xl),
          LayoutBuilder(
            builder: (context, constraints) {
              final sets = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Sets', style: theme.textTheme.labelLarge),
                  // The sets live on the movement, so editing them here
                  // rewrites every day it is planned on — a global edit that
                  // looks local is exactly the kind of thing you only notice
                  // after it has rewritten your week.
                  Text(
                    'Applies to every day this movement is planned on',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.55,
                      ),
                    ),
                  ),
                  const SizedBox(height: VoyagerSpacing.sm),
                  _SetsSection(
                    exercise: _exercise,
                    unit: unit,
                    onChanged: _saveSets,
                  ),
                ],
              );
              final charts = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Weight per set', style: theme.textTheme.labelLarge),
                  const SizedBox(height: VoyagerSpacing.sm),
                  _WeightSparkline(history: history, unit: unit),
                  const SizedBox(height: VoyagerSpacing.xl),
                  Text(
                    'Volume · last $kVolumeHeatmapDays sessions',
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: VoyagerSpacing.sm),
                  _VolumeHeatmap(history: history, unit: unit),
                ],
              );
              // The set rows are a fixed width, so on a wide card they sit
              // beside the charts rather than above a strip of empty space.
              if (constraints.maxWidth <
                  _setsColumnWidth + VoyagerSpacing.xl + _minChartsWidth) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    sets,
                    const SizedBox(height: VoyagerSpacing.xl),
                    charts,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: _setsColumnWidth, child: sets),
                  const SizedBox(width: VoyagerSpacing.xl),
                  Expanded(child: charts),
                ],
              );
            },
          ),
          const SizedBox(height: VoyagerSpacing.xl),
          Text('Form cues', style: theme.textTheme.labelLarge),
          const SizedBox(height: VoyagerSpacing.sm),
          VoyagerTextField(
            controller: _cuesController,
            maxLines: 6,
            minLines: 3,
            onChanged: _onCuesChanged,
            decoration: const InputDecoration(
              hintText: 'Elbows tucked, pause on the chest…',
            ),
          ),
        ],
      ),
    );
  }
}

/// The movement's sets, edited where they are shown: one row per set, its
/// drops indented beneath it.
///
/// This replaces a uniform "target" row stacked over a read-only recipe that
/// opened a wheel sheet to edit. The two said the same thing twice, and the
/// one that could express drops was the one you couldn't touch. The planned
/// sets are now one list; whether they store as a uniform target or as a
/// custom recipe is the parent's concern, not something the user picks.
///
/// Writes are debounced the same way the form cues are, so the whole card
/// saves on one rhythm; adding or removing a row saves at once.
class _SetsSection extends StatefulWidget {
  const _SetsSection({
    required this.exercise,
    required this.unit,
    required this.onChanged,
  });

  final Exercise exercise;
  final WeightUnit unit;
  final Future<void> Function(List<SetPrescription> sets) onChanged;

  @override
  State<_SetsSection> createState() => _SetsSectionState();
}

class _SetsSectionState extends State<_SetsSection> {
  /// Matched to the form-cues field below so the card has one save rhythm.
  static const _saveDebounce = Duration(milliseconds: 600);

  late final List<List<_SegmentFields>> _sets = [
    for (final set
        in widget.exercise.isCustomPrescription
            ? widget.exercise.setPrescriptions
            : seedPrescriptionsFromExercise(widget.exercise))
      [for (final segment in set.segments) _newFields(segment)],
  ];

  /// What was last written, so a debounce that fires with nothing changed
  /// doesn't write.
  late List<SetPrescription> _saved;

  Timer? _saveTimer;

  /// `dispose` never runs when the window is closed, so a debounced edit
  /// would otherwise have nowhere to land.
  late final Future<void> Function() _lifecycleFlushCallback;

  @override
  void initState() {
    super.initState();
    _saved = _current;
    _lifecycleFlushCallback = _lifecycleFlush;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
  }

  Future<void> _lifecycleFlush() async {
    _saveTimer?.cancel();
    await _flush();
  }

  @override
  void dispose() {
    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
    _saveTimer?.cancel();
    _flush();
    for (final set in _sets) {
      for (final fields in set) {
        fields.dispose();
      }
    }
    super.dispose();
  }

  _SegmentFields _newFields(SetSegment segment) {
    final fields = _SegmentFields(segment, widget.unit);
    // Leaving a field rewrites it to what is stored — a typed 99 reps lands as
    // $kMaxReps, and the field should say so.
    void onBlur() {
      if (fields.weightFocus.hasFocus || fields.repsFocus.hasFocus) return;
      fields.normalize(widget.unit);
      _flush();
    }

    fields.weightFocus.addListener(onBlur);
    fields.repsFocus.addListener(onBlur);
    return fields;
  }

  List<SetPrescription> get _current => [
    for (final set in _sets)
      SetPrescription(segments: [for (final fields in set) fields.segment]),
  ];

  void _onEdited(_SegmentFields fields) {
    fields.parse(widget.unit);
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _flush);
  }

  /// Returns the write it started, or null when nothing changed, so a
  /// window-close flush can wait for it.
  Future<void>? _flush() {
    _saveTimer?.cancel();
    final current = _current;
    if (_samePrescriptions(current, _saved)) return null;
    _saved = current;
    return widget.onChanged(current);
  }

  static bool _samePrescriptions(
    List<SetPrescription> a,
    List<SetPrescription> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i].segments;
      final y = b[i].segments;
      if (x.length != y.length) return false;
      for (var j = 0; j < x.length; j++) {
        if (x[j] != y[j]) return false;
      }
    }
    return true;
  }

  void _addSet() {
    if (_sets.length >= kMaxSets) return;
    setState(() => _sets.add([_newFields(_sets.last.first.segment)]));
    _flush();
  }

  void _removeSet(int index) {
    if (_sets.length <= 1) return;
    final removed = _sets[index];
    setState(() => _sets.removeAt(index));
    _disposeAfterFrame(removed);
    _flush();
  }

  void _addDrop(int index) {
    final set = _sets[index];
    if (set.length - 1 >= kMaxDropsPerSet) return;
    setState(
      () => set.add(_newFields(nextDropSegment(set.last.segment, widget.unit))),
    );
    _flush();
  }

  void _removeDrop(int index, int segment) {
    final removed = _sets[index][segment];
    setState(() => _sets[index].removeAt(segment));
    _disposeAfterFrame([removed]);
    _flush();
  }

  /// The removed row's fields are still mounted until the rebuild lands, so
  /// their controllers and focus nodes outlive it by a frame.
  void _disposeAfterFrame(List<_SegmentFields> removed) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final fields in removed) {
        fields.dispose();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _sets.length; i++)
          for (var seg = 0; seg < _sets[i].length; seg++)
            Padding(
              key: ObjectKey(_sets[i][seg]),
              padding: const EdgeInsets.only(bottom: VoyagerSpacing.xs),
              child: Row(
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(
                      seg == 0 ? 'Set ${i + 1}' : '  ↳ Drop $seg',
                      style: muted,
                    ),
                  ),
                  _SegmentNumberField(
                    controller: _sets[i][seg].weight,
                    focusNode: _sets[i][seg].weightFocus,
                    onChanged: (_) => _onEdited(_sets[i][seg]),
                    width: 104,
                    hintText: '—',
                    suffixText: widget.unit.label,
                    formatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: VoyagerSpacing.sm,
                    ),
                    child: Text('×', style: muted),
                  ),
                  _SegmentNumberField(
                    controller: _sets[i][seg].reps,
                    focusNode: _sets[i][seg].repsFocus,
                    onChanged: (_) => _onEdited(_sets[i][seg]),
                    width: 80,
                    suffixText: 'reps',
                    formatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                  const SizedBox(width: VoyagerSpacing.sm),
                  if (seg == 0) ...[
                    IconButton(
                      onPressed: _sets[i].length - 1 >= kMaxDropsPerSet
                          ? null
                          : () => _addDrop(i),
                      icon: const Icon(
                        PhosphorIconsRegular.caretDown,
                        size: 14,
                      ),
                      tooltip: 'Add drop',
                      visualDensity: VisualDensity.compact,
                    ),
                    if (_sets.length > 1)
                      IconButton(
                        onPressed: () => _removeSet(i),
                        icon: const Icon(PhosphorIconsRegular.trash, size: 14),
                        tooltip: 'Remove set',
                        visualDensity: VisualDensity.compact,
                      ),
                  ] else
                    IconButton(
                      onPressed: () => _removeDrop(i, seg),
                      icon: const Icon(PhosphorIconsRegular.x, size: 14),
                      tooltip: 'Remove drop',
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
        const SizedBox(height: VoyagerSpacing.xs),
        GlassButton(
          dense: true,
          icon: const Icon(PhosphorIconsRegular.plus, size: 14),
          label: 'Add set',
          onPressed: _sets.length >= kMaxSets ? null : _addSet,
        ),
      ],
    );
  }
}

/// One weight × reps slice's fields and the numbers they stand for.
class _SegmentFields {
  _SegmentFields(SetSegment segment, WeightUnit unit)
    : weightKg = segment.weightKg,
      repsValue = segment.reps,
      weight = TextEditingController(
        text: segment.weightKg > 0
            ? unit.formatKilograms(segment.weightKg)
            : '',
      ),
      reps = TextEditingController(text: '${segment.reps}');

  double weightKg;
  int repsValue;
  final TextEditingController weight;
  final TextEditingController reps;
  final weightFocus = FocusNode();
  final repsFocus = FocusNode();

  SetSegment get segment => SetSegment(weightKg: weightKg, reps: repsValue);

  /// Reads the fields into the numbers. Empty weight means "no planned load"
  /// (bodyweight), which is a real answer and stores as zero; unparseable text
  /// keeps the last good number.
  ///
  /// Storage is kilograms but the field shows the user's unit rounded to a
  /// tenth, so parsing that text back lands a hair off the kilograms it was
  /// formatted from — 60 kg displays as 132.3 lb and returns as 60.01. If the
  /// text still reads the same, the stored number is kept exactly, or simply
  /// tabbing through the card would drift it.
  void parse(WeightUnit unit) {
    repsValue = (int.tryParse(reps.text.trim()) ?? repsValue).clamp(
      1,
      kMaxReps,
    );
    final text = weight.text.trim();
    final display = text.isEmpty ? 0.0 : double.tryParse(text);
    if (display == null) return;
    final parsed = unit.toKilograms(display.clamp(0, unit.max).toDouble());
    if (unit.formatKilograms(parsed) != unit.formatKilograms(weightKg)) {
      weightKg = parsed;
    }
  }

  /// Rewrites both fields to the numbers they stand for.
  void normalize(WeightUnit unit) {
    parse(unit);
    _setText(weight, weightKg > 0 ? unit.formatKilograms(weightKg) : '');
    _setText(reps, '$repsValue');
  }

  static void _setText(TextEditingController controller, String text) {
    if (controller.text == text) return;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void dispose() {
    weight.dispose();
    reps.dispose();
    weightFocus.dispose();
    repsFocus.dispose();
  }
}

class _SegmentNumberField extends StatelessWidget {
  const _SegmentNumberField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.formatters,
    required this.width,
    this.suffixText,
    this.hintText,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final List<TextInputFormatter> formatters;
  final double width;
  final String? suffixText;
  final String? hintText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: VoyagerTextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        onSubmitted: (_) => focusNode.unfocus(),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.next,
        inputFormatters: formatters,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        decoration: InputDecoration(
          isDense: true,
          hintText: hintText,
          suffixText: suffixText,
          suffixStyle: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
        ),
      ),
    );
  }
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine({required this.history, required this.unit});

  final List<ExerciseDaySummary> history;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
    );
    if (history.isEmpty) {
      return Text('No sets logged yet', style: muted);
    }
    final best = history
        .expand((d) => d.setWeightsKg)
        .fold<double>(0, math.max);
    final sessions = history.length;
    return Text(
      '$sessions session${sessions == 1 ? '' : 's'} · '
      'best ${unit.formatKilogramsWithUnit(best)}',
      style: muted,
    );
  }
}

/// Weight achieved on every completed set, oldest first.
///
/// One point per set rather than a per-session average, so a session where the
/// last set dropped 20 lb reads as the drop it was instead of being averaged
/// into a mild dip.
///
/// Hovering reads out the set under the pointer in the app's chart bubble —
/// the nearest point by x, so the whole plot height is a target rather than a
/// two-pixel line.
class _WeightSparkline extends StatefulWidget {
  const _WeightSparkline({required this.history, required this.unit});

  final List<ExerciseDaySummary> history;
  final WeightUnit unit;

  @override
  State<_WeightSparkline> createState() => _WeightSparklineState();
}

class _WeightSparklineState extends State<_WeightSparkline> {
  int? _hoverIndex;

  void _setHover(int? index) {
    if (index == _hoverIndex) return;
    setState(() => _hoverIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final points = [
      for (final day in widget.history)
        for (var i = 0; i < day.setWeightsKg.length; i++)
          (
            date: day.date,
            set: i + 1,
            weightKg: day.setWeightsKg[i],
            reps: day.setReps[i],
          ),
    ];
    if (points.length < 2) {
      return _ChartPlaceholder(
        height: 120,
        message: points.isEmpty
            ? 'Log a set to start the trend'
            : 'One set so far — two are needed for a trend',
      );
    }
    final values = [for (final p in points) p.weightKg];
    final hover = _hoverIndex != null && _hoverIndex! < points.length
        ? _hoverIndex
        : null;

    return SizedBox(
      height: 120,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          int indexAt(Offset position) =>
              (position.dx / (size.width / (points.length - 1))).round().clamp(
                0,
                points.length - 1,
              );

          return MouseRegion(
            onHover: (event) => _setHover(indexAt(event.localPosition)),
            onExit: (_) => _setHover(null),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SparklinePainter(
                      values: values,
                      hoverIndex: hover,
                      lineColor: theme.colorScheme.primary,
                      gridColor: VoyagerColors.of(context).chartGrid,
                    ),
                  ),
                ),
                if (hover != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomSingleChildLayout(
                        delegate: _HoverBubbleLayout(
                          anchor: _SparklinePainter.pointAt(
                            values,
                            hover,
                            size,
                          ),
                        ),
                        child: ChartHoverBubble(
                          periodLabel:
                              '${DateFormat('MMM d, yyyy').format(points[hover].date)}'
                              ' · set ${points[hover].set}',
                          valueLabel:
                              '${widget.unit.formatKilogramsWithUnit(points[hover].weightKg)}'
                              ' × ${points[hover].reps}',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.hoverIndex,
    required this.lineColor,
    required this.gridColor,
  });

  final List<double> values;
  final int? hoverIndex;
  final Color lineColor;
  final Color gridColor;

  /// Where point [i] of [values] lands in a plot of [size]. Shared with the
  /// hover bubble so it anchors to exactly the point that is drawn.
  static Offset pointAt(List<double> values, int i, Size size) {
    final lowest = values.reduce(math.min);
    final max = values.reduce(math.max);
    // The floor sits a little below the lightest set, so the lowest point
    // doesn't sit on the baseline and small changes read less steep.
    final min = lowest - (max - lowest) * 0.15;
    // A perfectly flat series has zero range; pad it so the line lands
    // mid-height instead of dividing by zero.
    final range = (max - min).abs() < 0.001 ? 1.0 : max - min;
    final dx = size.width / (values.length - 1);
    final t = (values[i] - min) / range;
    return Offset(i * dx, size.height - (t * (size.height - 12)) - 6);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      Paint()
        ..color = gridColor
        ..strokeWidth = 1,
    );

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final point = pointAt(values, i, size);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            lineColor.withValues(alpha: 0.22),
            lineColor.withValues(alpha: 0.0),
          ],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );

    final hover = hoverIndex;
    if (hover != null) {
      final point = pointAt(values, hover, size);
      canvas.drawLine(
        Offset(point.dx, 0),
        Offset(point.dx, size.height),
        Paint()
          ..color = gridColor
          ..strokeWidth = 1,
      );
      canvas.drawCircle(point, 4, Paint()..color = lineColor);
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.lineColor != lineColor ||
      old.gridColor != gridColor ||
      old.hoverIndex != hoverIndex ||
      !listEquals(old.values, values);

  static bool listEquals(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Centres a hover bubble horizontally on [anchor] and sits it just above.
/// Unclamped, like the analytics sparkline's: near an end it overhangs the
/// plot rather than sliding off the point it describes.
class _HoverBubbleLayout extends SingleChildLayoutDelegate {
  const _HoverBubbleLayout({required this.anchor});

  final Offset anchor;

  static const double _gap = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      const BoxConstraints();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    anchor.dx - childSize.width / 2,
    anchor.dy - _gap - childSize.height,
  );

  @override
  bool shouldRelayout(_HoverBubbleLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}

/// A row of rounded squares, one per day the exercise was performed, with
/// brightness tracking that day's total volume (Σ weight × reps). Hovering a
/// square reads out its day in the app's chart bubble.
class _VolumeHeatmap extends StatefulWidget {
  const _VolumeHeatmap({required this.history, required this.unit});

  final List<ExerciseDaySummary> history;
  final WeightUnit unit;

  @override
  State<_VolumeHeatmap> createState() => _VolumeHeatmapState();
}

class _VolumeHeatmapState extends State<_VolumeHeatmap> {
  final _stackKey = GlobalKey();

  /// The hovered day, and the top-centre of its square in the stack.
  ({ExerciseDaySummary day, Offset anchor})? _hover;

  void _enter(ExerciseDaySummary day, BuildContext squareContext) {
    final square = squareContext.findRenderObject() as RenderBox?;
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (square == null || stack == null) return;
    final anchor = stack.globalToLocal(
      square.localToGlobal(Offset(square.size.width / 2, 0)),
    );
    setState(() => _hover = (day: day, anchor: anchor));
  }

  /// Only the square still hovered may clear the bubble — the pointer enters
  /// the next square before it leaves the last.
  void _exit(ExerciseDaySummary day) {
    if (_hover?.day != day) return;
    setState(() => _hover = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);
    final accent = theme.colorScheme.primary;
    final history = widget.history;
    final unit = widget.unit;

    final recent = history.length <= kVolumeHeatmapDays
        ? history
        : history.sublist(history.length - kVolumeHeatmapDays);
    if (recent.isEmpty) {
      return _ChartPlaceholder(height: 30, message: 'No volume logged yet');
    }
    final maxVolume = recent.map((d) => d.volumeKg).fold<double>(0, math.max);
    final hover = _hover;
    final sets = hover?.day.setWeightsKg.length ?? 0;

    return Stack(
      key: _stackKey,
      clipBehavior: Clip.none,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final day in recent)
              Builder(
                builder: (squareContext) => MouseRegion(
                  onEnter: (_) => _enter(day, squareContext),
                  onExit: (_) => _exit(day),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      // Floor of 0.18 so a light day still reads as a day
                      // trained rather than dissolving into the background.
                      color: accent.withValues(
                        alpha: maxVolume <= 0
                            ? 0.18
                            : 0.18 + 0.82 * (day.volumeKg / maxVolume),
                      ),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(
                        color: hover?.day == day
                            ? VoyagerListItemSurface.focusBorderColor(context)
                            : colors.hairline,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (hover != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomSingleChildLayout(
                delegate: _HoverBubbleLayout(anchor: hover.anchor),
                child: ChartHoverBubble(
                  periodLabel: DateFormat('MMM d, yyyy').format(hover.day.date),
                  valueLabel:
                      '${NumberFormat.decimalPattern().format(unit.fromKilograms(hover.day.volumeKg).round())}'
                      ' ${unit.label} volume',
                  detailLabel: '$sets set${sets == 1 ? '' : 's'}',
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ChartPlaceholder extends StatelessWidget {
  const _ChartPlaceholder({required this.height, required this.message});

  final double height;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          message,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
          ),
        ),
      ),
    );
  }
}
