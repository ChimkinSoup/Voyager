import 'package:flutter/material.dart';

enum VoyagerMenuItemPosition { only, first, middle, last }

/// Shared styling for popup menus, dropdown overlays, and [showMenu] routes.
abstract final class VoyagerMenuTheme {
  static const Color menuColor = Color(0xFF2A2A33);
  static const double radius = 18;
  static const BorderRadius menuBorderRadius = BorderRadius.all(
    Radius.circular(radius),
  );

  static const Radius _itemHighlightRadius = Radius.circular(radius);

  static RoundedRectangleBorder get shape => RoundedRectangleBorder(
    borderRadius: menuBorderRadius,
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

  static MenuStyle menuStyle({Color? color}) => MenuStyle(
    backgroundColor: WidgetStatePropertyAll(color ?? menuColor),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(8),
    shadowColor: WidgetStatePropertyAll(
      Colors.black.withValues(alpha: 0.45),
    ),
    shape: WidgetStatePropertyAll(shape),
    padding: WidgetStatePropertyAll(EdgeInsets.zero),
  );

  static PopupMenuThemeData popupMenuTheme({
    required TextTheme textTheme,
    required Color onSurface,
  }) => PopupMenuThemeData(
    color: menuColor,
    surfaceTintColor: Colors.transparent,
    elevation: 8,
    shadowColor: Colors.black.withValues(alpha: 0.45),
    shape: shape,
    menuPadding: EdgeInsets.zero,
    textStyle: textTheme.bodyLarge,
    labelTextStyle: WidgetStatePropertyAll(textTheme.bodyLarge),
    iconColor: onSurface,
  );

  static DropdownMenuThemeData dropdownMenuTheme(TextTheme textTheme) =>
      DropdownMenuThemeData(
        textStyle: textTheme.bodyLarge,
        menuStyle: menuStyle(),
      );

  static MenuThemeData menuTheme() => MenuThemeData(style: menuStyle());

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
      shape: popup.shape ?? shape,
      elevation: popup.elevation ?? 8,
      shadowColor: popup.shadowColor ?? Colors.black.withValues(alpha: 0.45),
      surfaceTintColor: popup.surfaceTintColor ?? Colors.transparent,
      menuPadding: popup.menuPadding ?? EdgeInsets.zero,
    );
  }
}
