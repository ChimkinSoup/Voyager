import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';

/// The overlays Voyager stacks on a field — the squiggle layer, the `#tag`
/// pills, the Vim caret/selection/search layer — only line up while they wrap
/// the text at exactly the width the field wraps it at.
///
/// `RenderEditable` does not wrap at its full content width: it reserves
/// `_kCaretGap + cursorWidth` for the caret and lays the paragraph out in
/// what is left (`_layoutText`, editable.dart). An overlay padded with the
/// field's content padding alone gets those pixels back, so at some widths it
/// fits one more word on a line — and from that line on, every mark it paints
/// is a word out of step with the glyphs underneath.
///
/// The reserved strip is only a few pixels wide, so whether it moves a line
/// break depends on where the next word boundary happens to fall. The tests
/// sweep a range of field widths rather than pick one, so they cover the
/// widths where a break sits inside the strip.
void main() {
  const text = 'test test test test test test test test test test test test ';
  late TextEditingController controller;
  late FocusNode focusNode;

  setUp(() {
    controller = TextEditingController(text: text);
    focusNode = FocusNode();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  Future<void> pumpField(WidgetTester tester, double width) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: SizedBox(
                width: width,
                height: 600,
                // No `style`: the field falls back to `bodyLarge`, which is
                // also what TextField merges its own text style out of
                // (`_m3InputStyle`, text_field.dart). A bare TextStyle here
                // would leave the field with the theme's letterSpacing and the
                // overlays without it, drifting a fraction of a pixel per
                // character for reasons that have nothing to do with wrapping.
                child: TagHighlightedTextField(
                  // Keyed on the width so each step of a sweep gets a fresh
                  // field: without it the widget's State survives the rebuild
                  // and a field left in Normal mode by the previous width is
                  // still in it. Keying the field rather than tearing the
                  // whole tree down keeps the ProviderScope — and the single
                  // database behind it — mounted across the sweep.
                  key: ValueKey(width),
                  controller: controller,
                  focusNode: focusNode,
                  maxLines: null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
  }

  Future<void> enterNormalMode(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
  }

  /// The offsets at which a new line of the wrapped paragraph starts.
  List<int> lineStarts(double Function(int offset) topAt) {
    final starts = <int>[];
    double? previous;
    for (var i = 0; i <= text.length; i++) {
      final top = topAt(i);
      if (previous == null || (top - previous).abs() > 0.5) starts.add(i);
      previous = top;
    }
    return starts;
  }

  List<int> fieldLineStarts(WidgetTester tester) {
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    return lineStarts(
      (i) => editable.getLocalRectForCaret(TextPosition(offset: i)).top,
    );
  }

  List<int> overlayLineStarts(WidgetTester tester) {
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byType(SpellCheckSquiggleLayer),
        matching: find.byType(RichText),
      ),
    );
    return lineStarts(
      (i) => paragraph.getOffsetForCaret(TextPosition(offset: i), Rect.zero).dy,
    );
  }

  /// Wide enough for several wrapped lines, stepped finely enough that some
  /// width in the range puts a word boundary inside the caret strip.
  final widths = [for (var w = 300.0; w <= 440.0; w += 2.0) w];

  testWidgets('overlays wrap where the field wraps, in Insert mode', (
    tester,
  ) async {
    for (final width in widths) {
      await pumpField(tester, width);
      expect(
        overlayLineStarts(tester),
        fieldLineStarts(tester),
        reason: 'field width $width',
      );
    }
  });

  testWidgets('overlays wrap where the field wraps, in Normal mode', (
    tester,
  ) async {
    for (final width in widths) {
      await pumpField(tester, width);
      await enterNormalMode(tester);
      expect(
        overlayLineStarts(tester),
        fieldLineStarts(tester),
        reason: 'field width $width',
      );
    }
  });

  testWidgets('leaving Insert mode does not re-wrap the text', (tester) async {
    for (final width in widths) {
      await pumpField(tester, width);
      final inInsert = fieldLineStarts(tester);
      await enterNormalMode(tester);
      // The Vim block caret is painted by VimTextOverlay, so the field's own
      // caret has no reason to widen — and widening it reflows the paragraph
      // under the user on every Esc.
      expect(fieldLineStarts(tester), inInsert, reason: 'field width $width');
    }
  });

  testWidgets('the Vim overlay paints at the same width as the squiggles', (
    tester,
  ) async {
    await pumpField(tester, 400);
    await enterNormalMode(tester);

    final vimWidth = tester
        .getSize(
          find.descendant(
            of: find.byType(VimTextOverlay),
            matching: find.byType(CustomPaint),
          ),
        )
        .width;
    final squiggleWidth = tester
        .getSize(
          find.descendant(
            of: find.byType(SpellCheckSquiggleLayer),
            matching: find.byType(RichText),
          ),
        )
        .width;
    expect(vimWidth, squiggleWidth);
  });
}
