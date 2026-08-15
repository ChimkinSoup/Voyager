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
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';

/// Two things have to hold for the misspelling squiggle, and neither is
/// visible to a widget-tree assertion — the underline is painted by the text
/// engine from font metrics, at an offset no Dart API reports. So these
/// render the tightest spellchecked field in the app (the todo edit panel's
/// `dense` Notes box) and read the pixels back.
///
///  1. The squiggle sits just under the words it marks. A text overlay is a
///     plain [Padding] around a [Text] and so misses the [VisualDensity]
///     shift InputDecorator applies to the real text — 4px on desktop — which
///     silently drops it most of a line below its own word
///     ([withDensityShift]).
///  2. It stays clear of the *next* line. The wave hangs below the baseline,
///     so a line height tight enough leaves it painting over the following
///     line's letters ([kMinSquiggleLineHeight]).
///
/// The sample deliberately has no descenders, which makes each line's glyph
/// band end exactly at its baseline and gives the measurement a fixed datum.
const _text = 'arstarst\narstarst\narstarst';

/// Iosevka is loaded for real — the whole question is where *this* font's
/// underline metrics sit, which the test-default font would answer wrongly.
Future<void> _loadIosevka() async {
  final loader = FontLoader(AppFonts.family)
    ..addFont(
      Future.value(
        ByteData.view(
          File('assets/Iosevka-Regular/Iosevka-Aile-01.ttf')
              .readAsBytesSync()
              .buffer,
        ),
      ),
    );
  await loader.load();
}

/// Contiguous bands of rows holding a pixel [matches] accepts, in logical
/// pixels. Only the middle columns are sampled, so the field's own rounded
/// border — dark, and spanning every row down both sides — is not read as
/// content.
List<({double top, double bottom})> _bands(
  ByteData rgba,
  int width,
  int height,
  double scale,
  bool Function(int r, int g, int b) matches,
) {
  final rows = <int>[];
  final left = (width * 0.15).round();
  final right = (width * 0.85).round();
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

bool _isRed(int r, int g, int b) => r > 150 && g < 120 && b < 120;

bool _isGlyph(int r, int g, int b) =>
    !_isRed(r, g, b) && r < 110 && g < 110 && b < 110;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_loadIosevka);

  testWidgets('the squiggle hugs its own line and stays off the next', (
    tester,
  ) async {
    // The app runs on desktop, and the offset under test is a desktop
    // VisualDensity effect. On Android Flutter's own spellcheck span builder
    // also takes its composing-region branch and adds an underline of its
    // own, which would land in these rows. Cleared before the test body ends
    // — flutter_test fails the test if a foundation debug variable is still
    // set by then.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final service = VoyagerSpellCheckService()..updateDictionary({'the'});
    final controller = TextEditingController(text: _text);
    addTearDown(controller.dispose);
    final boundary = GlobalKey();

    tester.view.physicalSize = const Size(600, 300);
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
                child: SizedBox(
                  width: 260,
                  height: 130,
                  // The floating label is dropped: it is the one other run of
                  // dark pixels in the field, and it sits above the first
                  // line where the row scan would read it as text.
                  child: LabeledTextField(
                    label: '',
                    showLabel: false,
                    controller: controller,
                    expands: true,
                    dense: true,
                    borderRadius: 12,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 15,
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
    await tester.pump(const Duration(milliseconds: 200));

    final renderBoundary =
        boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    // Rasterizing and reading back pixels is real async work the engine
    // completes on its own clock — inside the test's fake-async zone the
    // futures never resolve and the test just hangs.
    const scale = 6.0;
    late List<({double top, double bottom})> glyphs;
    late List<({double top, double bottom})> squiggles;
    await tester.runAsync(() async {
      final image = await renderBoundary.toImage(pixelRatio: scale);
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      glyphs = _bands(rgba!, image.width, image.height, scale, _isGlyph);
      squiggles = _bands(rgba, image.width, image.height, scale, _isRed);
      image.dispose();
    });
    debugDefaultTargetPlatformOverride = null;

    expect(glyphs, hasLength(3), reason: 'expected one band per line of text');
    expect(squiggles, hasLength(3), reason: 'every line should be flagged');

    for (var line = 0; line < 3; line++) {
      // No descenders in the sample, so the glyph band ends on the baseline.
      final baseline = glyphs[line].bottom;
      final squiggle = squiggles[line];

      expect(
        squiggle.top - baseline,
        inInclusiveRange(0.0, 3.0),
        reason:
            'line $line: the squiggle should sit just under its own word. '
            'Above the baseline means it is striking through the text; more '
            'than ~3px below at this size means the overlay is missing the '
            "decorator's density shift and has slipped toward the next line.",
      );

      if (line < 2) {
        expect(
          squiggle.bottom,
          lessThan(glyphs[line + 1].top),
          reason:
              'line $line: the squiggle runs into the letters of line '
              '${line + 1} — the line box is too short to hold it.',
        );
      }
    }
  });

  test('withSquiggleRoom only raises heights below the floor', () {
    expect(
      withSquiggleRoom(const TextStyle(height: 1.0)).height,
      kMinSquiggleLineHeight,
    );
    // Left alone: already roomy, and "use the font's own line height".
    expect(withSquiggleRoom(const TextStyle(height: 1.35)).height, 1.35);
    expect(withSquiggleRoom(const TextStyle()).height, isNull);
  });

  test('withDensityShift insets both sides by half the density adjustment', () {
    const padding = EdgeInsets.symmetric(horizontal: 15, vertical: 15);

    // Desktop: defaultDensityForPlatform resolves to compact, a (-8, -8)
    // base size adjustment, so InputDecorator's text starts 4px higher and
    // the content box is 4px shorter on the bottom as well.
    expect(
      withDensityShift(padding, VisualDensity.compact),
      const EdgeInsets.fromLTRB(15, 11, 15, 11),
    );
    // Mobile: standard density, nothing to correct for.
    expect(withDensityShift(padding, VisualDensity.standard), padding);
  });
}
