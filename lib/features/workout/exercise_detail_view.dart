import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/workout/workout_units.dart';

/// How many performed days the volume heatmap shows. Days the exercise wasn't
/// trained are absent, so on a 4-day split this row spans roughly four months
/// of calendar time — which is the point.
const int kVolumeHeatmapDays = 30;

/// The on-screen rect of [context]'s render box, for the zoom to grow from.
///
/// Falls back to a zero-size rect at the origin if the box has gone away
/// between the tap and this call, which degrades the animation to a plain
/// grow-from-corner rather than throwing.
Rect anchorRectFor(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Rect.zero;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Opens a movement's analytics page with a camera-zoom growing out of
/// [anchorRect] — the same gesture the LeetCode detail view uses, so
/// "tapping a thing expands that thing" reads the same everywhere in the app.
Future<void> openExerciseDetailView(
  BuildContext context,
  Exercise exercise,
  Rect anchorRect,
) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) =>
          _ExerciseDetailOverlay(exercise: exercise, anchorRect: anchorRect),
    ),
  );
}

class _ExerciseDetailOverlay extends StatefulWidget {
  const _ExerciseDetailOverlay({
    required this.exercise,
    required this.anchorRect,
  });

  final Exercise exercise;
  final Rect anchorRect;

  @override
  State<_ExerciseDetailOverlay> createState() => _ExerciseDetailOverlayState();
}

class _ExerciseDetailOverlayState extends State<_ExerciseDetailOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    await _controller.reverse();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final fullScreenRect = Offset.zero & size;
    final reduced = VoyagerMotion.reduced(context);

    return Material(
      color: Colors.black.withValues(alpha: 0.001),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = reduced
              ? _controller.value
              : VoyagerSpring.moveCurve.transform(_controller.value);
          final scrim = Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.5 * t),
              ),
            ),
          );

          // Reduced motion drops the zoom entirely: the card arrives at full
          // size and only fades.
          if (reduced) {
            return Stack(
              children: [
                scrim,
                Positioned.fill(child: Opacity(opacity: t, child: child)),
              ],
            );
          }

          final rect = Rect.lerp(widget.anchorRect, fullScreenRect, t)!;
          return Stack(
            children: [
              scrim,
              // Laid out at full size and scaled by Transform rather than
              // resized: reflowing the sparkline and heatmap into the anchor's
              // starting width would overflow on the first frames.
              Positioned.fill(
                child: Transform(
                  alignment: Alignment.topLeft,
                  transform: Matrix4.identity()
                    ..translateByDouble(rect.left, rect.top, 0, 1)
                    ..scaleByDouble(
                      rect.width / fullScreenRect.width,
                      rect.height / fullScreenRect.height,
                      1,
                      1,
                    ),
                  child: Opacity(opacity: t, child: child),
                ),
              ),
            ],
          );
        },
        child: _ExerciseDetailCard(
          exercise: widget.exercise,
          onClose: _close,
        ),
      ),
    );
  }
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

  /// Dials in the sets/reps/weight this movement is planned at — everywhere it
  /// is planned, since the target lives on the movement rather than on the day
  /// it was dropped on.
  ///
  /// Deliberately does no `setState`: the fields hold their own text while they
  /// are being typed in, and rebuilding the section under the caret would fight
  /// the user for the cursor.
  Future<void> _saveTarget({
    required int sets,
    required int reps,
    required double weightKg,
  }) {
    return _save(
      _exercise.copyWith(
        targetSets: sets,
        targetReps: reps,
        targetWeightKg: weightKg,
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

    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(VoyagerSpacing.xl),
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
            Text('Target', style: theme.textTheme.labelLarge),
            // The target lives on the movement, so editing it here rewrites
            // every day it is planned on. That used to be a tooltip on an Edit
            // button; with the fields editable in place there is no button to
            // hang it on, and a global edit that looks local is exactly the
            // kind of thing you only notice after it has rewritten your week.
            Text(
              'Applies to every day this movement is planned on',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: VoyagerSpacing.sm),
            _TargetSection(
              exercise: _exercise,
              unit: unit,
              onChanged: _saveTarget,
            ),
            const SizedBox(height: VoyagerSpacing.xl),
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
      ),
    );
  }
}

/// The movement's planned numbers, editable where they are shown.
///
/// Editing here is the deliberate, sat-down path — as opposed to the wheels
/// mid-workout, which only ever bend a single session. Saving moves the
/// baseline itself, on every day the movement appears.
///
/// The numbers are live fields rather than a display that opens an editor:
/// there is nothing to confirm and nothing to dismiss, so changing a target is
/// the same gesture as reading one. Writes are debounced the same way the form
/// cues below are, so the whole card saves on one rhythm.
class _TargetSection extends StatefulWidget {
  const _TargetSection({
    required this.exercise,
    required this.unit,
    required this.onChanged,
  });

