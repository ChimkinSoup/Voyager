import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Stops a modal route's barrier from taking a click once the route has
/// started to leave.
///
/// Flutter turns a barrier off with `IgnorePointer(ignoring:
/// !animation.isForwardOrCompleted)`, which is a *build* — it only takes
/// effect on the frame after the pop. A click that lands in that gap is spent
/// on the barrier of a route that is already gone, and [ModalBarrier] answers
/// it with `Navigator.maybePop`, which by then finds the route *underneath*
/// and pops that instead. The second click of a fast double-click behind an
/// open picker closed the dialog holding it.
///
/// Hit testing reads the route afresh, so there is no frame to be stale in,
/// and the click falls through to whatever is below the leaving route —
/// which is where the user aimed it.
mixin GuardedModalBarrier<T> on ModalRoute<T> {
  @override
  Widget buildModalBarrier() =>
      _ModalBarrierGuard(route: this, child: super.buildModalBarrier());
}

class _ModalBarrierGuard extends SingleChildRenderObjectWidget {
  const _ModalBarrierGuard({required this.route, required Widget super.child});

  final ModalRoute<dynamic> route;

  @override
  _RenderModalBarrierGuard createRenderObject(BuildContext context) =>
      _RenderModalBarrierGuard(route);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderModalBarrierGuard renderObject,
  ) {
    renderObject.route = route;
  }
}

class _RenderModalBarrierGuard extends RenderProxyBox {
  _RenderModalBarrierGuard(this.route);

  /// Read on every hit test, so nothing here needs to mark anything dirty:
  /// being the current route decides nothing about layout or painting.
  ModalRoute<dynamic> route;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // A route that is no longer current is either leaving or has something
    // above it — and anything above it brings its own barrier, so letting
    // this one through costs nothing.
    if (!route.isCurrent) return false;
    return super.hitTest(result, position: position);
  }
}
