import 'package:flutter/material.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/glass_surface.dart';

class ContextualPopover extends StatelessWidget {
  const ContextualPopover({
    super.key,
    required this.child,
    this.width = 220,
    this.height,
    this.accentColor,
  });

  static const _radius = 12.0;
  static const _borderWidth = 2.0;

  /// Corner radius of the popover's clipped content area (inside the accent
  /// border), for descendants that need to round a full-bleed edge to match.
  static const contentRadius = _radius - _borderWidth;

  final Widget child;
  final double width;
  final double? height;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = accentColor ?? theme.colorScheme.primary;

    return SizedBox(
      width: width,
      height: height,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(_radius),
        accentBorder: accent,
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(contentRadius),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
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
  Color? accentColor,
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
      accentColor: accentColor,
      capturedThemes: InheritedTheme.capture(
          from: context, to: Navigator.of(context).context),
    ),
  );
}

/// Shows a contextual popover anchored to [targetRect] (in screen/global
/// coordinates).  Unlike [showContextualPopover], this variant does not need a
/// [BuildContext] for the anchor widget — pass any [Rect] you have (e.g.
/// derived from a [PointerDownEvent.position]).
Future<T?> showContextualPopoverAt<T>({
  required BuildContext context,
  required Rect targetRect,
  required WidgetBuilder builder,
  double width = 220,
  double? height,
  Color? accentColor,
}) async {
  final overlay =
      Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
  if (overlay == null) return null;

  // Convert global screen coordinates → overlay-local coordinates.
  final overlayOrigin = overlay.localToGlobal(Offset.zero);
  final localRect = targetRect.translate(-overlayOrigin.dx, -overlayOrigin.dy);

  return Navigator.of(context).push<T>(
    _ContextualPopoverRoute<T>(
      targetRect: localRect,
      builder: builder,
      width: width,
      height: height,
      accentColor: accentColor,
      capturedThemes: InheritedTheme.capture(
          from: context, to: Navigator.of(context).context),
    ),
  );
}

/// Hosts a [ContextualPopover] whose accent border can be updated by
/// descendants via [ContextualPopoverAccent.update].
class ContextualPopoverAccentHost extends StatefulWidget {
  const ContextualPopoverAccentHost({
    super.key,
    required this.child,
    required this.width,
    this.height,
    this.accentColor,
  });

  final Widget child;
  final double width;
  final double? height;
  final Color? accentColor;

  @override
  State<ContextualPopoverAccentHost> createState() =>
      _ContextualPopoverAccentHostState();
}

class _ContextualPopoverAccentHostState extends State<ContextualPopoverAccentHost> {
  late Color? _accentColor;

  @override
  void initState() {
    super.initState();
    _accentColor = widget.accentColor;
  }

  @override
  void didUpdateWidget(covariant ContextualPopoverAccentHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.accentColor != oldWidget.accentColor) {
      _accentColor = widget.accentColor;
    }
  }

  void setAccent(Color color) {
    if (_accentColor == color) return;
    setState(() => _accentColor = color);
  }

  @override
  Widget build(BuildContext context) {
    Widget popover = ContextualPopover(
      width: widget.width,
      height: widget.height,
      accentColor: _accentColor,
      child: widget.child,
    );
    if (_accentColor != null) {
      final base = Theme.of(context);
      popover = Theme(
        data: base.copyWith(
          colorScheme: base.colorScheme.copyWith(primary: _accentColor),
        ),
        child: popover,
      );
    }
    return _ContextualPopoverAccentScope(
      setAccent: setAccent,
      child: popover,
    );
  }
}

class _ContextualPopoverAccentScope extends InheritedWidget {
  const _ContextualPopoverAccentScope({
    required this.setAccent,
    required super.child,
  });

  final void Function(Color color) setAccent;

  static _ContextualPopoverAccentScope? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_ContextualPopoverAccentScope>();
  }

  @override
  bool updateShouldNotify(_ContextualPopoverAccentScope oldWidget) => false;
}

/// Updates the accent border of the enclosing [ContextualPopoverAccentHost].
abstract final class ContextualPopoverAccent {
  static void update(BuildContext context, Color color) {
    final scope = _ContextualPopoverAccentScope.maybeOf(context);
    scope?.setAccent(color);
  }
}

class _ContextualPopoverRoute<T> extends PopupRoute<T> {
  _ContextualPopoverRoute({
    required this.targetRect,
    required this.builder,
    required this.width,
    this.height,
    this.accentColor,
    required this.capturedThemes,
  });

  final Rect targetRect;
  final WidgetBuilder builder;
  final double width;
  final double? height;
  final Color? accentColor;
  final CapturedThemes capturedThemes;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    Widget popover = ContextualPopoverAccentHost(
      width: width,
      height: height,
      accentColor: accentColor,
      child: builder(context),
    );
    final reduced = VoyagerMotion.reduced(context);
    final curved = CurvedAnimation(
      parent: animation,
      curve: reduced ? Curves.easeOut : VoyagerSpring.drawerCurve,
    );
    return capturedThemes.wrap(
      CustomSingleChildLayout(
        delegate: _PopoverLayoutDelegate(
          targetRect: targetRect,
          width: width,
          height: height,
        ),
        child: FadeTransition(
          opacity: animation,
          child: reduced
              ? popover
              : ScaleTransition(
                  // Anchored toward the trigger's corner (the layout delegate
                  // places the popover left-aligned with targetRect) rather
                  // than scaling from center, so it visually grows out of
                  // what opened it.
                  scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
                  alignment: Alignment.topLeft,
                  child: popover,
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
