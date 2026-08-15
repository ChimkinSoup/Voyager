import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';

/// The `#tag` pill is painted by a [CustomPainter] into an overlay stacked
/// behind the real [TextField], so nothing in the widget tree says whether it
/// actually lands on the word it belongs to — only the pixels do. Two ways it
/// has come apart:
///
///  1. The overlay is a plain [Padding] around text and so misses the
///     [VisualDensity] shift InputDecorator applies to the real text, dropping
///     the pills a few pixels below their words (`withDensityShift`).
///  2. The pill rect was anchored on the selection box's top, which carries the
///     line's leading rather than tracking the letters — so it drifted with any
///     change to the line height or to the overlay's own position.
///
/// The sample has no descenders, which makes each line exactly one band of dark
/// pixels running from the top of `#` down to the baseline.
const _text = '#tam\n#tam\n#tam';

/// Iosevka is loaded for real: the pill is sized from that font's cap height.
Future<void> _loadIosevka() async {
  final loader = FontLoader(AppFonts.family)
    ..addFont(
      Future.value(
        ByteData.view(
          File(
            'assets/Iosevka-Regular/Iosevka-Aile-01.ttf',
          ).readAsBytesSync().buffer,
        ),
      ),
    );
  await loader.load();
}

/// Contiguous bands of rows holding a pixel [matches] accepts, in logical
/// pixels. Only the columns the tags occupy are sampled.
List<({double top, double bottom})> _bands(
  ByteData rgba,
  int width,
  int height,
  double scale,
  bool Function(int r, int g, int b) matches,
) {
  final rows = <int>[];
  final left = (20 * scale).round();
  final right = (50 * scale).round();
  for (var y = 0; y < height; y++) {
    for (var x = left; x < right; x++) {
      final i = (y * width + x) * 4;
      if (matches(
        rgba.getUint8(i),
        rgba.getUint8(i + 1),
        rgba.getUint8(i + 2),
      )) {
        rows.add(y);
        break;
      }
    }
  }
  final out = <({double top, double bottom})>[];
  if (rows.isEmpty) return out;
  var start = rows.first;
  var prev = rows.first;
  for (final y in rows.skip(1)) {
    if (y != prev + 1) {
      out.add((top: start / scale, bottom: prev / scale));
      start = y;
    }
    prev = y;
  }
  out.add((top: start / scale, bottom: prev / scale));
  return out;
}

bool _isGlyph(int r, int g, int b) => r < 110 && g < 110 && b < 110;

/// Anything left that is not the field's near-white background.
bool _isPill(int r, int g, int b) =>
    !_isGlyph(r, g, b) && !(r >= 250 && g >= 240 && b >= 250);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_loadIosevka);

  testWidgets('every #tag pill is centred on its own word', (tester) async {
    // The density shift the overlay has to mirror is a desktop effect; under
    // flutter_test's android default it is zero and this would pass either
    // way. Cleared before the test body ends, as flutter_test requires.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final service = VoyagerSpellCheckService()..updateDictionary({'the'});
    final controller = TextEditingController(text: _text);
    addTearDown(controller.dispose);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final boundary = GlobalKey();

    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voyagerSpellCheckServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            textTheme: AppFonts.applyTo(ThemeData().textTheme, Colors.black),
          ),
          home: Scaffold(
            backgroundColor: Colors.white,
            body: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: boundary,
                child: ColoredBox(
                  color: Colors.white,
                  child: SizedBox(
                    width: 300,
                    height: 90,
                    // Borderless: the border strokes are dark pixels spanning
                    // the rows the scan reads.
                    child: TagHighlightedTextField(
                      controller: controller,
                      focusNode: focusNode,
                      expands: true,
                      useNotchedBorder: false,
                      keyboardType: TextInputType.multiline,
                      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final renderBoundary =
        boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    // Rasterizing and reading pixels back is real async work the engine does on
    // its own clock — inside the fake-async zone those futures never resolve.
    const scale = 8.0;
    late List<({double top, double bottom})> glyphs;
    late List<({double top, double bottom})> pills;
    await tester.runAsync(() async {
      final image = await renderBoundary.toImage(pixelRatio: scale);
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      glyphs = _bands(rgba!, image.width, image.height, scale, _isGlyph);
      // A pill is most of a line tall; the sliver dropped here is the tinted
      // last row of the boundary itself.
      pills = _bands(rgba, image.width, image.height, scale, _isPill)
          .where((band) => band.bottom - band.top > 4)
          .toList();
      image.dispose();
    });
    debugDefaultTargetPlatformOverride = null;

    expect(glyphs, hasLength(3), reason: 'expected one band per line of text');
    expect(pills, hasLength(3), reason: 'expected one pill per tag');

    for (var line = 0; line < 3; line++) {
      final glyph = glyphs[line];
      final pill = pills[line];

      expect(
        glyph.top - pill.top,
        inInclusiveRange(1.5, 4.5),
        reason:
            'line $line: the pill should clear the top of the letters by about '
            'its vertical padding. Negative means the letters overflow it; too '
            'large means the pill has drifted up off its own word.',
      );
      expect(
        pill.bottom - glyph.bottom,
        inInclusiveRange(1.5, 4.5),
        reason:
            'line $line: the pill should clear the baseline by about its '
            'vertical padding.',
      );
    }
  });
}
