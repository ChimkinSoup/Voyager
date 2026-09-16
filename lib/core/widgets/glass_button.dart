import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/surface_grain.dart';

/// A modular, reusable glassmorphic button widget featuring an authentic glass aesthetic.
///
/// Incorporates a translucent tinted fill (and in dark mode, matte graphite
/// [SurfaceGrain]), dual-gradient specular borders, top gloss reflections,
/// dynamic hover/press states, and full theme adaptability.
///
/// Fully resizeable (via [width], [height], [padding], [margin], [borderRadius], or [dense])
/// and recolorable (via [color] tint, [textColor], [iconColor], or [borderColor]).
class GlassButton extends StatefulWidget {
  const GlassButton({
    super.key,
    this.onPressed,
    this.label,
    this.icon,
    this.trailingIcon,
    this.child,
    this.color,
    this.textColor,
    this.iconColor,
    this.borderColor,
    this.width,
    this.height,
    this.padding,
    this.margin,
    this.borderRadius,
    this.glassOpacity,
    this.borderOpacity,
    this.elevation = 1.5,
    this.enabled = true,
    this.dense = false,
    this.tooltip,
    this.alignment = Alignment.center,
    this.focusNode,
    this.autofocus = false,
    this.canRequestFocus = false,
  }) : assert(
          label != null || child != null || icon != null,
          'GlassButton must have either a label, child, or icon',
        );

  /// Callback when the button is tapped. If null or [enabled] is false, the button is disabled.
  final VoidCallback? onPressed;

  /// Text label displayed inside the button. Ignored if [child] is provided.
  final String? label;

  /// Optional leading icon widget (e.g. `Icon(...)`).
  final Widget? icon;

  /// Optional trailing icon widget.
  final Widget? trailingIcon;

  /// Custom child widget. If provided, overrides [label], [icon], and [trailingIcon].
  final Widget? child;

  /// Base tint color for the glass surface.
  /// If null, defaults to theme accent color or surface container.
  final Color? color;

  /// Override color for the text label.
  final Color? textColor;

  /// Override color for the icon(s).
  final Color? iconColor;

  /// Override color for the specular glass border highlight.
  final Color? borderColor;

  /// Explicit width for resizing. If null, sizes to fit content + padding.
  final double? width;

  /// Explicit height for resizing. If null, sizes to fit content + padding.
  final double? height;

  /// Padding inside the glass surface around content.
  final EdgeInsetsGeometry? padding;

  /// Outer margin around the button container.
  final EdgeInsetsGeometry? margin;

  /// Custom border radius for shaping the glass container. Defaults to `BorderRadius.circular(12)` (or `10` when [dense]).
  final BorderRadius? borderRadius;

  /// Base opacity of the glass / paper surface fill. Null uses the theme
  /// default (~0.06 light / ~0.95 dark matte plate) — see DESIGN.md Glass Button.
  final double? glassOpacity;

  /// Base opacity of the specular glass edge highlight. Null uses the theme
  /// default (~0.22 light / ~0.32 dark).
  final double? borderOpacity;

  /// Shadow elevation for depth and drop shadow.
  final double elevation;

  /// Whether the button is active and interactive.
  final bool enabled;

  /// Whether to use compact padding, text, and icon sizes (ideal for toolbars/headers).
  final bool dense;

  /// Optional tooltip message displayed on hover or long press.
  final String? tooltip;

  /// Alignment of internal content.
  final Alignment alignment;

  /// Optional [FocusNode] to control keyboard focus.
  final FocusNode? focusNode;

  /// Whether this button should autofocus on mount. Defaults to `false`.
  final bool autofocus;

  /// Whether this button can request keyboard focus automatically. Defaults to `false`
  /// so buttons don't steal focus and flash focus highlights during page transitions.
  final bool canRequestFocus;

  /// What a null [glassOpacity] / [borderOpacity] resolves to. Public so a
  /// caller that interpolates its own states — the study grading row fades
  /// its four buttons in with the card — starts from these numbers rather
  /// than copying them and drifting when they move.
  static double defaultGlassOpacity(bool isDark) => isDark ? 0.95 : 0.06;

