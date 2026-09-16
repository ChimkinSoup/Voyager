import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Shifts [child] up by [controller]'s scroll offset, read at paint time.
///
/// For layers stacked over a [TextField] that scrolls internally, so they move
/// with its text. These used to read the offset in `build` (a
/// [ListenableBuilder] around a [Transform]), which lags whenever the offset
/// changes during layout: an edit that shortens the text — a Vim `dd` near the
/// bottom of a scrolled field — clamps the field's position there, after this
/// frame's builds and without notifying listeners, so the block caret, tag
/// pills and squiggles painted a line high until something rebuilt them. Paint
/// runs after layout, so the offset read here is the one the field paints
/// with.
class ScrollOffsetFollower extends SingleChildRenderObjectWidget {
  const ScrollOffsetFollower({
    super.key,
    required this.controller,
    super.child,
  });

  final ScrollController controller;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderScrollOffsetFollower(controller);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderScrollOffsetFollower renderObject,
  ) {
    renderObject.controller = controller;
  }
}

class RenderScrollOffsetFollower extends RenderProxyBox {
  RenderScrollOffsetFollower(this._controller);

  ScrollController _controller;

  set controller(ScrollController value) {
    if (value == _controller) return;
    if (attached) {
      _controller.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _controller = value;
    markNeedsPaint();
  }

  double get _dy => _controller.hasClients ? -_controller.offset : 0.0;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _controller.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child != null) context.paintChild(child, offset.translate(0, _dy));
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(0.0, _dy, 0.0, 1.0);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: Offset(0, _dy),
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }
}
