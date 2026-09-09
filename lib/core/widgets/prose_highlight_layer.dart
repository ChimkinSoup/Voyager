import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:voyager/core/text/prose_highlight_paint.dart';
import 'package:voyager/core/text/prose_text_span.dart';

/// Paints the fill behind `==highlighted==` text in an editable field, with
/// the rounded corners [TextStyle.backgroundColor] cannot give it.
///
/// Skia fills a run's background as a plain rect and nothing on [TextStyle]
/// reaches its corners, so the fill is lifted out of the paragraph entirely:
/// [buildProseSpan] leaves a highlighted run carrying only
/// [kProseHighlightMark], and this layer finds those runs and draws them.
///
/// Positioned by its caller exactly like [SelectionHighlightLayer] — same
/// [style]/[strutStyle] and the field's `overlayPadding`, in a
/// `Positioned.fill` under an `IgnorePointer` — so the [TextPainter] here
/// wraps the text identically and every box it reports lands on the real
/// glyph. It belongs *beneath* the field, above the selection layer: the fill
/// is translucent and would wash out the glyphs from above, and it sat above
/// the selection back when the paragraph drew it.
class ProseHighlightLayer extends StatefulWidget {
  const ProseHighlightLayer({
    super.key,
    required this.controller,
    required this.style,
    required this.color,
    required this.spanBuilder,
    this.strutStyle,
    this.textAlign = TextAlign.start,
    this.textHeightBehavior,
    this.locale,
    this.scrollController,
  });

  final TextEditingController controller;
  final TextStyle style;

  /// The fill, already at its final alpha — [ProseEmphasisTheme.highlightColor].
  final Color color;

  /// Builds the paragraph this layer measures against, and carries the marks
  /// it looks for: [ProseEditingController.overlaySpan].
  final ProseSpanBuilder spanBuilder;

  final StrutStyle? strutStyle;
  final TextAlign textAlign;
  final TextHeightBehavior? textHeightBehavior;
  final Locale? locale;

  /// The same [ScrollController] the field's [TextField] was given, when it
  /// can scroll internally.
  final ScrollController? scrollController;

  @override
  State<ProseHighlightLayer> createState() => _ProseHighlightLayerState();
}

class _ProseHighlightLayerState extends State<ProseHighlightLayer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_repaint);
  }

  @override
  void didUpdateWidget(covariant ProseHighlightLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_repaint);
      widget.controller.addListener(_repaint);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_repaint);
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    // Cheap out before laying anything out: most fields hold no highlight at
    // all, and this listener runs on every keystroke.
    if (!text.contains('=')) return const SizedBox.shrink();

    final painter = _ProseHighlightPainter(
      span: widget.spanBuilder(text, widget.style),
      style: widget.style,
      strutStyle: widget.strutStyle,
      textAlign: widget.textAlign,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      textHeightBehavior:
          widget.textHeightBehavior ??
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
          final offset = scrollController.hasClients
              ? scrollController.offset
              : 0.0;
          return Transform.translate(
            offset: Offset(0, -offset),
            child: CustomPaint(painter: painter),
          );
        },
      ),
    );
  }
}

class _ProseHighlightPainter extends CustomPainter {
  _ProseHighlightPainter({
    required this.span,
    required this.style,
    required this.strutStyle,
    required this.textAlign,
    required this.textDirection,
    required this.textScaler,
    required this.textHeightBehavior,
    required this.locale,
    required this.color,
  });

  /// The field's text as the field itself renders it — same weights, same
  /// slants, same collapsed delimiters — so the boxes below land on the real
  /// glyphs, and marked so the ranges can be read straight off it.
  final TextSpan span;

  final TextStyle style;
  final StrutStyle? strutStyle;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final TextHeightBehavior? textHeightBehavior;
  final Locale? locale;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final ranges = proseHighlightRanges(span);
    if (ranges.isEmpty) return;

    final painter = TextPainter(
      text: span,
      textAlign: textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      strutStyle: strutStyle,
      textHeightBehavior: textHeightBehavior,
      locale: locale,
    )..layout(maxWidth: size.width);

    paintProseHighlights(
      canvas,
      proseHighlightRects(
        ranges,
        (selection) => painter.getBoxesForSelection(
          selection,
          boxHeightStyle: ui.BoxHeightStyle.tight,
          boxWidthStyle: ui.BoxWidthStyle.tight,
        ),
      ),
      color,
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant _ProseHighlightPainter old) =>
      old.span != span ||
      old.style != style ||
      old.strutStyle != strutStyle ||
      old.textAlign != textAlign ||
      old.textDirection != textDirection ||
      old.textScaler != textScaler ||
      old.textHeightBehavior != textHeightBehavior ||
      old.locale != locale ||
      old.color != color;
}
