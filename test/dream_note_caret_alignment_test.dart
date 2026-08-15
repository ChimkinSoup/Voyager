import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/features/dream_journal/dream_sticky_note.dart';

/// Paragraph origin of the one [RenderEditable] under [root].
Offset _editableOrigin(RenderObject root) {
  RenderEditable? found;
  void walk(RenderObject node) {
    if (node is RenderEditable) found ??= node;
    node.visitChildren(walk);
  }

  walk(root);
  return found!.localToGlobal(Offset.zero);
}

void main() {
  testWidgets(
    'sticky-note Vim overlay lines up with the field it paints over',
    (tester) async {
      // The note's text is `bodySmall`; the theme's placeholder slot is the
      // taller `bodyMedium`. InputDecorator baseline-aligns the input to
      // whichever of the two sits lower, so a field that lets the theme style
      // its hint has its real glyphs pushed a couple of pixels below where
      // this overlay — which derives its own padding from the content padding
      // — paints the block caret and the repainted glyph on it.
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = TextEditingController(text: 'Hey jumpy Wolf today');
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dictionaryProvider.overrideWith((_) async => <String>{}),
            customWordsProvider.overrideWith((_) async => <String>{}),
          ],
          child: MaterialApp(
            theme: VoyagerTheme.dark(),
            home: VimEnabledScope(
              enabled: true,
              child: Scaffold(
                body: Stack(
                  children: [
                    DreamStickyNote(
                      controller: controller,
                      onChanged: (_) {},
                      focusNode: focusNode,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Expand the note, focus the field, then Esc into Normal mode.
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(VimTextOverlay), findsOneWidget);
      final editable = _editableOrigin(
        tester.renderObject(find.byType(EditableText)),
      );
      final overlay = tester.getTopLeft(find.byType(VimTextOverlay));

      expect(
        overlay.dy,
        closeTo(editable.dy, 0.5),
        reason:
            'overlay paints above the real glyphs — the character under the '
            'block caret would look shifted up',
      );
      expect(overlay.dx, closeTo(editable.dx, 0.5));
    },
  );
}
