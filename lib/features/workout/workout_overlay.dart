import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/features/workout/active_workout_view.dart';
import 'package:voyager/features/workout/workout_island.dart';
import 'package:voyager/features/workout/workout_session_controller.dart';

/// Shell-level host for the live workout. Mounted once by [AppShell] above
/// every page, which is what makes the island survive navigation — a page-owned
/// overlay would be torn down the moment you switched sections.
///
/// Collapsed it is a pill pinned to the top. Expanded it grows downward from
/// that pill into the full active-workout panel, and collapsing reverses the
/// same motion, so the two states read as one object changing size rather than
/// two screens swapping.
class WorkoutOverlay extends ConsumerStatefulWidget {
  const WorkoutOverlay({super.key});

  @override
  ConsumerState<WorkoutOverlay> createState() => _WorkoutOverlayState();
}

class _WorkoutOverlayState extends ConsumerState<WorkoutOverlay>
    with SingleTickerProviderStateMixin {
  /// 0 = island, 1 = expanded. Driven by a spring rather than a curve so
  /// tapping the island mid-collapse retargets from wherever it is instead of
  /// snapping back to the start.
  late final SpringMotion _expansion = SpringMotion(
    vsync: this,
    spring: VoyagerSpring.drawer,
  );
  var _lastExpanded = false;

  @override
  void dispose() {
    _expansion.dispose();
    super.dispose();
  }

  void _syncExpansion(bool expanded) {
    if (expanded == _lastExpanded) return;
    _lastExpanded = expanded;
    final target = expanded ? 1.0 : 0.0;
    if (VoyagerMotion.reduced(context)) {
      _expansion.jumpTo(target);
      return;
    }
    _expansion.animateTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final isLive = ref.watch(
      workoutSessionControllerProvider.select((s) => s.isLive),
    );
    final expanded = ref.watch(
      workoutSessionControllerProvider.select((s) => s.expanded),
    );
    final controller = ref.read(workoutSessionControllerProvider.notifier);

    if (!isLive) {
      // Nothing to host — and importantly no ticker left running behind the
      // rest of the app.
      _lastExpanded = false;
      _expansion.jumpTo(0);
      return const SizedBox.shrink();
    }

    _syncExpansion(expanded);
    final topInset = MediaQuery.paddingOf(context).top;
    final reduced = VoyagerMotion.reduced(context);

    return Positioned(
      top: topInset + VoyagerSpacing.sm,
      left: 0,
      right: 0,
      child: AnimatedBuilder(
        animation: _expansion.controller,
        builder: (context, _) {
          final t = _expansion.value.clamp(0.0, 1.0);
          return Align(
            alignment: Alignment.topCenter,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                // Both layers stay mounted through the transition and cross-
                // fade: rebuilding the panel from scratch on every expand would
                // reset the wheels mid-motion.
                IgnorePointer(
                  ignoring: t > 0.5,
                  child: Opacity(
                    opacity: (1 - t * 2).clamp(0.0, 1.0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: VoyagerSpacing.lg,
                      ),
                      child: WorkoutIsland(onTap: controller.expand),
                    ),
                  ),
                ),
                if (t > 0.001)
                  IgnorePointer(
                    ignoring: t < 0.5,
                    child: Opacity(
                      opacity: ((t - 0.5) * 2).clamp(0.0, 1.0),
                      child: _ExpandingPanel(
                        t: t,
                        reduced: reduced,
                        child: const ActiveWorkoutView(),
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

/// Grows the panel downward from the island's footprint: the top edge stays
/// put and the body unrolls beneath it, which is what makes the expansion read
/// as the pill opening rather than a sheet flying in.
class _ExpandingPanel extends StatelessWidget {
  const _ExpandingPanel({
    required this.t,
    required this.reduced,
    required this.child,
  });

  final double t;
  final bool reduced;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    // Capped so the panel doesn't stretch to the full width of a desktop
    // window, where a centred column of controls is easier to work through.
    final maxWidth = width < 560 ? width - VoyagerSpacing.lg * 2 : 520.0;

    final panel = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth,
        maxHeight: MediaQuery.sizeOf(context).height * 0.82,
      ),
      child: child,
    );

    if (reduced) return panel;

    return Align(
      alignment: Alignment.topCenter,
      // heightFactor drives the reveal, so the panel is genuinely clipped
      // shorter during the transition rather than being scaled — scaling would
      // squash the type on the way down.
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: Curves.easeOut.transform(t).clamp(0.02, 1.0),
          child: panel,
        ),
      ),
    );
  }
}
