import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';

export 'package:voyager/core/widgets/color_picker_field.dart'
    show ColorPaletteGrid, paletteViewportHeight, pickColorFromPalette;

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
    final available = palette
        .map(normalizeColorValue)
        .where((color) => !_used.contains(color))
        .toList();
    if (available.isEmpty) {
      _used.clear();
      return nextColor();
    }
    final picked = available[Random().nextInt(available.length)];
    _used.add(picked);
    return picked;
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
