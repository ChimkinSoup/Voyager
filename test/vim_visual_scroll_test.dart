import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';

/// Moving a Visual selection's caret up out of view scrolls the field to it,
/// as moving it down does. EditableText scrolls to the selection's extent, so
/// that has to be the end Vim's caret is on.
void main() {
  late TextEditingController controller;
  late FocusNode focusNode;

  Future<void> pump(WidgetTester tester) async {
    controller = TextEditingController(
      text: List.generate(20, (i) => 'line $i').join('\n'),
    );
    focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voyagerSpellCheckServiceProvider.overrideWithValue(
            VoyagerSpellCheckService()..updateDictionary({'line'}),
          ),
        ],
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: SizedBox(
                height: 120,
                child: TagHighlightedTextField(
                  controller: controller,
                  focusNode: focusNode,
                  expands: true,
                  useNotchedBorder: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG, character: 'G');
    await tester.pumpAndSettle();
  }

  /// Whether the line holding [offset] lies within the field's viewport.
  bool lineVisible(WidgetTester tester, int offset) {
    final editable = tester.renderObject<RenderEditable>(
      find.descendant(
        of: find.byType(EditableText),
        matching: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_Editable',
        ),
      ),
    );
    final caret = editable.getLocalRectForCaret(TextPosition(offset: offset));
    return caret.top >= -0.5 && caret.bottom <= editable.size.height + 0.5;
  }

  for (final (name, key, character) in [
    ('v', LogicalKeyboardKey.keyV, 'v'),
    ('V', LogicalKeyboardKey.keyV, 'V'),
  ]) {
    testWidgets('$name then k scrolls up to the caret', (tester) async {
      await pump(tester);
      await tester.sendKeyEvent(key, character: character);
      await tester.pumpAndSettle();
      for (var i = 0; i < 15; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK, character: 'k');
        await tester.pumpAndSettle();
      }
      // Line 4: the caret's line, at the top of the selection.
      expect(lineVisible(tester, controller.text.indexOf('line 4')), isTrue);
    });
  }
}
