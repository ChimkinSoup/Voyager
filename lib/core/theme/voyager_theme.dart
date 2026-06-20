import 'package:flutter/material.dart';
import 'package:voyager/core/theme/app_fonts.dart';

class VoyagerTheme {
  static ThemeData dark({Color accent = const Color(0xFF7C9EFF)}) {
    final accentLine = Color.lerp(accent, Colors.white, 0.42)!;
    final dividerColor = accentLine.withValues(alpha: 0.24);
    final outlineColor = accentLine.withValues(alpha: 0.34);
    final colorScheme = ColorScheme.dark(
      primary: accent,
      secondary: accent.withValues(alpha: 0.7),
      surface: const Color(0xFF24242B),
      outline: outlineColor,
      outlineVariant: dividerColor,
    );
    final pressOverlay = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.pressed)) {
        return colorScheme.onSurface.withValues(alpha: 0.16);
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return colorScheme.onSurface.withValues(alpha: 0.08);
      }
      return Colors.transparent;
    });
    final pressElevation = WidgetStateProperty.resolveWith<double?>((states) {
      if (states.contains(WidgetState.disabled)) return 0;
      if (states.contains(WidgetState.pressed)) return 0;
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return 2;
      }
      return 1;
    });
    final buttonShape = WidgetStatePropertyAll<OutlinedBorder>(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    );
    final buttonSide = WidgetStateProperty.resolveWith<BorderSide?>((states) {
      if (states.contains(WidgetState.disabled)) {
        return BorderSide(color: outlineColor.withValues(alpha: 0.35));
      }
      if (states.contains(WidgetState.pressed) ||
          states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return BorderSide(color: accentLine.withValues(alpha: 0.55));
      }
      return BorderSide(color: outlineColor);
    });

    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: colorScheme,
    );
    final textTheme = AppFonts.applyTo(base.textTheme, colorScheme.onSurface);
    final primaryTextTheme = AppFonts.applyTo(
      base.primaryTextTheme,
      colorScheme.onPrimary,
    );

    final sharedButtonStyle = ButtonStyle(
      overlayColor: pressOverlay,
      elevation: pressElevation,
      shape: buttonShape,
      splashFactory: NoSplash.splashFactory,
      animationDuration: const Duration(milliseconds: 90),
      textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
    );
    final outlinedButtonStyle = sharedButtonStyle.copyWith(side: buttonSide);

    return ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      fontFamily: AppFonts.family,
      colorScheme: colorScheme,
      textTheme: textTheme,
      primaryTextTheme: primaryTextTheme,
      splashFactory: NoSplash.splashFactory,
      highlightColor: colorScheme.onSurface.withValues(alpha: 0.10),
      hoverColor: colorScheme.onSurface.withValues(alpha: 0.08),
      focusColor: colorScheme.onSurface.withValues(alpha: 0.08),
      dividerColor: dividerColor,
      scaffoldBackgroundColor: const Color(0xFF1B1B22),
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFF24242B),
        elevation: 0,
        titleTextStyle: textTheme.titleLarge,
        toolbarTextStyle: textTheme.titleMedium,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF2A2A33),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: dividerColor),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: dividerColor,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF30303A),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurface.withValues(alpha: 0.55),
        ),
        labelStyle: textTheme.labelLarge,
        floatingLabelStyle: textTheme.labelLarge?.copyWith(color: accent),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: outlineColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: outlineColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: accent.withValues(alpha: 0.95),
            width: 1.8,
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        selectedTileColor: colorScheme.primary.withValues(alpha: 0.14),
        titleTextStyle: textTheme.bodyLarge,
        subtitleTextStyle: textTheme.bodyMedium,
      ),
      filledButtonTheme: FilledButtonThemeData(style: sharedButtonStyle),
      elevatedButtonTheme: ElevatedButtonThemeData(style: sharedButtonStyle),
      outlinedButtonTheme: OutlinedButtonThemeData(style: outlinedButtonStyle),
      textButtonTheme: TextButtonThemeData(style: sharedButtonStyle),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          overlayColor: pressOverlay,
          shape: buttonShape,
          splashFactory: NoSplash.splashFactory,
          animationDuration: const Duration(milliseconds: 90),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: outlinedButtonStyle,
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        textStyle: textTheme.bodyLarge,
        labelTextStyle: WidgetStatePropertyAll(textTheme.bodyLarge),
      ),
      dialogTheme: DialogThemeData(
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
      snackBarTheme: SnackBarThemeData(contentTextStyle: textTheme.bodyMedium),
      tooltipTheme: TooltipThemeData(textStyle: textTheme.bodySmall),
      dropdownMenuTheme: DropdownMenuThemeData(textStyle: textTheme.bodyLarge),
      navigationRailTheme: NavigationRailThemeData(
        selectedLabelTextStyle: textTheme.labelSmall,
        unselectedLabelTextStyle: textTheme.labelSmall,
      ),
      checkboxTheme: CheckboxThemeData(side: BorderSide(color: outlineColor)),
      chipTheme: ChipThemeData(labelStyle: textTheme.labelLarge),
    );
  }
}
