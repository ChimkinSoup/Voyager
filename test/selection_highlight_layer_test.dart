import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/selection_highlight_layer.dart';

/// A line height that is deliberately not a whole multiple of the glyph box,
/// so the paragraph's line *advance* and its per-line selection boxes disagree
/// — the mismatch that puts a pale seam between the rows Flutter draws. A
/// layer that fills line bands has to cover it; one that fills the boxes
/// cannot.
const _style = TextStyle(fontSize: 13, height: 1.37);

const _fill = Color(0xFF3355FF);
const _alpha = 0.4;
const _size = Size(320, 240);

/// Renders [text] with [selection] highlighted, over white, and returns the
/// raw RGBA pixels.
Future<_Pixels> _render(
  WidgetTester tester, {
  required String text,
  required TextSelection selection,
}) async {
  final controller = TextEditingController(text: text)
    ..selection = selection;
  addTearDown(controller.dispose);
  final focusNode = FocusNode();
  addTearDown(focusNode.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: const ValueKey('capture'),
            child: Container(
              width: _size.width,
              height: _size.height,
              color: Colors.white,
              child: Focus(
                focusNode: focusNode,
                child: SelectionHighlightLayer(
                  controller: controller,
                  focusNode: focusNode,
                  style: _style,
                  color: _fill.withValues(alpha: _alpha),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  focusNode.requestFocus();
  await tester.pump();

  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  // runAsync, or this never returns: `toByteData` completes on the engine's
  // real event loop, which testWidgets' fake clock does not pump.
  late final _Pixels pixels;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    pixels = _Pixels(data!.buffer.asUint8List(), image.width, image.height);
    image.dispose();
  });
  return pixels;
}

class _Pixels {
  _Pixels(this.bytes, this.width, this.height);

  final Uint8List bytes;
  final int width;
  final int height;

  int argbAt(int x, int y) {
    final i = (y * width + x) * 4;
    return (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
  }

  bool isWhite(int x, int y) => argbAt(x, y) == 0xFFFFFF;

  /// The rightmost x on row [y] that is not the white background.
  int? rightmostPaintedOn(int y) {
    for (var x = width - 1; x >= 0; x--) {
      if (!isWhite(x, y)) return x;
    }
    return null;
  }

  bool rowHasPaint(int y) => rightmostPaintedOn(y) != null;
}

void main() {
  testWidgets('multi-line selection has no gap between adjacent lines', (
    tester,
  ) async {
    final pixels = await _render(
      tester,
      text: 'aaaaaaaaaaaa\nbbbbbbbbbbbb\ncccccccccccc\ndddddddddddd',
      selection: const TextSelection(baseOffset: 0, extentOffset: 51),
    );

    // Column 2 is inside the first characters of every line, so it is covered
    // on all four of them. Walk it top to bottom.
    const x = 2;
    final painted = <int>[
      for (var y = 0; y < pixels.height; y++)
        if (!pixels.isWhite(x, y)) y,
    ];
    expect(painted, isNotEmpty, reason: 'nothing was highlighted at all');

    // One unbroken run: a seam anywhere between the rows would split this.
    expect(
      painted.last - painted.first + 1,
      painted.length,
      reason: 'found ${painted.last - painted.first + 1 - painted.length} '
          'unhighlighted pixel row(s) inside the selection — the seam is back',
    );

    // And uniform: rows drawn as separate translucent rects would double-blend
    // into a *dark* seam where they touch, which the run-length check above
    // cannot see. Ends are antialiased against the background, so skip them.
    final interior = painted.sublist(1, painted.length - 1);
    final colors = {for (final y in interior) pixels.argbAt(x, y)};
    expect(
      colors,
      hasLength(1),
      reason: 'selection fill is not one flat colour: $colors',
    );
  });

  testWidgets('each line is only as wide as its own text', (tester) async {
    // A short line between two long ones. Flutter's BoxWidthStyle.max would
    // run all three out to the width of the longest.
    final pixels = await _render(
      tester,
      text: 'aaaaaaaaaaaaaaaaaaaa\nbb\ncccccccccccccccccccc',
      selection: const TextSelection(baseOffset: 0, extentOffset: 44),
    );

    final widths = <int>[];
    var previous = -1;
    for (var y = 0; y < pixels.height; y++) {
      final right = pixels.rightmostPaintedOn(y);
      if (right == null) continue;
      if (right != previous) {
        widths.add(right);
        previous = right;
      }
    }

    final longest = widths.reduce((a, b) => a > b ? a : b);
    final shortest = widths.reduce((a, b) => a < b ? a : b);
    expect(
      shortest,
      lessThan(longest ~/ 2),
      reason: 'the short middle line is highlighted nearly as wide as the long '
          'ones ($shortest vs $longest) — the selection is still a box',
    );
  });

  testWidgets('a line ends at its last glyph, not past its line break', (
    tester,
  ) async {
    // Identical lines, so the only thing that can make one wider than another
    // is a mark for the line break after it — which reads as a trailing space
    // the text does not have.
    final pixels = await _render(
      tester,
      text: 'mountain\nmountain\nmountain',
      selection: const TextSelection(baseOffset: 0, extentOffset: 26),
    );

    final rights = <int>[
      for (var y = 0; y < pixels.height; y++) ?pixels.rightmostPaintedOn(y),
    ];
    expect(rights, isNotEmpty);

    final widest = rights.reduce((a, b) => a > b ? a : b);
    final narrowest = rights.reduce((a, b) => a < b ? a : b);
    // Within antialiasing of each other: the last line has no selected break,
    // so any mark on the first two would show up here.
    expect(
      widest - narrowest,
      lessThanOrEqualTo(1),
      reason: 'the lines whose break is selected are $widest px wide against '
          "the last line's $narrowest — there is a trailing mark",
    );
  });

  testWidgets('a selected line break leaves a sliver on an empty line', (
    tester,
  ) async {
    final pixels = await _render(
      tester,
      text: 'aaaa\n\nbbbb',
      selection: const TextSelection(baseOffset: 0, extentOffset: 10),
    );

    // The blank middle line has no glyphs, so the only thing that can paint it
    // is the mark standing in for its selected newline.
    final rows = [
      for (var y = 0; y < pixels.height; y++)
        if (pixels.rowHasPaint(y)) y,
    ];
    expect(rows, isNotEmpty);

    final lineHeight = (rows.last - rows.first + 1) / 3;
    final middle = (rows.first + lineHeight * 1.5).round();
    expect(
      pixels.rowHasPaint(middle),
      isTrue,
      reason: 'the empty line between two selected lines is not marked',
    );
    // A sliver, not a full-width band.
    expect(pixels.rightmostPaintedOn(middle), lessThan(20));
  });

  testWidgets('nothing is painted without focus or with a collapsed caret', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'aaaa\nbbbb')
      ..selection = const TextSelection(baseOffset: 0, extentOffset: 9);
    addTearDown(controller.dispose);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            focusNode: focusNode,
            child: SelectionHighlightLayer(
              controller: controller,
              focusNode: focusNode,
              style: _style,
              color: _fill.withValues(alpha: _alpha),
            ),
          ),
        ),
      ),
    );

    // Scoped to the layer: Material puts CustomPaints of its own in the tree.
    final highlight = find.descendant(
      of: find.byType(SelectionHighlightLayer),
      matching: find.byType(CustomPaint),
    );

    // Material only highlights the focused field.
    expect(highlight, findsNothing);

    focusNode.requestFocus();
    await tester.pump();
    expect(highlight, findsOneWidget);

    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();
    expect(highlight, findsNothing);
  });
}