  static double defaultBorderOpacity(bool isDark) => isDark ? 0.32 : 0.22;

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  bool _isPressed = false;
  bool _isFocused = false;

  late final AnimationController _scaleController;
  late Animation<double> _scaleAnimation;
  FocusNode? _internalFocusNode;

  FocusNode get _effectiveFocusNode =>
      widget.focusNode ??
      (_internalFocusNode ??= FocusNode(canRequestFocus: widget.canRequestFocus));

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 180),
    );
    // Placeholder until didChangeDependencies runs (inherited-widget lookups
    // like MediaQuery aren't safe to make in initState).
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.96,
    ).animate(_scaleController);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = VoyagerMotion.reduced(context);
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.96).animate(
      CurvedAnimation(
        parent: _scaleController,
        curve: reduced ? Curves.easeOut : VoyagerSpring.snappyCurve,
      ),
    );
  }

  @override
  void dispose() {
    _scaleController.dispose();
    _internalFocusNode?.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    if (!widget.enabled || widget.onPressed == null) return;
    setState(() => _isPressed = true);
    _scaleController.forward();
  }

  void _handleTapUp(TapUpDetails details) {
    if (!_isPressed) return;
    setState(() => _isPressed = false);
    _scaleController.reverse();
  }

  void _handleTapCancel() {
    if (!_isPressed) return;
    setState(() => _isPressed = false);
    _scaleController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vc = VoyagerColors.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isInteractive = widget.enabled && widget.onPressed != null;

    final effectiveRadius = widget.borderRadius ??
        BorderRadius.circular(widget.dense ? 10.0 : 12.0);

    // Light keeps an accent-tinted wafer; dark defaults to the field plate so
    // the control separates from the live grid without a BackdropFilter.
    final baseColor = widget.color ??
        (isDark
            ? (theme.inputDecorationTheme.fillColor ??
                theme.colorScheme.surface)
            : theme.colorScheme.primary);

    // Ink Slate on cream glass, bone on the dark plate — both are onSurface.
    final defaultFg = widget.textColor ?? theme.colorScheme.onSurface;

    final fgColor = isInteractive
        ? defaultFg
        : defaultFg.withValues(alpha: 0.4);

    final iconColor = widget.iconColor ?? fgColor;

    // Flutter has no cross-platform "prefers-reduced-transparency" signal;
    // `highContrast` is the closest accessibility proxy it exposes. Read here
    // for the same reason [GlassSurface] reads it — otherwise a button stays
    // translucent on top of a surface that has gone near-solid.
    final nearSolid = MediaQuery.maybeOf(context)?.highContrast ?? false;

    final baseGlassOpacity =
        widget.glassOpacity ?? GlassButton.defaultGlassOpacity(isDark);
    final baseBorderOpacity =
        widget.borderOpacity ?? GlassButton.defaultBorderOpacity(isDark);

    // Calculate dynamic glass opacity based on interaction state
    double opacityMultiplier = 1.0;
    if (_isPressed) {
      opacityMultiplier = 1.4;
    } else if (_isHovered) {
      opacityMultiplier = 1.25;
    } else if (!isInteractive) {
      opacityMultiplier = 0.5;
    }

    final currentGlassOpacity =
        (baseGlassOpacity * opacityMultiplier).clamp(0.01, 0.97);

    // Light: flat accent wafer. Dark: matte [SurfaceGrain] uses
    // [currentGlassOpacity] as the plate alpha (near-solid → ~97%).
    final fillAlpha = nearSolid ? 0.97 : currentGlassOpacity;

    // Specular edge highlights
    final borderHighlight = widget.borderColor ??
        (isDark ? Colors.white : baseColor);
    final borderShadow = isDark
        ? vc.shadow.withValues(alpha: 0.5)
        : baseColor.withValues(alpha: 0.3);

    final currentBorderOpacity =
        (baseBorderOpacity * (_isHovered ? 1.3 : 1.0)).clamp(0.1, 0.9);

    final effectivePadding = widget.padding ??
        EdgeInsets.symmetric(
          horizontal: widget.dense ? 10.0 : 16.0,
          vertical: widget.dense ? 6.0 : 10.0,
        );

    Widget content;
    if (widget.child != null) {
      content = widget.child!;
    } else {
      final children = <Widget>[];

      if (widget.icon != null) {
        children.add(
          IconTheme(
            data: IconThemeData(
              color: iconColor,
              size: widget.dense ? 16.0 : 18.0,
            ),
            child: widget.icon!,
          ),
        );
      }

      if (widget.label != null) {
        if (children.isNotEmpty) {
          children.add(SizedBox(width: widget.dense ? 6.0 : 8.0));
        }
        children.add(
          Text(
            widget.label!,
            style: (widget.dense
                    ? theme.textTheme.labelMedium
                    : theme.textTheme.labelLarge)
                ?.copyWith(
              color: fgColor,
              fontWeight: FontWeight.normal,
              letterSpacing: 0.2,
            ),
          ),
        );
      }

      if (widget.trailingIcon != null) {
        if (children.isNotEmpty) {
          children.add(SizedBox(width: widget.dense ? 6.0 : 8.0));
        }
        children.add(
          IconTheme(
            data: IconThemeData(
              color: iconColor,
              size: widget.dense ? 16.0 : 18.0,
            ),
            child: widget.trailingIcon!,
          ),
        );
      }

      content = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: children,
      );
    }

    Widget buttonCore = ScaleTransition(
      scale: _scaleAnimation,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: widget.width,
        height: widget.height,
        margin: widget.margin,
        decoration: BoxDecoration(
          borderRadius: effectiveRadius,
          boxShadow: [
            if (widget.elevation > 0)
              BoxShadow(
                color: (isDark ? vc.shadow : baseColor).withValues(
                  alpha: isDark
                      ? (_isHovered ? 0.35 : 0.2)
                      : (_isHovered ? 0.25 : 0.12),
                ),
                blurRadius: widget.elevation * (_isHovered ? 6.0 : 4.0) * vc.shadowBlurScale,
                offset: Offset(0, _isHovered ? 4.0 : 2.0),
              ),
            // A crisp ring, not a glow: `shadowBlurScale` widens shadows so a
            // 3–5% alpha still separates a surface, but at this ring's alpha
            // that same widening reads as an accent-colored bloom around the
            // button when keyboard focus lands on it.
            if (_isFocused)
              BoxShadow(
                color: baseColor.withValues(alpha: 0.5),
                blurRadius: 0.0,
                spreadRadius: 2.0,
              ),
          ],
        ),
        // No BackdropFilter: a button blurring the animated background redoes
        // that blur on every background frame, and five in the calendar header
        // tripled idle GPU load (~8% -> ~22%). Dark mode uses matte
        // [SurfaceGrain] instead; light keeps a thin tinted wafer.
        child: ClipRRect(
          borderRadius: effectiveRadius,
          child: CustomPaint(
            foregroundPainter: _GlassBorderPainter(
              borderRadius: effectiveRadius,
              borderWidth: _isHovered || _isFocused ? 1.5 : 1.0,
              highlightColor: borderHighlight.withValues(alpha: currentBorderOpacity),
              shadowColor: borderShadow.withValues(alpha: currentBorderOpacity * 0.4),
              outlineColor: baseColor.withValues(alpha: 0.35),
            ),
            child: Stack(
              alignment: widget.alignment,
              children: [
                if (isDark)
                  Positioned.fill(
                    child: SurfaceGrain(
                      color: baseColor.withValues(alpha: fillAlpha),
                      borderRadius: effectiveRadius,
                      grainOpacity: surfaceGrainOpacityForContrast(
                        nearSolid: nearSolid,
                      ),
                      seed: identityHashCode(this),
                    ),
                  )
                else
                  Positioned.fill(
                    child: ColoredBox(
                      color: baseColor.withValues(alpha: fillAlpha),
                    ),
                  ),
                // Top gloss reflection line
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: widget.height != null
                      ? (widget.height! * 0.45).clamp(1.0, 100.0)
                      : 18.0,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                          top: effectiveRadius.topLeft,
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            vc.highlightWash.withValues(
                              alpha: _isHovered ? 0.14 : 0.06,
                            ),
                            vc.highlightWash.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Inner button content
                widget.width != null || widget.height != null
                    ? Container(
                        width: widget.width,
                        height: widget.height,
                        alignment: widget.alignment,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: widget.alignment,
                          child: Padding(
                            padding: effectivePadding,
                            child: content,
                          ),
                        ),
                      )
                    : FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: widget.alignment,
                        child: Padding(
                          padding: effectivePadding,
                          child: content,
                        ),
                      ),
              ],
            ),
          ),
        ),
      ),
    );

    Widget result = GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      onTap: isInteractive ? widget.onPressed : null,
      behavior: HitTestBehavior.opaque,
      child: FocusableActionDetector(
        enabled: isInteractive,
        focusNode: _effectiveFocusNode,
        autofocus: widget.autofocus,
        mouseCursor: isInteractive
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (hovered) {
          if (isInteractive && _isHovered != hovered) {
            setState(() => _isHovered = hovered);
          }
        },
        onShowFocusHighlight: (focused) {
          if (isInteractive && _isFocused != focused) {
            setState(() => _isFocused = focused);
          }
        },
        child: buttonCore,
      ),
    );

    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      result = Tooltip(
        message: widget.tooltip!,
        child: result,
      );
    }

    return result;
  }
}

