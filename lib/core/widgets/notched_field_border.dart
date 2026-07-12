import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:voyager/core/constants/app_constants.dart';

/// A self-contained "chrome" wrapper that draws a rounded border, a fill,
/// an accent focus glow, and (optionally) a Material-style floating label
/// that rises onto the border and cuts a notch into it — without relying on
/// Flutter's [InputDecorator]/[InputDecoration] border-notching machinery.
///
/// This widget is purely decorative: it paints around [child] and never
/// touches [child]'s own layout, padding, or content position. That
/// decoupling is what makes it safe to wrap *any* input widget — including
/// composite ones like a `TextField` overlaid with a custom highlight
/// painter — without shifting the wrapped content by even a pixel when the
/// label floats up or the border animates.
///
/// See `TEXTBOX_WIDGET.md` at the repository root for the full design
/// rationale, usage guide, and migration notes.
class NotchedFieldBorder extends StatefulWidget {
  const NotchedFieldBorder({
    super.key,
    required this.focusNode,
    required this.child,
    this.label,
    this.hasContent = false,
    this.enabled = true,
    this.accentColor,
    this.borderRadius = 18,
    this.borderWidth = 1.8,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 18,
    ),
    this.labelStyle,
    this.showGlow = true,
    this.showFill = true,
    this.alignLabelToTop = false,
  });

  /// The wrapped input widget. Its own decoration should have no visible
  /// border/fill of its own (e.g. `InputBorder.none`) so it doesn't double up
  /// with the border this widget paints.
  final Widget child;

  /// Focus node of the wrapped input; drives the focused border color, glow,
  /// and (together with [hasContent]) the floating label position.
  final FocusNode focusNode;

  /// Floating label text. When null or empty, no label/notch is drawn — just
  /// a plain, continuously-stroked rounded border.
  final String? label;

  /// Whether the wrapped input currently has non-empty content. Combined
  /// with focus state to decide whether the label should be floated:
  /// `floated = focused || hasContent`, matching standard Material behavior.
  final bool hasContent;

  final bool enabled;

  /// Accent color used for the focused border, glow, and floated+focused
  /// label. Defaults to the theme's primary color.
  final Color? accentColor;

  final double borderRadius;
  final double borderWidth;

  /// Padding reserved for [child]'s own content. This widget does not apply
  /// padding itself — it only uses this value to align the label with where
  /// [child] is expected to start its text (top-left of its content area).
  final EdgeInsetsGeometry contentPadding;

  /// Base style for the label at its resting (inline, unfloated) size. The
  /// floated label reuses this style scaled down (matching Material's
  /// standard 0.75x floating scale) and recolored based on focus.
  final TextStyle? labelStyle;

  /// Whether to draw the accent glow (drop shadow) when focused.
  final bool showGlow;

  /// Whether to paint a background fill behind [child].
  final bool showFill;

  /// When true, the resting (unfloated) label is aligned to the top of the
  /// content area — correct for multi-line fields, whose text starts at the
  /// top. When false (default), the resting label is vertically centered in
  /// the field, so on a single-line field the placeholder sits on the vertical
  /// center line (where the text actually renders) rather than being pinned to
  /// the top-padding offset.
  final bool alignLabelToTop;

  @override
  State<NotchedFieldBorder> createState() => _NotchedFieldBorderState();
}

