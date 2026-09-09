import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/text/prose_highlight_paint.dart';
import 'package:voyager/core/widgets/prose_highlight_underlay.dart';
import 'package:voyager/core/widgets/voyager_prose_text.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';

/// The accent both surfaces below are given, and the fill it resolves to over
/// white: `red` at the 25% alpha `ProseEmphasisTheme.of` uses.
const _accent = Color(0xFFFF0000);

bool _isFill(int r, int g, int b) =>
    r >= 245 && g >= 176 && g <= 206 && b >= 176 && b <= 206;

/// The horizontal extent of the fill on device-pixel row [y], or null when the
/// row holds none of it.
///
/// Measured as leftmost-to-rightmost rather than as a count so the glyphs
/// sitting on top of the fill — which are never this colour — cannot narrow a
/// row from the inside.
int? _fillWidthAt(ByteData rgba, int width, int y) {
  var left = -1;
  var right = -1;
  for (var x = 0; x < width; x++) {
    final i = (y * width + x) * 4;
    if (!_isFill(
      rgba.getUint8(i),
      rgba.getUint8(i + 1),
      rgba.getUint8(i + 2),
    )) {
      continue;
    }
    if (left < 0) left = x;
    right = x;
  }
  return left < 0 ? null : right - left + 1;
}

/// Every row of the fill, top to bottom, in device pixels.
List<int> _fillRows(ByteData rgba, int width, int height) => [
  for (var y = 0; y < height; y++) ?_fillWidthAt(rgba, width, y),
];

/// Renders [boundary] and reports the fill's row widths.
Future<List<int>> _fillProfile(
  WidgetTester tester,
  GlobalKey boundary,
  double scale,
) async {
  final render =
      boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
  late List<int> rows;
  await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: scale);
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    rows = _fillRows(rgba, image.width, image.height);
    image.dispose();
  });
  return rows;
}

