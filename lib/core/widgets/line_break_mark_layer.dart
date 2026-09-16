import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/widgets/scroll_offset_follower.dart';

/// Gap between the end of a line's text and its mark, in em.
const double _kMarkGap = 0.3;

/// The mark's width, stem top and arm, in em. The stem rises above the middle
/// of the letters and the arm sits a little below it, the way a ↵ glyph does.
const double _kMarkWidth = 0.5;
const double _kMarkStemTop = 0.32;
const double _kMarkArm = 0.12;
const double _kMarkHead = 0.14;
const double _kMarkStroke = 1.2;

/// How far above the baseline the middle of a lowercase word sits, in em:
/// half of Iosevka Aile's x-height (520 of 1000 units per em).
const double _kMarkLift = 0.26;

/// Paints a ↵ after every line the user ended with Enter, so a real line
/// break reads differently from a line that only wrapped. Blank lines get one
/// too, at their start. The text is never touched; the marks are paint only.
///
/// Positioned by its caller like [ProseHighlightLayer] — same [style],
/// [strutStyle] and the field's `overlayPadding`, in a `Positioned.fill` under
/// an `IgnorePointer` — so the [TextPainter] here wraps the text exactly as the
/// field does.
class LineBreakMarkLayer extends StatefulWidget {
  const LineBreakMarkLayer({
    super.key,
    required this.controller,
    required this.style,
    required this.color,
    this.spanBuilder,
    this.strutStyle,
    this.scrollController,
  });

  final TextEditingController controller;
  final TextStyle style;
  final Color color;

  /// Builds the paragraph this layer measures against —
  /// [ProseEditingController.overlaySpan] on a field with emphasis, so hidden
  /// delimiters take up the width they really do.
  final ProseSpanBuilder? spanBuilder;

  final StrutStyle? strutStyle;

  /// The same [ScrollController] the field's [TextField] was given, when it
  /// can scroll internally.
  final ScrollController? scrollController;

  @override
  State<LineBreakMarkLayer> createState() => _LineBreakMarkLayerState();
}

class _LineBreakMarkLayerState extends State<LineBreakMarkLayer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_repaint);
  }

  @override
  void didUpdateWidget(covariant LineBreakMarkLayer oldWidget) {
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
    if (!text.contains('\n')) return const SizedBox.shrink();

    final textScaler = MediaQuery.textScalerOf(context);
    final em = textScaler.scale(widget.style.fontSize ?? 14);
    final painter = _LineBreakMarkPainter(
      span: (widget.spanBuilder ?? flatProseSpan)(text, widget.style),
      strutStyle: widget.strutStyle,
      textDirection: Directionality.of(context),
      textScaler: textScaler,
      em: em,
      color: widget.color,
    );
    // Clipped top and bottom only, to the field's viewport: a line that runs
    // right up to the wrap width puts its mark in the padding beside it.
    final clipper = _ViewportClipper(overhang: em);

    final scrollController = widget.scrollController;
    if (scrollController == null) {
      return ClipRect(clipper: clipper, child: CustomPaint(painter: painter));
    }
    return ClipRect(
      clipper: clipper,
      child: ScrollOffsetFollower(
        controller: scrollController,
        child: CustomPaint(painter: painter),
      ),
    );
  }
}

class _ViewportClipper extends CustomClipper<Rect> {
  const _ViewportClipper({required this.overhang});

  final double overhang;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, 0, size.width + overhang, size.height);

  @override
  bool shouldReclip(_ViewportClipper old) => old.overhang != overhang;
}

class _LineBreakMarkPainter extends CustomPainter {
  _LineBreakMarkPainter({
    required this.span,
    required this.strutStyle,
    required this.textDirection,
    required this.textScaler,
    required this.em,
    required this.color,
  });

  final TextSpan span;
  final StrutStyle? strutStyle;
  final TextDirection textDirection;
  final TextScaler textScaler;

  /// The field's font size after text scaling.
  final double em;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final text = span.toPlainText();
    final painter = TextPainter(
      text: span,
      strutStyle: strutStyle,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: size.width);
    final lines = painter.computeLineMetrics();
    if (lines.isEmpty) {
      painter.dispose();
      return;
    }
    // The strut is forced, so every line shares the first one's ascent.
    final ascent = lines.first.ascent;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kMarkStroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    for (var i = text.indexOf('\n'); i != -1; i = text.indexOf('\n', i + 1)) {
      // A CRLF is one grapheme, and a caret inside it snaps to the next line.
      final breakAt = i > 0 && text.codeUnitAt(i - 1) == 0x0D ? i - 1 : i;
      // The leading edge of the break itself: past any trailing spaces, at
      // the top of its line.
      final caret = painter.getOffsetForCaret(
        TextPosition(offset: breakAt),
        Rect.zero,
      );
      final left = math.min(caret.dx, size.width) + _kMarkGap * em;
      final right = left + _kMarkWidth * em;
      final middle = caret.dy + ascent - _kMarkLift * em;
      final arm = middle + _kMarkArm * em;
      final head = _kMarkHead * em;
      path
        ..moveTo(right, middle - _kMarkStemTop * em)
        ..lineTo(right, arm)
        ..lineTo(left, arm)
        ..moveTo(left + head, arm - head)
        ..lineTo(left, arm)
        ..lineTo(left + head, arm + head);
    }
    painter.dispose();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _LineBreakMarkPainter old) =>
      old.span != span ||
      old.strutStyle != strutStyle ||
      old.textDirection != textDirection ||
      old.textScaler != textScaler ||
      old.em != em ||
      old.color != color;
}
