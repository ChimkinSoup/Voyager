import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// Regular-weight glyph for journal/search metadata that still tints with the
/// journal accent. Live weather chrome uses [WeatherIcon] instead.
IconData weatherIconData(String? icon) => switch (icon) {
  'cloudy' => PhosphorIconsRegular.cloud,
  'rain' => PhosphorIconsRegular.cloudRain,
  'snow' => PhosphorIconsRegular.snowflake,
  _ => PhosphorIconsRegular.sun,
};

PhosphorDuotoneIconData weatherDuotoneIconData(String? icon) => switch (icon) {
  'cloudy' => PhosphorIconsDuotone.cloud,
  'rain' => PhosphorIconsDuotone.cloudRain,
  'snow' => PhosphorIconsDuotone.snowflake,
  _ => PhosphorIconsDuotone.sun,
};

/// Stroke (outline) and fill colors for a weather condition in one theme.
class WeatherIconColors {
  const WeatherIconColors({required this.stroke, required this.fill});

  final Color stroke;
  final Color fill;
}

/// Weather-natural hues, shifted brighter on dark so the glyph still reads on
/// graphite. These are condition colors, not the user accent.
WeatherIconColors weatherIconColors(String? icon, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return switch (icon) {
    'cloudy' => WeatherIconColors(
      stroke: dark ? const Color(0xFFC5D0DC) : const Color(0xFF4E5D6C),
      fill: dark ? const Color(0xFF8A96A6) : const Color(0xFFC5CFD8),
    ),
    'rain' => WeatherIconColors(
      stroke: dark ? const Color(0xFF6BA4E8) : const Color(0xFF2E6BB0),
      fill: dark ? const Color(0xFF7A8B9C) : const Color(0xFFA9B7C6),
    ),
    'snow' => WeatherIconColors(
      stroke: dark ? const Color(0xFF9AD0EA) : const Color(0xFF3E86B0),
      fill: dark ? const Color(0xFFC5E6F5) : const Color(0xFFD4EAF4),
    ),
    _ => WeatherIconColors(
      stroke: dark ? const Color(0xFFFFB347) : const Color(0xFFC56A0A),
      fill: dark ? const Color(0xFFFFE08A) : const Color(0xFFF5C542),
    ),
  };
}

/// Duotone weather glyph with a condition-colored stroke and fill.
class WeatherIcon extends StatelessWidget {
  const WeatherIcon(this.icon, {super.key, this.size});

  final String? icon;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final iconSize = size ?? IconTheme.of(context).size ?? 22;
    final colors = weatherIconColors(icon, Theme.of(context).brightness);
    return PhosphorIcon(
      weatherDuotoneIconData(icon),
      size: iconSize,
      color: colors.stroke,
      duotoneSecondaryColor: colors.fill,
      duotoneSecondaryOpacity: 1,
    );
  }
}
