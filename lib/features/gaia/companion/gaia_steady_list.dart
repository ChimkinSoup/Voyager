import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Sent as something in the chat opens or closes, so the chat keeps it where
/// it is on screen: what opens pushes what's below it down, rather than what's
/// above it up, out of reach.
class GaiaHoldInPlace extends Notification {
  GaiaHoldInPlace(this.context);

  final BuildContext context;
}

/// A chat's reversed list, which holds a message in place as something in it
/// opens or closes ([GaiaHoldInPlace]). When [steady], scrolled up, what's
/// being read stays put as what's below it changes too; at the bottom, it
/// follows the newest.
class GaiaSteadyList extends ListView {
  GaiaSteadyList({
    super.key,
    super.controller,
    super.reverse,
    super.padding,
    super.children,
    this.steady = false,
  });

  GaiaSteadyList.builder({
    super.key,
    super.controller,
    super.reverse,
    super.scrollCacheExtent,
    super.padding,
    super.itemCount,
    super.findChildIndexCallback,
    required super.itemBuilder,
    this.steady = false,
  }) : super.builder();

  final bool steady;

  @override
  Widget build(BuildContext context) =>
      NotificationListener<GaiaHoldInPlace>(
        onNotification: (notification) {
          // The message it's in, as the list's child.
          var box = notification.context.findRenderObject();
          while (box != null && box.parent is! _RenderSteadySliverList) {
            box = box.parent;
          }
          if (box is RenderBox) {
            (box.parent! as _RenderSteadySliverList).hold(box);
          }
          return true;
        },
        child: super.build(context),
      );

  @override
  Widget buildChildLayout(BuildContext context) =>
      _SteadySliverList(delegate: childrenDelegate, steady: steady);
}

class _SteadySliverList extends SliverList {
  const _SteadySliverList({required super.delegate, required this.steady});

  final bool steady;

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _RenderSteadySliverList(
        childManager: context as SliverMultiBoxAdaptorElement,
        steady: steady,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSteadySliverList renderObject,
  ) => renderObject.steady = steady;
}

/// The list's offset counts from its bottom, so what changes below would move
/// what's above. It's put right here, in layout: from a frame callback the
/// moved list would already have been painted, and shake.
class _RenderSteadySliverList extends RenderSliverList {
  _RenderSteadySliverList({required super.childManager, required this.steady});

  bool steady;

  /// The child across the list's top, and how far along the list its top
  /// was, while scrolled up.
  RenderBox? _anchor;
  double _anchorTop = 0;

  /// [_anchor] was [hold]'s, kept even at the bottom.
  var _held = false;

  /// Keeps [child]'s top where it is on screen through the next layout, as it
  /// opens or closes something, even at the bottom, where the list would
  /// otherwise follow its newest: what it opens goes down, not up.
  void hold(RenderBox child) {
    final offset = childScrollOffset(child);
    if (offset == null) return;
    _anchor = child;
    _anchorTop = offset + paintExtentOf(child);
    _held = true;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    // Scrolled up since the last layout moves the list, not the anchor along
    // it, so only what's changed below it counts.
    final anchor = (steady && constraints.scrollOffset > 0) || _held
        ? _anchor
        : null;
    _held = false;
    final top = anchor == null ? null : _measureTopOf(anchor);
    if (top != null) {
      // Not past the bottom, counting the list's padding before it.
      final moved = max(
        top - _anchorTop,
        constraints.scrollOffset > 0
            ? -constraints.scrollOffset - constraints.precedingScrollExtent
            : 0.0,
      );
      _anchorTop = top;
      if (moved.abs() > 0.01) {
        geometry = SliverGeometry(scrollOffsetCorrection: moved);
        return;
      }
    }
    super.performLayout();
    final correction = geometry!.scrollOffsetCorrection;
    if (correction != null) {
      // Its own, for children it found the list's start isn't where it
      // thought: that moves every child along it.
      _anchorTop += correction;
    } else if (steady) {
      _anchorAcrossTop();
    }
  }

  /// How far along the list [anchor]'s top is, laying out what's below it
  /// first, as [anchor] could be dropped as out of view otherwise. Null once
  /// it's not among the children laid out, as when kept alive off screen.
  double? _measureTopOf(RenderBox anchor) {
    final constraints = this.constraints.asBoxConstraints();
    var child = firstChild;
    var top = child == null ? null : childScrollOffset(child);
    if (top == null) return null;
    while (child != null) {
      child.layout(constraints, parentUsesSize: true);
      top = top! + paintExtentOf(child);
      if (child == anchor) return top;
      var next = childAfter(child);
      // A message synced in between, not built yet.
      if (next != null && indexOf(next) != indexOf(child) + 1) {
        next = insertAndLayoutChild(
          constraints,
          after: child,
          parentUsesSize: true,
        );
      }
      child = next;
    }
    return null;
  }

  void _anchorAcrossTop() {
    _anchor = null;
    if (constraints.scrollOffset <= 0) return;
    final listTop = constraints.scrollOffset + constraints.remainingPaintExtent;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final top = childScrollOffset(child)! + paintExtentOf(child);
      _anchor = child;
      _anchorTop = top;
      if (top >= listTop) return;
    }
  }
}
