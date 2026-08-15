import 'package:flutter/material.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/domain/models/enums.dart' show AppThemeMode;

/// The concrete surface tones for one theme.
///
/// Both themes are built from the same widget-theme body; only these tones and
/// the direction the accent is shifted in ([accentLineTarget]) differ. Keeping
/// them in one place is what makes it possible to add a theme without
/// re-deriving every `ThemeData` sub-theme.
///
/// The four surfaces are ordered by how far "forward" they sit: [scaffold] is
/// furthest back (the shader/paper background paints over it), then [appBar],
/// then [card], then [field]. In dark mode each step gets lighter; in light
/// mode each step gets whiter. Widgets that pick a surface by contrast rather
/// than by name therefore keep working in both.
class VoyagerPalette {
  const VoyagerPalette({
    required this.brightness,
    required this.scaffold,
    required this.appBar,
    required this.card,
    required this.field,
    required this.onSurface,
    required this.accentLineTarget,
    required this.accentLineAmount,
    required this.dividerAlpha,
    required this.outlineAlpha,
  });

  final Brightness brightness;

  /// Backdrop tone. Sits behind the background pipeline, so it is only visible
  /// directly while the shader is still loading.
  final Color scaffold;

  final Color appBar;

  /// Cards, dialogs and menus.
  final Color card;

  /// Text-field fills, tooltips and snackbars — the most forward surface.
  final Color field;

  /// Primary text and icon color.
  final Color onSurface;

  /// What the accent is blended toward to produce hairlines and outlines: away
  /// from the background, so the line stays legible whichever way the theme
  /// runs. White on dark, slate on light.
  final Color accentLineTarget;

  /// How far toward [accentLineTarget] the accent is pushed. Light needs less
  /// than dark: a darkened line on a pale surface reads at lower contrast
  /// before it starts looking heavy.
  final double accentLineAmount;

  final double dividerAlpha;
  final double outlineAlpha;

  bool get isDark => brightness == Brightness.dark;

  static const dark = VoyagerPalette(
    brightness: Brightness.dark,
    scaffold: Color(0xFF1B1B22),
    appBar: Color(0xFF24242B),
    card: Color(0xFF2A2A33),
    field: Color(0xFF30303A),
    onSurface: Color(0xFFE6E6EA),
    accentLineTarget: Colors.white,
    accentLineAmount: 0.42,
    dividerAlpha: 0.24,
    outlineAlpha: 0.34,
  );

  /// Warm off-white cream. The tones step very tightly (only a few points of
  /// luminance apart) on purpose — the spec asks for a flat, matte surface, and
  /// wide steps between surfaces would reintroduce the layered, elevated look
  /// the paper texture is meant to replace.
  static const light = VoyagerPalette(
    brightness: Brightness.light,
    scaffold: Color(0xFFF5F1E9),
    appBar: Color(0xFFFAF7F0),
    card: Color(0xFFFDFBF6),
    field: Color(0xFFFFFEFA),
    onSurface: Color(0xFF2B303B),
    accentLineTarget: Color(0xFF2B303B),
    accentLineAmount: 0.30,
    dividerAlpha: 0.26,
    outlineAlpha: 0.38,
  );

  static VoyagerPalette of(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.dark:
        return dark;
      case AppThemeMode.light:
        return light;
    }
  }
}

class VoyagerTheme {
  static ThemeData dark({Color accent = const Color(0xFF7C9EFF)}) =>
      _build(VoyagerPalette.dark, accent);

  static ThemeData light({Color accent = const Color(0xFF7C9EFF)}) =>
      _build(VoyagerPalette.light, accent);

  static ThemeData forMode(
    AppThemeMode mode, {
    Color accent = const Color(0xFF7C9EFF),
  }) => _build(VoyagerPalette.of(mode), accent);