class _NotchedFieldBorderState extends State<NotchedFieldBorder>
    with TickerProviderStateMixin {
  late final AnimationController _floatController;
  late final AnimationController _focusController;

  bool get _shouldFloat => widget.focusNode.hasFocus || widget.hasContent;

  @override
  void initState() {
    super.initState();
    final floated = _shouldFloat;
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      value: floated ? 1 : 0,
    );
    _focusController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      value: widget.focusNode.hasFocus ? 1 : 0,
    );
    widget.focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant NotchedFieldBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChanged);
      widget.focusNode.addListener(_handleFocusChanged);
    }
    if (oldWidget.hasContent != widget.hasContent ||
        oldWidget.focusNode != widget.focusNode) {
      _syncFloat();
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocusChanged);
    _floatController.dispose();
    _focusController.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    _syncFloat();
    final focused = widget.focusNode.hasFocus;
    if (focused) {
      _focusController.forward();
    } else {
      _focusController.reverse();
    }
  }

  void _syncFloat() {
    if (_shouldFloat) {
      _floatController.forward();
    } else {
      _floatController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final fillColor =
        theme.inputDecorationTheme.fillColor ?? theme.colorScheme.surface;
    final restingColor = widget.enabled ? theme.dividerColor : theme.disabledColor;
    final baseLabelStyle = (widget.labelStyle ??
            theme.textTheme.bodyLarge ??
            const TextStyle())
        .copyWith(color: theme.colorScheme.onSurfaceVariant);
    final resolvedPadding = widget.contentPadding.resolve(
      Directionality.of(context),
    );

    return AnimatedBuilder(
      animation: Listenable.merge([_floatController, _focusController]),
      builder: (context, _) {
        final floatT = _floatController.value;
        final focusT = _focusController.value;
        final borderColor = widget.enabled
            ? Color.lerp(restingColor, accent, focusT)!
            : theme.disabledColor;
        final labelColor = widget.enabled
            ? Color.lerp(
                theme.colorScheme.onSurfaceVariant,
                accent,
                focusT,
              )!
            : theme.disabledColor;

        final hasLabel = (widget.label ?? '').isNotEmpty;
        double gapWidth = 0;
        double gapStart = resolvedPadding.left;
        TextStyle? floatedStyle;
        double floatedHeight = 0;
        double restingHeight = 0;
        double labelLeft = resolvedPadding.left;
        const gapHorizontalPadding = 4.0;
        const floatScale = 0.75;

        if (hasLabel) {
          floatedStyle = baseLabelStyle.copyWith(
            fontSize: (baseLabelStyle.fontSize ?? 16) * floatScale,
          );
          final textDir = Directionality.of(context);
          final floatedPainter = TextPainter(
            text: TextSpan(text: widget.label, style: floatedStyle),
            textDirection: textDir,
            maxLines: 1,
          )..layout();
          final restingPainter = TextPainter(
            text: TextSpan(text: widget.label, style: baseLabelStyle),
            textDirection: textDir,
            maxLines: 1,
          )..layout();
          floatedHeight = floatedPainter.height;
          restingHeight = restingPainter.height;

          // Slide the label right as it floats so its notch clears the rounded
          // top-left corner — the top edge only runs straight starting at
          // x = borderRadius, so anchoring the gap there keeps equal padding on
          // both sides of the label instead of it hugging the left corner.
          final floatedLabelLeft = math.max(
            resolvedPadding.left,
            widget.borderRadius + gapHorizontalPadding,
          );
          labelLeft =
              lerpDouble(resolvedPadding.left, floatedLabelLeft, floatT)!;

          final targetGapWidth =
              floatedPainter.width + gapHorizontalPadding * 2;
          gapWidth = targetGapWidth * floatT;
          gapStart = labelLeft - gapHorizontalPadding;
        }

        return Stack(
          clipBehavior: Clip.none,
          // `passthrough` hands [child] the exact same constraints it would
          // have received without this wrapper (e.g. tight constraints from
          // an ancestor `Expanded` for an `expands: true` field), so wrapping
          // a field in this border never changes its sizing behavior.
          fit: StackFit.passthrough,
          children: [
            if (widget.showFill)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: fillColor,
                    borderRadius: BorderRadius.circular(widget.borderRadius),
                    boxShadow: widget.showGlow && focusT > 0
                        ? [
                            BoxShadow(
                              color: accent.withValues(alpha: popupGlowAlpha * focusT),
                              blurRadius: 14,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _NotchedBorderPainter(
                    borderRadius: widget.borderRadius,
                    borderWidth: widget.borderWidth,
                    color: borderColor,
                    gapStart: gapStart,
                    gapWidth: gapWidth,
                  ),
                ),
              ),
            ),
            if (hasLabel)
              Positioned.fill(
                child: IgnorePointer(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Center the resting label against the field's measured
                      // height so it lands on the vertical center line (where a
                      // single-line field draws its text), rather than the
                      // top-padding offset. Multi-line fields opt into
                      // top-alignment instead.
                      final restingTop =
                          widget.alignLabelToTop ||
                              !constraints.maxHeight.isFinite
                          ? resolvedPadding.top
                          : (constraints.maxHeight - restingHeight) / 2;
                      final labelTop = lerpDouble(
                        restingTop,
                        -floatedHeight / 2,
                        floatT,
                      )!;
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            left: labelLeft,
                            top: labelTop,
                            child: Text(
                              widget.label!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle.lerp(
                                baseLabelStyle,
                                floatedStyle,
                                floatT,
                              )?.copyWith(color: labelColor),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Paints a rounded-rectangle border with an optional straight gap along the
/// top edge (the "notch") that a floating label sits in. Unlike
/// [Path.combine]-based cutouts, the gap is built by tracing the rounded
/// rect's outline as a single open path that starts right after the gap and
/// ends right before it — so the stroke simply never touches the gap
/// segment, matching how Flutter's own [OutlineInputBorder] draws its notch.
class _NotchedBorderPainter extends CustomPainter {
  const _NotchedBorderPainter({
    required this.borderRadius,
    required this.borderWidth,
    required this.color,
    required this.gapStart,
    required this.gapWidth,
  });

  final double borderRadius;
  final double borderWidth;
  final Color color;
  final double gapStart;
  final double gapWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;

    final inset = borderWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - borderWidth,
      size.height - borderWidth,
    );
    final radius = (borderRadius - inset).clamp(0.0, borderRadius);

    if (gapWidth <= 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(radius)),
        paint,
      );
      return;
    }

    final maxGapStart = rect.right - radius - gapWidth;
    final minGapStart = rect.left + radius;
    final clampedStart = gapWidth >= (maxGapStart - minGapStart)
        ? (rect.left + rect.right - gapWidth) / 2
        : gapStart.clamp(minGapStart, maxGapStart);
    final gapEnd = clampedStart + gapWidth;

    final path = Path()
      ..moveTo(gapEnd, rect.top)
      ..lineTo(rect.right - radius, rect.top)
      ..arcToPoint(
        Offset(rect.right, rect.top + radius),
        radius: Radius.circular(radius),
      )
      ..lineTo(rect.right, rect.bottom - radius)
      ..arcToPoint(
        Offset(rect.right - radius, rect.bottom),
        radius: Radius.circular(radius),
      )
      ..lineTo(rect.left + radius, rect.bottom)
      ..arcToPoint(
        Offset(rect.left, rect.bottom - radius),
        radius: Radius.circular(radius),
      )
      ..lineTo(rect.left, rect.top + radius)
      ..arcToPoint(
        Offset(rect.left + radius, rect.top),
        radius: Radius.circular(radius),
      )
      ..lineTo(clampedStart, rect.top);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _NotchedBorderPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.gapStart != gapStart ||
        oldDelegate.gapWidth != gapWidth ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.borderWidth != borderWidth;
  }
}
