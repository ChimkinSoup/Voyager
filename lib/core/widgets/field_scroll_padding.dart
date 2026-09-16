import 'package:flutter/material.dart';

/// Caret reveal inset for Voyager [TextField]s.
///
/// Flutter defaults to 20px. [EditableText] inflates the caret by that
/// padding and asks ancestor scrollables to [Scrollable.ensureVisible]. At
/// the top of a rubber-banding scroll view that extra inset cannot be
/// satisfied, so the view overscrolls and snaps back on every caret tick.
/// Zero still keeps the caret on screen; sheets already pad for the keyboard
/// via [MediaQuery.viewInsets].
const EdgeInsets kVoyagerFieldScrollPadding = EdgeInsets.zero;

/// Scroll physics for Voyager [TextField]s: when the text shrinks under an
/// idle scroll position, the position is clamped into the new range before
/// the frame paints.
///
/// [RangeMaintainingScrollPhysics] means to do that, but it skips the clamp
/// whenever the position differs from the metrics it last recorded, and a
/// [RenderEditable] doesn't keep those current: once one delete has clamped
/// the offset, the recorded position is still the one from before it. A
/// second line deleted at the bottom of a scrolled field — `dd` twice — then
/// painted a frame scrolled a line past the end, the caret and text jumping
/// up before snapping back down.
class VoyagerFieldScrollPhysics extends ScrollPhysics {
  const VoyagerFieldScrollPhysics({super.parent});

  @override
  VoyagerFieldScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      VoyagerFieldScrollPhysics(parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final adjusted = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    // A drag or fling in progress keeps its overscroll, as the parent has it.
    if (isScrolling || velocity != 0.0) return adjusted;
    return adjusted.clamp(
      newPosition.minScrollExtent,
      newPosition.maxScrollExtent,
    );
  }
}
