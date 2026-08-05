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
    this.height,
    this.accentColor,
    required this.capturedThemes,
  });

  final Offset anchor;
  final Size overlaySize;
  final WidgetBuilder builder;
  final double width;
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

class _CenterOnAnchorDelegate extends SingleChildLayoutDelegate {
  _CenterOnAnchorDelegate({required this.anchor, required this.width, this.height});

  final Offset anchor;
  final double width;
  final double? height;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      minHeight: 0,
      maxHeight: height ?? constraints.maxHeight * 0.8,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var x = anchor.dx - childSize.width / 2;
    var y = anchor.dy - childSize.height / 2;
    const margin = 12.0;
    x = x.clamp(margin, (size.width - childSize.width - margin).clamp(margin, double.infinity));
    y = y.clamp(margin, (size.height - childSize.height - margin).clamp(margin, double.infinity));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_CenterOnAnchorDelegate oldDelegate) {
    return anchor != oldDelegate.anchor || width != oldDelegate.width || height != oldDelegate.height;
  }
}
