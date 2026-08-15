import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';

void main() {
  // Grid pitch for the default swatchRadius of 26: diameter + 8px spacing.
  const cell = 26 * 2 + 8.0;

  test('computeColorPaletteLayout sizes the box to its content', () {
    final layout = computeColorPaletteLayout(
      colorCount: 12,
      maxWidth: 400,
      maxHeight: 500,
    );

    // 12 colors settle into 4 columns x 3 rows; the box is exactly that grid
    // with no trailing spacing on the last column/row.
    expect(layout.columns, 4);
    expect(layout.width, layout.columns * cell - 8);
    expect(layout.height, 3 * cell - 8);

    // Nothing is clipped, so the viewport and the content agree.
    expect(layout.scrollable, isFalse);
    expect(layout.width, layout.contentWidth);
    expect(layout.height, layout.contentHeight);
  });

  test('computeColorPaletteLayout aims for a roughly square-ish grid', () {
    // The column count targets a 4:3-ish shape rather than one long row.
    for (final count in [4, 9, 12, 24, 40]) {
      final layout = computeColorPaletteLayout(
        colorCount: count,
        maxWidth: 4000, // wide enough that maxWidth never binds
        maxHeight: 4000,
      );
      final rows = (count / layout.columns).ceil();
      expect(
        layout.columns,
        lessThanOrEqualTo(rows * 2),
        reason: '$count colors spread into ${layout.columns} columns',
      );
      // Every color gets a slot.
      expect(layout.columns * rows, greaterThanOrEqualTo(count));
    }
  });

  test('computeColorPaletteLayout never exceeds the width it is given', () {
    final layout = computeColorPaletteLayout(
      colorCount: 40,
      maxWidth: 280,
      maxHeight: 4000,
    );
    // floor(280 / 60) = 4 columns fit, even though the 4:3 target wants more.
    expect(layout.columns, 4);
    expect(layout.width, lessThanOrEqualTo(280));
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

  test('computeColorPaletteLayout caps height and scrolls the overflow', () {
    final layout = computeColorPaletteLayout(
      colorCount: 40,
      maxWidth: 280,
      maxHeight: 180,
    );

    expect(layout.scrollable, isTrue);
    // The viewport is clamped to maxHeight...
    expect(layout.height, 180);
    // ...but contentHeight keeps the full grid so the scroll extent is right.
    expect(layout.contentHeight, 10 * cell - 8);
    expect(layout.contentHeight, greaterThan(layout.height));
    // Only the height is capped; the width still spans the full grid.
    expect(layout.width, layout.contentWidth);
  });

  test('computeColorPaletteLayout keeps at least one column for a tight box', () {
    // maxWidth smaller than a single cell must not floor down to zero columns.
    final layout = computeColorPaletteLayout(
      colorCount: 6,
      maxWidth: 10,
      maxHeight: 10,
    );
    expect(layout.columns, greaterThanOrEqualTo(1));
    expect(layout.width, greaterThan(0));
    expect(layout.height, greaterThan(0));
  });

  test('computeColorPaletteLayout returns a placeholder for an empty palette', () {
    final layout = computeColorPaletteLayout(
      colorCount: 0,
      maxWidth: 400,
      maxHeight: 500,
    );
    expect(layout.columns, 1);
    expect(layout.scrollable, isFalse);
    expect(layout.width, greaterThan(0));
    expect(layout.height, greaterThan(0));
  });
}
