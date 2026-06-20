import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';

export 'package:voyager/core/widgets/color_picker_field.dart'
    show ColorPaletteGrid, pickColorFromPalette;

Future<int?> pickPaletteColorWithRef(
  WidgetRef ref,
  BuildContext context, {
  int? current,
  Set<int> usedColors = const {},
}) {
  return pickColorFromPalette(
    context,
    palette: ref.read(colorPaletteProvider),
    current: current,
    usedColors: usedColors,
  );
}

/// Tracks assigned palette colors per app session to avoid repeats until exhausted.
class PaletteAssigner {
  PaletteAssigner(this.palette, [List<int>? used]) : _used = {...?used};

  final List<int> palette;
  final Set<int> _used;

  int nextColor() {
    for (final color in palette) {
      final normalized = normalizeColorValue(color);
      if (!_used.contains(normalized)) {
        _used.add(normalized);
        return normalized;
      }
    }
    if (palette.isEmpty) return defaultColorPalette.first;
    final fallback =
        palette[_used.length % palette.length];
    final normalized = normalizeColorValue(fallback);
    _used.add(normalized);
    return normalized;
  }

  void release(int color) => _used.remove(normalizeColorValue(color));
  void assign(int color) => _used.add(normalizeColorValue(color));
}

PaletteAssigner paletteFromItems(Iterable<int?> colors, List<int> palette) {
  return PaletteAssigner(
    palette,
    colors.whereType<int>().map(normalizeColorValue).toList(),
  );
}

Color presetColor(int value) => Color(normalizeColorValue(value));
