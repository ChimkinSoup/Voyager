import 'dart:math';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A chat's messages with its composer over their foot. What's above the
/// composer's field ([GaiaFieldLine]), as its chips, floats over the messages
/// rather than pushing them up: scrolled up, the text runs on under it. The
/// list's [GaiaFloatGap] keeps that much room at its end, so at the bottom
/// nothing's under it.
class GaiaChatBody extends MultiChildRenderObjectWidget {
  GaiaChatBody({super.key, required Widget messages, required Widget composer})
    : super(children: [messages, composer]);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderChatBody();
}

/// Where the composer's field starts: what's above it floats.
class GaiaFieldLine extends LeafRenderObjectWidget {
  const GaiaFieldLine({super.key});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFieldLine();
}

/// A sliver as tall as what floats over the chat's foot, as the first of a
/// reversed list's, so its last message clears it.
class GaiaFloatGap extends LeafRenderObjectWidget {
  const GaiaFloatGap({super.key});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFloatGap();
}

/// Its child lifted clear of what floats over the chat's foot beneath it:
/// only as far as what's under its column reaches.
class GaiaAboveFloat extends SingleChildRenderObjectWidget {
  const GaiaAboveFloat({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderAboveFloat();
}

class _BodyParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderChatBody extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _BodyParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _BodyParentData> {
  _RenderFieldLine? _line;
  final _gaps = <_RenderFloatGap>{};
  final _lifts = <_RenderAboveFloat>{};

  /// From the composer's top to its field's.
  double _float = 0;

  static _RenderChatBody? _of(RenderObject child) {
    for (var node = child.parent; node != null; node = node.parent) {
      if (node is _RenderChatBody) return node;
    }
    return null;
  }

  void _addGap(_RenderFloatGap gap) {
    _gaps.add(gap);
    gap.extent = _float;
  }

  /// How far [shown] has to rise to clear what floats under it.
  double _liftOver(RenderBox shown) {
    final composer = lastChild;
    if (composer == null || !composer.hasSize) return 0;
    final column = MatrixUtils.transformRect(
      shown.getTransformTo(composer),
      Offset.zero & shown.size,
    );
    double? top;
    void visit(RenderObject node) {
      if (node is RenderBox) {
        if (!node.hasSize) return;
        final rect = MatrixUtils.transformRect(
          node.getTransformTo(composer),
          Offset.zero & node.size,
        );
        if (rect.top >= _float ||
            rect.right <= column.left ||
            rect.left >= column.right) {
          return;
        }
        var leaf = true;
        node.visitChildren((_) => leaf = false);
        // What paints: a chip's background, or text, an icon or an image.
        if ((leaf || node is RenderDecoratedBox) &&
            !rect.isEmpty &&
            rect.bottom <= _float + 0.5) {
          top = min(top ?? rect.top, rect.top);
          return;
        }
      }
      node.visitChildren(visit);
    }

    composer.visitChildren(visit);
    return top == null ? 0 : _float - top!;
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BodyParentData) {
      child.parentData = _BodyParentData();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    size = constraints.biggest;
    final messages = firstChild!;
    final composer = childAfter(messages)!;
    composer.layout(BoxConstraints.loose(size), parentUsesSize: true);
    final line = _line;
    final float = line == null
        ? 0.0
        : MatrixUtils.transformPoint(
            line.getTransformTo(composer),
            Offset.zero,
          ).dy.clamp(0.0, composer.size.height);
    if (float != _float) {
      _float = float;
      invokeLayoutCallback<BoxConstraints>((_) {
        for (final gap in _gaps) {
          gap.extent = float;
        }
      });
    }
    // What floats can change under them without its height changing.
    if (_lifts.isNotEmpty) {
      invokeLayoutCallback<BoxConstraints>((_) {
        for (final lift in _lifts) {
          lift._relift();
        }
      });
    }
    final top = size.height - composer.size.height;
    messages.layout(
      BoxConstraints(
        maxWidth: size.width,
        minHeight: max(0, top + float),
        maxHeight: max(0, top + float),
      ),
      parentUsesSize: true,
    );
    (messages.parentData! as _BodyParentData).offset = Offset(
      (size.width - messages.size.width) / 2,
      0,
    );
    (composer.parentData! as _BodyParentData).offset = Offset(
      (size.width - composer.size.width) / 2,
      top,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _RenderFieldLine extends RenderBox {
  _RenderChatBody? _body;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _body = _RenderChatBody._of(this)?.._line = this;
  }

  @override
  void detach() {
    if (_body?._line == this) _body!._line = null;
    _body = null;
    super.detach();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.smallest;

  @override
  void performLayout() => size = constraints.smallest;
}

class _RenderFloatGap extends RenderSliver {
  _RenderChatBody? _body;

  double _extent = 0;
  set extent(double value) {
    if (value == _extent) return;
    _extent = value;
    markNeedsLayout();
  }

  /// The extent last laid out.
  double? _shown;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _body = _RenderChatBody._of(this)?.._addGap(this);
  }

  @override
  void detach() {
    _body?._gaps.remove(this);
    _body = null;
    super.detach();
  }

  @override
  void performLayout() {
    // Scrolled up, the text stays put as it changes: only the floating
    // things come and go over it.
    final change = max(
      _extent - (_shown ?? _extent),
      -constraints.scrollOffset,
    );
    _shown = _extent;
    if (constraints.scrollOffset > 0 && change != 0) {
      geometry = SliverGeometry(scrollOffsetCorrection: change);
      return;
    }
    geometry = SliverGeometry(
      scrollExtent: _extent,
      paintExtent: calculatePaintOffset(constraints, from: 0, to: _extent),
      maxPaintExtent: _extent,
      cacheExtent: calculateCacheOffset(constraints, from: 0, to: _extent),
    );
  }
}

class _RenderAboveFloat extends RenderShiftedBox {
  _RenderAboveFloat() : super(null);

  _RenderChatBody? _body;
  double _lift = 0;

  /// What the child shows, narrower than it, as last laid out.
  RenderBox? _shown;

  void _relift() {
    final shown = _shown;
    final body = _body;
    if (shown == null || !shown.attached || body == null) return;
    final lift = body._liftOver(shown);
    if (lift == _lift) return;
    _lift = lift;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _body = _RenderChatBody._of(this)?.._lifts.add(this);
  }

  @override
  void detach() {
    _body?._lifts.remove(this);
    _body = null;
    _shown = null;
    super.detach();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final size = child.getDryLayout(constraints);
    return constraints.constrain(Size(size.width, size.height + _lift));
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    // Reading the sizes of boxes other than its child's, which only a
    // layout callback may.
    invokeLayoutCallback<BoxConstraints>((_) {
      // Through what spans it, as a [Center], to what it shows.
      var shown = child;
      while (shown.size.width >= child.size.width - 0.5 &&
          shown is RenderObjectWithChildMixin<RenderBox>) {
        final next = (shown as RenderObjectWithChildMixin<RenderBox>).child;
        if (next == null) break;
        shown = next;
      }
      _shown = shown;
      _lift = _body?._liftOver(shown) ?? 0;
    });
    size = constraints.constrain(
      Size(child.size.width, child.size.height + _lift),
    );
    (child.parentData! as BoxParentData).offset = Offset.zero;
  }
}
