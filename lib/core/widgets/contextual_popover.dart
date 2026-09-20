import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/modal_barrier_guard.dart';

class ContextualPopover extends StatelessWidget {
  const ContextualPopover({
    super.key,
    required this.child,
    this.width = 220,
    this.height,
    this.accentColor,
  });

  static const _radius = 18.0;
  static const _accentBorderWidth = 2.0;

  /// Corner radius of the popover's clipped content area (inside the accent
  /// border), for descendants that need to round a full-bleed edge to match.
  ///
  /// Held at the accent border's inset even when the popover draws the
  /// neutral hairline instead — a constant is what makes it usable as a
  /// `const` corner radius, and one pixel of extra inset on a hairline
  /// popover is not visible.
  static const contentRadius = _radius - _accentBorderWidth;

  /// Width at or above which a popover stops being a picker and starts being
  /// a panel: the inbox, the event editor, the search list. Those carry
  /// enough content to sit on the heavier material; a 220px date list under
  /// the same blur reads as a second dialog rather than a menu.
  static const _heavyGlassWidth = 320.0;

  final Widget child;
  final double width;
  final double? height;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: GlassSurface(
        weight: width >= _heavyGlassWidth
            ? GlassWeight.heavy
            : GlassWeight.light,
        borderRadius: BorderRadius.circular(_radius),
        // Passed through rather than defaulted to the theme's primary: a
        // popover that belongs to a specific coloured thing says so with a
        // 2px accent edge, and every other one takes [GlassSurface]'s
        // blended hairline.
        accentBorder: accentColor,
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
  BuildContext? tapThroughContext,
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
      tapThroughRect: _overlayRectOf(tapThroughContext, overlay),
      capturedThemes: InheritedTheme.capture(
          from: context, to: Navigator.of(context).context),
    ),
  );
}

/// The bounds of [target] in the overlay's coordinates, which is the space
/// the popover route lays its barrier out in.
Rect? _overlayRectOf(BuildContext? target, RenderBox overlay) {
  final box = target?.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
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
          colorScheme: base.colorScheme.copyWith(
            primary: _accentColor,
            onPrimary: onColorLabel(_accentColor!),
          ),
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

class _ContextualPopoverRoute<T> extends PopupRoute<T>
    with GuardedModalBarrier<T> {
  _ContextualPopoverRoute({
    required this.targetRect,
    required this.builder,
    required this.width,
    this.height,
    this.accentColor,
    this.tapThroughRect,
    required this.capturedThemes,
  });

  final Rect targetRect;
  final WidgetBuilder builder;
  final double width;
  final double? height;
  final Color? accentColor;

  /// Region, in overlay coordinates, where a click outside the popover both
  /// closes it and reaches whatever is under it, instead of being spent on
  /// the barrier. Null keeps the ordinary modal behaviour everywhere.
  final Rect? tapThroughRect;

  final CapturedThemes capturedThemes;

  /// Set the moment either exit asks to close, so this popover asks once.
  ///
  /// `maybePop` resolves the pop in a microtask, so a second click arriving
  /// inside the same frame still sees this route as current and would pop the
  /// route below it. The tap-through exit below pops synchronously and so
  /// cannot double up on itself, but it can still fire on a click that lands
  /// in the same frame as a barrier dismissal that has not resolved yet.
  bool _dismissRequested = false;

  @override
  Widget buildModalBarrier() {
    final region = tapThroughRect;
    // Built here rather than taken from `super` for the one thing the base
    // barrier hard-codes: it answers a tap with `Navigator.maybePop`, which
    // finds whatever is current *then*. Two clicks inside one frame both land
    // on this barrier — the first pop is still a pending microtask when the
    // second is hit-tested, so [GuardedModalBarrier] cannot see it coming —
    // and the second would pop the surface the popover was opened from.
    // [barrierColor] is transparent, so this is the branch the base takes.
    final barrier = guardBarrier(
      ModalBarrier(
        dismissible: barrierDismissible,
        semanticsLabel: barrierLabel,
        barrierSemanticsDismissible: semanticsDismissible,
        onDismiss: () {
          if (_dismissRequested || !isCurrent) return;
          _dismissRequested = true;
          navigator?.maybePop();
        },
      ),
    );
    if (region == null) return barrier;
    return _TapThroughBarrier(
      region: region,
      // The trigger is cut out of the region: passing its click through would
      // close the popover on the way down and reopen it on the way up, so
      // clicking the pill again would never close the menu.
      except: targetRect,
      onTapThrough: () {
        if (_dismissRequested || !isCurrent) return;
        _dismissRequested = true;
        navigator?.pop();
      },
      child: barrier,
    );
  }

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
    // The entrance below fades and scales this subtree. Both are layer
    // effects, and without a boundary of its own the popover's whole content —
    // a form's worth of fields, the glass gradient, the specular border — is
    // re-rasterized on every frame of the transition instead of being drawn
    // once and re-composited. That is what made opening the calendar's event
    // editor drop frames: the panel is not cheap to paint, and it was being
    // painted sixteen times on the way in.
    Widget popover = RepaintBoundary(
      child: ContextualPopoverAccentHost(
        width: width,
        height: height,
        accentColor: accentColor,
        child: builder(context),
      ),
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

/// Wraps the ordinary modal barrier so that clicks inside [region] (but
/// outside [except]) fall through to the widgets below while still closing the
/// popover — one click both dismisses the menu and presses what it landed on.
class _TapThroughBarrier extends SingleChildRenderObjectWidget {
  const _TapThroughBarrier({
    required this.region,
    required this.except,
    required this.onTapThrough,
    required Widget super.child,
  });

  final Rect region;
  final Rect except;
  final VoidCallback onTapThrough;

  @override
  _RenderTapThroughBarrier createRenderObject(BuildContext context) {
    return _RenderTapThroughBarrier(
      region: region,
      except: except,
      onTapThrough: onTapThrough,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTapThroughBarrier renderObject,
  ) {
    renderObject
      ..region = region
      ..except = except
      ..onTapThrough = onTapThrough;
  }
}

class _RenderTapThroughBarrier extends RenderProxyBox {
  _RenderTapThroughBarrier({
    required this.region,
    required this.except,
    required this.onTapThrough,
  });

  /// Read afresh on every hit test, so none of these needs to mark anything
  /// dirty when it changes: nothing about layout or painting depends on them.
  Rect region;
  Rect except;
  VoidCallback onTapThrough;

  bool _passesThrough(Offset position) =>
      region.contains(position) && !except.contains(position);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (_passesThrough(position)) {
      // Listen without claiming: adding ourselves to the result routes the
      // event here too, and returning false lets the hit test carry on into
      // the route below, the way a translucent hit test behaves.
      result.add(BoxHitTestEntry(this, position));
      return false;
    }
    return super.hitTest(result, position: position);
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    // The position is re-read rather than remembered: a hit anywhere else on
    // the barrier lands here too, because [RenderBox.hitTest] adds this box to
    // the result on its way down to the barrier it wraps. Closing on those
    // would double up with the barrier's own dismissal and take the dialog
    // underneath with it.
    if (event is PointerDownEvent && _passesThrough(entry.localPosition)) {
      onTapThrough();
    }
  }
}
