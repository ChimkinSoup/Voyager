import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_session.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';

/// A Visual-mode selection that runs over a blank line has nothing to measure
/// on it, so the overlay used to skip that line entirely and leave a gap in the
/// middle of the highlight. The OS selection marks it with about a space, and
/// so does [VimTextOverlay] now.
const _style = TextStyle(fontSize: 13, height: 1.37);
const _size = Size(320, 240);

Future<_Pixels> _renderVisual(
  WidgetTester tester, {
  required String text,
  required TextSelection selection,
}) async {
  final controller = TextEditingController(text: text)..selection = selection;
  addTearDown(controller.dispose);
  final focusNode = FocusNode();
  addTearDown(focusNode.dispose);

  final session = VimSession(
    textController: controller,
    resolveEditableState: () => null,
    isMultiline: () => true,
  )..modeListenable.value = VimMode.visual;

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
                child: VimTextOverlay(
                  session: session,
                  controller: controller,
                  focusNode: focusNode,
                  style: _style,
                  accentColor: const Color(0xFF3355FF),
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

  bool isWhite(int x, int y) {
    final i = (y * width + x) * 4;
    return bytes[i] == 0xFF && bytes[i + 1] == 0xFF && bytes[i + 2] == 0xFF;
  }

  /// The rightmost x on row [y] that is not the white background.
  int? rightmostPaintedOn(int y) {
    for (var x = width - 1; x >= 0; x--) {
      if (!isWhite(x, y)) return x;
    }
    return null;
  }
}

void main() {
  testWidgets('a Visual selection marks a blank line it covers', (
    tester,
  ) async {
    final pixels = await _renderVisual(
      tester,
      text: 'aaaa\n\nbbbb',
      selection: const TextSelection(baseOffset: 0, extentOffset: 10),
    );

    final rows = [
      for (var y = 0; y < pixels.height; y++)
        if (pixels.rightmostPaintedOn(y) != null) y,
    ];
    expect(rows, isNotEmpty, reason: 'nothing was highlighted at all');

    final lineHeight = (rows.last - rows.first + 1) / 3;
    final middle = (rows.first + lineHeight * 1.5).round();
    expect(
      pixels.rightmostPaintedOn(middle),
      isNotNull,
      reason: 'the blank line between two selected lines is not marked',
    );
    // A mark about a space wide, not a band out to the line above.
    expect(pixels.rightmostPaintedOn(middle), lessThan(20));
  });

  testWidgets('a line with text is not widened by the break after it', (
    tester,
  ) async {
    // Ragged on purpose: three lines of the same width cannot show this bug at
    // all, because painting a covered break out to the widest line in the
    // paragraph is then indistinguishable from tracing the text.
    const text = 'mountain\nox\nmountain';
    final pixels = await _renderVisual(
      tester,
      text: text,
      selection: const TextSelection(baseOffset: 0, extentOffset: 20),
    );

    // Sampled at each line's vertical centre, not over every painted row: the
    // block caret is a full-height cell while a selection band is a tight text
    // box, so the caret on line 1 pokes a couple of rows above and below the
    // band. Those rows are only as wide as the one character under the caret,
    // and reading them as lines would call every selection ragged.
    final metrics = TextPainter(
      text: const TextSpan(text: 'mountain', style: _style),
      textDirection: TextDirection.ltr,
    )..layout();
    final lineHeight = metrics.preferredLineHeight;
    final longWidth = metrics.width;
    metrics.dispose();

    final shortMetrics = TextPainter(
      text: const TextSpan(text: 'ox', style: _style),
      textDirection: TextDirection.ltr,
    )..layout();
    final shortWidth = shortMetrics.width;
    shortMetrics.dispose();

    final rights = <int>[
      for (var line = 0; line < 3; line++)
        pixels.rightmostPaintedOn((lineHeight * (line + 0.5)).round())!,
    ];

    // The short middle line, whose break the selection covers, has to stop at
    // its own two characters rather than run out to "mountain" above it.
    expect(
      rights[1],
      closeTo(shortWidth - 1, 2),
      reason:
          'the middle line is ${rights[1]}px wide against its own ${shortWidth}px '
          'of text — its line break was painted out to the widest line',
    );
    expect(rights[0], closeTo(longWidth - 1, 2));
    expect(rights[2], closeTo(longWidth - 1, 2));
  });
}
