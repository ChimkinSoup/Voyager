import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';

/// Voyager stacks transparent text layers behind its fields — the misspelling
/// squiggles of `SpellCheckSquiggleLayer`, the `#tag` pills of
/// `_TagHighlightLayer` — and lines them up by giving the overlay a plain
/// [Padding] equal to the field's `contentPadding`. That only holds while
/// InputDecorator lays the real text out at exactly `contentPadding`: under
/// Material 3 it adds an "input gap" of its own for outline-bordered and
/// filled fields, which [withInputGap] exists to mirror.
///
/// These tests pin the gap for each decoration shape in use, so a Flutter
/// change to it surfaces here rather than as a few pixels of drift under the
/// wavy underlines.
const _pad = EdgeInsets.all(8);

/// How far past `contentPadding.left` InputDecorator placed the text.
Future<double> _inputGap(WidgetTester tester, InputDecoration decoration) async {
  final controller = TextEditingController(text: 'tst');
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: TextField(
              controller: controller,
              decoration: decoration.copyWith(contentPadding: _pad),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final editable = tester
      .state<EditableTextState>(find.byType(EditableText))
      .renderEditable;
  final textLeft = editable
      .localToGlobal(
        editable.getLocalRectForCaret(const TextPosition(offset: 0)).topLeft,
      )
      .dx;
  final decoratorLeft = tester.getRect(find.byType(InputDecorator)).left;
  // The caret rect carries a fraction of its own width; the gap is the whole
  // pixels beyond the content padding.
  return (textLeft - decoratorLeft - _pad.left).roundToDouble();
}

void main() {
  testWidgets('an outline border shifts the text by its gapPadding', (
    tester,
  ) async {
    // The dream journal's sticky note, which picks the theme's outline up
    // through InputDecorationTheme.
    expect(
      await _inputGap(
        tester,
        InputDecoration(
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Colors.grey),
          ),
        ),
      ),
      withInputGap(EdgeInsets.zero).left,
    );

    // voyager_text_field.dart pins gapPadding to 0 and so needs no
    // compensation — its overlay pads with contentPadding directly.
    expect(
      await _inputGap(
        tester,
        const InputDecoration(
          filled: false,
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide.none,
            gapPadding: 0,
          ),
        ),
      ),
      0,
    );
  });

  testWidgets('filling a borderless field is enough to shift its text', (
    tester,
  ) async {
    // labeled_text_field.dart and the notched tag_highlighted_text_field:
    // borderless *and* unfilled, the only combination that adds nothing.
    expect(
      await _inputGap(
        tester,
        const InputDecoration(
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
      0,
    );

    // Voyager's theme sets `filled: true` globally, so a field that suppresses
    // every border still picks the gap up unless it opts out of the fill too.
    expect(
      await _inputGap(
        tester,
        const InputDecoration(
          filled: true,
          fillColor: Colors.black12,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
      withInputGap(EdgeInsets.zero).left,
    );
  });

  testWidgets('the notification inbox fields take the gap in both states', (
    tester,
  ) async {
    InputDecoration decorate({required BorderSide focused}) => InputDecoration(
      isDense: true,
      filled: true,
      fillColor: Colors.black12,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: focused,
      ),
    );

    // InputDecorator resolves the gap from the border of the *current* state,
    // so an unfocused field and a focused one have to be checked separately.
    expect(
      await _inputGap(tester, decorate(focused: const BorderSide(width: 1.2))),
      withInputGap(EdgeInsets.zero).left,
    );
    expect(
      await _inputGap(tester, decorate(focused: BorderSide.none)),
      withInputGap(EdgeInsets.zero).left,
    );
  });
}
