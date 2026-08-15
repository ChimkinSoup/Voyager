import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_session.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';

const _style = TextStyle(fontSize: 16, height: 1.4, color: Color(0xFF333333));
const _size = Size(160, 80);
const _darkAccent = Color(0xFF2244AA);
const _lightAccent = Color(0xFF88CCFF);

void main() {
  group('vimBlockCaretForeground', () {
    test('uses white on dark accents', () {
      expect(vimBlockCaretForeground(_darkAccent), equals(Colors.white));
    });

    test('uses black on light accents', () {
      expect(vimBlockCaretForeground(_lightAccent), equals(Colors.black));
    });
  });

  group('block caret painting', () {
    Future<_Pixels> renderCaret(
      WidgetTester tester, {
      required String text,
      required int caretOffset,
      required Color accentColor,
      VimMode mode = VimMode.normal,
      String? hintText,
    }) async {
      final controller = TextEditingController(text: text)
        ..selection = TextSelection.collapsed(offset: caretOffset);
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      final session = VimSession(
        textController: controller,
        resolveEditableState: () => null,
        isMultiline: () => true,
      )..modeListenable.value = mode;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: const ValueKey('capture'),
                child: Container(
                  width: _size.width,
                  height: _size.height,
                  color: const Color(0xFFCCCCCC),
                  child: Focus(
                    focusNode: focusNode,
                    autofocus: true,
                    child: VimTextOverlay(
                      session: session,
                      controller: controller,
                      focusNode: focusNode,
                      style: _style,
                      accentColor: accentColor,
                      hintText: hintText,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('capture')),
      );
      late final _Pixels pixels;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        pixels = _Pixels(data!.buffer.asUint8List(), image.width, image.height);
        image.dispose();
      });
      return pixels;
    }

    testWidgets('repaints a light glyph on a dark accent block', (tester) async {
      final pixels = await renderCaret(
        tester,
        text: 'X',
        caretOffset: 0,
        accentColor: _darkAccent,
      );

      expect(
        pixels.hasForeground(vimBlockCaretForeground(_darkAccent)),
        isTrue,
        reason: 'expected white glyph repainted on block',
      );
    });

    testWidgets(
      'repainted glyph keeps its descender inside the paragraph glyph box',
      (tester) async {
        // bodySmall-like strut: the dream-journal note field. A tight ink box
        // plus rounded clip used to shave the bottom of letters like "y".
        const style = TextStyle(
          fontSize: 12,
          height: 1.45,
          color: Color(0xFF333333),
        );
        final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);
        final paragraph = TextPainter(
          text: const TextSpan(text: 'y', style: style),
          textDirection: TextDirection.ltr,
          strutStyle: strut,
        )..layout(maxWidth: _size.width);
        final glyphBox = paragraph
            .getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 1),
            )
            .first
            .toRect();
        paragraph.dispose();

        final controller = TextEditingController(text: 'y')
          ..selection = const TextSelection.collapsed(offset: 0);
        addTearDown(controller.dispose);
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        final session = VimSession(
          textController: controller,
          resolveEditableState: () => null,
          isMultiline: () => true,
        )..modeListenable.value = VimMode.normal;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: RepaintBoundary(
                  key: const ValueKey('capture-y'),
                  child: Container(
                    width: _size.width,
                    height: _size.height,
                    color: const Color(0xFFCCCCCC),
                    child: Focus(
                      focusNode: focusNode,
                      autofocus: true,
                      child: VimTextOverlay(
                        session: session,
                        controller: controller,
                        focusNode: focusNode,
                        style: style,
                        strutStyle: strut,
                        accentColor: _darkAccent,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture-y')),
        );
        late final _Pixels pixels;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          pixels = _Pixels(data!.buffer.asUint8List(), image.width, image.height);
          image.dispose();
        });

        final fg = vimBlockCaretForeground(_darkAccent);
        final bounds = pixels.foregroundBounds(fg);
        expect(bounds, isNotNull, reason: 'expected inverted glyph pixels');
        // toImage() defaults to pixelRatio 1.0, so image pixels == logical.
        expect(
          bounds!.bottom,
          greaterThan(glyphBox.bottom - 2.0),
          reason: 'descender was clipped — glyph would look shifted up',
        );
        expect(
          bounds.top,
          lessThan(glyphBox.top + 2.0),
          reason: 'glyph top drifted above the paragraph ink box',
        );
      },
    );

    testWidgets('repaints a dark glyph on a light accent block', (tester) async {
      final pixels = await renderCaret(
        tester,
        text: 'X',
        caretOffset: 0,
        accentColor: _lightAccent,
      );

      expect(
        pixels.hasForeground(vimBlockCaretForeground(_lightAccent)),
        isTrue,
        reason: 'expected black glyph repainted on block',
      );
    });

    testWidgets('Visual mode uses the same block caret treatment', (tester) async {
      final pixels = await renderCaret(
        tester,
        text: 'Z',
        caretOffset: 0,
        accentColor: _darkAccent,
        mode: VimMode.visual,
      );

      expect(
        pixels.hasForeground(vimBlockCaretForeground(_darkAccent)),
        isTrue,
      );
    });

    testWidgets('empty line uses a full block caret', (tester) async {
      final pixels = await renderCaret(
        tester,
        text: 'a\n\nb',
        caretOffset: 2,
        accentColor: _darkAccent,
      );

      expect(
        pixels.accentRun(_darkAccent),
        greaterThan(5),
        reason: 'expected block width, not a thin bar',
      );
    });

    testWidgets('empty document uses a full block caret', (tester) async {
      final pixels = await renderCaret(
        tester,
        text: '',
        caretOffset: 0,
        accentColor: _darkAccent,
      );

      expect(pixels.firstRowWithAccent(_darkAccent), isNotNull);
    });

    testWidgets('an empty field repaints the hint\'s first letter on the block', (
      tester,
    ) async {
      // The field paints the placeholder below this layer, where the opaque
      // block would swallow its first letter.
      final overHint = await renderCaret(
        tester,
        text: '',
        caretOffset: 0,
        accentColor: _darkAccent,
        hintText: 'Start writing...',
      );
      expect(
        overHint.hasForeground(vimBlockCaretForeground(_darkAccent)),
        isTrue,
      );

      final overSpace = await renderCaret(
        tester,
        text: '',
        caretOffset: 0,
        accentColor: _darkAccent,
      );
      expect(
        overSpace.hasForeground(vimBlockCaretForeground(_darkAccent)),
        isFalse,
        reason: 'nothing to repaint without a hint',
      );
    });
  });

  group('vimHintCaretGlyph', () {
    test('takes the placeholder\'s first letter on an empty field', () {
      expect(
        vimHintCaretGlyph(text: '', hintText: 'Start writing...'),
        'S',
      );
    });

    test('keeps a surrogate pair whole', () {
      expect(vimHintCaretGlyph(text: '', hintText: '😀 note'), '😀');
    });

    test('gives nothing once the field has text', () {
      // The placeholder is off screen by then, so the block goes back to
      // measuring the glyph it actually sits on.
      expect(vimHintCaretGlyph(text: 'a', hintText: 'Start writing...'), isNull);
    });

    test('gives nothing for a field without a hint', () {
      expect(vimHintCaretGlyph(text: '', hintText: null), isNull);
      expect(vimHintCaretGlyph(text: '', hintText: ''), isNull);
    });
  });

  group('vimCaretGlyphPaintOrigin', () {
    // bodySmall-like metrics with strut — the dream-journal note field.
    const style = TextStyle(fontSize: 12, height: 1.45, color: Color(0xFF333333));
    final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);

    test('aligns the probe glyph box onto the paragraph glyph box', () {
      final paragraph = TextPainter(
        text: const TextSpan(text: 'Hello', style: style),
        textDirection: TextDirection.ltr,
        strutStyle: strut,
      )..layout(maxWidth: 200);
      const offset = 1; // 'e'
      final block = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: offset, extentOffset: offset + 1),
          )
          .first
          .toRect();
      paragraph.dispose();

      final probe = TextPainter(
        text: const TextSpan(text: 'e', style: style),
        textDirection: TextDirection.ltr,
        strutStyle: strut,
      )..layout();

      final paintOrigin = vimCaretGlyphPaintOrigin(
        probe: probe,
        glyphLength: 1,
        blockRect: block,
      );
      final paintedBox = probe
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
          )
          .first
          .toRect()
          .shift(paintOrigin);
      probe.dispose();

      expect(paintedBox.top, closeTo(block.top, 0.01));
      expect(paintedBox.left, closeTo(block.left, 0.01));
      expect(paintedBox.bottom, closeTo(block.bottom, 0.01));
    });
  });

  testWidgets(
    'Normal-mode block caret is not clipped at the bottom of a compact-density field',
    (tester) async {
      // Voyager on Windows resolves ThemeData.visualDensity to compact.
      // InputDecorator takes 4px off each side of the content padding; the
      // overlay used to only match the top, leaving it 4px too short and
      // clipping the block caret (the Add-task composer is the obvious case).
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(visualDensity: VisualDensity.compact),
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: Center(
                child: LabeledTextField(
                  label: '',
                  showLabel: false,
                  hintText: 'Add task',
                  controller: controller,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      final overlaySize = tester.getSize(find.byType(VimTextOverlay));
      final style = tester.widget<TextField>(find.byType(TextField)).style!;
      final probe = TextPainter(
        text: TextSpan(text: ' ', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final lineHeight = probe.preferredLineHeight;
      probe.dispose();

      expect(
        overlaySize.height,
        greaterThanOrEqualTo(lineHeight - 0.5),
        reason:
            'overlay shorter than the line clips the block caret at the bottom',
      );
    },
  );
}

class _Pixels {
  _Pixels(this.bytes, this.width, this.height);

  final Uint8List bytes;
  final int width;
  final int height;

  Color colorAt(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      bytes[i + 3],
      bytes[i],
      bytes[i + 1],
      bytes[i + 2],
    );
  }

  int? firstRowWithAccent(Color accent) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (closeTo(colorAt(x, y), accent, tolerance: 16)) return y;
      }
    }
    return null;
  }

  /// Longest horizontal run of [accent] pixels anywhere in the image — the
  /// width of the widest uninterrupted slice of the block caret.
  int accentRun(Color accent) {
    var longest = 0;
    for (var y = 0; y < height; y++) {
      var run = 0;
      for (var x = 0; x < width; x++) {
        if (closeTo(colorAt(x, y), accent, tolerance: 16)) {
          run++;
          if (run > longest) longest = run;
        } else {
          run = 0;
        }
      }
    }
    return longest;
  }

  bool hasForeground(Color foreground) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (closeTo(colorAt(x, y), foreground, tolerance: 20)) return true;
      }
    }
    return false;
  }

  /// Inclusive pixel bounds of [foreground], or null if none.
  Rect? foregroundBounds(Color foreground) {
    var minX = width;
    var minY = height;
    var maxX = -1;
    var maxY = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (!closeTo(colorAt(x, y), foreground, tolerance: 20)) continue;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
    if (maxX < 0) return null;
    return Rect.fromLTRB(
      minX.toDouble(),
      minY.toDouble(),
      maxX.toDouble(),
      maxY.toDouble(),
    );
  }

  static bool closeTo(Color a, Color b, {int tolerance = 8}) {
    return (a.red - b.red).abs() <= tolerance &&
        (a.green - b.green).abs() <= tolerance &&
        (a.blue - b.blue).abs() <= tolerance &&
        a.alpha > 200 &&
        b.alpha > 200;
  }
}
