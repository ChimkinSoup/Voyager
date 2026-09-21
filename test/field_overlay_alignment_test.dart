import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';

// The layers over a field are positioned from its content padding, so they
// only land on the glyphs where InputDecorator puts the input where that
// padding says. These are the two ways it didn't.

Widget _harness(Widget field, {double? height}) => ProviderScope(
  overrides: [
    voyagerSpellCheckServiceProvider.overrideWithValue(
      VoyagerSpellCheckService(),
    ),
  ],
  child: MaterialApp(
    // The app's text metrics, at desktop density: that pairing is what put
    // the journal title under Material's 48px minimum.
    theme: VoyagerTheme.light().copyWith(visualDensity: VisualDensity.compact),
    home: VimEnabledScope(
      enabled: true,
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 300, height: height, child: field),
        ),
      ),
    ),
  ),
);

double _top(WidgetTester tester, Finder finder) =>
    tester.renderObject<RenderBox>(finder).localToGlobal(Offset.zero).dy;

Finder get _editable => find.descendant(
  of: find.byType(EditableText),
  matching: find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_Editable',
  ),
);

void main() {
  testWidgets('the journal title keeps its Vim caret on the text', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Hello');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    // As journal_page.dart builds it: the body box's own padding, and
    // nothing outside putting the 48px back.
    await tester.pumpWidget(
      _harness(
        LabeledTextField(
          label: 'Title',
          controller: controller,
          focusNode: focusNode,
          allowShortHeight: true,
          contentPadding: const EdgeInsets.fromLTRB(14, 14, 40, 14),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    // Under Material's minimum, which is the case [allowShortHeight]
    // exists for: left to stretch the box, the decorator re-centres the
    // text off the padding the overlay below is positioned from.
    expect(
      tester.getSize(find.byType(LabeledTextField)).height,
      lessThan(kMinInteractiveDimension),
    );
    final overlay = find.descendant(
      of: find.byType(VimTextOverlay),
      matching: find.byType(CustomPaint),
    );
    expect(overlay, findsOneWidget, reason: 'in Normal mode');
    expect(_top(tester, overlay), _top(tester, _editable));
  });

  testWidgets('a field with no label and no hint keeps its input on the '
      'overlays', (tester) async {
    final controller = TextEditingController(text: 'Hello');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _harness(
        LabeledTextField(
          label: '',
          showLabel: false,
          controller: controller,
          expands: true,
        ),
        height: 200,
      ),
    );

    // Laid out in the overlay padding, like every layer beside it.
    final squiggles = find.byType(SpellCheckSquiggleLayer);
    expect(_top(tester, squiggles), _top(tester, _editable));
  });
}
