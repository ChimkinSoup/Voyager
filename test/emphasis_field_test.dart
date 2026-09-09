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
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';

/// The style each character of the field's rendered paragraph is drawn in.
///
/// Read off [RenderEditable] rather than off the controller, so what is
/// asserted is what the field actually laid out — including that the wrapping
/// controller reached the [EditableText] at all.
List<TextStyle> renderedStyles(WidgetTester tester) {
  final span = tester
      .state<EditableTextState>(find.byType(EditableText))
      .renderEditable
      .text!;
  final styles = <TextStyle>[];
  void walk(InlineSpan node, TextStyle inherited) {
    if (node is! TextSpan) return;
    final style = node.style == null ? inherited : inherited.merge(node.style);
    final text = node.text;
    if (text != null) {
      for (var i = 0; i < text.length; i++) {
        styles.add(style);
      }
    }
    for (final child in node.children ?? const <InlineSpan>[]) {
      walk(child, style);
    }
  }

  walk(span, const TextStyle());
  return styles;
}

Widget _host(Widget field, {required VoyagerSpellCheckService service}) {
  return ProviderScope(
    overrides: [voyagerSpellCheckServiceProvider.overrideWithValue(service)],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        textTheme: AppFonts.applyTo(ThemeData().textTheme, Colors.black),
      ),
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 400, height: 200, child: field),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VoyagerSpellCheckService service;
  setUp(() => service = VoyagerSpellCheckService()..updateDictionary({'the'}));

  group('the field renders emphasis itself', () {
    testWidgets('markers collapse and the word goes bold', (tester) async {
      final controller = TextEditingController(text: 'a **bold** b');
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        _host(
          TagHighlightedTextField(
            controller: controller,
            focusNode: focusNode,
            maxLines: null,
            minLines: 3,
            keyboardType: TextInputType.multiline,
          ),
          service: service,
        ),
      );
      await tester.pump();

      final styles = renderedStyles(tester);
      expect(styles, hasLength('a **bold** b'.length));
      // `**` at 2..3 and 8..9
      for (final offset in [2, 3, 8, 9]) {
        expect(styles[offset].fontSize, 0, reason: 'marker at $offset');
      }
      expect(styles[4].fontWeight, FontWeight.bold);
      expect(styles[0].fontWeight, isNot(FontWeight.bold));
    });

    testWidgets('the caret brings the markers back', (tester) async {
      final controller = TextEditingController(text: 'a **bold** b');
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        _host(
          TagHighlightedTextField(
            controller: controller,
            focusNode: focusNode,
            maxLines: null,
            minLines: 3,
            keyboardType: TextInputType.multiline,
          ),
          service: service,
        ),
      );
      await tester.pump();
      expect(renderedStyles(tester)[2].fontSize, 0);

      focusNode.requestFocus();
      controller.selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();

      final revealed = renderedStyles(tester);
      for (final offset in [2, 3, 8, 9]) {
        expect(
          revealed[offset].fontSize,
          isNot(0),
          reason: 'marker at $offset should be visible with the caret inside',
        );
      }

      // And they go away again when the field loses the caret.
      focusNode.unfocus();
      await tester.pump();
      expect(renderedStyles(tester)[2].fontSize, 0);
    });

    testWidgets('LabeledTextField is wired the same way', (tester) async {
      final controller = TextEditingController(text: 'x *it* y');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(
          LabeledTextField(
            label: 'Notes',
            controller: controller,
            maxLines: null,
            minLines: 3,
          ),
          service: service,
        ),
      );
      await tester.pump();

      final styles = renderedStyles(tester);
      expect(styles[2].fontSize, 0);
      expect(styles[3].fontStyle, FontStyle.italic);
    });

    testWidgets('VoyagerTextField is wired the same way', (tester) async {
      final controller = TextEditingController(text: 'x ==h== y');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(
          VoyagerTextField(controller: controller, maxLines: null, minLines: 3),
          service: service,
        ),
      );
      await tester.pump();

      final styles = renderedStyles(tester);
      expect(styles[2].fontSize, 0);
      expect(styles[4].backgroundColor, isNotNull);
    });

    testWidgets('single-line fields keep their markers literal', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'a **bold** b');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(
          LabeledTextField(label: 'Title', controller: controller),
          service: service,
        ),
      );
      await tester.pump();

      final styles = renderedStyles(tester);
      expect(styles[2].fontSize, isNot(0));
      expect(styles[4].fontWeight, isNot(FontWeight.bold));
    });
  });

  group('the caller keeps a plain controller', () {
    testWidgets('typing reaches it, and its writes reach the field', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      final changes = <String>[];

      await tester.pumpWidget(
        _host(
          TagHighlightedTextField(
            controller: controller,
            focusNode: focusNode,
            maxLines: null,
            minLines: 3,
            keyboardType: TextInputType.multiline,
            onChanged: changes.add,
          ),
          service: service,
        ),
      );

      await tester.enterText(find.byType(EditableText), 'hi **there**');
      await tester.pump();

      // The wrapper is a view, not a second copy: the value the caller reads is
      // the value that was typed, markers and all.
      expect(controller.text, 'hi **there**');
      expect(changes.last, 'hi **there**');
      // The caret is sitting right after the closing `**` it just typed, which
      // is inside the span — so the markers are still up.
      expect(renderedStyles(tester)[3].fontSize, isNot(0));

      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      expect(renderedStyles(tester)[3].fontSize, 0);

      controller.text = 'set from outside __u__';
      await tester.pump();
      expect(
        tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable
            .text!
            .toPlainText(),
        'set from outside __u__',
      );
      // Setting `text` leaves no valid selection, so the field parks the caret
      // at the end — which is inside the span that ends there. Move it off
      // before asking whether the markers are hidden.
      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      expect(renderedStyles(tester)[17].fontSize, 0);
      expect(
        renderedStyles(tester)[19].decoration,
        TextDecoration.underline,
      );
    });

    testWidgets('selection set on the caller drives the reveal', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'a **b** c');
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        _host(
          TagHighlightedTextField(
            controller: controller,
            focusNode: focusNode,
            maxLines: null,
            minLines: 3,
            keyboardType: TextInputType.multiline,
          ),
          service: service,
        ),
      );
      focusNode.requestFocus();
      await tester.pump();

      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      expect(renderedStyles(tester)[2].fontSize, 0);

      controller.selection = const TextSelection(baseOffset: 0, extentOffset: 9);
      await tester.pump();
      expect(renderedStyles(tester)[2].fontSize, isNot(0));
    });
  });

  group('the overlays follow the field', () {
    setUpAll(() async {
      final loader = FontLoader(AppFonts.family);
      for (final path in const [
        'assets/Iosevka-Regular/Iosevka-Aile-01.ttf',
        'assets/Iosevka-Bold/Iosevka-Aile-Bold-01.ttf',
      ]) {
        loader.addFont(
          Future.value(
            ByteData.view(File(path).readAsBytesSync().buffer),
          ),
        );
      }
      await loader.load();
    });

    testWidgets('a bold tag keeps its pill, markers and all', (tester) async {
      // Two things would move this pill off its word if the layer laid the
      // text out flat: the `**` are drawn at no width, so a flat paragraph
      // puts `#tam` two glyphs further right than it really is, and the tag
      // itself is bold, which is wider than the regular face the layer used to
      // measure with (EMPHASIS_FORMATTING.md §8).
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final controller = TextEditingController(text: '**#tam**');
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      final boundary = GlobalKey();

      tester.view.physicalSize = const Size(600, 200);
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
                      height: 60,
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
      const scale = 8.0;
      late ({double left, double right}) glyphs;
      late ({double left, double right}) pill;
      await tester.runAsync(() async {
        final image = await renderBoundary.toImage(pixelRatio: scale);
        final rgba = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final rows = _rowSpan(rgba, image.width, image.height, _isGlyph);
        glyphs = _columnSpan(rgba, image.width, scale, _isGlyph, rows);
        // The pill clears the letters by its vertical padding, and the bottom
        // row of the boundary itself carries a tint that a full-height scan
        // would read as a pill running the whole width.
        pill = _columnSpan(rgba, image.width, scale, _isPill, (
          top: rows.top - (5 * scale).round(),
          bottom: rows.bottom + (5 * scale).round(),
        ));
        image.dispose();
      });
      debugDefaultTargetPlatformOverride = null;

      // The pill is the tag's own box plus 3px of horizontal padding either
      // side; anything wider on one side than the other means it has slid off.
      expect(
        glyphs.left - pill.left,
        inInclusiveRange(1.5, 4.5),
        reason:
            'the pill should start about its padding left of the "#". Larger '
            'means it is measuring a paragraph the field did not draw.',
      );
      expect(
        pill.right - glyphs.right,
        inInclusiveRange(1.5, 4.5),
        reason: 'the pill should end about its padding right of the "m".',
      );
    });
  });
}

