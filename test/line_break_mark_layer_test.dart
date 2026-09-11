import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/line_break_mark_layer.dart';

/// The test font draws every glyph as a 1em square, so at 20px and a height
/// of 1.0 each line is a 20px band and a 200px box wraps at ten characters.
const _style = TextStyle(fontSize: 20, height: 1.0);
const _size = Size(200, 120);
const _line = 20;

/// Renders only the marks for [text], over white — the layer paints no text,
/// so every pixel that is not white is a mark.
Future<_Pixels> _render(WidgetTester tester, String text) async {
  final controller = TextEditingController(text: text);
  addTearDown(controller.dispose);

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
              child: LineBreakMarkLayer(
                controller: controller,
                style: _style,
                strutStyle: StrutStyle.fromTextStyle(
                  _style,
                  forceStrutHeight: true,
                ),
                color: Colors.black,
              ),
            ),
          ),
        ),
      ),
    ),
  );

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

  /// The leftmost painted x in line band [line], or null if it is blank.
  int? inkStartOnLine(int line) {
    int? left;
    for (var y = line * _line; y < (line + 1) * _line; y++) {
      for (var x = 0; x < width; x++) {
        if (!isWhite(x, y)) {
          if (left == null || x < left) left = x;
          break;
        }
      }
    }
    return left;
  }
}

void main() {
  testWidgets('marks each Enter, blank lines included, and nothing else', (
    tester,
  ) async {
    // Line 0 "ab", line 1 blank, lines 2–3 one paragraph wrapped after
    // "aaaa aaaa ", line 4 "cd" with no break after it.
    final pixels = await _render(tester, 'ab\n\naaaa aaaa aaaa\ncd');

    final line0 = pixels.inkStartOnLine(0);
    expect(line0, isNotNull, reason: 'no mark after "ab"');
    expect(line0, greaterThanOrEqualTo(2 * 20), reason: 'mark overlaps "ab"');

    expect(pixels.inkStartOnLine(1), isNotNull, reason: 'blank line unmarked');

    expect(
      pixels.inkStartOnLine(2),
      isNull,
      reason: 'a line that only wrapped was marked as a break',
    );

    final line3 = pixels.inkStartOnLine(3);
    expect(line3, isNotNull, reason: 'no mark after the wrapped paragraph');
    expect(line3, greaterThanOrEqualTo(4 * 20));

    expect(
      pixels.inkStartOnLine(4),
      isNull,
      reason: 'the last line has no break to mark',
    );
  });

  testWidgets('trailing spaces push the mark out past them', (tester) async {
    final pixels = await _render(tester, 'ab   \ncd');
    expect(pixels.inkStartOnLine(0), greaterThanOrEqualTo(5 * 20));
  });

  testWidgets('a CRLF is marked at the end of its own line', (tester) async {
    final pixels = await _render(tester, 'ab\r\ncd');
    expect(pixels.inkStartOnLine(0), greaterThanOrEqualTo(2 * 20));
    expect(pixels.inkStartOnLine(1), isNull);
  });
}