  static ThemeData _build(VoyagerPalette palette, Color accent) {
    final accentLine = Color.lerp(
      accent,
      palette.accentLineTarget,
      palette.accentLineAmount,
    )!;
    final dividerColor = accentLine.withValues(alpha: palette.dividerAlpha);
    final outlineColor = accentLine.withValues(alpha: palette.outlineAlpha);

    // The accent is user-chosen and can land anywhere on the luminance range,
    // so the label color on top of it is picked from the accent itself rather
    // than from the theme — a pale accent needs dark text in either theme.
    final onAccent = accent.computeLuminance() > 0.55
        ? const Color(0xFF1B1B22)
        : Colors.white;

    final colorScheme = palette.isDark
        ? ColorScheme.dark(
            primary: accent,
            onPrimary: onAccent,
            secondary: accent.withValues(alpha: 0.7),
            surface: palette.appBar,
            onSurface: palette.onSurface,
            outline: outlineColor,
            outlineVariant: dividerColor,
          )
        : ColorScheme.light(
            primary: accent,
            onPrimary: onAccent,
            secondary: accent.withValues(alpha: 0.7),
            surface: palette.appBar,
            onSurface: palette.onSurface,
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
      brightness: palette.brightness,
      useMaterial3: true,
      colorScheme: colorScheme,
    );
    // A raw ThemeData's text themes carry colour but no geometry — every slot's
    // fontSize is null until the Theme widget merges the typography in. Folding
    // it in here is what lets AppFonts see the real sizes; tuning the bare theme
    // sizes every slot as if it were 14px, and since that merge keeps whatever
    // is already non-null, the wrong leading would then outlive it.
    final geometry = base.typography.englishLike;
    final textTheme = AppFonts.applyTo(
      geometry.merge(base.textTheme),
      colorScheme.onSurface,
    );
    final primaryTextTheme = AppFonts.applyTo(
      geometry.merge(base.primaryTextTheme),
      colorScheme.onPrimary,
    );

    final sharedButtonStyle = ButtonStyle(
      overlayColor: pressOverlay,
      elevation: pressElevation,
      shape: buttonShape,
      splashFactory: NoSplash.splashFactory,
      animationDuration: const Duration(milliseconds: 90),
      textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
      // Elevation without a shadow color of its own would use Material's
      // default black; on cream that reads as grime under every button.
      shadowColor: WidgetStatePropertyAll(VoyagerShadows.color(palette)),
    );
    final textButtonStyle = sharedButtonStyle.copyWith(
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    final outlinedButtonStyle = sharedButtonStyle.copyWith(side: buttonSide);

    return ThemeData(
      brightness: palette.brightness,
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
      shadowColor: VoyagerShadows.color(palette),
      scaffoldBackgroundColor: palette.scaffold,
      extensions: [VoyagerColors.fromPalette(palette, accent: accent)],
      appBarTheme: AppBarTheme(
        backgroundColor: palette.appBar,
        elevation: 0,
        titleTextStyle: textTheme.titleLarge,
        toolbarTextStyle: textTheme.titleMedium,
      ),
      cardTheme: CardThemeData(
        color: palette.card,
        shadowColor: VoyagerShadows.color(palette),
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
        fillColor: palette.field,
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
      textButtonTheme: TextButtonThemeData(style: textButtonStyle),
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
      popupMenuTheme: VoyagerMenuTheme.popupMenuTheme(
        textTheme: textTheme,
        onSurface: colorScheme.onSurface,
        accentColor: colorScheme.primary,
        color: palette.card,
      ),
      menuTheme: VoyagerMenuTheme.menuTheme(
        accentColor: colorScheme.primary,
        color: palette.card,
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.card,
        shadowColor: VoyagerShadows.color(palette),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.field,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurface,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        textStyle: textTheme.bodySmall?.copyWith(color: colorScheme.onSurface),
        decoration: BoxDecoration(
          color: palette.field,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: outlineColor),
        ),
      ),
      dropdownMenuTheme: VoyagerMenuTheme.dropdownMenuTheme(
        textTheme,
        color: palette.card,
      ),
      navigationRailTheme: NavigationRailThemeData(
        selectedLabelTextStyle: textTheme.labelSmall,
        unselectedLabelTextStyle: textTheme.labelSmall,
      ),
      checkboxTheme: CheckboxThemeData(side: BorderSide(color: outlineColor)),
      chipTheme: ChipThemeData(labelStyle: textTheme.labelLarge),
    );
  }
}

/// Drop shadows for both themes.
///
/// The light theme's brief is a flat, matte surface, so its shadows are pushed
/// to 3–5% opacity with a wide blur — enough to separate a popover from the
/// paper behind it, never enough to read as elevation. The dark theme keeps the
/// heavier shadows it always had; on a near-black backdrop a faint shadow is
/// invisible, and there is no paper texture for it to muddy.
abstract final class VoyagerShadows {
  static Color color(VoyagerPalette palette) =>
      palette.isDark ? Colors.black : const Color(0xFF2B303B);

  /// Opacity for a shadow cast by a small floating element (menu item hover
  /// lift, chip, drag proxy).
  static double subtleAlpha(VoyagerPalette palette) =>
      palette.isDark ? 0.18 : 0.03;

  /// Opacity for a shadow cast by a large floating surface (menu, popover,
  /// dialog, modal).
  static double strongAlpha(VoyagerPalette palette) =>
      palette.isDark ? 0.40 : 0.05;

  /// Blur radius multiplier. Light shadows are spread much wider so that at
  /// 3–5% opacity they still separate the surface without forming a visible
  /// edge.
  static double blurScale(VoyagerPalette palette) =>
      palette.isDark ? 1.0 : 2.2;
}

/// Semantic colors that widgets used to spell as `Colors.white`/`Colors.black`
/// with an alpha — hairlines, scrims, chart gridlines, shadows.
///
/// Registered as a [ThemeExtension] so a widget reads the right value for
/// whichever theme it is under, including inside the local `Theme.copyWith`
/// overrides the calendar panels build.
@immutable
class VoyagerColors extends ThemeExtension<VoyagerColors> {
  const VoyagerColors({
    required this.hairline,
    required this.strongHairline,
    required this.scrim,
    required this.shadow,
    required this.subtleShadowAlpha,
    required this.strongShadowAlpha,
    required this.shadowBlurScale,
    required this.onAccent,
    required this.chartGrid,
    required this.highlightWash,
  });