  final Exercise exercise;
  final WeightUnit unit;
  final Future<void> Function({
    required int sets,
    required int reps,
    required double weightKg,
  })
  onChanged;

  @override
  State<_TargetSection> createState() => _TargetSectionState();
}

class _TargetSectionState extends State<_TargetSection> {
  /// Matched to the form-cues field above so the card has one save rhythm.
  static const _saveDebounce = Duration(milliseconds: 600);

  late final _setsController = TextEditingController(
    text: '${widget.exercise.targetSets}',
  );
  late final _repsController = TextEditingController(
    text: '${widget.exercise.targetReps}',
  );
  late final _weightController = TextEditingController(
    text: widget.exercise.targetWeightKg > 0
        ? widget.unit.formatKilograms(widget.exercise.targetWeightKg)
        : '',
  );

  final _setsFocus = FocusNode();
  final _repsFocus = FocusNode();
  final _weightFocus = FocusNode();

  // What is actually on the row right now. Compared against on every flush so
  // a debounce that fires with nothing changed doesn't write, and so the
  // comparison doesn't drift against the stale `widget.exercise` the parent
  // deliberately never rebuilds us with.
  late int _savedSets = widget.exercise.targetSets;
  late int _savedReps = widget.exercise.targetReps;
  late double _savedWeightKg = widget.exercise.targetWeightKg;

  Timer? _saveTimer;

  /// Same reason as the form-cues field above: `dispose` never runs when the
  /// window is closed, so a debounced target edit had nowhere to land.
  late final Future<void> Function() _lifecycleFlushCallback;

  @override
  void initState() {
    super.initState();
    _lifecycleFlushCallback = _lifecycleFlush;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
    for (final node in [_setsFocus, _repsFocus, _weightFocus]) {
      node.addListener(() {
        // Leaving a field commits it immediately rather than waiting out the
        // debounce, and rewrites it to what was stored — a typed 999 sets
        // lands as $kMaxSets, and the field should say so.
        if (!node.hasFocus) _flush(normalize: true);
      });
    }
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
    _setsController.dispose();
    _repsController.dispose();
    _weightController.dispose();
    _setsFocus.dispose();
    _repsFocus.dispose();
    _weightFocus.dispose();
    super.dispose();
  }

  int get _parsedSets =>
      (int.tryParse(_setsController.text.trim()) ?? _savedSets)
          .clamp(1, kMaxSets);

  int get _parsedReps =>
      (int.tryParse(_repsController.text.trim()) ?? _savedReps)
          .clamp(1, kMaxReps);

  /// Empty means "no planned load" (bodyweight), which is a real answer and
  /// stores as zero — not a parse failure to fall back from.
  double get _parsedWeightKg {
    final text = _weightController.text.trim();
    if (text.isEmpty) return 0;
    final display = double.tryParse(text);
    if (display == null) return _savedWeightKg;
    return widget.unit.toKilograms(display.clamp(0, widget.unit.max));
  }

  void _onEdited(String _) {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _flush);
  }

  /// Returns the write it started, or null when nothing changed, so a
  /// window-close flush can wait for it.
  Future<void>? _flush({bool normalize = false}) {
    _saveTimer?.cancel();
    final sets = _parsedSets;
    final reps = _parsedReps;
    // Storage is kilograms but the field shows the user's unit rounded to a
    // tenth, so parsing that text back lands a hair off the kilograms it was
    // formatted from — 60 kg displays as 132.3 lb and returns as 60.01. Left
    // alone, simply opening and closing the card would drift the target. If
    // the text still reads the same, the stored number is kept exactly.
    final parsedWeightKg = _parsedWeightKg;
    final weightKg =
        widget.unit.formatKilograms(parsedWeightKg) ==
            widget.unit.formatKilograms(_savedWeightKg)
        ? _savedWeightKg
        : parsedWeightKg;

    if (normalize) {
      _setText(_setsController, '$sets');
      _setText(_repsController, '$reps');
      _setText(
        _weightController,
        weightKg > 0 ? widget.unit.formatKilograms(weightKg) : '',
      );
    }

    if (sets == _savedSets && reps == _savedReps && weightKg == _savedWeightKg) {
      return null;
    }
    _savedSets = sets;
    _savedReps = reps;
    _savedWeightKg = weightKg;
    return widget.onChanged(sets: sets, reps: reps, weightKg: weightKg);
  }

  static void _setText(TextEditingController controller, String text) {
    if (controller.text == text) return;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);

    return Container(
      padding: const EdgeInsets.all(VoyagerSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TargetField(
            label: 'Sets',
            controller: _setsController,
            focusNode: _setsFocus,
            onChanged: _onEdited,
            formatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          const SizedBox(width: VoyagerSpacing.sm),
          _TargetField(
            label: 'Reps',
            controller: _repsController,
            focusNode: _repsFocus,
            onChanged: _onEdited,
            formatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          const SizedBox(width: VoyagerSpacing.sm),
          _TargetField(
            label: 'Weight',
            controller: _weightController,
            focusNode: _weightFocus,
            onChanged: _onEdited,
            flex: 3,
            hintText: '—',
            suffixText: widget.unit.label,
            formatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
          ),
        ],
      ),
    );
  }
}

