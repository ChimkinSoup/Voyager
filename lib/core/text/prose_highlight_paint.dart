import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// How far the corners of a `==highlight==` fill are rounded
/// (EMPHASIS_FORMATTING.md §3.4).
///
/// Against a body line band of around 20px this reads as a soft edge rather
/// than a pill: the shape is still a highlighter stroke, just not a knife.
const double kProseHighlightRadius = 4;

/// What a `==highlight==` run carries in place of its fill.
///
/// [TextStyle.backgroundColor] can only ever paint a hard rect — there is no
/// radius on it, and no parameter that reaches the rect Skia fills behind a
/// run — so the fill is drawn separately, by `ProseHighlightLayer` beneath an
/// editable field and `ProseHighlightUnderlay` beneath a read surface, and the
/// run itself is only *marked*.
///
/// The mark is fully transparent, so a surface that renders emphasis without
/// mounting either of those shows no stray ink rather than a stray rect. Its
/// low bit is what keeps it distinct from the plain `Colors.transparent` a
/// caller may set for reasons of its own.
const Color kProseHighlightMark = Color(0x00000001);

/// The paragraph ranges of [root] that carry [kProseHighlightMark], merged
/// across the style runs a single `==…==` is split into.
///
/// Offsets are the laid-out paragraph's own, not the document's: a
/// [PlaceholderSpan] counts as the one character it occupies there, which is
/// what lets this run over a tree a read surface has already chopped up for
/// tag pills or `$…$` math.
///
/// Background colour inherits down the tree the way every other text property
/// does, so a run is marked when the nearest style that names one names this —
/// or when it sits under one that does and names a background of its own. That
/// second case is a search keyword's wash inside a `==highlight==`
/// (`applyStyledRanges`): only one style slot carries a background, real ink
/// wins it, and the run is still inside the fill. Without it the fill would
/// split at every keyword and each fragment would round its own corners.
List<TextRange> proseHighlightRanges(InlineSpan root) {
  final ranges = <TextRange>[];
  var offset = 0;
  int? open;

  void close(int end) {
    if (open == null) return;
    ranges.add(TextRange(start: open!, end: end));
    open = null;
  }

  void walk(InlineSpan node, Color? inherited, bool underMark) {
    final own = node.style?.backgroundColor;
    final background = own ?? inherited;
    if (node is! TextSpan) {
      // A placeholder is one character to the paragraph, and never marked:
      // whatever it renders paints its own background.
      close(offset);
      offset += 1;
      return;
    }
    final marked =
        background == kProseHighlightMark || (underMark && own != null);
    final text = node.text;
    if (text != null && text.isNotEmpty) {
      if (marked) {
        open ??= offset;
      } else {
        close(offset);
      }
      offset += text.length;
    }
    for (final child in node.children ?? const <InlineSpan>[]) {
      walk(child, background, marked);
    }
  }

  walk(root, null, false);
  close(offset);
  return ranges;
}

/// The boxes a laid-out paragraph reports for one range.
///
/// Both paragraph holders expose the same call under different names —
/// [TextPainter.getBoxesForSelection] for the layers that lay out their own
/// copy, `RenderParagraph.getBoxesForSelection` for the underlay that borrows
/// the one already on screen — so the geometry below takes it as a function
/// rather than picking one.
typedef ProseBoxesFor = List<ui.TextBox> Function(TextSelection selection);

/// One rect per line each of [ranges] covers.
///
/// [ProseBoxesFor] returns a box per *style run*, so `==a **b** c==` comes back
/// as three abutting boxes on one line. Rounding those individually would put
/// corners in the middle of a phrase, and — the fill being translucent — the
/// seams where they meet would double-blend into visible rules. Merging by
/// line gives one rect per line instead, which is also what lets a wrapped
/// highlight round each of its fragments.
List<Rect> proseHighlightRects(
  Iterable<TextRange> ranges,
  ProseBoxesFor boxesFor,
) {
  final rects = <Rect>[];
  for (final range in ranges) {
    if (range.isCollapsed) continue;
    // Per range, not across them: two highlights sharing a line are two fills,
    // and merging them would swallow the plain words between.
    final lines = <double, Rect>{};
    for (final box in boxesFor(
      TextSelection(baseOffset: range.start, extentOffset: range.end),
    )) {
      final rect = box.toRect();
      if (rect.isEmpty) continue;
      // Boxes on one line share a top to within rounding; key on it so runs of
      // different styles merge while wrapped lines stay apart.
      final key = (rect.top * 4).roundToDouble();
      final merged = lines[key];
      lines[key] = merged == null ? rect : merged.expandToInclude(rect);
    }
    rects.addAll(lines.values);
  }
  return rects;
}

/// Fills [rects] with [color], corners rounded to [kProseHighlightRadius].
///
/// One [Path], one fill. The colour is translucent, so rects drawn separately
/// would double-blend wherever two touch; a single fill paints every pixel of
/// the union exactly once. Rounded rects are added in one winding direction,
/// which is what makes the non-zero fill a union rather than a set of holes.
void paintProseHighlights(Canvas canvas, List<Rect> rects, Color color) {
  if (rects.isEmpty) return;
  final path = Path();
  for (final rect in rects) {
    path.addRRect(
      RRect.fromRectAndRadius(
        rect,
        const Radius.circular(kProseHighlightRadius),
      ),
    );
  }
  canvas.drawPath(path, Paint()..color = color);
}
