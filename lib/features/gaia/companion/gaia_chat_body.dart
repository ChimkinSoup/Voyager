import 'dart:math';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:voyager/features/gaia/companion/gaia_starfield.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';

/// A chat's messages with its composer over their foot. What's above the
/// composer's field ([GaiaFieldLine]), as its chips, floats over the messages
/// rather than pushing them up: scrolled up, the text runs on under it. The
/// list's [GaiaFloatGap] keeps that much room at its end, so at the bottom
/// nothing's under it.
///
/// Between them it paints [halo], what's behind the chat: solid under the
/// field ([GaiaFieldBox]) and the gap round it that its hover light shows
/// in, and fading up from the field's top over [haloFade], across the
/// composer's width, by [haloShown]. So over the messages, the foot of them
/// among it, but under the chips above the field. Only across, not round the
/// field's sides and corners: a fade tracing its outline reads as a glow.
class GaiaChatBody extends MultiChildRenderObjectWidget {
  GaiaChatBody({
    super.key,
    required Widget messages,
    required Widget composer,
    required this.halo,
    required this.haloFade,
    required this.haloShown,
  }) : super(children: [messages, composer]);

  final Color halo;
  final double haloFade;

  /// How much of the fade over the field's top shows, 0 to 1: as far as the
  /// messages are scrolled under it, so at rest it isn't over the newest.
  final double haloShown;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderChatBody(halo, haloFade, haloShown);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    renderObject as _RenderChatBody
      ..halo = halo
      ..haloFade = haloFade
      ..haloShown = haloShown;
  }
}

/// The composer's field: its fill and the 2px gap round it, which the chat
/// body's halo fades into.
class GaiaFieldBox extends SingleChildRenderObjectWidget {
  const GaiaFieldBox({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFieldBox(GaiaStarfield.clearOf(context));

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderFieldBox).clearStars = GaiaStarfield.clearOf(
      context,
    );
  }
}

/// What the chat body's halo leaves out, at a chip's corners: a button over
/// the messages' foot, which would otherwise fade with them. The halo's fade
/// is painted under it instead, so as it fades in or out, what shows through
/// it is faded as round it. Outside the button's own fade.
class GaiaHaloHole extends SingleChildRenderObjectWidget {
  const GaiaHaloHole({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHaloHole();
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
  _RenderChatBody(this._halo, this._haloFade, this._haloShown);

  Color _halo;
  set halo(Color value) {
    if (value == _halo) return;
    _halo = value;
    _markNeedsPaint();
  }

  double _haloFade;
  set haloFade(double value) {
    if (value == _haloFade) return;
    _haloFade = value;
    _markNeedsPaint();
  }

  double _haloShown;
  set haloShown(double value) {
    if (value == _haloShown) return;
    _haloShown = value;
    _markNeedsPaint();
  }

  /// This and the holes, which paint some of the halo themselves.
  void _markNeedsPaint() {
    markNeedsPaint();
    for (final hole in _holes) {
      hole.markNeedsPaint();
    }
  }

  _RenderFieldLine? _line;
  _RenderFieldBox? _field;
  final _gaps = <_RenderFloatGap>{};
  final _holes = <_RenderHaloHole>{};
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
    // The field may have moved under them.
    for (final hole in _holes) {
      hole.markNeedsPaint();
    }
  }

  /// The band over the field's top that the halo fades up across, in this
  /// body's coordinates: as wide as the composer. Null without a field.
  Rect? _band() {
    final field = _field;
    final composer = lastChild;
    if (field == null || !field.attached || !field.hasSize) return null;
    if (composer == null || !composer.hasSize) return null;
    final top = MatrixUtils.transformPoint(
      field.getTransformTo(this),
      Offset.zero,
    ).dy;
    final left = (composer.parentData! as _BodyParentData).offset.dx;
    return Rect.fromLTRB(
      left,
      top - _haloFade,
      left + composer.size.width,
      top,
    );
  }

  /// [_halo] fading in down [band], as much as [_haloShown].
  void _paintBand(Canvas canvas, Rect band) {
    final (:colors, :stops) = gaiaFade(
      _halo.withValues(alpha: _halo.a * _haloShown),
      clear: 0,
      full: 1,
    );
    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
          stops: stops,
        ).createShader(band),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final messages = firstChild!;
    final composer = childAfter(messages)!;
    context.paintChild(
      messages,
      offset + (messages.parentData! as _BodyParentData).offset,
    );
    final at = offset + (composer.parentData! as _BodyParentData).offset;
    // Read as it paints: whatever moves the field within the composer
    // repaints this, or lays it out as the composer's size changes.
    final field = _field;
    if (field != null && field.attached && field.hasSize) {
      final edge =
          MatrixUtils.transformPoint(field.getTransformTo(this), Offset.zero) +
              offset &
          field.size;
      _paintHalo(
        context.canvas,
        edge,
        [
          for (final hole in _holes)
            if (hole.attached && hole.hasSize)
              MatrixUtils.transformRect(
                hole.getTransformTo(this),
                Offset.zero & hole.size,
              ).shift(offset),
        ],
        // Not past the composer's sides: its padding can be narrower than
        // the fade, which would reach over the sidebar's divider.
        Rect.fromLTRB(
          at.dx,
          edge.top - _haloFade,
          at.dx + composer.size.width,
          edge.bottom + _haloFade,
        ),
      );
    }
    context.paintChild(composer, at);
  }

