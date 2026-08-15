import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Paints a multi-line field's selection highlight in place of the one
/// [EditableText] draws, because two things about Flutter's are wrong on a
/// ragged paragraph and neither is reachable through a parameter.
///
///  * **The block out to the widest line.** `EditableText`'s
///    `defaultSelectionWidthStyle` is [ui.BoxWidthStyle.max] on every non-web
///    platform, which emits a second, filler box on each selected line running
///    from that line's last glyph out to the *paragraph's* width. Dragging over
///    a block of prose therefore highlights a rectangle, including a wide band
///    of empty space past the end of every short line — characters that are not
///    there and that copying does not pick up.
///  * **The seam between lines.** The per-line boxes do not tile: a line's box
///    is its ascent plus descent, while the next line starts a full line
///    *advance* below, and the two differ by a fraction of a pixel. Every
///    [ui.BoxHeightStyle] leaves that hole — `tight`, `max`, `strut` and all
///    three `includeLineSpacing*` variants were measured, and each one puts the
///    same gap between consecutive rows. `RenderEditable` then draws every box
///    with its own `canvas.drawRect`, so the field background shows through as
///    a pale rule across a multi-line selection.
///
/// Both are fixed here by construction:
///
///  * Horizontally, each row is only as wide as the glyphs it actually covers,
///    taken from [ui.BoxWidthStyle.tight] boxes. A line that *has* glyphs ends
///    exactly at its last one, with nothing standing in for the newline after
///    it — that mark reads as a trailing space the text does not contain. Only
///    a selected line with no glyphs at all gets a short [_sliverRatio] mark,
///    so a blank line inside a selection is still visibly part of it instead of
///    a hole in the column.
///  * Vertically, rows are the line **bands** from [TextPainter.computeLineMetrics]
///    — line _i_ spans the sum of the heights before it to that plus its own —
///    so consecutive bands share an exact edge and cannot leave a gap.
///
/// The rows are then filled as a **single** [Path] in one [Canvas.drawPath].
/// That part is not incidental: the selection colour is translucent
/// (`colorScheme.primary` at 40%), so rows drawn as separate rects would
/// double-blend wherever they touch and trade the pale seam for a dark one.
/// One fill paints every pixel of the union exactly once.
///
/// Positioned by its caller exactly like `SpellCheckSquiggleLayer` — same
/// [style]/[strutStyle]/padding as the field, in a `Positioned.fill` under an
/// `IgnorePointer` — so the [TextPainter] here wraps the text identically and
/// every box it reports lands on the real glyph. It belongs directly *beneath*
/// the field in the stack, where `EditableText` was drawing this highlight: the
/// fill is translucent and would wash out the glyphs from above.
///
/// The caller must also suppress the field's own highlight
/// (`TextSelectionThemeData(selectionColor: Colors.transparent)`) and resolve
/// [color] *outside* that override, or this layer paints nothing too.
class SelectionHighlightLayer extends StatefulWidget {
  const SelectionHighlightLayer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.style,
    required this.color,
    this.strutStyle,
    this.textAlign = TextAlign.start,
    this.textHeightBehavior,
    this.locale,
    this.scrollController,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle style;

  /// The highlight fill, already resolved from the ambient
  /// [TextSelectionThemeData] — see [resolveSelectionColor].
  final Color color;

  final StrutStyle? strutStyle;
  final TextAlign textAlign;
  final TextHeightBehavior? textHeightBehavior;
  final Locale? locale;

  /// The same [ScrollController] the field's [TextField] was given, when it
  /// can scroll internally.
  final ScrollController? scrollController;

  @override
  State<SelectionHighlightLayer> createState() =>
      _SelectionHighlightLayerState();
}

/// The fill [TextField] would have used for its own highlight.
///
/// Mirrors `TextField.build`, which falls back to `colorScheme.primary` at 40%
/// when the ambient theme names no colour. Call this *above* the
/// `TextSelectionTheme` that blanks the field's highlight, or it resolves to
/// the transparent override.
Color resolveSelectionColor(BuildContext context) {
  final theme = Theme.of(context);
  return TextSelectionTheme.of(context).selectionColor ??
      theme.colorScheme.primary.withValues(alpha: 0.4);
}

class _SelectionHighlightLayerState extends State<SelectionHighlightLayer> {
  @override
  void initState() {
    super.initState();
    _listen(widget);
  }

  @override
  void didUpdateWidget(covariant SelectionHighlightLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.focusNode != widget.focusNode) {
      _unlisten(oldWidget);
      _listen(widget);
    }
  }

  @override
  void dispose() {
    _unlisten(widget);
    super.dispose();
  }

  void _listen(SelectionHighlightLayer w) {
    w.controller.addListener(_repaint);
    w.focusNode.addListener(_repaint);
  }

  void _unlisten(SelectionHighlightLayer w) {
    w.controller.removeListener(_repaint);
    w.focusNode.removeListener(_repaint);
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.controller.selection;
    // Material only shows a highlight on the focused field (`selectionColor:
    // focusNode.hasFocus ? ... : null`, text_field.dart), so this one has to
    // disappear with focus as well.
    if (!widget.focusNode.hasFocus ||
        !selection.isValid ||
        selection.isCollapsed) {
      return const SizedBox.shrink();
    }

    final painter = _SelectionHighlightPainter(
      text: widget.controller.text,
      selection: selection,
      style: widget.style,
      strutStyle: widget.strutStyle,
      textAlign: widget.textAlign,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      textHeightBehavior: widget.textHeightBehavior ??
          DefaultTextHeightBehavior.maybeOf(context),
      locale: widget.locale,
      color: widget.color,
    );

    final scrollController = widget.scrollController;
    if (scrollController == null) {
      return ClipRect(child: CustomPaint(painter: painter));
    }
    return ClipRect(
      child: ListenableBuilder(
        listenable: scrollController,
        builder: (context, _) {
          final offset =
              scrollController.hasClients ? scrollController.offset : 0.0;
          return Transform.translate(
            offset: Offset(0, -offset),
            child: CustomPaint(painter: painter),
          );
        },
      ),
    );
  }
}

