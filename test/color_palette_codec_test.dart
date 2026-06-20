import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';

void main() {
  test('parseHexColor accepts hash-prefixed RGB', () {
    expect(parseHexColor('#7C9EFF'), 0xFF7C9EFF);
  });

  test('encode and decode round-trip palette', () {
    const palette = [0xFF7C9EFF, 0xFF4CAF50];
    final json = encodeColorPaletteJson(palette);
    expect(decodeColorPaletteJson(json), palette);
  });

  test('decodeColorPaletteJson falls back to defaults when empty', () {
    expect(decodeColorPaletteJson(null), defaultColorPalette);
    expect(decodeColorPaletteJson(''), defaultColorPalette);
  });

  test('normalizeColorValue strips alpha channel differences', () {
    expect(normalizeColorValue(0x807C9EFF), 0xFF7C9EFF);
  });

  test('paletteContains compares normalized values', () {
    expect(paletteContains([0x807C9EFF], 0xFF7C9EFF), isTrue);
  });
}