bool _isGlyph(int r, int g, int b) => r < 110 && g < 110 && b < 110;

/// Anything left that is not the field's near-white background.
bool _isPill(int r, int g, int b) =>
    !_isGlyph(r, g, b) && !(r >= 250 && g >= 240 && b >= 250);

/// First and last row holding a pixel [matches] accepts, in device pixels.
({int top, int bottom}) _rowSpan(
  ByteData rgba,
  int width,
  int height,
  bool Function(int r, int g, int b) matches,
) {
  var top = height;
  var bottom = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      if (!matches(
        rgba.getUint8(i),
        rgba.getUint8(i + 1),
        rgba.getUint8(i + 2),
      )) {
        continue;
      }
      if (y < top) top = y;
      if (y > bottom) bottom = y;
      break;
    }
  }
  return (top: top, bottom: bottom);
}

/// Leftmost and rightmost column holding a pixel [matches] accepts within
/// [rows], in logical pixels.
({double left, double right}) _columnSpan(
  ByteData rgba,
  int width,
  double scale,
  bool Function(int r, int g, int b) matches,
  ({int top, int bottom}) rows,
) {
  var left = width;
  var right = -1;
  for (var y = rows.top; y <= rows.bottom; y++) {
    if (y < 0) continue;
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      if (!matches(
        rgba.getUint8(i),
        rgba.getUint8(i + 1),
        rgba.getUint8(i + 2),
      )) {
        continue;
      }
      if (x < left) left = x;
      if (x > right) right = x;
    }
  }
  return (left: left / scale, right: (right + 1) / scale);
}
