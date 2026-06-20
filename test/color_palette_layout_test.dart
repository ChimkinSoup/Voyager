import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';

void main() {
  test('computeColorPaletteLayout keeps 4:3 aspect ratio', () {
    final layout = computeColorPaletteLayout(
      colorCount: 12,
      maxWidth: 400,
      maxHeight: 500,
    );
    expect(layout.width / layout.height, closeTo(4 / 3, 0.01));
  });

  test('computeColorPaletteLayout shrinks for fewer colors', () {
    final few = computeColorPaletteLayout(
      colorCount: 4,
      maxWidth: 400,
      maxHeight: 500,
    );
    final many = computeColorPaletteLayout(
      colorCount: 24,
      maxWidth: 400,
      maxHeight: 500,
    );
    expect(few.height, lessThan(many.height));
    expect(few.width, lessThanOrEqualTo(many.width));
  });

  test('computeColorPaletteLayout enables scroll when capped', () {
    final layout = computeColorPaletteLayout(
      colorCount: 40,
      maxWidth: 280,
      maxHeight: 180,
    );
    expect(layout.scrollable, isTrue);
    expect(layout.width / layout.height, closeTo(4 / 3, 0.01));
  });
}
