import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// [SingleChildScrollView] with the overscroll clamp taken out.
///
/// Flutter's own single-child viewport pulls the scroll offset back inside
/// `[min, max]` at the end of *every* layout pass:
///
/// ```dart
/// // single_child_scroll_view.dart, _RenderSingleChildViewport.performLayout
/// if (offset.hasPixels) {
///   if (offset.pixels > _maxScrollExtent) { ... }
///   else if (offset.pixels < _minScrollExtent) { ... }
/// }
/// ```
///
/// While the view is rubber-banding, that clamp fires on any relayout of the
/// content and snaps the offset back to the edge mid-drag. The finger (or
/// trackpad) is still going, so the bounce immediately builds again from zero:
/// bounce, snap, bounce, snap — visible as jitter. Moving the mouse across a
/// text field is enough to trigger it, because Material rebuilds (and so
/// relayouts) a [TextField] on hover enter/exit, and the content sliding under
/// a stationary cursor crosses field boundaries constantly while scrolling.
///
/// Sliver viewports ([ListView], [CustomScrollView]) carry no such clamp —
/// they let [ScrollPhysics.adjustPositionForNewDimensions] decide, which is
/// what [RangeMaintainingScrollPhysics] is for — and they do not jitter. This
/// widget is Flutter's single-child viewport with that one clamp removed, so
/// the bounce survives a relayout. It is used instead of a sliver viewport
/// because a single-child viewport shrink-wraps its cross axis, which most of
/// this app's scrollers (and every horizontal one) rely on for their size.
class VoyagerScrollView extends StatelessWidget {
  const VoyagerScrollView({
    super.key,
    this.scrollDirection = Axis.vertical,
    this.padding,
    this.controller,
    this.primary,
    required this.child,
  }) : assert(
          !(controller != null && (primary ?? false)),
          'Primary ScrollViews obtain their ScrollController via inheritance '
          'from a PrimaryScrollController widget. You cannot both set primary '
          'to true and pass an explicit controller.',
        );

  final Axis scrollDirection;
  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;
  final bool? primary;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final axisDirection = getAxisDirectionFromAxisReverseAndDirectionality(
      context,
      scrollDirection,
      false,
    );
    final contents = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    final effectivePrimary = primary ??
        controller == null &&
            PrimaryScrollController.shouldInherit(context, scrollDirection);
    final scrollController = effectivePrimary
        ? PrimaryScrollController.maybeOf(context)
        : controller;

    final scrollable = Scrollable(
      axisDirection: axisDirection,
      controller: scrollController,
      viewportBuilder: (context, offset) => _SingleChildViewport(
        axisDirection: axisDirection,
        offset: offset,
        child: contents,
      ),
    );

    return effectivePrimary && scrollController != null
        // Further descendant ScrollViews will not inherit the same
        // PrimaryScrollController.
        ? PrimaryScrollController.none(child: scrollable)
        : scrollable;
  }
}

// The rest of this file is Flutter's own single-child viewport (from
// packages/flutter/lib/src/widgets/single_child_scroll_view.dart, BSD-3), with
// the parameters this app never passes dropped and the boundary clamp in
// performLayout removed. Keeping the render object rather than composing a
// sliver viewport is what preserves the cross-axis shrink-wrap that callers
// size themselves against.

class _SingleChildViewport extends SingleChildRenderObjectWidget {
  const _SingleChildViewport({
    required this.axisDirection,
    required this.offset,
    super.child,
  });

  final AxisDirection axisDirection;
  final ViewportOffset offset;

