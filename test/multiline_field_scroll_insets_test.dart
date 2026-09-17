import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';

// MULTILINE_FIELD_SCROLL_INSETS.md: a multi-line field's text scrolls through
// its vertical padding rather than stopping at a viewport inset from the
// border, the caret keeps the same inset from the top and bottom borders, and
// nothing it or its overlays paint gets past the border.

const _fieldHeight = 200.0;
const _fieldWidth = 300.0;
const _text = Color(0xFFFF0000);
const _selection = Color(0xFF0000FF);
const _accent = Color(0xFF00FF00);

final _longText = List.generate(40, (i) => 'line $i').join('\n');

final _fieldKey = GlobalKey();

Widget _harness({
  required Widget field,
  required GlobalKey boundaryKey,
  VisualDensity density = VisualDensity.compact,
  bool vim = false,
}) {
  return ProviderScope(
    overrides: [
      voyagerSpellCheckServiceProvider.overrideWithValue(
        VoyagerSpellCheckService()..updateDictionary({'line'}),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        visualDensity: density,
        textSelectionTheme: const TextSelectionThemeData(
          selectionColor: _selection,
        ),
      ),
      home: VimEnabledScope(
        enabled: vim,
        child: Scaffold(
          backgroundColor: Colors.white,
          body: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: boundaryKey,
              child: Padding(
                // Room on every side, so paint that escapes the field has
                // somewhere to land.
                padding: const EdgeInsets.all(40),
                child: SizedBox(
                  key: _fieldKey,
                  width: _fieldWidth,
                  height: _fieldHeight,
                  child: field,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

RenderEditable _editable(WidgetTester tester) => tester.renderObject(
  find.descendant(
    of: find.byType(EditableText),
    matching: find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_Editable',
    ),
  ),
);

ScrollPosition _position(WidgetTester tester) => tester
    .state<EditableTextState>(find.byType(EditableText))
    .widget
    .scrollController!
    .position;

/// The boundary's last frame as RGBA, read from its retained layer.
Future<(ByteData, int)> _pixels(WidgetTester tester, GlobalKey key) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderBox;
  final result = await tester.runAsync(() async {
    final image = await (boundary.debugLayer! as OffsetLayer).toImage(
      Offset.zero & boundary.size,
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return (bytes!, image.width);
  });
  return result!;
}

/// Whether any pixel in [rect] (boundary coordinates) is exactly [color].
bool _any((ByteData, int) pixels, Rect rect, Color color) {
  final (bytes, width) = pixels;
  final r = (color.r * 255).round();
  final g = (color.g * 255).round();
  final b = (color.b * 255).round();
  for (var y = rect.top.toInt(); y < rect.bottom.toInt(); y++) {
    for (var x = rect.left.toInt(); x < rect.right.toInt(); x++) {
      final i = (y * width + x) * 4;
      if (bytes.getUint8(i) == r &&
          bytes.getUint8(i + 1) == g &&
          bytes.getUint8(i + 2) == b) {
        return true;
      }
    }
  }
  return false;
}

/// The field's box in boundary coordinates.
const _field = Rect.fromLTWH(40, 40, _fieldWidth, _fieldHeight);

void main() {
  group('an expanding field', () {
    final fields = <String, Widget Function(TextEditingController, FocusNode)>{
      'TagHighlightedTextField': (c, f) =>
          TagHighlightedTextField(controller: c, focusNode: f, expands: true),
      'the journal body': (c, f) => TagHighlightedTextField(
        controller: c,
        focusNode: f,
        expands: true,
        hintText: 'Start writing...',
        decoration: const InputDecoration(
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
      'LabeledTextField': (c, f) => LabeledTextField(
        label: '',
        showLabel: false,
        controller: c,
        focusNode: f,
        expands: true,
      ),
    };
    for (final MapEntry(key: name, value: build) in fields.entries) {
      for (final density in [VisualDensity.compact, VisualDensity.standard]) {
        testWidgets(
          '$name insets its viewport equally from the top and bottom borders '
          '(density ${density.vertical})',
          (tester) async {
            final controller = TextEditingController(text: _longText);
            final focusNode = FocusNode();
            addTearDown(controller.dispose);
            addTearDown(focusNode.dispose);
            final boundaryKey = GlobalKey();

            await tester.pumpWidget(
              _harness(
                field: build(controller, focusNode),
                boundaryKey: boundaryKey,
                density: density,
              ),
            );
            final editable = _editable(tester);
            final fieldBox =
                _fieldKey.currentContext!.findRenderObject()! as RenderBox;
            final top = fieldBox
                .globalToLocal(editable.localToGlobal(Offset.zero))
                .dy;
            expect(top, greaterThan(0), reason: 'the at-rest indent');
            expect(
              _fieldHeight - (top + editable.size.height),
              moreOrLessEquals(top, epsilon: 0),
              reason:
                  'the caret is revealed inside the viewport, so a caret '
                  'moved past the bottom edge keeps the room it keeps at the '
                  'top',
            );
            expect(editable.clipBehavior, Clip.none);
          },
        );
      }
    }
  });

  testWidgets(
    'a caret moved past either edge mid-document stops as far from each border',
    (tester) async {
      final controller = TextEditingController(text: _longText);
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      final boundaryKey = GlobalKey();

      await tester.pumpWidget(
        _harness(
          boundaryKey: boundaryKey,
          field: TagHighlightedTextField(
            controller: controller,
            focusNode: focusNode,
            expands: true,
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final editable = _editable(tester);
      final fieldBox =
          _fieldKey.currentContext!.findRenderObject()! as RenderBox;

      /// The caret's line, in field coordinates, once it has been revealed.
      Future<Rect> revealLine(int line) async {
        final offset = controller.text.indexOf('line $line\n');
        controller.selection = TextSelection.collapsed(offset: offset);
        await tester.pump();
        await tester.pump();
        final caret = editable.getLocalRectForCaret(
          TextPosition(offset: offset),
        );
        final lineRect = Rect.fromCenter(
          center: caret.center,
          width: caret.width,
          height: editable.preferredLineHeight,
        );
        return lineRect.shift(
          fieldBox.globalToLocal(editable.localToGlobal(Offset.zero)),
        );
      }

      _position(tester).jumpTo(_position(tester).maxScrollExtent / 2);
      await tester.pump();
      final start = (_position(tester).pixels / editable.preferredLineHeight)
          .floor();
      final visibleLines = (editable.size.height / editable.preferredLineHeight)
          .floor();

      final below = await revealLine(start + visibleLines + 3);
      final bottomGap = _fieldHeight - below.bottom;
      final above = await revealLine(start - 3);
      final topGap = above.top;

      expect(topGap, greaterThan(4));
      expect(bottomGap, moreOrLessEquals(topGap, epsilon: 2));
    },
  );

  testWidgets('scrolled text and its overlays paint through the top padding', (
    tester,
  ) async {
    final controller = TextEditingController(text: _longText);
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      _harness(
        boundaryKey: boundaryKey,
        field: TagHighlightedTextField(
          controller: controller,
          focusNode: focusNode,
          expands: true,
          style: const TextStyle(fontSize: 16, height: 1.5, color: _text),
          highlightDebounce: Duration.zero,
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    await tester.pump();
    // Half a line: the first line straddles the 12px top padding.
    _position(tester).jumpTo(12);
    await tester.pump();

    final pixels = await _pixels(tester, boundaryKey);
    // Clear of the border stroke along the top edge.
    final strip = Rect.fromLTRB(
      _field.left + 16,
      _field.top + 3,
      _field.left + 120,
      _field.top + 11,
    );
    expect(_any(pixels, strip, _text), isTrue, reason: 'text');
    expect(_any(pixels, strip, _selection), isTrue, reason: 'selection');
    // And none of it above the field.
    final above = Rect.fromLTRB(0, 0, _field.right + 40, _field.top);
    expect(_any(pixels, above, _text), isFalse);
    expect(_any(pixels, above, _selection), isFalse);
  });

  for (final vim in [false, true]) {
    testWidgets(
      'the ${vim ? 'Vim block' : 'insert'} caret on the last line stays '
      'inside the bottom border',
      (tester) async {
        final controller = TextEditingController(text: _longText);
        final focusNode = FocusNode();
        addTearDown(controller.dispose);
        addTearDown(focusNode.dispose);
        final boundaryKey = GlobalKey();

        await tester.pumpWidget(
          _harness(
            boundaryKey: boundaryKey,
            vim: vim,
            field: TagHighlightedTextField(
              controller: controller,
              focusNode: focusNode,
              expands: true,
              accentColor: _accent,
              // Tall enough that a caret on the last line would reach the
              // border by itself.
              style: const TextStyle(fontSize: 16, height: 2.5),
            ),
          ),
        );
        await tester.tap(find.byType(TextField));
        await tester.pump();
        if (vim) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.keyG, character: 'G');
        } else {
          controller.selection = TextSelection.collapsed(
            offset: controller.text.length,
          );
        }
        await tester.pump();
        await tester.pump();
        final position = _position(tester);
        expect(position.pixels, position.maxScrollExtent);
        // The last line's box, less the viewport: whatever of the caret runs
        // past the field's bottom edge is what the clip has to catch.
        _position(tester).jumpTo(position.maxScrollExtent);
        await tester.pump();

        final pixels = await _pixels(tester, boundaryKey);
        final lastLine = Rect.fromLTRB(
          _field.left,
          _field.bottom - 40,
          _field.right,
          _field.bottom,
        );
        final below = Rect.fromLTRB(
          0,
          _field.bottom,
          _field.right + 40,
          _field.bottom + 40,
        );
        expect(
          _any(pixels, lastLine, _accent),
          isTrue,
          reason: 'the caret is on the last line',
        );
        expect(_any(pixels, below, _accent), isFalse);
      },
    );
  }
}
