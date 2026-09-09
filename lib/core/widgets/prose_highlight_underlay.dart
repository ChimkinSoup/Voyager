import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:voyager/core/text/prose_highlight_paint.dart';

/// Paints the fill behind `==highlighted==` text on a read surface, with the
/// rounded corners [TextStyle.backgroundColor] cannot give it.
///
/// Wrap the `Text.rich` that renders the prose. [proseReadRanges] leaves a
/// highlighted run carrying only [kProseHighlightMark]; this finds the
/// paragraph the child laid out, asks *it* where those runs ended up, and
/// fills them before the glyphs go down.
///
/// Borrowing the child's paragraph rather than laying out a second copy — the
/// way the layers around an editable field have to — is what makes this work
/// on the surfaces that chop their text up: a tag pill or a `$…$` equation is
/// a `WidgetSpan`, whose size an independent [TextPainter] cannot know, but
/// which the real paragraph has already placed.
class ProseHighlightUnderlay extends SingleChildRenderObjectWidget {
  const ProseHighlightUnderlay({
    super.key,
    required this.color,
    required Widget super.child,
  });

  /// The fill, already at its final alpha — [ProseEmphasisTheme.highlightColor].
  final Color color;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderProseHighlightUnderlay(color);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderProseHighlightUnderlay renderObject,
  ) {
    renderObject.color = color;
  }
}

/// The render object behind [ProseHighlightUnderlay].
class RenderProseHighlightUnderlay extends RenderProxyBox {
  RenderProseHighlightUnderlay(this._color);

  Color _color;
  set color(Color value) {
    if (_color == value) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _paintFill(context, offset);
    super.paint(context, offset);
  }

  void _paintFill(PaintingContext context, Offset offset) {
    final paragraph = _paragraphOf(child);
    if (paragraph == null) return;
    final ranges = proseHighlightRanges(paragraph.text);
    if (ranges.isEmpty) return;
    final rects = proseHighlightRects(ranges, paragraph.getBoxesForSelection);
    if (rects.isEmpty) return;

    final canvas = context.canvas;
    canvas.save();
    // A paragraph capped with `maxLines` still reports boxes for the lines it
    // dropped, and a fill for text the reader cannot see would sit on the card
    // as a stray smudge.
    canvas.clipRect(offset & size);
    canvas.translate(offset.dx, offset.dy);
    // Where the paragraph sits inside us: `Text` may put a `Semantics` or a
    // selection container in between, and a parent may inset it.
    final origin = MatrixUtils.transformPoint(
      paragraph.getTransformTo(this),
      Offset.zero,
    );
    canvas.translate(origin.dx, origin.dy);
    paintProseHighlights(canvas, rects, _color);
    canvas.restore();
  }

  /// The first [RenderParagraph] under [node], depth first.
  ///
  /// Depth first from the top finds the child's *own* paragraph before any a
  /// placeholder inside it holds — the text of a tag pill, which paints its
  /// own background and is measured in its own coordinate space.
  static RenderParagraph? _paragraphOf(RenderObject? node) {
    if (node == null) return null;
    if (node is RenderParagraph) return node;
    RenderParagraph? found;
    node.visitChildren((child) {
      found ??= _paragraphOf(child);
    });
    return found;
  }
}
