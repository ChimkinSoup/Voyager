import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';

void main() {
  test('vimOverlayPadding adds the outline gap and caret strip', () {
    const content = EdgeInsets.fromLTRB(12, 16, 12, 8);
    final padding = vimOverlayPadding(
      contentPadding: content,
      density: VisualDensity.standard,
      cursorWidth: 2.0,
      outlineGap: true,
    );
    // 4px outline inputGap on each side, plus RenderEditable's 1 + cursorWidth
    // reserved on the right.
    expect(padding.left, 16);
    expect(padding.right, 12 + 4 + 1 + 2);
    expect(padding.top, 16);
    expect(padding.bottom, 8);
  });

  test(
    'vimOverlayPadding averages uneven vertical pad for outline-centered fields',
    () {
      // M3 dense outlined default is 16 top / 8 bottom. Compact density takes
      // 4px off each side, then centering must split the remainder evenly or
      // the block caret sits 4px below the glyph.
      const content = kM3OutlinedDenseContentPadding;
      final padding = vimOverlayPadding(
        contentPadding: content,
        density: VisualDensity.compact,
        cursorWidth: 2.0,
        outlineGap: true,
        outlineCenter: true,
      );
      expect(padding.top, padding.bottom);
      expect(padding.top, 8.0);
    },
  );

  testWidgets(
    'raw VimTextScope field stacks VimTextOverlay and hides the native caret',
    (tester) async {
      final controller = TextEditingController(text: 'hello');
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: VimTextScope(
                enabled: true,
                controller: controller,
                multiline: false,
                builder: (context, vim) {
                  const padding = EdgeInsets.all(8);
                  final theme = Theme.of(context);
                  final style = theme.textTheme.bodyLarge ?? const TextStyle();
                  return VimOverlayHost(
                    session: vim.session,
                    overlayPaintsSelection: vim.overlayPaintsSelection,
                    controller: controller,
                    focusNode: focusNode,
                    style: style,
                    accentColor: theme.colorScheme.primary,
                    overlayPadding: vimOverlayPadding(
                      contentPadding: padding,
                      density: theme.visualDensity,
                      cursorWidth: vim.overlayCaretWidth,
                    ),
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      style: style,
                      cursorColor: vim.overlayCaretColor(
                        theme.colorScheme.primary,
                      ),
                      cursorWidth: vim.overlayCaretWidth,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: padding,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.byType(VimTextOverlay), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('NORMAL'), findsOneWidget);

      final field = tester.widget<TextField>(find.byType(TextField));
      // The overlay draws the block; the field's own caret must stay the
      // ordinary 2px strip and be invisible, or Esc would re-wrap the text
      // and the OS caret would show through as a highlight.
      expect(field.cursorWidth, 2.0);
      expect(field.cursorColor, Colors.transparent);
    },
  );

  testWidgets('outlined dense field: overlay top matches EditableText top', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'hello');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.dark(),
        home: VimEnabledScope(
          enabled: true,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: VimTextScope(
                  enabled: true,
                  controller: controller,
                  multiline: false,
                  builder: (context, vim) {
                    final theme = Theme.of(context);
                    final style =
                        theme.textTheme.bodyLarge ?? const TextStyle();
                    return VimOverlayHost(
                      session: vim.session,
                      overlayPaintsSelection: vim.overlayPaintsSelection,
                      controller: controller,
                      focusNode: focusNode,
                      style: style,
                      accentColor: theme.colorScheme.primary,
                      overlayPadding: vimOverlayPadding(
                        contentPadding: kM3OutlinedDenseContentPadding,
                        density: theme.visualDensity,
                        cursorWidth: vim.overlayCaretWidth,
                        outlineGap: true,
                        outlineCenter: true,
                      ),
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        style: style,
                        cursorColor: vim.overlayCaretColor(
                          theme.colorScheme.primary,
                        ),
                        cursorWidth: vim.overlayCaretWidth,
                        decoration: const InputDecoration(
                          hintText: 'Add something…',
                          isDense: true,
                          contentPadding: kM3OutlinedDenseContentPadding,
                        ),
                      ),
                    );
                  },
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
    await tester.pump();

    final editableTop = tester.getTopLeft(find.byType(EditableText)).dy;
    final overlayTop = tester.getTopLeft(find.byType(VimTextOverlay)).dy;
    expect(
      overlayTop,
      moreOrLessEquals(editableTop, epsilon: 0.5),
      reason:
          'block caret was painting below the glyph on outlined dense fields',
    );
  });

  testWidgets('linewise Visual then Esc then i keeps the input connection', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'hello');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: VimEnabledScope(
          enabled: true,
          child: Scaffold(
            body: VimTextScope(
              enabled: true,
              controller: controller,
              multiline: false,
              builder: (context, vim) {
                const padding = EdgeInsets.all(8);
                final theme = Theme.of(context);
                final style = theme.textTheme.bodyLarge ?? const TextStyle();
                return VimOverlayHost(
                  session: vim.session,
                  overlayPaintsSelection: vim.overlayPaintsSelection,
                  controller: controller,
                  focusNode: focusNode,
                  style: style,
                  accentColor: theme.colorScheme.primary,
                  overlayPadding: vimOverlayPadding(
                    contentPadding: padding,
                    density: theme.visualDensity,
                    cursorWidth: vim.overlayCaretWidth,
                  ),
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    style: style,
                    cursorColor: vim.overlayCaretColor(
                      theme.colorScheme.primary,
                    ),
                    cursorWidth: vim.overlayCaretWidth,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: padding,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final editorState = tester.state<EditableTextState>(
      find.byType(EditableText),
    );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV, character: 'V');
      await tester.pump();
      expect(find.text('V-LINE'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();
    expect(
      tester.state<EditableTextState>(find.byType(EditableText)),
      same(editorState),
    );

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'xhello',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    expect(controller.text, 'xhello');
  });
}
