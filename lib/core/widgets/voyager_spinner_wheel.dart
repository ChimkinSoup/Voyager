import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'package:voyager/core/motion/motion.dart';

/// The share of a fling's launch velocity a Voyager spinner keeps.
const _flingDamping = 0.4;

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
  ) => super.createBallisticSimulation(position, velocity * _flingDamping);
}

/// The first and last rows a wheel may come to rest on.
typedef VoyagerWheelLimits = ({int first, int last});

/// [VoyagerHighFrictionScrollPhysics] for a wheel that may only rest between
/// two of its rows — which, on an endless wheel, can move as the value it
/// edits changes.
///
/// Past either limit the wheel stretches rather than stopping dead: a drag is
/// resisted harder the further it goes, and letting go springs it back. That
/// is the whole signal that the move is refused, so it has to be felt on every
/// platform — the ambient parent physics would clamp on one and bounce on
/// another.
///
/// The stretch never reaches half a row, so the row past a limit never becomes
/// the selected one. On an endless wheel that row exists and would report
/// itself through `onSelectedItemChanged`.
class VoyagerLimitedWheelPhysics extends VoyagerHighFrictionScrollPhysics {
  const VoyagerLimitedWheelPhysics({
    super.parent,
    required this.itemExtent,
    required this.limits,
  });

  /// How far past a limit the wheel can be pulled, as a share of one row.
  static const stretchShare = 0.4;

  final double itemExtent;

  /// Read on every use rather than fixed here: a [Scrollable] keeps the
  /// physics it built its position with until the physics' *type* changes, so
  /// a new instance with new limits would never reach it.
  final VoyagerWheelLimits Function() limits;

  @override
  VoyagerLimitedWheelPhysics applyTo(ScrollPhysics? ancestor) =>
      VoyagerLimitedWheelPhysics(
        parent: buildParent(ancestor),
        itemExtent: itemExtent,
        limits: limits,
      );

  double get _reach => itemExtent * stretchShare;

  ({double min, double max}) get _range {
    final l = limits();
    return (min: l.first * itemExtent, max: l.last * itemExtent);
  }

  /// The stretch a pull of [pull] pixels past a limit shows: half the pull at
  /// first, less the further it goes, never quite [_reach].
  double _stretch(double pull) => _reach * pull / (pull + 2 * _reach);

  /// The pull that shows [stretch] — [_stretch] run backwards.
  double _pull(double stretch) {
    final shown = math.min(stretch, _reach * 0.99);
    return 2 * _reach * shown / (_reach - shown);
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    final (:min, :max) = _range;
    final pixels = position.pixels;
    // Undo the stretch, move by the whole drag, and stretch again: the
    // resistance then depends only on how far past the limit the pull has
    // gone, so the wheel eases back out along the curve it went in on. A drag
    // moves the wheel by -offset.
    var free = pixels;
    if (pixels > max) free = max + _pull(pixels - max);
    if (pixels < min) free = min - _pull(min - pixels);
    free -= offset;
    var to = free;
    if (free > max) to = max + _stretch(free - max);
    if (free < min) to = min - _stretch(min - free);
    return pixels - to;
  }

  /// Nothing clamps: a finite wheel's own ends are limits like any other and
  /// stretch the same way.
  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) => 0;

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final (:min, :max) = _range;
    final pixels = position.pixels;
    final tolerance = toleranceFor(position);

    // Let go past a limit: spring back onto it. Velocity carried outward
    // would stretch the wheel further than a drag can, so it is dropped.
    if (pixels < min || pixels > max) {
      return ScrollSpringSimulation(
        spring,
        pixels,
        pixels.clamp(min, max),
        0,
        tolerance: tolerance,
      );
    }

    final settle = super.createBallisticSimulation(position, velocity);
    final end = settle?.x(double.infinity);
    if (end == null || (end >= min && end <= max)) return settle;

    // A fling that would sail past a limit comes to rest on it instead.
    final limit = end.clamp(min, max);
    final damped = velocity * _flingDamping;
    // Within half a row of it there is no room to decelerate into: a
    // friction curve that short runs off the end of a double.
    if ((limit - pixels).abs() < itemExtent / 2 ||
        damped.abs() <= tolerance.velocity) {
      return ScrollSpringSimulation(
        spring,
        pixels,
        limit,
        0,
        tolerance: tolerance,
      );
    }
    return FrictionSimulation.through(
      pixels,
      limit,
      damped,
      tolerance.velocity * damped.sign,
    );
  }
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
    this.limits,
    this.itemExtent,
    this.onEdgeNotch,
  });

  final FixedExtentScrollController controller;

  /// Null is an endless wheel, which has no end to clamp against and so never
  /// raises [onEdgeNotch].
  final int? itemCount;

  /// The rows a notch may land on. A notch refused at one bumps the wheel a
  /// little way past it and leaves [VoyagerLimitedWheelPhysics] to spring it
  /// back, so the refusal is seen rather than just nothing happening. The
  /// bump is measured in rows, hence [itemExtent].
  final VoyagerWheelLimits Function()? limits;

  final double? itemExtent;

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
    final limits = widget.limits?.call();
    var target = from + direction;
    if (count != null) target = target.clamp(0, count - 1);
    if (limits != null) target = target.clamp(limits.first, limits.last);
    if (target == from) {
      if (limits != null) _bump(from, direction);
      widget.onEdgeNotch?.call(direction);
      return;
    }

    _target = target;
    if (VoyagerMotion.reduced(context)) {
      controller.jumpToItem(target);
      _target = null;
      return;
    }
    _track(
      controller.animateToItem(
        target,
        duration: const Duration(milliseconds: 150),
        curve: VoyagerSpring.snappyCurve,
      ),
    );
  }

  /// Nudges the wheel past the [limit] it is resting on. The nudge ends as a
  /// ballistic scroll, which the limited physics turns into the spring back.
  void _bump(int limit, int direction) {
    if (VoyagerMotion.reduced(context)) return;
    final extent = widget.itemExtent!;
    // Still where the wheel comes to rest, so a notch back the other way
    // mid-bump steps off the limit rather than off whatever row it is over.
    _target = limit;
    _track(
      widget.controller.animateTo(
        (limit + direction * 0.3) * extent,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
      ),
    );
  }

  void _track(Future<void> motion) {
    final generation = ++_generation;
    motion.whenComplete(() {
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
    this.limits,
    this.onNotification,
    this.onEdgeNotch,
  });

  final FixedExtentScrollController controller;
  final double itemExtent;

  /// Null makes the wheel endless, which is what carrying past the last digit
  /// into the column beside it needs.
  final int? itemCount;

  /// The rows the wheel may rest on, read afresh on every gesture. Past them
  /// it stretches and springs back — see [VoyagerLimitedWheelPhysics]. Null
  /// leaves it to the platform, which on Windows stops a finite wheel dead at
  /// its ends and never stops an endless one.
  final VoyagerWheelLimits Function()? limits;

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
            limits: limits,
            itemExtent: itemExtent,
            onEdgeNotch: onEdgeNotch,
            child: ListWheelScrollView.useDelegate(
              controller: controller,
              itemExtent: itemExtent,
              physics: limits == null
                  ? const VoyagerHighFrictionScrollPhysics()
                  : VoyagerLimitedWheelPhysics(
                      itemExtent: itemExtent,
                      limits: limits!,
                    ),
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