  @override
  _RenderSingleChildViewport createRenderObject(BuildContext context) {
    return _RenderSingleChildViewport(
      axisDirection: axisDirection,
      offset: offset,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSingleChildViewport renderObject,
  ) {
    // Order dependency: The offset setter reads the axis direction.
    renderObject
      ..axisDirection = axisDirection
      ..offset = offset;
  }

  @override
  SingleChildRenderObjectElement createElement() =>
      _SingleChildViewportElement(this);
}

class _SingleChildViewportElement extends SingleChildRenderObjectElement
    with NotifiableElementMixin, ViewportElementMixin {
  _SingleChildViewportElement(_SingleChildViewport super.widget);
}

class _RenderSingleChildViewport extends RenderBox
    with RenderObjectWithChildMixin<RenderBox>
    implements RenderAbstractViewport {
  _RenderSingleChildViewport({
    required AxisDirection axisDirection,
    required ViewportOffset offset,
  })  // Named parameters cannot be private, so these cannot be initializing
      // formals; the framework's own version assigns them the same way.
      // ignore: prefer_initializing_formals
      : _axisDirection = axisDirection,
        // ignore: prefer_initializing_formals
        _offset = offset;

  AxisDirection get axisDirection => _axisDirection;
  AxisDirection _axisDirection;
  set axisDirection(AxisDirection value) {
    if (value == _axisDirection) return;
    _axisDirection = value;
    markNeedsLayout();
  }

  Axis get axis => axisDirectionToAxis(axisDirection);

  ViewportOffset get offset => _offset;
  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) return;
    if (attached) _offset.removeListener(_hasScrolled);
    _offset = value;
    if (attached) _offset.addListener(_hasScrolled);
    markNeedsLayout();
  }

  void _hasScrolled() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void setupParentData(RenderObject child) {
    // We don't actually use the offset argument in BoxParentData, so let's
    // avoid allocating it at all.
    if (child.parentData is! ParentData) {
      child.parentData = ParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_hasScrolled);
  }

  @override
  void detach() {
    _offset.removeListener(_hasScrolled);
    super.detach();
  }

  @override
  bool get isRepaintBoundary => true;

  double get _viewportExtent {
    assert(hasSize);
    return switch (axis) {
      Axis.horizontal => size.width,
      Axis.vertical => size.height,
    };
  }

  double get _minScrollExtent {
    assert(hasSize);
    return 0.0;
  }

  double get _maxScrollExtent {
    assert(hasSize);
    if (child == null) return 0.0;
    return math.max(0.0, switch (axis) {
      Axis.horizontal => child!.size.width - size.width,
      Axis.vertical => child!.size.height - size.height,
    });
  }

  BoxConstraints _getInnerConstraints(BoxConstraints constraints) {
    return switch (axis) {
      Axis.horizontal => constraints.heightConstraints(),
      Axis.vertical => constraints.widthConstraints(),
    };
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0.0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0.0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width) ?? 0.0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width) ?? 0.0;

  // We don't override computeDistanceToActualBaseline(), because we
  // want the default behavior (returning null). Otherwise, as you
  // scroll, it would shift in its parent if the parent was baseline-aligned,
  // which makes no sense.

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    if (child == null) return constraints.smallest;
    final childSize = child!.getDryLayout(_getInnerConstraints(constraints));
    return constraints.constrain(childSize);
  }

  @override
  void performLayout() {
    final constraints = this.constraints;
    if (child == null) {
      size = constraints.smallest;
    } else {
      child!.layout(_getInnerConstraints(constraints), parentUsesSize: true);
      size = constraints.constrain(child!.size);
    }

    // Flutter's version clamps offset.pixels into range here. That is what
    // kills a rubber band the moment anything inside relayouts — see the class
    // doc above. Leaving it out hands the same job to the physics, via
    // applyContentDimensions below, exactly as sliver viewports do.
    offset.applyViewportDimension(_viewportExtent);
    offset.applyContentDimensions(_minScrollExtent, _maxScrollExtent);
  }

  Offset get _paintOffset => _paintOffsetForPosition(offset.pixels);

  Offset _paintOffsetForPosition(double position) {
    return switch (axisDirection) {
      AxisDirection.up =>
        Offset(0.0, position - child!.size.height + size.height),
      AxisDirection.left =>
        Offset(position - child!.size.width + size.width, 0.0),
      AxisDirection.right => Offset(-position, 0.0),
      AxisDirection.down => Offset(0.0, -position),
    };
  }

  bool _shouldClipAtPaintOffset(Offset paintOffset) {
    assert(child != null);
    return paintOffset.dx < 0 ||
        paintOffset.dy < 0 ||
        paintOffset.dx + child!.size.width > size.width ||
        paintOffset.dy + child!.size.height > size.height;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    final paintOffset = _paintOffset;

    void paintContents(PaintingContext context, Offset offset) {
      context.paintChild(child!, offset + paintOffset);
    }

    if (_shouldClipAtPaintOffset(paintOffset)) {
      _clipRectLayer.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        paintContents,
        clipBehavior: Clip.hardEdge,
        oldLayer: _clipRectLayer.layer,
      );
    } else {
      _clipRectLayer.layer = null;
      paintContents(context, offset);
    }
  }

  final LayerHandle<ClipRectLayer> _clipRectLayer =
      LayerHandle<ClipRectLayer>();

  @override
  void dispose() {
    _clipRectLayer.layer = null;
    super.dispose();
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final paintOffset = _paintOffset;
    transform.translateByDouble(paintOffset.dx, paintOffset.dy, 0, 1);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject? child) {
    if (child != null && _shouldClipAtPaintOffset(_paintOffset)) {
      return Offset.zero & size;
    }
    return null;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _paintOffset,
      position: position,
      hitTest: (result, transformed) {
        assert(transformed == position + -_paintOffset);
        return child!.hitTest(result, position: transformed);
      },
    );
  }

  @override
  RevealedOffset getOffsetToReveal(
    RenderObject target,
    double alignment, {
    Rect? rect,
    Axis? axis,
  }) {
    // One dimensional viewport has only one axis, override if it was
    // provided/may be mismatched.
    axis = this.axis;

    rect ??= target.paintBounds;
    if (target is! RenderBox) {
      return RevealedOffset(offset: offset.pixels, rect: rect);
    }

    final targetBox = target;
    final transform = targetBox.getTransformTo(child);
    final bounds = MatrixUtils.transformRect(transform, rect);
    final contentSize = child!.size;

    final (
      double mainAxisExtent,
      double leadingScrollOffset,
      double targetMainAxisExtent,
    ) = switch (axisDirection) {
      AxisDirection.up => (
          size.height,
          contentSize.height - bounds.bottom,
          bounds.height,
        ),
      AxisDirection.left => (
          size.width,
          contentSize.width - bounds.right,
          bounds.width,
        ),
      AxisDirection.right => (size.width, bounds.left, bounds.width),
      AxisDirection.down => (size.height, bounds.top, bounds.height),
    };

    final targetOffset = leadingScrollOffset -
        (mainAxisExtent - targetMainAxisExtent) * alignment;
    final targetRect = bounds.shift(_paintOffsetForPosition(targetOffset));
    return RevealedOffset(offset: targetOffset, rect: targetRect);
  }

  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (!offset.allowImplicitScrolling) {
      return super.showOnScreen(
        descendant: descendant,
        rect: rect,
        duration: duration,
        curve: curve,
      );
    }

    final newRect = RenderViewportBase.showInViewport(
      descendant: descendant,
      viewport: this,
      offset: offset,
      rect: rect,
      duration: duration,
      curve: curve,
    );
    super.showOnScreen(rect: newRect, duration: duration, curve: curve);
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DiagnosticsProperty<Offset>('offset', _paintOffset));
  }

  @override
  Rect describeSemanticsClip(RenderObject child) {
    final remainingOffset = _maxScrollExtent - offset.pixels;
    switch (axisDirection) {
      case AxisDirection.up:
        return Rect.fromLTRB(
          semanticBounds.left,
          semanticBounds.top - remainingOffset,
          semanticBounds.right,
          semanticBounds.bottom + offset.pixels,
        );
      case AxisDirection.right:
        return Rect.fromLTRB(
          semanticBounds.left - offset.pixels,
          semanticBounds.top,
          semanticBounds.right + remainingOffset,
          semanticBounds.bottom,
        );
      case AxisDirection.down:
        return Rect.fromLTRB(
          semanticBounds.left,
          semanticBounds.top - offset.pixels,
          semanticBounds.right,
          semanticBounds.bottom + remainingOffset,
        );
      case AxisDirection.left:
        return Rect.fromLTRB(
          semanticBounds.left - remainingOffset,
          semanticBounds.top,
          semanticBounds.right + offset.pixels,
          semanticBounds.bottom,
        );
    }
  }
}