/// Custom painter to draw a 3D specular gradient border on glass edges.
class _GlassBorderPainter extends CustomPainter {
  _GlassBorderPainter({
    required this.borderRadius,
    required this.borderWidth,
    required this.highlightColor,
    required this.shadowColor,
    required this.outlineColor,
  });

  final BorderRadius borderRadius;
  final double borderWidth;
  final Color highlightColor;
  final Color shadowColor;

  /// Flat 1px outline in the button's base color, drawn beneath the
  /// specular gradient stroke so the glass highlight/shadow still reads on top.
  final Color outlineColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || size.width <= 0 || size.height <= 0) return;
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect);
    final path = Path()..addRRect(rrect);

    final outlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = outlineColor;
    canvas.drawPath(path, outlinePaint);

    // Specular rim: light from the upper-left. Highlight covers ~80% of the
    // top edge and ~20% of the bottom — a lit shelf on top, almost none on
    // the floor.
    //
    // Built in pixel space, not from an Alignment: an Alignment gradient
    // treats the rect as a unit square, which collapsed wide pills to ~50/50,
    // and a fixed-length axis overshoots so wide pills clamped entirely into
    // the shadow color (Study/Cram went dark while the compact Track FAB
    // still showed white).
    //
    // The split runs from (0.8w, 0) to (0.2w, h); the gradient axis is its
    // perpendicular, pointing down-right so the highlight lands up-left. The
    // rect's corners bound that axis at 0 and `extent`, and the split line
    // passes through the centre — which is always the midpoint of a
    // rectangle's projection — so the band sits at 0.5 of the run whatever
    // the button's proportions.
    const topHighlightFraction = 0.80;
    const bottomHighlightFraction = 0.20;
    const fade = 0.08;
    final w = size.width;
    final h = size.height;
    final along = Offset(
      (bottomHighlightFraction - topHighlightFraction) * w,
      h,
    );
    final axis = Offset(along.dy, -along.dx) / along.distance;
    final extent = (w * axis.dx).abs() + (h * axis.dy).abs();

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..shader = ui.Gradient.linear(
        Offset.zero,
        axis * extent,
        [
          highlightColor,
          highlightColor.withValues(alpha: highlightColor.a * 0.5),
          shadowColor.withValues(alpha: shadowColor.a * 0.3),
          shadowColor,
        ],
        const [0.0, 0.5 - fade, 0.5 + fade, 1.0],
      );

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _GlassBorderPainter oldDelegate) {
    return oldDelegate.borderRadius != borderRadius ||
        oldDelegate.borderWidth != borderWidth ||
        oldDelegate.highlightColor != highlightColor ||
        oldDelegate.shadowColor != shadowColor ||
        oldDelegate.outlineColor != outlineColor;
  }
}
