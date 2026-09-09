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
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/features/rankings/rankings_field_editor.dart';

/// A rankings template field's notes box is the one spellchecked field in the
/// app short enough to hit InputDecorator's [kMinInteractiveDimension] floor:
/// `minLines: 1`, 8px of vertical padding and 12px text come to ~29px of
/// content, under the 48 a non-dense decorator insists on. The decorator does
/// not pad that slack — it *centres the text* in it
/// (`interactiveAdjustment`, input_decorator.dart), past
/// `textAlignVertical: top`. The overlays stacked behind the field are plain
/// [Padding] around a paragraph and know nothing of it, so the squiggle was
/// painted 11.5px up: a full line above the word it belongs to.
///
/// Nothing in the widget tree reports where the wavy underline landed — the
/// text engine draws it from font metrics — so this renders the real editor
/// and reads the pixels back.
///
/// The sample has no descenders, which makes the glyph band end exactly on the
/// baseline and gives the measurement a fixed datum.
const _notes = 'arstarst arstarst';

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
/// pixels. Only the middle columns are read, so neither the card's own border
/// nor the field's runs down either side count as content.
List<({double top, double bottom})> _bands(
  ByteData rgba,
  int width,
  int height,
  double scale,
  bool Function(int r, int g, int b) matches,
) {
  final rows = <int>[];
  final left = (width * 0.15).round();
  final right = (width * 0.75).round();
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

  testWidgets('a template field squiggle sits under its own word', (
    tester,
  ) async {
    // The app runs on desktop, and the density half of the overlay's offset is
    // a desktop effect. Cleared before the body ends, as flutter_test requires.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final service = VoyagerSpellCheckService()..updateDictionary({'the'});
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
                    child: RankingFieldEditor(
                      field: const RankingTemplateField(
                        id: 'f1',
                        // Blank: the label is dark text of its own, and it
                        // sits in the rows the scan reads.
                        label: '',
                        sortOrder: 0,
                      ),
                      value: const RankingFieldValue(notes: _notes),
                      precision: RankingScorePrecision.integers,
                      accentColor: Colors.blue,
                      onChanged: (_) {},
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
    // Rasterizing and reading pixels back is real async work the engine does
    // on its own clock — inside the fake-async zone those futures never
    // resolve and the test simply hangs.
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

    expect(glyphs, hasLength(1), reason: 'expected one band of notes text');
    expect(squiggles, hasLength(1), reason: 'the notes should be flagged');

    // No descenders in the sample, so the glyph band ends on the baseline.
    expect(
      squiggles.single.top - glyphs.single.bottom,
      inInclusiveRange(0.0, 3.0),
      reason:
          'the squiggle should sit just under the word. Negative means it has '
          "been lifted off it — the decorator's kMinInteractiveDimension "
          'centering the text inside a box taller than its content, which '
          '`isDense: true` on the field exists to prevent.',
    );
  });
}