class _SelectionHighlightPainter extends CustomPainter {
  _SelectionHighlightPainter({
    required this.text,
    required this.selection,
    required this.style,
    required this.strutStyle,
    required this.textAlign,
    required this.textDirection,
    required this.textScaler,
    required this.textHeightBehavior,
    required this.locale,
    required this.color,
  });

  final String text;
  final TextSelection selection;
  final TextStyle style;
  final StrutStyle? strutStyle;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final TextHeightBehavior? textHeightBehavior;
  final Locale? locale;
  final Color color;

  /// Width of the mark that stands in for a selected *empty* line, in fractions
  /// of the line's height.
  ///
  /// A space is around 0.3em wide in the faces this app uses and a line is
  /// around 1.3em tall, so a quarter of the line height reads as roughly one
  /// space without this having to measure a glyph the paragraph may not
  /// contain.
  static const double _sliverRatio = 0.25;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      strutStyle: strutStyle,
      textHeightBehavior: textHeightBehavior,
      locale: locale,
    )..layout(maxWidth: size.width);

    final rows = _rows(painter);
    if (rows.isNotEmpty) {
      // One path, one fill: see the class doc on why these must not be drawn
      // as separate rects.
      final path = Path();
      for (final row in rows) {
        path.addRect(row);
      }
      canvas.drawPath(path, Paint()..color = color);
    }
    painter.dispose();
  }

  List<Rect> _rows(TextPainter painter) {
    final lines = painter.computeLineMetrics();
    if (lines.isEmpty) return const [];

    final start = selection.start.clamp(0, text.length);
    final end = selection.end.clamp(0, text.length);
    if (start >= end) return const [];

    // Band i spans [bandEdges[i], bandEdges[i + 1]). Built from the line
    // heights rather than from the selection boxes precisely because these
    // tile — the boxes do not.
    final bandEdges = List<double>.filled(lines.length + 1, 0);
    for (var i = 0; i < lines.length; i++) {
      bandEdges[i + 1] = bandEdges[i] + lines[i].height;
    }

    final extents = <int, ({double left, double right})>{};
    void cover(int band, double left, double right) {
      final existing = extents[band];
      extents[band] = existing == null
          ? (left: left, right: right)
          : (
              left: math.min(existing.left, left),
              right: math.max(existing.right, right),
            );
    }

    for (final box in painter.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
      boxHeightStyle: ui.BoxHeightStyle.tight,
      boxWidthStyle: ui.BoxWidthStyle.tight,
    )) {
      cover(
        _bandAt(bandEdges, (box.top + box.bottom) / 2),
        math.min(box.left, box.right),
        math.max(box.left, box.right),
      );
    }

    // A band with width holds glyphs, so its row already ends at the last of
    // them. What is left are the selected lines with no glyphs at all — which
    // still report a box, only an empty one — and those would otherwise punch
    // a hole in the column.
    final withGlyphs = {
      for (final entry in extents.entries)
        if (entry.value.right > entry.value.left) entry.key,
    };

    for (var i = start; i < end; i++) {
      if (text.codeUnitAt(i) != 0x0A) continue;
      final position = TextPosition(offset: i);
      final caret = painter.getOffsetForCaret(position, Rect.zero);
      // Centre of the caret rather than its top edge: the top can sit a hair
      // above the band it belongs to and pick the line above.
      final band = _bandAt(
        bandEdges,
        caret.dy + painter.getFullHeightForCaret(position, Rect.zero) / 2,
      );
      if (withGlyphs.contains(band)) continue;
      final width = (bandEdges[band + 1] - bandEdges[band]) * _sliverRatio;
      if (textDirection == TextDirection.rtl) {
        cover(band, caret.dx - width, caret.dx);
      } else {
        cover(band, caret.dx, caret.dx + width);
      }
    }

    return [
      for (final entry in extents.entries)
        if (entry.value.right > entry.value.left)
          Rect.fromLTRB(
            entry.value.left,
            bandEdges[entry.key],
            entry.value.right,
            bandEdges[entry.key + 1],
          ),
    ];
  }

  /// The band containing [y], clamped to the paragraph.
  static int _bandAt(List<double> edges, double y) {
    for (var i = edges.length - 2; i > 0; i--) {
      if (y >= edges[i]) return i;
    }
    return 0;
  }

  @override
  bool shouldRepaint(covariant _SelectionHighlightPainter old) {
    return old.text != text ||
        old.selection != selection ||
        old.style != style ||
        old.strutStyle != strutStyle ||
        old.textAlign != textAlign ||
        old.textDirection != textDirection ||
        old.textScaler != textScaler ||
        old.textHeightBehavior != textHeightBehavior ||
        old.locale != locale ||
        old.color != color;
  }
}
