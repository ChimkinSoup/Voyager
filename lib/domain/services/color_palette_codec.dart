import 'dart:convert';

import 'package:voyager/core/constants/default_color_palette.dart';

/// Strips alpha variations so `#RRGGBB` and `0xFFRRGGBB` compare equal.
int normalizeColorValue(int color) => 0xFF000000 | (color & 0xFFFFFF);

bool paletteContains(List<int> palette, int color) {
  final normalized = normalizeColorValue(color);
  return palette.any((c) => normalizeColorValue(c) == normalized);
}

List<int> decodeColorPaletteJson(String? json) {
  if (json == null || json.trim().isEmpty) {
    return List<int>.from(defaultColorPalette);
  }
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return List<int>.from(defaultColorPalette);
    final colors = <int>[];
    for (final entry in decoded) {
      if (entry is! int) continue;
      final normalized = normalizeColorValue(entry);
      if (!colors.contains(normalized)) {
        colors.add(normalized);
      }
    }
    return colors.isEmpty ? List<int>.from(defaultColorPalette) : colors;
  } catch (_) {
    return List<int>.from(defaultColorPalette);
  }
}

String encodeColorPaletteJson(List<int> colors) {
  final unique = <int>[];
  for (final color in colors) {
    final normalized = normalizeColorValue(color);
    if (!unique.contains(normalized)) {
      unique.add(normalized);
    }
  }
  return jsonEncode(unique);
}

int? parseHexColor(String input) {
  final normalized = input.trim().replaceFirst('#', '').toUpperCase();
  if (!RegExp(r'^[0-9A-F]{6}([0-9A-F]{2})?$').hasMatch(normalized)) {
    return null;
  }
  final withAlpha = normalized.length == 6 ? 'FF$normalized' : normalized;
  final parsed = int.tryParse(withAlpha, radix: 16);
  if (parsed == null) return null;
  return normalizeColorValue(parsed);
}

String formatColorHex(int color) {
  return '#${normalizeColorValue(color).toRadixString(16).padLeft(8, '0').substring(2)}';
}
