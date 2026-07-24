import 'package:flutter/material.dart';

enum VoyagerMenuItemPosition { only, first, middle, last }

/// Shared styling for popup menus, dropdown overlays, and [showMenu] routes.
abstract final class VoyagerMenuTheme {
  /// Fallback menu surface, used only when no themed color was threaded in.
  /// The live value comes from the active palette's card tone — read it from
  /// `Theme.of(context).popupMenuTheme.color` rather than using this directly,
  /// or menus will stay dark under the light theme.
  static const Color menuColor = Color(0xFF2A2A33);

  /// The menu surface for [context]'s theme, falling back to [menuColor].
  static Color menuColorOf(BuildContext context) =>
      Theme.of(context).popupMenuTheme.color ?? menuColor;
  static const double radius = 18;
  static const BorderRadius menuBorderRadius = BorderRadius.all(
    Radius.circular(radius),
  );

  static const Radius _itemHighlightRadius = Radius.circular(radius);

  static OutlinedBorder shape([Color? accentColor]) => _GlowBorder(
    borderRadius: menuBorderRadius,
    side: accentColor != null ? BorderSide(color: accentColor, width: 2.0) : BorderSide.none,
    glowColor: accentColor?.withValues(alpha: 0.6),
  );

  static VoyagerMenuItemPosition positionFor(int index, int count) {
    if (count <= 1) return VoyagerMenuItemPosition.only;
    if (index == 0) return VoyagerMenuItemPosition.first;
    if (index == count - 1) return VoyagerMenuItemPosition.last;
    return VoyagerMenuItemPosition.middle;
  }

  static BorderRadius itemHighlightRadius(VoyagerMenuItemPosition position) {
    switch (position) {
      case VoyagerMenuItemPosition.only:
        return BorderRadius.all(_itemHighlightRadius);
      case VoyagerMenuItemPosition.first:
        return BorderRadius.vertical(top: _itemHighlightRadius);
      case VoyagerMenuItemPosition.last:
        return BorderRadius.vertical(bottom: _itemHighlightRadius);
      case VoyagerMenuItemPosition.middle:
        return BorderRadius.zero;
    }
  }

  static EdgeInsets itemPadding(ThemeData theme) => theme.useMaterial3
      ? const EdgeInsets.symmetric(horizontal: 12)
      : const EdgeInsets.symmetric(horizontal: 16);

  static MenuStyle menuStyle({Color? color, Color? accentColor}) => MenuStyle(
    backgroundColor: WidgetStatePropertyAll(color ?? menuColor),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(0),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    shape: WidgetStatePropertyAll(shape(accentColor)),
    padding: const WidgetStatePropertyAll(EdgeInsets.zero),
  );

  static PopupMenuThemeData popupMenuTheme({
    required TextTheme textTheme,
    required Color onSurface,
    Color? accentColor,
    Color? color,
  }) => PopupMenuThemeData(
    color: color ?? menuColor,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    shadowColor: Colors.transparent,
    shape: shape(accentColor),
    menuPadding: EdgeInsets.zero,
    textStyle: textTheme.bodyLarge,
    labelTextStyle: WidgetStatePropertyAll(textTheme.bodyLarge),
    iconColor: onSurface,
  );

  static DropdownMenuThemeData dropdownMenuTheme(
    TextTheme textTheme, {
    Color? accentColor,
    Color? color,
  }) => DropdownMenuThemeData(
    textStyle: textTheme.bodyLarge,
    menuStyle: menuStyle(accentColor: accentColor, color: color),
  );

  static MenuThemeData menuTheme({Color? accentColor, Color? color}) =>
      MenuThemeData(style: menuStyle(accentColor: accentColor, color: color));

  static ({
    Color color,
    ShapeBorder shape,
    double elevation,
    Color shadowColor,
    Color surfaceTintColor,
    EdgeInsetsGeometry menuPadding,
  })
  showMenuStyle(ThemeData theme) {
    final popup = theme.popupMenuTheme;
    return (
      color: popup.color ?? menuColor,
      shape: popup.shape ?? shape(theme.colorScheme.primary),
      elevation: popup.elevation ?? 0,
      shadowColor: popup.shadowColor ?? Colors.transparent,
      surfaceTintColor: popup.surfaceTintColor ?? Colors.transparent,
      menuPadding: popup.menuPadding ?? EdgeInsets.zero,
    );
  }
}

class _GlowBorder extends RoundedRectangleBorder {
  const _GlowBorder({
    super.borderRadius,
    super.side,
    this.glowColor,
  });

  final Color? glowColor;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (glowColor != null) {
      final Paint paint = Paint()
        ..color = glowColor!
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 16.0);

      final RRect rrect = borderRadius.resolve(textDirection).toRRect(rect);
      canvas.drawRRect(rrect, paint);
    }
    super.paint(canvas, rect, textDirection: textDirection);
  }
}
