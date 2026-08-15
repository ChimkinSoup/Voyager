import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// Opens a Voyager-styled popup menu with no outer padding by default.
///
/// When [shiftUpToFit] is `false` (default), the menu remains anchored at its
/// top position (e.g. directly below the trigger control) instead of pushing
/// upwards over the popup/trigger control when the menu contains many items.
/// In this case, the menu height is constrained to the available space below
/// and its inner list scrollable.
Future<T?> showVoyagerMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  BoxConstraints? constraints,
  EdgeInsetsGeometry menuPadding = EdgeInsets.zero,
  Color? accentColor,
  bool shiftUpToFit = false,
}) {
  final theme = Theme.of(context);
  final menuStyle = VoyagerMenuTheme.showMenuStyle(theme);
  final shape = accentColor != null ? VoyagerMenuTheme.shape(accentColor) : menuStyle.shape;

  return Navigator.of(context).push<T>(
    VoyagerPopupMenuRoute<T>(
      position: position,
      items: items,
      constraints: constraints,
      menuPadding: menuPadding,
      shape: shape,
      color: menuStyle.color,
      elevation: menuStyle.elevation,
      shadowColor: menuStyle.shadowColor,
      surfaceTintColor: menuStyle.surfaceTintColor,
      clipBehavior: Clip.none,
      shiftUpToFit: shiftUpToFit,
    ),
  );
}

/// Custom SingleChildLayoutDelegate for Voyager popup menus.
class VoyagerPopupMenuRouteLayout extends SingleChildLayoutDelegate {
  VoyagerPopupMenuRouteLayout(
    this.position,
    this.textDirection,
    this.padding, {
    this.shiftUpToFit = false,
  });

  final RelativeRect position;
  final TextDirection textDirection;
  final EdgeInsets padding;
  final bool shiftUpToFit;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final double maxChildWidth = constraints.maxWidth - padding.horizontal;
    double maxChildHeight = constraints.maxHeight - padding.vertical;

    if (!shiftUpToFit) {
      final double availableBelow =
          constraints.maxHeight - position.top - padding.bottom;
      if (availableBelow >= 120) {
        maxChildHeight = availableBelow;
      } else {
        final double availableAbove = position.top - padding.top - 8;
        if (availableAbove > availableBelow) {
          maxChildHeight = availableAbove;
        }
      }
    }

    return BoxConstraints(
      minWidth: 0.0,
      maxWidth: maxChildWidth,
      minHeight: 0.0,
      maxHeight: maxChildHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x;
    if (position.left > position.right) {
      x = position.left;
    } else {
      x = size.width - position.right - childSize.width;
    }
    x = x.clamp(padding.left, size.width - padding.right - childSize.width);

    double y = position.top;
    if (shiftUpToFit) {
      if (y + childSize.height > size.height - padding.bottom) {
        y = size.height - padding.bottom - childSize.height;
      }
      y = y.clamp(padding.top, size.height - padding.bottom - childSize.height);
    } else {
      final double availableBelow = size.height - position.top - padding.bottom;
      if (availableBelow >= 120) {
        y = position.top;
      } else {
        final double availableAbove = position.top - padding.top - 8;
        if (availableAbove > availableBelow) {
          y = (position.top - 8 - childSize.height)
              .clamp(padding.top, position.top - 8);
        } else {
          y = position.top;
        }
      }
    }

    return Offset(x, y);
  }

  @override
  bool shouldRelayout(VoyagerPopupMenuRouteLayout oldDelegate) {
    return position != oldDelegate.position ||
        textDirection != oldDelegate.textDirection ||
        padding != oldDelegate.padding ||
        shiftUpToFit != oldDelegate.shiftUpToFit;
  }
}

/// Custom [PopupRoute] for Voyager popup menus.
class VoyagerPopupMenuRoute<T> extends PopupRoute<T> {
  VoyagerPopupMenuRoute({
    required this.position,
    required this.items,
    this.constraints,
    this.menuPadding = EdgeInsets.zero,
    this.shape,
    this.color,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.clipBehavior = Clip.none,
    this.shiftUpToFit = false,
  });

  final RelativeRect position;
  final List<PopupMenuEntry<T>> items;
  final BoxConstraints? constraints;
  final EdgeInsetsGeometry menuPadding;
  final ShapeBorder? shape;
  final Color? color;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final Clip clipBehavior;
  final bool shiftUpToFit;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final mediaQuery = MediaQuery.of(context);
    final popupMenuTheme = PopupMenuTheme.of(context);

    final List<Widget> children = <Widget>[];
    for (int i = 0; i < items.length; i += 1) {
      children.add(items[i]);
    }

    final Widget menuContent = ConstrainedBox(
      constraints:
          constraints ?? const BoxConstraints(minWidth: 112, maxWidth: 280),
      // Entries built on [PopupMenuItem] carry SemanticsRole.menuItem, which
      // asserts unless an ancestor node claims SemanticsRole.menu. Material's
      // own popup route wraps its list the same way.
      child: Semantics(
        role: SemanticsRole.menu,
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        child: VoyagerScrollView(
          padding: menuPadding,
          child: ListBody(children: children),
        ),
      ),
    );

