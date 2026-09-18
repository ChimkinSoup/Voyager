// A glass surface blurs its backdrop, drains most of its colour *and* most of
// its contrast. Without those last two steps something bright or saturated
// behind the surface comes through as a smudge instead of as depth — which is
// what the time picker showed when it opened over the reminder editor's
// accent-filled "All devices" pill.
//
// Colour and brightness are separate failures, each pinned by a test here: a
// small bright shape shows up as a glow whatever its hue, and a broad colour
// field tints the whole surface however flat it is.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/domain/models/enums.dart';

/// The most saturated colour Voyager paints: a filled accent pill.
const _accent = Color(0xFF7C9EFF);

/// [_accent] as a filled `SelectorPill` actually composites over a card —
/// measured off the reminder editor's "All devices" pill, the one that showed
/// through the time picker.
const _filledPill = Color(0xFF637BC2);

const _side = 400;
final _boundary = GlobalKey();

/// Paints [backdrop] under a 240×240 surface centred at (80, 80)–(320, 320).
Future<ByteData> _render(WidgetTester tester, Widget backdrop) async {
  tester.view.physicalSize = const Size(400, 400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: VoyagerTheme.forMode(AppThemeMode.dark, accent: _accent),
        home: Builder(
          builder: (context) => Scaffold(
            // The surface opens over a card, as it does in the app.
            backgroundColor: Theme.of(context).cardColor,
            body: Stack(
              children: [
                backdrop,
                Center(
                  child: GlassSurface(
                    borderRadius: BorderRadius.circular(18),
                    child: const SizedBox(width: 240, height: 240),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // [RenderRepaintBoundary.toImage] hands work to the engine, which a widget
  // test's fake async never gets back from unless the wait is real.
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    return image.toByteData(format: ui.ImageByteFormat.rawRgba);
  }))!;
}

/// Mean channels of a 40×40 patch centred on ([cx], [cy]).
(double, double, double) _patch(ByteData pixels, int cx, int cy) {
  var r = 0.0, g = 0.0, b = 0.0;
  for (var y = cy - 20; y < cy + 20; y++) {
    for (var x = cx - 20; x < cx + 20; x++) {
      final o = (y * _side + x) * 4;
      r += pixels.getUint8(o);
      g += pixels.getUint8(o + 1);
      b += pixels.getUint8(o + 2);
    }
  }
  return (r / 1600, g / 1600, b / 1600);
}

double _luma((double, double, double) c) =>
    0.2126 * c.$1 + 0.7152 * c.$2 + 0.0722 * c.$3;

/// How far apart the weakest and strongest channel of [c] are — how coloured
/// it reads, independent of how bright it is.
double _spread((double, double, double) c) {
  final channels = [c.$1, c.$2, c.$3];
  return channels.reduce((a, b) => a > b ? a : b) -
      channels.reduce((a, b) => a < b ? a : b);
}

void main() {
  testWidgets('a bright shape behind the glass leaves no glow', (tester) async {
    final pixels = await _render(
      tester,
      // Wholly under the surface's top-left quadrant, with nothing under its
      // right. Hidden is the case that matters: a glow with no visible cause
      // reads as a rendering fault rather than as something showing through.
      Positioned(
        left: 100,
        top: 110,
        width: 90,
        height: 34,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _filledPill,
            borderRadius: BorderRadius.circular(17),
          ),
        ),
      ),
    );

    final over = _patch(pixels, 145, 127); // squarely over the pill
    final clear = _patch(pixels, 265, 127); // same band, nothing behind it

    // Draining the colour alone leaves ~13 here and a plainly visible grey
    // glow; the contrast compression is what takes it down. This rig is
    // harsher than the screen it came from — the whole pill sits behind the
    // sample, where on the reminder editor the popover's edge clips its top
    // away and the same measurement reads under 2.
    expect(
      _luma(over) - _luma(clear),
      lessThan(5.0),
      reason:
          'the pill still reads as a shape: ${_luma(over).toStringAsFixed(1)} '
          'against ${_luma(clear).toStringAsFixed(1)}',
    );
  });

  testWidgets('a saturated field behind the glass barely tints it', (
    tester,
  ) async {
    // Nothing but accent to gather, so the blur cannot average the colour
    // away and only the desaturation can — the worst case for a colour cast.
    final accent = _patch(
      await _render(
        tester,
        const Positioned.fill(child: ColoredBox(color: _accent)),
      ),
      200,
      200, // dead centre, where only the backdrop can be showing
    );
    // The same surface over a backdrop of its own colour: whatever tint it
    // shows here is the material's, not the backdrop's.
    final neutral = _patch(
      await _render(tester, const SizedBox.shrink()),
      200,
      200,
    );

    // The accent spans 131 between its weakest and strongest channel. What
    // survives the desaturation is the shift between these two, which without
    // it is ~9 — enough to read as a blue cast. Some tint is the point of a
    // material; a blush is not.
    expect(
      _spread(accent) - _spread(neutral),
      lessThan(4.0),
      reason: 'rgb$accent against a neutral rgb$neutral',
    );
  });
}
