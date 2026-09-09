import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:voyager/core/motion/motion.dart';

/// The scroll physics every Voyager spinner turns on.
///
/// A picker wheel is aimed at, not flung: at the stock fling velocity a flick
/// runs through a dozen items before it settles, which on a five-item score
/// roller means overshooting the whole scale. Damping the launch velocity is
/// what makes one flick move a few items and stop where the eye expects.
class VoyagerHighFrictionScrollPhysics extends FixedExtentScrollPhysics {
  const VoyagerHighFrictionScrollPhysics({super.parent});

  @override
  VoyagerHighFrictionScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      VoyagerHighFrictionScrollPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => super.createBallisticSimulation(position, velocity * 0.4);
}

/// The ambient scroll behavior a picker wheel runs under, with the mouse added
/// to the devices allowed to drag it.
///
/// Flutter leaves the mouse out by default, on the reasoning that a desktop
/// list is scrolled with the wheel and a click-drag inside it should select
/// text. A picker column has nothing to select, and grabbing the digits and
/// pulling them is the gesture the control looks like it affords — so here the
/// default is simply wrong.
ScrollBehavior voyagerWheelScrollBehavior(BuildContext context) =>
    ScrollConfiguration.of(context).copyWith(
      dragDevices: {
        ...ScrollConfiguration.of(context).dragDevices,
        PointerDeviceKind.mouse,
      },
    );

/// One mouse-wheel notch, one item.
///
/// Windows hands a notch to Flutter as three lines of twenty pixels — sixty,
/// which against a 32px score row snaps to *two* items. On the whole-number
/// column that reads as skipping every other value; on the two-slot decimals
/// column it lands back on the digit it started from while carrying the whole
/// part, so the decimals wheel looks like it is driving the integer.
///
/// The overlay has to sit *above* the wheel rather than around it. Flutter
/// gives no hook for the pointer-scroll distance — the wheel's own
/// [Scrollable] converts the pixels itself — so the only way to take the
/// notch off it is to win the [PointerSignalResolver], which the first entry
/// in the hit-test path does. Anything wrapping the wheel is an *ancestor*
/// and so is dispatched after it; a translucent [Listener] stacked on top is
/// visited first and still lets the drag fall through to the wheel below.
class VoyagerWheelNotch extends StatefulWidget {
  const VoyagerWheelNotch({
    super.key,
    required this.controller,
    required this.child,
    this.itemCount,
    this.onEdgeNotch,
  });

  final FixedExtentScrollController controller;

  /// Null is an endless wheel, which has no end to clamp against and so never
  /// raises [onEdgeNotch].
  final int? itemCount;

  /// A notch that could not move the wheel because it is already at that end:
  /// -1 for the top, 1 for the bottom.
  ///
  /// A drag reports the same push as an overscroll, but a pointer scroll
  /// clamps its target before it moves and so emits no scroll at all. Without
  /// this a gesture that exists for the finger is unreachable with a mouse.
  final ValueChanged<int>? onEdgeNotch;

  final Widget child;

  @override
  State<VoyagerWheelNotch> createState() => _VoyagerWheelNotchState();
}

class _VoyagerWheelNotchState extends State<VoyagerWheelNotch> {
  /// Where the hop currently in flight is heading. A second notch arriving
  /// mid-hop steps one past *that*, rather than one past whichever item the
  /// wheel happens to be passing over — otherwise spinning quickly loses
  /// every notch that lands during an animation.
  int? _target;

  /// Which hop owns [_target], so an interrupted one does not clear the
  /// target its successor set.
  var _generation = 0;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    // Registering also keeps the list behind the popover from scrolling under
    // the pointer: the resolver hands the notch to one scrollable only.
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => _step(dy < 0 ? -1 : 1),
    );
  }

  void _step(int direction) {
    final controller = widget.controller;
    if (!controller.hasClients) return;
    final from = _target ?? controller.selectedItem;
    final count = widget.itemCount;
    final target = count == null
        ? from + direction
        : (from + direction).clamp(0, count - 1);
    if (target == from) {
      widget.onEdgeNotch?.call(direction);
      return;
    }

    _target = target;
    if (VoyagerMotion.reduced(context)) {
      controller.jumpToItem(target);
      _target = null;
      return;
    }
    final generation = ++_generation;
    controller
        .animateToItem(
          target,
          duration: const Duration(milliseconds: 150),
          curve: VoyagerSpring.snappyCurve,
        )
        .whenComplete(() {
          // Interrupted or arrived, both end the hop. Only the newest one may
          // drop the target; an older future completing must not.
          if (mounted && generation == _generation) _target = null;
        });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      // The wheel keeps the constraints it would have had on its own, so
      // stacking the overlay over it cannot change how it lays out.
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: _onPointerSignal,
          ),
        ),
      ],
    );
  }
}

/// One column of a spinner: the time picker's hours, the score popover's
/// digits.
///
/// Items are built once per snap rather than once per frame — the selected row
/// is styled by comparing indices in [itemBuilder], not by subscribing every
/// item to the scroll animation.
class VoyagerSpinnerWheel extends StatelessWidget {
  const VoyagerSpinnerWheel({
    super.key,
    required this.controller,
    required this.itemExtent,
    required this.itemBuilder,
    required this.onSelectedItemChanged,
    this.itemCount,
    this.width = 40,
    this.onNotification,
    this.onEdgeNotch,
  });

  final FixedExtentScrollController controller;
  final double itemExtent;

  /// Null makes the wheel endless, which is what carrying past the last digit
  /// into the column beside it needs.
  final int? itemCount;

  final double width;
  final IndexedWidgetBuilder itemBuilder;
  final ValueChanged<int> onSelectedItemChanged;

  /// Raised for every scroll notification the wheel emits, so a caller can
  /// tell a drag from a settle without wrapping the wheel itself.
  final NotificationListenerCallback<ScrollNotification>? onNotification;

  /// A mouse notch refused because the wheel is already at that end. See
  /// [VoyagerWheelNotch.onEdgeNotch].
  final ValueChanged<int>? onEdgeNotch;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: NotificationListener<ScrollNotification>(
        onNotification: onNotification ?? (_) => false,
        child: ScrollConfiguration(
          behavior: voyagerWheelScrollBehavior(context),
          child: VoyagerWheelNotch(
            controller: controller,
            itemCount: itemCount,
            onEdgeNotch: onEdgeNotch,
            child: ListWheelScrollView.useDelegate(
              controller: controller,
              itemExtent: itemExtent,
              physics: const VoyagerHighFrictionScrollPhysics(),
              perspective: 0.005,
              onSelectedItemChanged: onSelectedItemChanged,
              childDelegate: ListWheelChildBuilderDelegate(
                builder: itemBuilder,
                childCount: itemCount,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The top-and-bottom fade every spinner sits behind, so the rows leaving the
/// window dissolve instead of being cut off by the edge of the box.
class VoyagerSpinnerFade extends StatelessWidget {
  const VoyagerSpinnerFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.black,
          Colors.black,
          Colors.transparent,
        ],
        stops: [0.0, 0.25, 0.75, 1.0],
      ).createShader(bounds),
      blendMode: BlendMode.dstIn,
      child: child,
    );
  }
}
