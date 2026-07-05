import 'package:flutter/material.dart';

class ContextualPopover extends StatelessWidget {
  const ContextualPopover({
    super.key,
    required this.child,
    this.width = 220,
    this.height,
  });

  final Widget child;
  final double width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Dark Scaffold Base #1B1B22 with subtle colored shadow
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B22),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: 0.15),
            blurRadius: 16,
            blurStyle: BlurStyle.outer,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

Future<T?> showContextualPopover<T>({
  required BuildContext context,
  required BuildContext buttonContext,
  required WidgetBuilder builder,
  double width = 220,
  double? height,
}) async {
  final button = buttonContext.findRenderObject() as RenderBox?;
  if (button == null) return null;
  final overlay =
      Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
  if (overlay == null) return null;

  final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
  final buttonRect = topLeft & button.size;

  return Navigator.of(context).push<T>(
    _ContextualPopoverRoute<T>(
      targetRect: buttonRect,
      builder: builder,
      width: width,
      height: height,
      capturedThemes: InheritedTheme.capture(
          from: context, to: Navigator.of(context).context),
    ),
  );
}

class _ContextualPopoverRoute<T> extends PopupRoute<T> {
  _ContextualPopoverRoute({
    required this.targetRect,
    required this.builder,
    required this.width,
    this.height,
    required this.capturedThemes,
  });

  final Rect targetRect;
  final WidgetBuilder builder;
  final double width;
  final double? height;
  final CapturedThemes capturedThemes;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return capturedThemes.wrap(
      CustomSingleChildLayout(
        delegate: _PopoverLayoutDelegate(
          targetRect: targetRect,
          width: width,
          height: height,
        ),
        child: FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.95, end: 1.0).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
            child: ContextualPopover(
              width: width,
              height: height,
              child: builder(context),
            ),
          ),
        ),
      ),
    );
  }
}

class _PopoverLayoutDelegate extends SingleChildLayoutDelegate {
  _PopoverLayoutDelegate({
    required this.targetRect,
    required this.width,
    this.height,
  });

  final Rect targetRect;
  final double width;
  final double? height;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      minHeight: 0,
      maxHeight: height ?? constraints.maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double y = targetRect.bottom + 8;
    if (y + childSize.height > size.height) {
      // Place above if it goes off screen
      y = targetRect.top - childSize.height - 8;
    }
    double x = targetRect.left;
    if (x + childSize.width > size.width) {
      x = size.width - childSize.width - 8;
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_PopoverLayoutDelegate oldDelegate) {
    return targetRect != oldDelegate.targetRect ||
        width != oldDelegate.width ||
        height != oldDelegate.height;
  }
}