/// Asserts [rows] describes a fill that narrows towards its corners.
///
/// A hard rect is the same width on every row of a line — which is exactly
/// what the old `backgroundColor` fill drew, and what this is here to catch.
void _expectRoundedCorners(List<int> rows, {required double scale}) {
  expect(rows, isNotEmpty, reason: 'nothing was filled at all');
  final widest = rows.reduce((a, b) => a > b ? a : b);
  // Geometrically the top row is `2 * radius` narrower than the middle; half
  // of that is asked for here, to leave room for the antialiased edge. Never
  // zero, or a hard rect would satisfy this by doing nothing.
  final inset = (kProseHighlightRadius * scale).round().clamp(1, widest);
  expect(
    widest - rows.first,
    greaterThanOrEqualTo(inset),
    reason:
        'the top row of a fill rounded to ${kProseHighlightRadius}px should be '
        'at least $inset device pixels narrower than its middle; a hard rect '
        'is the same width all the way up.',
  );
  expect(
    widest - rows.last,
    greaterThanOrEqualTo(inset),
    reason: 'the bottom row should be inset by its corners too.',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('proseHighlightRanges', () {
    test('merges the style runs one highlight is split into', () {
      // `==a **b** c==`, as the emitter builds it: the delimiters at no width,
      // the bold word its own run, all three carrying the mark.
      const marked = TextStyle(backgroundColor: kProseHighlightMark);
      final span = TextSpan(
        children: [
          const TextSpan(text: 'x '),
          const TextSpan(text: '==', style: TextStyle(fontSize: 0)),
          const TextSpan(text: 'a ', style: marked),
          TextSpan(
            text: 'b',
            style: marked.copyWith(fontWeight: FontWeight.bold),
          ),
          const TextSpan(text: ' c', style: marked),
          const TextSpan(text: '=='),
        ],
      );
      // One range over `a b c`, not three: 'x ' is 2, the opening `==` 2 more.
      expect(proseHighlightRanges(span), [const TextRange(start: 4, end: 9)]);
    });

    test('a placeholder is one character, and breaks the run', () {
      const marked = TextStyle(backgroundColor: kProseHighlightMark);
      const span = TextSpan(
        children: [
          TextSpan(text: 'ab', style: marked),
          WidgetSpan(child: SizedBox.shrink()),
          TextSpan(text: 'cd', style: marked),
        ],
      );
      expect(proseHighlightRanges(span), [
        const TextRange(start: 0, end: 2),
        const TextRange(start: 3, end: 5),
      ]);
    });

    test('the mark inherits down the tree', () {
      const span = TextSpan(
        style: TextStyle(backgroundColor: kProseHighlightMark),
        children: [
          TextSpan(text: 'ab'),
          TextSpan(
            text: 'cd',
            style: TextStyle(fontStyle: FontStyle.italic),
          ),
        ],
      );
      expect(proseHighlightRanges(span), [const TextRange(start: 0, end: 4)]);
    });

    test('an unmarked paragraph reports nothing', () {
      expect(proseHighlightRanges(const TextSpan(text: 'plain')), isEmpty);
      expect(
        proseHighlightRanges(
          const TextSpan(
            text: 'a search hit',
            style: TextStyle(backgroundColor: Color(0x2E000000)),
          ),
        ),
        isEmpty,
      );
    });
  });

  group('proseHighlightRects', () {
    test('merges boxes on one line and keeps wrapped lines apart', () {
      const boxes = [
        // Two style runs abutting on the first line…
        ui.TextBox.fromLTRBD(4, 0, 20, 18, TextDirection.ltr),
        ui.TextBox.fromLTRBD(20, 0, 36, 18, TextDirection.ltr),
        // …and the tail of the same highlight, wrapped onto the second.
        ui.TextBox.fromLTRBD(0, 18, 12, 36, TextDirection.ltr),
      ];
      final rects = proseHighlightRects(const [
        TextRange(start: 0, end: 9),
      ], (_) => boxes);
      expect(rects, hasLength(2));
      expect(rects, contains(const Rect.fromLTRB(4, 0, 36, 18)));
      expect(rects, contains(const Rect.fromLTRB(0, 18, 12, 36)));
    });

    test('two highlights sharing a line stay two fills', () {
      // The plain words between them must not be swallowed by one wide rect.
      final rects = proseHighlightRects(
        const [TextRange(start: 0, end: 3), TextRange(start: 8, end: 11)],
        (selection) => [
          if (selection.start == 0)
            const ui.TextBox.fromLTRBD(0, 0, 24, 18, TextDirection.ltr)
          else
            const ui.TextBox.fromLTRBD(60, 0, 84, 18, TextDirection.ltr),
        ],
      );
      expect(rects, [
        const Rect.fromLTRB(0, 0, 24, 18),
        const Rect.fromLTRB(60, 0, 84, 18),
      ]);
    });

    test('an empty range asks the paragraph for nothing', () {
      var asked = 0;
      final rects = proseHighlightRects(const [TextRange(start: 3, end: 3)], (
        _,
      ) {
        asked++;
        return const [];
      });
      expect(asked, 0);
      expect(rects, isEmpty);
    });
  });

  group('the fill is drawn with rounded corners', () {
    testWidgets('on a read surface', (tester) async {
      final boundary = GlobalKey();
      const scale = 4.0;
      tester.view.physicalSize = const Size(600, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.white,
            body: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: boundary,
                child: const ColoredBox(
                  color: Colors.white,
                  child: SizedBox(
                    width: 400,
                    height: 80,
                    // Transparent glyphs: the fill is what is being measured,
                    // and the test font paints a solid box over every letter.
                    child: VoyagerProseText(
                      '==highlighted==',
                      accentColor: _accent,
                      style: TextStyle(color: Colors.transparent, fontSize: 24),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(ProseHighlightUnderlay), findsOneWidget);
      _expectRoundedCorners(
        await _fillProfile(tester, boundary, scale),
        scale: scale,
      );
    });

    testWidgets('and beneath an editable field', (tester) async {
      final controller = TextEditingController(text: '==highlighted==');
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      final service = VoyagerSpellCheckService();
      final boundary = GlobalKey();
      const scale = 4.0;
      tester.view.physicalSize = const Size(600, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            voyagerSpellCheckServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.white,
              body: Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(
                  key: boundary,
                  child: ColoredBox(
                    color: Colors.white,
                    child: SizedBox(
                      width: 400,
                      height: 120,
                      child: VoyagerTextField(
                        controller: controller,
                        focusNode: focusNode,
                        accentColor: _accent,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(
                          color: Colors.transparent,
                          fontSize: 24,
                        ),
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

      _expectRoundedCorners(
        await _fillProfile(tester, boundary, scale),
        scale: scale,
      );
    });
  });
}
