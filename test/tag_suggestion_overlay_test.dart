import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';

void main() {
  late TextEditingController controller;
  late FocusNode focusNode;
  late VoyagerSpellCheckService spellCheckService;

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
    spellCheckService = VoyagerSpellCheckService();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  /// A single-line tag field wired to a fixed journal pool. Single-line keeps
  /// spellcheck (and its provider-backed service) out of the picture — this is
  /// a test about completion, not squiggles.
  Future<void> pumpField(
    WidgetTester tester, {
    List<String> pool = const ['AA', 'BB', 'CC'],
    FocusOnKeyEventCallback? onKeyEvent,
    ValueChanged<String>? onChanged,
    bool multiline = false,
    double railWidth = 0,
    bool vim = false,
  }) async {
    final field = SizedBox(
      width: 400,
      height: multiline ? 300 : null,
      child: TagHighlightedTextField(
        controller: controller,
        focusNode: focusNode,
        tagScope: TagScope.journal,
        onKeyEvent: onKeyEvent,
        onChanged: onChanged,
        expands: multiline,
        maxLines: multiline ? null : 1,
      ),
    );

    // railWidth > 0 reproduces the app shell: a fixed rail on the left, and
    // the page in its own Navigator (go_router gives each branch one) — so the
    // enclosing Overlay, which is what the popup is positioned against, starts
    // railWidth from the left edge of the screen rather than at 0.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tagPoolProvider(TagScope.journal).overrideWith((ref) => pool),
          tagColorsProvider.overrideWith((ref) => <String, int>{}),
          voyagerSpellCheckServiceProvider.overrideWithValue(
            spellCheckService,
          ),
        ],
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: vim,
            child: Scaffold(
              body: railWidth == 0
                  ? Center(child: field)
                  : Row(
                      children: [
                        SizedBox(width: railWidth),
                        Expanded(
                          child: Navigator(
                            onGenerateRoute: (_) => MaterialPageRoute<void>(
                              builder: (_) => Center(child: field),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder suggestion(String tag) => find.text('#$tag');

  /// The suggestion rows only — the field's own text lives in an EditableText,
  /// so a bare `find.text` would also match what the user typed.
  List<String> visibleSuggestions(WidgetTester tester) {
    return tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(OverlayPortal),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data ?? '')
        .where((s) => s.startsWith('#'))
        .toList();
  }

  testWidgets('typing # offers the whole pool in usage order', (tester) async {
    await pumpField(tester);

    await tester.enterText(find.byType(TextField), '#');
    await tester.pumpAndSettle();

    expect(visibleSuggestions(tester), ['#AA', '#BB', '#CC']);
  });

  testWidgets('typing #C narrows to the matching tag', (tester) async {
    await pumpField(tester);

    await tester.enterText(find.byType(TextField), '#C');
    await tester.pumpAndSettle();

    expect(visibleSuggestions(tester), ['#CC']);
  });

  testWidgets('no popup for a query nothing matches', (tester) async {
    await pumpField(tester);

    await tester.enterText(find.byType(TextField), '#zz');
    await tester.pumpAndSettle();

    expect(visibleSuggestions(tester), isEmpty);
  });

  testWidgets('no popup before a # is typed', (tester) async {
    await pumpField(tester);

    await tester.enterText(find.byType(TextField), 'plain words');
    await tester.pumpAndSettle();

    expect(visibleSuggestions(tester), isEmpty);
  });

  testWidgets('Enter accepts the highlighted suggestion', (tester) async {
    await pumpField(tester);

    await tester.enterText(find.byType(TextField), 'today #C');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, 'today #CC');
    expect(controller.selection.baseOffset, 9);
    expect(visibleSuggestions(tester), isEmpty);
  });

  testWidgets('arrow keys move the highlight before Enter accepts',
      (tester) async {
    await pumpField(tester);

    await tester.enterText(find.byType(TextField), '#');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, '#BB');
  });

  testWidgets('tapping a suggestion accepts it', (tester) async {
    await pumpField(tester);

    await tester.enterText(find.byType(TextField), '#');
    await tester.pumpAndSettle();
    await tester.tap(suggestion('CC'));
    await tester.pumpAndSettle();

    expect(controller.text, '#CC');
  });

  testWidgets('accepting replaces the whole tag from mid-token',
      (tester) async {
    await pumpField(tester, pool: const ['alpha']);

    await tester.enterText(find.byType(TextField), '#alx tail');
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, '#alpha tail');
  });

  testWidgets('Escape closes the popup and leaves the text alone',
      (tester) async {
    await pumpField(tester);

    await tester.enterText(find.byType(TextField), '#C');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(visibleSuggestions(tester), isEmpty);
    expect(controller.text, '#C');
  });

  testWidgets('Escape stays dismissed for the same tag but not the next one',
      (tester) async {
    await pumpField(tester);

    await tester.enterText(find.byType(TextField), '#C');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Still the same token: stays closed.
    await tester.enterText(find.byType(TextField), '#CC');
    await tester.pumpAndSettle();
    expect(visibleSuggestions(tester), isEmpty);

    // A new token elsewhere in the text: opens again.
    await tester.enterText(find.byType(TextField), '#CC and #A');
    await tester.pumpAndSettle();
    expect(visibleSuggestions(tester), ['#AA']);
  });

  testWidgets('accepting reports the edit through onChanged', (tester) async {
    // The journal and dream bodies hang autosave and the CRDT edit session off
    // onChanged, so a completion that skipped it would be silently lost from
    // both.
    final changes = <String>[];
    await pumpField(tester, onChanged: changes.add);

    await tester.enterText(find.byType(TextField), '#C');
    changes.clear();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(changes, ['#CC']);
  });

  testWidgets('works in a multiline body with spellcheck on', (tester) async {
    // The configuration the journal and dream editors actually use: expanding,
    // unbounded lines, squiggle layer stacked over the tag highlighter.
    await pumpField(tester, multiline: true);

    await tester.enterText(find.byType(TextField), 'line one\nline two #C');
    await tester.pumpAndSettle();
    expect(visibleSuggestions(tester), ['#CC']);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.text, 'line one\nline two #CC');
  });

  group('placement', () {
    /// How far the popup's left edge sits from the `#` that opened it. The
    /// token starts at offset 0 here, so the caret is at the EditableText's
    /// own left edge.
    double horizontalDriftFromCaret(WidgetTester tester) {
      final popup = tester.getTopLeft(find.byType(ContextualPopover)).dx;
      final textStart = tester.getTopLeft(find.byType(EditableText)).dx;
      return popup - textStart;
    }

    testWidgets('opens at the caret', (tester) async {
      await pumpField(tester);

      await tester.enterText(find.byType(TextField), '#');
      await tester.pumpAndSettle();

      expect(horizontalDriftFromCaret(tester), closeTo(0, 2));
    });

    testWidgets('opens at the caret inside a nested navigator', (tester) async {
      // Regression: the popup was Positioned in global screen coordinates,
      // but Positioned measures against the enclosing Overlay — so under the
      // shell's per-branch Navigator it landed a full navigation rail to the
      // right of the # that opened it.
      await pumpField(tester, railWidth: 200);

      await tester.enterText(find.byType(TextField), '#');
      await tester.pumpAndSettle();

      expect(horizontalDriftFromCaret(tester), closeTo(0, 2));
    });

    testWidgets('flips above the line when it would run off the bottom',
        (tester) async {
      await pumpField(tester, multiline: true);

      // Put the token on the last visible line of a tall field.
      await tester.enterText(find.byType(TextField), '${'\n' * 40}#');
      await tester.pumpAndSettle();

      final popupBottom = tester.getBottomLeft(find.byType(ContextualPopover)).dy;
      final screenHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(popupBottom, lessThanOrEqualTo(screenHeight));
    });
  });

  testWidgets('an empty pool never opens the popup', (tester) async {
    await pumpField(tester, pool: const []);

    await tester.enterText(find.byType(TextField), '#');
    await tester.pumpAndSettle();

    expect(visibleSuggestions(tester), isEmpty);
  });

  group('vim mode', () {
    testWidgets('a Normal-mode motion onto a tag opens nothing',
        (tester) async {
      // Completion is Insert-mode only, as it is in Vim: `l` onto a tag is
      // navigation, not a request to complete it. The popup would also claim
      // Escape and Enter, which Normal mode needs for itself.
      await pumpField(tester, vim: true);

      // Caret lands past the tag, so nothing is open to dismiss and the first
      // Escape goes straight to the Vim layer.
      await tester.enterText(find.byType(TextField), '#CC and more');
      await tester.pumpAndSettle();
      expect(visibleSuggestions(tester), isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // 0ll parks the caret inside '#CC'.
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pumpAndSettle();

      expect(controller.selection.baseOffset, 2);
      expect(visibleSuggestions(tester), isEmpty);
    });

    testWidgets('the same caret position still opens it without vim',
        (tester) async {
      // Control for the test above: proves the caret really does sit on a
      // completable token there, and that the mode is what suppresses it.
      await pumpField(tester);
      await tester.enterText(find.byType(TextField), '#CC and more');
      controller.selection = const TextSelection.collapsed(offset: 2);
      await tester.pumpAndSettle();

      expect(visibleSuggestions(tester), ['#CC']);
    });

    testWidgets('one Escape dismisses the popup and leaves Insert',
        (tester) async {
      // Vim gives both effects to a single <Esc>. The popup sees the key
      // first, so it has to close *and* pass the press up.
      await pumpField(tester, vim: true);
      await tester.enterText(find.byType(TextField), '#C');
      await tester.pumpAndSettle();
      expect(visibleSuggestions(tester), ['#CC']);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(visibleSuggestions(tester), isEmpty);

      // Already in Normal after that one press: 'x' is a command, not a
      // character.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pumpAndSettle();
      expect(controller.text, '#');
    });

    testWidgets('without vim, Escape stops at the popup', (tester) async {
      // Control for the test above, and a regression guard: bubbling Escape
      // unconditionally would close the dialog a field sits in as a side
      // effect of dismissing a completion list.
      final seen = <LogicalKeyboardKey>[];
      await pumpField(
        tester,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) seen.add(event.logicalKey);
          return KeyEventResult.ignored;
        },
      );

      await tester.enterText(find.byType(TextField), '#C');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(visibleSuggestions(tester), isEmpty);
      expect(seen, isNot(contains(LogicalKeyboardKey.escape)));
    });

    testWidgets('returning to Insert brings completion back', (tester) async {
      await pumpField(tester, vim: true);
      await tester.enterText(find.byType(TextField), 'note ');
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      // i: back to Insert.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'note #A');
      await tester.pumpAndSettle();

      expect(visibleSuggestions(tester), ['#AA']);
    });
  });

  group('caller key handler', () {
    testWidgets('runs for keys the popup does not claim', (tester) async {
      final seen = <LogicalKeyboardKey>[];
      await pumpField(
        tester,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) seen.add(event.logicalKey);
          return KeyEventResult.ignored;
        },
      );

      await tester.enterText(find.byType(TextField), '#');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pumpAndSettle();

      expect(seen, contains(LogicalKeyboardKey.keyX));
    });

    testWidgets('does not see Enter while the popup is open', (tester) async {
      var enterCount = 0;
      await pumpField(
        tester,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.enter) {
            enterCount++;
          }
          return KeyEventResult.ignored;
        },
      );

      await tester.enterText(find.byType(TextField), '#C');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(controller.text, '#CC');
      expect(enterCount, 0);

      // Popup closed — the caller gets its Enter back.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(enterCount, 1);
    });
  });
}
