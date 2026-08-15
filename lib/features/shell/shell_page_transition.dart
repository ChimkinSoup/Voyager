import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:voyager/core/motion/motion.dart';

/// Duration of a nav-section switch.
///
/// Shorter than [kVoyagerCrossfadeDuration], which the in-page segmented
/// toggles (LeetCode, Finance, Workout) use: switching sections is a far more
/// frequent action, and the full 400ms reads as sluggish at that rate. The
/// shape — curve, recede, layer order — is the same.
const Duration kShellBranchSwitchDuration = Duration(milliseconds: 260);

/// Keeps all shell branches mounted and switches between them with the same
/// motion as [VoyagerCrossfadeIndex]'s glass-safe mode: the branch being left
/// fades out and recedes off the top of the arriving one, which meanwhile
/// enlarges from `1 - [kVoyagerCrossfadeRecede]` at full opacity.
///
/// The arriving branch is never wrapped in an opacity layer, because a layer
/// confines what a [BackdropFilter] under it can sample: every glass surface on
/// the arriving page would frost an empty backdrop for the length of the switch
/// — reading as a stuck hover highlight — then snap to its real appearance when
/// it ended. [Transform] creates no such boundary, so the scale is safe.
class ShellBranchContainer extends StatefulWidget {
  const ShellBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

  @override
  State<ShellBranchContainer> createState() => _ShellBranchContainerState();
}

class _ShellBranchContainerState extends State<ShellBranchContainer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: kShellBranchSwitchDuration,
    value: 1,
  );

  /// The branch dissolving away. Equals [_toIndex] when settled. Tracked
  /// because it has to be painted *above* the arriving branch, which the
  /// natural index order only gets right when moving leftwards.
  late int _fromIndex = widget.currentIndex;

  /// The branch arriving, and the settled one once [_progress] reaches 1.
  late int _toIndex = widget.currentIndex;

  Duration get _duration => VoyagerMotion.reduced(context)
      ? VoyagerMotion.crossfade
      : kShellBranchSwitchDuration;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _progress.duration = _duration;
  }

  @override
  void didUpdateWidget(covariant ShellBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentIndex == _toIndex) return;

    // Mid-flight retarget: keep whichever side is more visible as the new
    // outgoing, so tapping through the rail doesn't jump to an empty frame.
    if (_progress.value < 1) {
      _fromIndex = _progress.value >= 0.5 ? _toIndex : _fromIndex;
    } else {
      _fromIndex = _toIndex;
    }
    _toIndex = widget.currentIndex;
    _progress.duration = _duration;
    _progress.forward(from: 0);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recede = VoyagerMotion.reduced(context) ? 0.0 : kVoyagerCrossfadeRecede;
    final last = widget.children.length - 1;
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final t = _progress.value.clamp(0.0, 1.0);
        final from = _fromIndex.clamp(0, last);
        final to = _toIndex.clamp(0, last);
        final transitioning = from != to && t < 1;
        return Stack(
          fit: StackFit.expand,
          children: [
            for (var i = 0; i < widget.children.length; i++)
              if (!(transitioning && i == from))
                _branch(i, from: from, to: to, t: t, recede: recede),
            // Last, so it dissolves off the top of whatever it reveals.
            if (transitioning)
              _branch(from, from: from, to: to, t: t, recede: recede),
          ],
        );
      },
    );
  }

  Widget _branch(
    int index, {
    required int from,
    required int to,
    required double t,
    required double recede,
  }) {
    final isCurrent = index == to;
    final departing = index == from && from != to && t < 1;

    final double opacity;
    final double scale;
    if (isCurrent) {
      opacity = 1;
      scale = 1 - recede * (1 - t);
    } else if (departing) {
      opacity = 1 - t;
      scale = 1 - recede * t;
    } else {
      // Idle sibling: stays laid out so arriving at it costs no layout pass,
      // but a zero opacity means it is never painted.
      opacity = 0;
      scale = 1;
    }

    Widget layer = TickerMode(
      // The departing branch keeps ticking while it dissolves, so its own
      // animations don't freeze mid-fade.
      enabled: isCurrent || departing,
      child: widget.children[index],
    );
    if (scale != 1) {
      layer = Transform.scale(scale: scale, child: layer);
    }
    // Only wrap when fractional — a 1.0 Opacity still creates the layer that
    // would confine BackdropFilter sampling on the arriving branch.
    if (opacity < 1) {
      layer = Opacity(opacity: opacity, child: layer);
    }

    return Positioned.fill(
      key: ValueKey(index),
      child: IgnorePointer(ignoring: !isCurrent, child: layer),
    );
  }
}

ShellNavigationContainerBuilder shellBranchContainerBuilder =
    (
      BuildContext context,
      StatefulNavigationShell navigationShell,
      List<Widget> children,
    ) {
      return ShellBranchContainer(
        currentIndex: navigationShell.currentIndex,
        children: children,
      );
    };
