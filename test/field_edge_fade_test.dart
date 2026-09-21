import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';

/// A multi-line field paints its text on past its scroll viewport so a
/// scrolled body reads flush to the border. [NotchedFieldBorder] floats its
/// label centred on that same top border line, so the text scrolling under it
/// used to print straight through the label.
///
/// The check is a repaint of the top gutter: with nothing scrolled it holds
/// only chrome, and scrolling a paragraph under it must leave it looking the
/// same, while the body of the field plainly redraws.
const _fieldWidth = 600.0;

/// The band the floated label's ink occupies below the border — 12px of 1.35
/// leading, halved by the label's `-floatedHeight / 2` offset, less the
/// descender room under its baseline.
const _labelBand = (top: 0, bottom: 8);

/// The rest of the gutter, between the label's ink and the first line of text
/// that rests there (`contentPadding.top`, less the compact density shift).
/// Scrolled text has to *reach* here, or the label is only legible because
/// something upstream clipped the paragraph at the viewport again — which is
/// the flush-to-the-border behaviour this fade exists to keep.
const _restOfGutter = (top: 9, bottom: 11);

/// Sampled clear of the label, which is drawn over the fade, not under it.
const _sampleLeft = 200;
const _sampleRight = 560;

void main() {
  late TextEditingController controller;
  late GlobalKey boundaryKey;

  setUp(() {
    controller = TextEditingController(
      text: List.generate(
        12,
        (i) => 'Line $i of a body long enough to scroll inside the field.',
      ).join('\n'),
    );
    boundaryKey = GlobalKey();
  });

  tearDown(() => controller.dispose());

  Future<void> pumpField(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        // The capture below runs real async, which is long enough for a
        // spellcheck lookup to reach for the on-disk database.
        overrides: [
          dictionaryProvider.overrideWith((_) async => <String>{}),
          customWordsProvider.overrideWith((_) async => <String>{}),
          flaggedWordsProvider.overrideWith((_) async => <String, String?>{}),
        ],
        child: MaterialApp(
          theme: VoyagerTheme.dark().copyWith(
            visualDensity: VisualDensity.compact,
          ),
          home: VimEnabledScope(
            enabled: false,
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: _fieldWidth,
                  child: RepaintBoundary(
                    key: boundaryKey,
                    child: VoyagerTextField(
                      controller: controller,
                      maxLines: 4,
                      decoration: const InputDecoration(labelText: 'Algorithm'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Every channel of the field as painted, row-major RGBA at 1:1.
  Future<(ByteData, int)> capture(WidgetTester tester) async {
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    // Rasterizing runs on the real event loop, not the fake async zone the
    // test body runs in — awaited there, the future never completes.
    final shot = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final width = image.width;
      image.dispose();
      return (bytes!, width);
    });
    return shot!;
  }

  /// Largest single-channel difference between two captures over the rows
  /// [top]..[bottom], ignoring the columns the label is drawn in.
  int maxDelta(
    (ByteData, int) before,
    (ByteData, int) after, {
    required int top,
    required int bottom,
  }) {
    var worst = 0;
    for (var y = top; y <= bottom; y++) {
      for (var x = _sampleLeft; x <= _sampleRight; x++) {
        final offset = (y * before.$2 + x) * 4;
        for (var channel = 0; channel < 3; channel++) {
          final delta =
              (before.$1.getUint8(offset + channel) -
                      after.$1.getUint8(offset + channel))
                  .abs();
          if (delta > worst) worst = delta;
        }
      }
    }
    return worst;
  }

  testWidgets(
    'scrolled text fades out before it reaches the label',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      await pumpField(tester);
      final atRest = await capture(tester);

      tester
          .widget<TextField>(find.byType(TextField))
          .scrollController!
          .jumpTo(30);
      await tester.pump();
      final scrolled = await capture(tester);

      // The scroll really happened: the body of the field is showing
      // different lines than it was.
      expect(
        maxDelta(atRest, scrolled, top: 40, bottom: 60),
        greaterThan(40),
        reason: 'the field did not repaint, so the top gutter proves nothing',
      );

      // Text still runs right up into the gutter, as the flush-to-the-border
      // layout intends — this is not a clip at the viewport.
      expect(
        maxDelta(
          atRest,
          scrolled,
          top: _restOfGutter.top,
          bottom: _restOfGutter.bottom,
        ),
        greaterThan(20),
        reason:
            'nothing scrolled into the gutter, so the label band below '
            'would stay clean however the fade was shaped',
      );

      // And where the label prints, that text is faded to nothing.
      expect(
        maxDelta(
          atRest,
          scrolled,
          top: _labelBand.top,
          bottom: _labelBand.bottom,
        ),
        lessThan(20),
      );
    },
  );
}
