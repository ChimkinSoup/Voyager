import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A widget that visually clamps its child's position during the paint phase 
/// so it does not render vertically outside the bounds of the given [targetKey].
/// Useful for keeping ReorderableListView drag proxy decorators visually confined
/// to the list bounds without hard clipping them.
class ClampToTargetBounds extends SingleChildRenderObjectWidget {
  final GlobalKey targetKey;

  const ClampToTargetBounds({
    super.key,
    required this.targetKey,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderClampToTargetBounds(targetKey: targetKey);
  }

  @override
  void updateRenderObject(
      BuildContext context, RenderClampToTargetBounds renderObject) {
    renderObject.targetKey = targetKey;
  }
}

class RenderClampToTargetBounds extends RenderProxyBox {
  GlobalKey _targetKey;
  ScrollPosition? _scrollPosition;
  bool _hasAttemptedScrollLookup = false;

  RenderClampToTargetBounds({
    required GlobalKey targetKey,
    RenderBox? child,
  })  : _targetKey = targetKey,
        super(child);

  GlobalKey get targetKey => _targetKey;

  set targetKey(GlobalKey value) {
    if (_targetKey == value) return;
    _targetKey = value;
    _hasAttemptedScrollLookup = false;
    if (attached) {
      _updateScrollListener();
    }
    markNeedsPaint();
  }

  void _handleScroll() {
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _updateScrollListener();
  }

  @override
  void detach() {
    _scrollPosition?.removeListener(_handleScroll);
    _scrollPosition = null;
    super.detach();
  }

  void _updateScrollListener() {
    final context = _targetKey.currentContext;
    if (context != null) {
      final newScrollPosition = Scrollable.maybeOf(context)?.position;
      if (newScrollPosition != _scrollPosition) {
        _scrollPosition?.removeListener(_handleScroll);
        _scrollPosition = newScrollPosition;
        _scrollPosition?.addListener(_handleScroll);
      }
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;

    if (!_hasAttemptedScrollLookup) {
      _hasAttemptedScrollLookup = true;
      _updateScrollListener();
    }

    final targetContext = _targetKey.currentContext;
    if (targetContext != null) {
      final RenderObject targetObj = targetContext.findRenderObject()!;
      final Matrix4 transform = targetObj.getTransformTo(null);
      final Rect targetRect = MatrixUtils.transformRect(transform, targetObj.paintBounds);
      
      final Offset myGlobalPos = localToGlobal(Offset.zero);
      
      double dy = 0;
      if (myGlobalPos.dy < targetRect.top) {
        dy = targetRect.top - myGlobalPos.dy;
      } else if (myGlobalPos.dy + size.height > targetRect.bottom) {
        dy = targetRect.bottom - (myGlobalPos.dy + size.height);
      }

      context.paintChild(child!, offset + Offset(0, dy));
    } else {
      context.paintChild(child!, offset);
    }
  }
}