    // The fade/scale transition is applied here, around just the menu's own
    // box, rather than in [buildTransitions] — that method only ever sees
    // the *page* passed to it, which is this whole route's full-screen
    // CustomSingleChildLayout. Scaling that would grow the menu from the
    // screen's own top-center instead of from the menu's anchored position.
    final reduced = VoyagerMotion.reduced(context);
    final Widget menuContainer = FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      ),
      child: ScaleTransition(
        scale: CurvedAnimation(
          parent: animation,
          curve: reduced ? Curves.easeOut : VoyagerSpring.drawerCurve,
          reverseCurve: Curves.easeIn,
        ),
        alignment: Alignment.topCenter,
        child: Material(
          type: MaterialType.card,
          color: color ?? popupMenuTheme.color,
          elevation: elevation ?? popupMenuTheme.elevation ?? 8.0,
          shadowColor: shadowColor ?? popupMenuTheme.shadowColor,
          surfaceTintColor: surfaceTintColor ?? popupMenuTheme.surfaceTintColor,
          shape: shape ?? popupMenuTheme.shape,
          clipBehavior: clipBehavior,
          child: menuContent,
        ),
      ),
    );

    return MediaQuery(
      data: mediaQuery.removePadding(removeTop: true, removeBottom: true),
      child: Builder(
        builder: (BuildContext context) {
          return CustomSingleChildLayout(
            delegate: VoyagerPopupMenuRouteLayout(
              position,
              Directionality.of(context),
              mediaQuery.padding,
              shiftUpToFit: shiftUpToFit,
            ),
            child: menuContainer,
          );
        },
      ),
    );
  }
}


/// Builds popup menu entries with position-aware rounded hover highlights.
List<PopupMenuEntry<T>> voyagerPopupMenuEntries<T>(
  List<({T value, Widget child})> items,
) {
  return [
    for (var i = 0; i < items.length; i++)
      VoyagerPopupMenuItem<T>(
        value: items[i].value,
        position: VoyagerMenuTheme.positionFor(i, items.length),
        child: items[i].child,
      ),
  ];
}

/// Select-style menu entries with a checkmark on the active value.
List<PopupMenuEntry<T>> voyagerSelectMenuEntries<T>({
  required BuildContext context,
  required List<({T value, String label})> items,
  required T selected,
}) {
  final checkColor = Theme.of(context).colorScheme.primary;
  return [
    for (var i = 0; i < items.length; i++)
      VoyagerPopupMenuItem<T>(
        value: items[i].value,
        position: VoyagerMenuTheme.positionFor(i, items.length),
        child: Row(
          children: [
            Expanded(
              child: Text(
                items[i].label,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (items[i].value == selected) ...[
              const SizedBox(width: 8),
              Icon(
                PhosphorIconsRegular.check,
                size: 18,
                color: checkColor,
              ),
            ],
          ],
        ),
      ),
  ];
}

/// Popup menu item whose hover/focus highlight respects menu corner radius.
class VoyagerPopupMenuItem<T> extends PopupMenuItem<T> {
  const VoyagerPopupMenuItem({
    super.key,
    required super.value,
    required super.child,
    required this.position,
    super.enabled = true,
    super.height = kMinInteractiveDimension,
    super.padding,
    super.onTap,
  });

  final VoyagerMenuItemPosition position;

  @override
  PopupMenuItemState<T, VoyagerPopupMenuItem<T>> createState() =>
      _VoyagerPopupMenuItemState<T>();
}

class _VoyagerPopupMenuItemState<T>
    extends PopupMenuItemState<T, VoyagerPopupMenuItem<T>> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final popupMenuTheme = PopupMenuTheme.of(context);
    final states = <WidgetState>{if (!widget.enabled) WidgetState.disabled};
    final style =
        widget.labelTextStyle?.resolve(states) ??
        popupMenuTheme.labelTextStyle?.resolve(states) ??
        theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurface);
    final padding = widget.padding ?? VoyagerMenuTheme.itemPadding(theme);
    final highlightRadius = VoyagerMenuTheme.itemHighlightRadius(
      widget.position,
    );

    Widget item = AnimatedDefaultTextStyle(
      style: style!,
      duration: kThemeChangeDuration,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: widget.height),
        child: Padding(
          padding: padding,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: buildChild(),
          ),
        ),
      ),
    );

    if (!widget.enabled) {
      item = IconTheme.merge(
        data: IconThemeData(
          opacity: theme.brightness == Brightness.dark ? 0.5 : 0.38,
        ),
        child: item,
      );
    }

    return MergeSemantics(
      child: buildSemantics(
        child: ClipRRect(
          borderRadius: highlightRadius,
          child: InkWell(
            onTap: widget.enabled ? handleTap : null,
            canRequestFocus: widget.enabled,
            borderRadius: highlightRadius,
            child: item,
          ),
        ),
      ),
    );
  }
}