  factory VoyagerColors.fromPalette(
    VoyagerPalette palette, {
    required Color accent,
  }) {
    final ink = palette.isDark ? Colors.white : palette.onSurface;
    return VoyagerColors(
      hairline: ink.withValues(alpha: palette.isDark ? 0.10 : 0.09),
      strongHairline: ink.withValues(alpha: palette.isDark ? 0.15 : 0.14),
      // Barrier scrims stay dark in both themes: a light scrim over cream is
      // indistinguishable from the page and stops reading as "behind a modal".
      scrim: Colors.black.withValues(alpha: palette.isDark ? 0.55 : 0.28),
      shadow: VoyagerShadows.color(palette),
      subtleShadowAlpha: VoyagerShadows.subtleAlpha(palette),
      strongShadowAlpha: VoyagerShadows.strongAlpha(palette),
      shadowBlurScale: VoyagerShadows.blurScale(palette),
      onAccent: accent.computeLuminance() > 0.55
          ? const Color(0xFF1B1B22)
          : Colors.white,
      chartGrid: ink.withValues(alpha: palette.isDark ? 0.12 : 0.11),
      // The direction "toward more light" flips between themes: on dark a
      // highlight brightens toward white, on cream it deepens toward slate.
      highlightWash: palette.isDark ? Colors.white : palette.onSurface,
    );
  }

  /// Faint separator / border line (the old `white @ 10%`).
  final Color hairline;

  /// A slightly more present border, for surfaces that need to hold an edge.
  final Color strongHairline;

  /// Modal barrier color.
  final Color scrim;

  final Color shadow;
  final double subtleShadowAlpha;
  final double strongShadowAlpha;
  final double shadowBlurScale;

  /// Legible text/icon color on top of a fill painted in the accent color.
  final Color onAccent;

  /// Gridlines and axis rules in charts and heatmaps.
  final Color chartGrid;

  /// What a color is blended toward to read as "lifted" or hovered — white on
  /// dark, slate on light. Blending toward white on cream produces no visible
  /// change, which is why this cannot just be `Colors.white`.
  final Color highlightWash;

  static VoyagerColors of(BuildContext context) =>
      Theme.of(context).extension<VoyagerColors>() ??
      VoyagerColors.fromPalette(
        Theme.of(context).brightness == Brightness.dark
            ? VoyagerPalette.dark
            : VoyagerPalette.light,
        accent: Theme.of(context).colorScheme.primary,
      );

  /// Ready-made shadow for a large floating surface (menu, popover, dialog).
  List<BoxShadow> surfaceShadow({double blurRadius = 24, Offset? offset}) => [
    BoxShadow(
      color: shadow.withValues(alpha: strongShadowAlpha),
      blurRadius: blurRadius * shadowBlurScale,
      offset: offset ?? const Offset(0, 8),
    ),
  ];

  @override
  VoyagerColors copyWith({
    Color? hairline,
    Color? strongHairline,
    Color? scrim,
    Color? shadow,
    double? subtleShadowAlpha,
    double? strongShadowAlpha,
    double? shadowBlurScale,
    Color? onAccent,
    Color? chartGrid,
    Color? highlightWash,
  }) {
    return VoyagerColors(
      hairline: hairline ?? this.hairline,
      strongHairline: strongHairline ?? this.strongHairline,
      scrim: scrim ?? this.scrim,
      shadow: shadow ?? this.shadow,
      subtleShadowAlpha: subtleShadowAlpha ?? this.subtleShadowAlpha,
      strongShadowAlpha: strongShadowAlpha ?? this.strongShadowAlpha,
      shadowBlurScale: shadowBlurScale ?? this.shadowBlurScale,
      onAccent: onAccent ?? this.onAccent,
      chartGrid: chartGrid ?? this.chartGrid,
      highlightWash: highlightWash ?? this.highlightWash,
    );
  }

  @override
  VoyagerColors lerp(ThemeExtension<VoyagerColors>? other, double t) {
    if (other is! VoyagerColors) return this;
    return VoyagerColors(
      hairline: Color.lerp(hairline, other.hairline, t)!,
      strongHairline: Color.lerp(strongHairline, other.strongHairline, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      subtleShadowAlpha:
          subtleShadowAlpha + (other.subtleShadowAlpha - subtleShadowAlpha) * t,
      strongShadowAlpha:
          strongShadowAlpha + (other.strongShadowAlpha - strongShadowAlpha) * t,
      shadowBlurScale:
          shadowBlurScale + (other.shadowBlurScale - shadowBlurScale) * t,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      chartGrid: Color.lerp(chartGrid, other.chartGrid, t)!,
      highlightWash: Color.lerp(highlightWash, other.highlightWash, t)!,
    );
  }
}
