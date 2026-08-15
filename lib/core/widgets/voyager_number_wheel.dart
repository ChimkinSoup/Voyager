import 'package:flutter/material.dart';

import 'package:voyager/core/motion/motion.dart';

/// The scroll feel shared by every Voyager picker wheel.
///
/// Fixed-extent snapping with the fling velocity damped to 40%: at full
/// velocity a flick overshoots by dozens of items, which turns "nudge the
/// weight up 5 lb" into a hunt. Extracted here so the time picker and the
/// workout weight/reps wheels cannot drift apart.
class VoyagerWheelPhysics extends FixedExtentScrollPhysics {
  const VoyagerWheelPhysics({super.parent});

  @override
  VoyagerWheelPhysics applyTo(ScrollPhysics? ancestor) {
    return VoyagerWheelPhysics(parent: buildParent(ancestor));
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    return super.createBallisticSimulation(position, velocity * 0.4);
  }
}

/// A single flickable column of values.
///
/// The caller owns the selection: pass [selectedIndex] and rebuild with the
/// value from [onSelectedIndexChanged]. External changes (a different
/// exercise's set coming into view) are honoured by scrolling to the new
/// index, and are suppressed from firing the callback back — otherwise a
/// programmatic scroll would read as a user edit and mark the set deviated.
class VoyagerNumberWheel extends StatefulWidget {
  const VoyagerNumberWheel({
    super.key,
    required this.itemCount,
    required this.selectedIndex,
    required this.onSelectedIndexChanged,
    required this.labelForIndex,
    this.onInteraction,
    this.width = 96,
    this.itemHeight = 44,
    this.visibleItems = 5,
    this.selectedStyle,
    this.unselectedStyle,
    this.semanticLabel,
  });

  final int itemCount;
  final int selectedIndex;
  final ValueChanged<int> onSelectedIndexChanged;
  final String Function(int index) labelForIndex;

  /// Fires on the first frame of a user-driven scroll (never a programmatic
  /// one). The active workout uses it to cancel a running rest countdown the
  /// moment the user starts dialling in the next set.
  final VoidCallback? onInteraction;

  final double width;
  final double itemHeight;

  /// How many rows are visible at once. Odd numbers keep the selected row
  /// centred; the outermost rows sit under the fade.
  final int visibleItems;

  final TextStyle? selectedStyle;
  final TextStyle? unselectedStyle;
  final String? semanticLabel;

  @override
  State<VoyagerNumberWheel> createState() => _VoyagerNumberWheelState();
}

class _VoyagerNumberWheelState extends State<VoyagerNumberWheel> {
  late final FixedExtentScrollController _controller;
  late int _displayIndex;
  var _programmatic = false;

  @override
  void initState() {
    super.initState();
    _displayIndex = widget.selectedIndex;
    _controller = FixedExtentScrollController(initialItem: _displayIndex);
  }

  @override
  void didUpdateWidget(covariant VoyagerNumberWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex == _displayIndex) return;
    // Post-frame: the wheel may not have clients yet on the build that
    // introduces it, and animateToItem on a detached controller throws.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      if (widget.selectedIndex == _controller.selectedItem) return;
      _programmatic = true;
      final target = widget.selectedIndex;
      final jump =
          VoyagerMotion.reduced(context) ||
          (target - _controller.selectedItem).abs() > widget.visibleItems * 3;
      if (jump) {
        // A long hop animated at spring speed reads as a slot machine, and
        // under reduced motion it should not travel at all.
        _controller.jumpToItem(target);
        _programmatic = false;
      } else {
        _controller
            .animateToItem(
              target,
              duration: const Duration(milliseconds: 260),
              curve: VoyagerSpring.moveCurve,
            )
            .whenComplete(() => _programmatic = false);
      }
      setState(() => _displayIndex = target);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedStyle =
        widget.selectedStyle ??
        theme.textTheme.headlineSmall?.copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        );
    final unselectedStyle =
        widget.unselectedStyle ??
        theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.32),
        );

    return Semantics(
      label: widget.semanticLabel,
      value: widget.labelForIndex(widget.selectedIndex),
      child: SizedBox(
        width: widget.width,
        height: widget.itemHeight * widget.visibleItems,
        child: ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black,
              Colors.black,
              Colors.transparent,
            ],
            stops: [0.0, 0.28, 0.72, 1.0],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (!_programmatic &&
                  (n is ScrollStartNotification ||
                      n is ScrollUpdateNotification)) {
                widget.onInteraction?.call();
              }
              return false;
            },
            child: ListWheelScrollView.useDelegate(
              controller: _controller,
              itemExtent: widget.itemHeight,
              physics: const VoyagerWheelPhysics(),
              perspective: 0.004,
              diameterRatio: 1.6,
              onSelectedItemChanged: (index) {
                setState(() => _displayIndex = index);
                if (_programmatic) return;
                widget.onSelectedIndexChanged(index);
              },
              childDelegate: ListWheelChildBuilderDelegate(
                childCount: widget.itemCount,
                builder: (context, index) {
                  final isSelected = index == _displayIndex;
                  return Center(
                    child: Text(
                      widget.labelForIndex(index),
                      maxLines: 1,
                      style: isSelected ? selectedStyle : unselectedStyle,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