/// One labelled number in the target row. Keeps the label/value stacking the
/// read-only version had, so the row reads the same whether or not the caret
/// is in it.
class _TargetField extends StatelessWidget {
  const _TargetField({
    required this.label,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.formatters,
    this.suffixText,
    this.hintText,
    this.flex = 2,
  });

  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final List<TextInputFormatter> formatters;
  final String? suffixText;
  final String? hintText;
  final int flex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
    );

    return Expanded(
      flex: flex,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: muted),
          const SizedBox(height: 2),
          VoyagerTextField(
            controller: controller,
            focusNode: focusNode,
            onChanged: onChanged,
            onSubmitted: (_) => focusNode.unfocus(),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            inputFormatters: formatters,
            borderRadius: 10,
            style: theme.textTheme.titleMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            decoration: InputDecoration(
              isDense: true,
              hintText: hintText,
              suffixText: suffixText,
              suffixStyle: muted,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
          ),
        ],
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
class _WeightSparkline extends StatelessWidget {
  const _WeightSparkline({required this.history, required this.unit});

  final List<ExerciseDaySummary> history;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final points = [for (final day in history) ...day.setWeightsKg];
    if (points.length < 2) {
      return _ChartPlaceholder(
        height: 120,
        message: points.isEmpty
            ? 'Log a set to start the trend'
            : 'One set so far — two are needed for a trend',
      );
    }
    return SizedBox(
      height: 120,
      child: CustomPaint(
        painter: _SparklinePainter(
          values: points,
          lineColor: theme.colorScheme.primary,
          gridColor: VoyagerColors.of(context).chartGrid,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.lineColor,
    required this.gridColor,
  });

  final List<double> values;
  final Color lineColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final min = values.reduce(math.min);
    final max = values.reduce(math.max);
    // A perfectly flat series has zero range; pad it so the line lands
    // mid-height instead of dividing by zero.
    final range = (max - min).abs() < 0.001 ? 1.0 : max - min;

    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      Paint()
        ..color = gridColor
        ..strokeWidth = 1,
    );

    final dx = size.width / (values.length - 1);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final t = (values[i] - min) / range;
      final point = Offset(i * dx, size.height - (t * (size.height - 12)) - 6);
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
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.lineColor != lineColor ||
      old.gridColor != gridColor ||
      !listEquals(old.values, values);

  static bool listEquals(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A row of rounded squares, one per day the exercise was performed, with
/// brightness tracking that day's total volume (Σ weight × reps).
class _VolumeHeatmap extends StatelessWidget {
  const _VolumeHeatmap({required this.history, required this.unit});

  final List<ExerciseDaySummary> history;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);
    final accent = theme.colorScheme.primary;

    final recent = history.length <= kVolumeHeatmapDays
        ? history
        : history.sublist(history.length - kVolumeHeatmapDays);
    if (recent.isEmpty) {
      return _ChartPlaceholder(
        height: 30,
        message: 'No volume logged yet',
      );
    }
    final maxVolume = recent
        .map((d) => d.volumeKg)
        .fold<double>(0, math.max);

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final day in recent)
          Tooltip(
            message:
                '${day.date.year}-${_two(day.date.month)}-${_two(day.date.day)}'
                ' · ${unit.formatKilograms(day.volumeKg)} ${unit.label} volume',
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                // Floor of 0.18 so a light day still reads as a day trained
                // rather than dissolving into the background.
                color: accent.withValues(
                  alpha: maxVolume <= 0
                      ? 0.18
                      : 0.18 + 0.82 * (day.volumeKg / maxVolume),
                ),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: colors.hairline),
              ),
            ),
          ),
      ],
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
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