  void _paintHalo(Canvas canvas, Rect edge, List<Rect> holes, Rect clip) {
    final paint = Paint()..color = _halo;
    // A difference, not even-odd: holes overlapping, or past the clip,
    // stay holes.
    final cut = Path();
    for (final hole in holes) {
      cut.addRRect(
        RRect.fromRectAndRadius(hole, const Radius.circular(GaiaRadius.chip)),
      );
    }
    final shape = Path.combine(
      PathOperation.difference,
      Path()..addRect(clip),
      cut,
    );
    canvas
      ..save()
      ..clipPath(shape)
      // Rounded as the field's outline the stars fade round, so no square
      // corner cuts them.
      ..drawRRect(
        RRect.fromRectAndRadius(edge, const Radius.circular(GaiaRadius.row)),
        paint,
      );
    if (_haloShown > 0) {
      _paintBand(
        canvas,
        Rect.fromLTRB(clip.left, edge.top - _haloFade, clip.right, edge.top),
      );
    }
    canvas.restore();
  }

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

class _RenderHaloHole extends RenderProxyBox {
  _RenderChatBody? _body;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _body = _RenderChatBody._of(this)
      ?.._holes.add(this)
      ..markNeedsPaint();
  }

  @override
  void detach() {
    _body
      ?.._holes.remove(this)
      ..markNeedsPaint();
    _body = null;
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    _body?.markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final body = _body;
    final band = body?._band();
    if (body != null && band != null && body._haloShown > 0) {
      final origin = MatrixUtils.transformPoint(
        getTransformTo(body),
        Offset.zero,
      );
      context.canvas
        ..save()
        ..clipRRect(
          RRect.fromRectAndRadius(
            offset & size,
            const Radius.circular(GaiaRadius.chip),
          ),
        );
      body._paintBand(context.canvas, band.shift(offset - origin));
      context.canvas.restore();
    }
    super.paint(context, offset);
  }
}

class _RenderFieldBox extends RenderProxyBox {
  _RenderFieldBox(this.clearStars);

  /// Tells the starfield where the field is, for its stars to fade round.
  void Function(RRect? box)? clearStars;

  /// The field's outline as last told, in global coordinates.
  RRect? _told;

  _RenderChatBody? _body;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _body = _RenderChatBody._of(this)?.._field = this;
  }

  @override
  void detach() {
    if (_body?._field == this) _body!._field = null;
    _body = null;
    if (_told != null) clearStars?.call(null);
    _told = null;
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    // Rounded as the light in its gap is.
    final box = RRect.fromRectAndRadius(
      MatrixUtils.transformRect(getTransformTo(null), Offset.zero & size),
      const Radius.circular(GaiaRadius.row),
    );
    if (box == _told) return;
    _told = box;
    // Not mid-paint: the starfield repaints for it.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (attached && _told == box) clearStars?.call(box);
    });
  }
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
