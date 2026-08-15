import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/workout_session_controller.dart';
import 'package:voyager/features/workout/workout_units.dart';

/// The collapsed live-workout pill.
///
/// Left: a live-workout dot in the accent colour. Centre: the current
/// exercise and its numbers. When a rest timer is running the whole border
/// becomes a progress ring that drains as the countdown ticks, and the
/// remaining time replaces nothing — it sits alongside, because losing sight
/// of what you are lifting to see how long you have left is the wrong trade.
class WorkoutIsland extends ConsumerStatefulWidget {
  const WorkoutIsland({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  ConsumerState<WorkoutIsland> createState() => _WorkoutIslandState();
}

class _WorkoutIslandState extends ConsumerState<WorkoutIsland>
    with SingleTickerProviderStateMixin {
  /// Drives the border drain and the countdown text. Runs only while a rest
  /// timer is live — an always-on ticker behind a persistent shell overlay
  /// would keep the whole app repainting forever.
  late final AnimationController _rest = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );
  DateTime? _trackedEnd;

  @override
  void dispose() {
    _rest.dispose();
    super.dispose();
  }

  void _syncRest(DateTime? endsAt, int totalSeconds) {
    if (endsAt == _trackedEnd) return;
    _trackedEnd = endsAt;
    if (endsAt == null || totalSeconds <= 0) {
      _rest.stop();
      _rest.value = 0;
      return;
    }
    final remaining = endsAt.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _rest.stop();
      _rest.value = 0;
      return;
    }
    // Resumes mid-drain rather than restarting: the countdown may be picked
    // up on a rebuild that happens seconds after it started.
    _rest.duration = remaining;
    _rest.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(workoutSessionControllerProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final unit = settings?.weightUnit ?? WeightUnit.lb;
    _syncRest(state.restEndsAt, state.restTotalSeconds);

    final theme = Theme.of(context);
    final colors = VoyagerColors.of(context);
    final accent = theme.colorScheme.primary;
    final exercise = state.currentExercise;
    final set = state.currentSet;
    final sets = state.currentExerciseSets.length;

    final label = exercise == null
        ? 'Workout in progress'
        : '${exercise.name}  •  '
              '${unit.formatKilogramsWithUnit(set?.weightKg ?? 0)}  •  '
              '${set?.reps ?? 0}|$sets';

    return Semantics(
      button: true,
      label: 'Live workout: $label. Tap to reopen.',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(999),
          child: AnimatedBuilder(
            animation: _rest,
            builder: (context, _) {
              final resting = state.restEndsAt != null;
              final remaining = resting
                  ? state.restEndsAt!.difference(DateTime.now())
                  : Duration.zero;
              return CustomPaint(
                // The ring is painted rather than composed from a Border so
                // it can be a partial arc — a Border can only be all-or-
                // nothing around the capsule.
                foregroundPainter: resting
                    ? _RestRingPainter(
                        progress: 1 - _rest.value,
                        color: accent,
                        radius: 999,
                      )
                    : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: VoyagerSpacing.lg,
                    vertical: VoyagerSpacing.md,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: resting ? Colors.transparent : colors.hairline,
                    ),
                    boxShadow: colors.surfaceShadow(blurRadius: 22),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _LiveDot(accent: accent),
                      const SizedBox(width: VoyagerSpacing.md),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (resting) ...[
                        const SizedBox(width: VoyagerSpacing.md),
                        Text(
                          _formatRemaining(remaining),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static String _formatRemaining(Duration remaining) {
    final seconds = remaining.inSeconds.clamp(0, 59 * 60 + 59);
    final minutes = seconds ~/ 60;
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

/// The "this is live" marker. A slow pulse under normal motion; a static dot
/// when the user has asked for reduced motion.
class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.accent});

  final Color accent;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Started here rather than in initState: the reduced-motion flag lives in
    // MediaQuery, which isn't readable that early.
    if (_started) return;
    _started = true;
    if (!VoyagerMotion.reduced(context)) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_pulse.value);
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.accent,
            boxShadow: [
              BoxShadow(
                color: widget.accent.withValues(alpha: 0.25 + 0.35 * t),
                blurRadius: 4 + 6 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RestRingPainter extends CustomPainter {
  _RestRingPainter({
    required this.progress,
    required this.color,
    required this.radius,
  });

  /// 1 at the start of the rest, 0 when it runs out.
  final double progress;
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final effectiveRadius = math.min(radius, size.height / 2);
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(1),
      Radius.circular(effectiveRadius),
    );

    // Track first, then the draining arc on top, so the pill keeps a defined
    // edge all the way to zero instead of dissolving.
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = color.withValues(alpha: 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      final length = metric.length * progress.clamp(0.0, 1.0);
      if (length <= 0) continue;
      canvas.drawPath(
        metric.extractPath(0, length),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RestRingPainter old) =>
      old.progress != progress || old.color != color;
}
