import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/glass_surface.dart';

/// Shows a popup that visibly grows outward from [anchorGlobalCenter] — the
/// "expanding outward like it came from the blossom" interaction the Life
/// Tracker spec asks for on both blossom stat popups and the bucket-list
/// popup. Simpler than a full anchor-rect morph: a single scale+fade from a
/// point, which reads the same way for a small popover.
Future<T?> showTreePopover<T>({
  required BuildContext context,
  required Offset anchorGlobalCenter,
  required WidgetBuilder builder,
  required double width,
  double? maxWidth,
  double? height,
  Color? accentColor,
}) async {
  final overlayBox =
      Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
  if (overlayBox == null) return null;
  final overlaySize = overlayBox.size;
  final localAnchor = overlayBox.globalToLocal(anchorGlobalCenter);

  return Navigator.of(context).push<T>(
    _TreePopoverRoute<T>(
      anchor: localAnchor,
      overlaySize: overlaySize,
      builder: builder,
      width: width,
      maxWidth: maxWidth,
      height: height,
      accentColor: accentColor,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: Navigator.of(context).context,
      ),
    ),
  );
}

class _TreePopoverRoute<T> extends PopupRoute<T> {
  _TreePopoverRoute({
    required this.anchor,
    required this.overlaySize,
    required this.builder,
    required this.width,
    this.maxWidth,
    this.height,
    this.accentColor,
    required this.capturedThemes,
  });

  final Offset anchor;
  final Size overlaySize;
  final WidgetBuilder builder;
  final double width;

  /// When set, the popup may grow past [width] up to this, so content that
  /// would otherwise wrap (a long stat value) widens the popup instead.
  final double? maxWidth;
  final double? height;
  final Color? accentColor;
  final CapturedThemes capturedThemes;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final reduced = VoyagerMotion.reduced(context);
    return capturedThemes.wrap(
      CustomSingleChildLayout(
        delegate: _CenterOnAnchorDelegate(
          anchor: anchor,
          width: width,
          maxWidth: maxWidth,
          height: height,
        ),
        child: Builder(
          builder: (context) {
            final theme = Theme.of(context);
            final accent = accentColor ?? theme.colorScheme.primary;
            final surface = GlassSurface(
              borderRadius: BorderRadius.circular(16),
              accentBorder: accent,
              child: Material(
                type: MaterialType.transparency,
                child: builder(context),
              ),
            );
            if (reduced) {
              return FadeTransition(opacity: animation, child: surface);
            }
            // Grows outward from the anchor point rather than a rect, so a
            // little overshoot reads as "popping out of the blossom" instead
            // of a generic menu opening.
            return ScaleTransition(
              scale: CurvedAnimation(
                parent: animation,
                curve: VoyagerSpring.momentumCurve,
              ),
              alignment: Alignment.center,
              child: FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
                ),
                child: surface,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Gap kept between the popup and the edge of the overlay.
const double _margin = 12.0;

class _CenterOnAnchorDelegate extends SingleChildLayoutDelegate {
  _CenterOnAnchorDelegate({
    required this.anchor,
    required this.width,
    this.maxWidth,
    this.height,
  });

  final Offset anchor;
  final double width;
  final double? maxWidth;
  final double? height;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    // Never wider than the screen leaves room for, and never narrower than
    // [width] — a popup that shrank on a small window would just move the
    // wrapping problem into the content. The floor holds only while the
    // window can afford it, though: CustomSingleChildLayout does not enforce
    // the incoming constraints on what this returns, so an unconditional
    // minWidth lays a 480dp popup out on a 411dp window with its right-hand
    // column — the delete buttons — off the edge and untappable.
    final available = math.max(0.0, constraints.maxWidth - 2 * _margin);
    final availableHeight = math.max(0.0, constraints.maxHeight - 2 * _margin);
    final preferred = math.min(width, available);
    final upper = math.max(preferred, math.min(maxWidth ?? width, available));
    return BoxConstraints(
      minWidth: preferred,
      maxWidth: upper,
      minHeight: 0,
      maxHeight: math.min(height ?? availableHeight * 0.8, availableHeight),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var x = anchor.dx - childSize.width / 2;
    var y = anchor.dy - childSize.height / 2;
    const margin = _margin;
    x = x.clamp(margin, (size.width - childSize.width - margin).clamp(margin, double.infinity));
    y = y.clamp(margin, (size.height - childSize.height - margin).clamp(margin, double.infinity));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_CenterOnAnchorDelegate oldDelegate) {
    return anchor != oldDelegate.anchor ||
        width != oldDelegate.width ||
        maxWidth != oldDelegate.maxWidth ||
        height != oldDelegate.height;
  }
}
