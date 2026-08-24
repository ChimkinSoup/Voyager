import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/snippets/snippet_enabled_scope.dart';
import 'package:voyager/core/snippets/snippet_index.dart';
import 'package:voyager/core/snippets/snippet_session.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/domain/models/snippet.dart';

/// The key that types [ch], for the letters and digits these tests use.
LogicalKeyboardKey _keyFor(String ch) {
  return LogicalKeyboardKey.knownLogicalKeys.firstWhere(
    (k) => k.keyLabel.toLowerCase() == ch.toLowerCase(),
    orElse: () => throw ArgumentError('No key for "$ch"'),
  );
}

/// The [EditableTextState] of the field under test.
///
/// Scoped to the [LabeledTextField]: some cases put a plain [TextField] beside
/// it purely as somewhere for focus traversal to land.
/// The tabstop marks the field's overlay is currently painting.
///
/// Read off the widget the session is handed to, rather than the session
/// itself, because that is the value the marks are actually drawn from.
SnippetMarks _marks(WidgetTester tester) => tester
    .widget<VimTextOverlay>(
      find.descendant(
        of: find.byType(LabeledTextField),
        matching: find.byType(VimTextOverlay),
      ),
    )
    .snippetSession!
    .marksListenable
    .value;

EditableTextState _fieldState(WidgetTester tester) =>
    tester.state<EditableTextState>(
      find.descendant(
        of: find.byType(LabeledTextField),
        matching: find.byType(EditableText),
      ),
    );

/// Exercises the real widget path: a focused field, keys delivered through
/// [WidgetTester.sendKeyEvent] so `VimTextScope`'s ancestor [Focus] has to
/// claim them, and text arriving the way the platform delivers it.
void main() {
  late TextEditingController controller;
  late FocusNode focusNode;
  final List<String> changes = [];

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
    changes.clear();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  Snippet snippet(
    String trigger,
    String replacement, {
    bool auto = true,
    bool word = false,
  }) => Snippet(
    id: trigger,
    trigger: trigger,
    replacement: replacement,
    autoExpand: auto,
    wordBoundary: word,
  );

  Future<void> pumpField(
    WidgetTester tester, {
    required List<Snippet> snippets,
    bool enabled = true,
    bool vimEnabled = false,
    bool snippetsAllowed = true,
    SnippetExpandKey expandKey = SnippetExpandKey.tab,
    String text = '',
    Widget Function(Widget field)? wrap,
    bool preserveValue = false,
  }) async {
    if (!preserveValue) {
      controller.text = text;
      controller.selection = TextSelection.collapsed(offset: text.length);
    }
    final field = LabeledTextField(
      label: 'Body',
      controller: controller,
      focusNode: focusNode,
      snippetsAllowed: snippetsAllowed,
      onChanged: changes.add,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: vimEnabled,
            child: SnippetEnabledScope(
              data: SnippetScopeData(
                enabled: enabled,
                expandKey: expandKey,
                index: SnippetIndex.from(snippets),
              ),
              child: Scaffold(body: wrap == null ? field : wrap(field)),
            ),
          ),
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pump();
  }

  /// Types [input] the way the platform does: for each character, the key
  /// event first — which the embedder dispatches before handing the character
  /// to the text input plugin — then the committed editing value.
  ///
  /// Expansion is queued on a microtask, so every keystroke is pumped; that is
  /// also what proves the bare trigger never survives to a frame.
  Future<void> type(WidgetTester tester, String input) async {
    final state = _fieldState(tester);
    for (final ch in input.split('')) {
      await tester.sendKeyEvent(_keyFor(ch));
      final value = controller.value;
      final caret = value.selection.baseOffset;
      state.updateEditingValue(
        TextEditingValue(
          text: value.text.replaceRange(caret, caret, ch),
          selection: TextSelection.collapsed(offset: caret + 1),
        ),
      );
      await tester.pump();
    }
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  group('auto expansion', () {
    testWidgets('typing the last trigger character expands', (tester) async {
      await pumpField(tester, snippets: [snippet('ee', 'expanded')]);
      await type(tester, 'ee');
      expect(controller.text, 'expanded');
      expect(controller.selection.baseOffset, 'expanded'.length);
    });

    testWidgets('the caret lands on the lowest tabstop', (tester) async {
      await pumpField(tester, snippets: [snippet('ee', r'($0)$1')]);
      await type(tester, 'ee');
      expect(controller.text, '()');
      expect(controller.selection.baseOffset, 1);
    });

    testWidgets('expands mid-sentence, leaving the rest alone', (tester) async {
      await pumpField(tester, snippets: [snippet('ee', 'X')], text: 'say  now');
      controller.selection = const TextSelection.collapsed(offset: 4);
      await tester.pump();
      await type(tester, 'ee');
      expect(controller.text, 'say X now');
    });

    testWidgets('fires onChanged so autosave sees the expansion', (
      tester,
    ) async {
      await pumpField(tester, snippets: [snippet('ee', 'expanded')]);
      await type(tester, 'ee');
      expect(changes.last, 'expanded');
    });

    testWidgets('a word-boundary trigger will not fire mid-word', (
      tester,
    ) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', 'X', word: true)],
        text: 'fr',
      );
      await type(tester, 'ee');
      expect(controller.text, 'free');
    });

    testWidgets('a word-boundary trigger fires after a delimiter', (
      tester,
    ) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', 'X', word: true)],
        text: 'go ',
      );
      await type(tester, 'ee');
      expect(controller.text, 'go X');
    });

    testWidgets('a word-boundary trigger will not fire before a word character', (
      tester,
    ) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', 'X', word: true)],
        text: 'X',
      );
      // Caret before the existing letter; typing the trigger leaves a word
      // character after the match, so `w` must not expand.
      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      await type(tester, 'ee');
      expect(controller.text, 'eeX');
    });

    testWidgets('a replacement longer than its trigger does not re-expand', (
      tester,
    ) async {
      // `e` → `ee` would match itself forever without the re-entrancy guard.
      await pumpField(tester, snippets: [snippet('e', 'ee')]);
      await type(tester, 'e');
      expect(controller.text, 'ee');
    });

    testWidgets('nothing expands while the master switch is off', (
      tester,
    ) async {
      await pumpField(tester, snippets: [snippet('ee', 'X')], enabled: false);
      await type(tester, 'ee');
      expect(controller.text, 'ee');
    });

    testWidgets('nothing expands in a field that opted out', (tester) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', 'X')],
        snippetsAllowed: false,
      );
      await type(tester, 'ee');
      expect(controller.text, 'ee');
    });
  });

  group('what must not expand', () {
    testWidgets('a paste ending in a trigger', (tester) async {
      await pumpField(tester, snippets: [snippet('ee', 'X')]);
      final state = _fieldState(tester);
      state.updateEditingValue(
        const TextEditingValue(
          text: 'see',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      expect(controller.text, 'see');
    });

    testWidgets('a delete that joins characters into a trigger', (
      tester,
    ) async {
      await pumpField(tester, snippets: [snippet('ee', 'X')], text: 'e e');
      controller.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      final state = _fieldState(tester);
      // Backspace over the space: "e e" → "ee", caret at the end.
      state.updateEditingValue(
        const TextEditingValue(
          text: 'ee',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      expect(controller.text, 'ee');
    });

    testWidgets('text still being composed by an IME', (tester) async {
      await pumpField(tester, snippets: [snippet('ee', 'X')], text: 'e');
      final state = _fieldState(tester);
      state.updateEditingValue(
        const TextEditingValue(
          text: 'ee',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      expect(controller.text, 'ee');
    });
  });

  // On a desktop there is no soft keyboard, so every typed character is
  // preceded by a key event and a write that arrives without one cannot have
  // been typed. The rest of this file runs under the test binding's default
  // (android), which is the soft-keyboard path where the diff stands alone.
  group('desktop: a key event is required', () {
    // Cleared inside the body rather than from tearDown: the binding asserts
    // no foundation debug variable is still set when the test body returns,
    // and that check runs before tearDown does.
    Future<void> onDesktop(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('typing still expands', (tester) async {
      await onDesktop(() async {
        await pumpField(tester, snippets: [snippet('ee', 'X')]);
        await type(tester, 'ee');
        expect(controller.text, 'X');
      });
    });

    testWidgets('a programmatic controller write does not', (tester) async {
      await onDesktop(() async {
        await pumpField(tester, snippets: [snippet('ee', 'X')], text: 'e');
        controller.value = const TextEditingValue(
          text: 'ee',
          selection: TextSelection.collapsed(offset: 2),
        );
        await tester.pump();
        expect(controller.text, 'ee');
      });
    });

    testWidgets('nor does a write through the field itself', (tester) async {
      await onDesktop(() async {
        // What a redo or a sync pull looks like: the same one-character insert
        // at the caret, with no key to account for it.
        await pumpField(tester, snippets: [snippet('ee', 'X')], text: 'e');
        _fieldState(tester).userUpdateTextEditingValue(
          const TextEditingValue(
            text: 'ee',
            selection: TextSelection.collapsed(offset: 2),
          ),
          SelectionChangedCause.keyboard,
        );
        await tester.pump();
        expect(controller.text, 'ee');
      });
    });

    testWidgets('an IME commit expands without a key event', (tester) async {
      await onDesktop(() async {
        await pumpField(tester, snippets: [snippet('ee', 'X')], text: 'e');
        final state = _fieldState(tester);
        // Composition in progress: nothing yet.
        state.updateEditingValue(
          const TextEditingValue(
            text: 'e',
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange(start: 0, end: 1),
          ),
        );
        await tester.pump();
        expect(controller.text, 'e');
        // Commit: the composing range ends and the character lands.
        state.updateEditingValue(
          const TextEditingValue(
            text: 'ee',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await tester.pump();
        expect(controller.text, 'X');
      });
    });
  });

  group('manual expansion', () {
    testWidgets('Tab expands a non-auto trigger', (tester) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', 'X', auto: false)],
        text: 'ee',
      );
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.text, 'X');
    });

    testWidgets('Tab with no match falls through to focus traversal', (
      tester,
    ) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', 'X', auto: false)],
        text: 'zz',
        wrap: (field) => Column(
          children: [
            field,
            const TextField(key: Key('next')),
          ],
        ),
      );
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.text, 'zz');
      expect(focusNode.hasFocus, isFalse);
    });

    testWidgets('Space expands when it is the expand key, and eats the space', (
      tester,
    ) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', 'X', auto: false)],
        expandKey: SnippetExpandKey.space,
        text: 'ee',
      );
      await press(tester, LogicalKeyboardKey.space);
      expect(controller.text, 'X');
    });

    testWidgets('Tab never expands when Space is the expand key', (
      tester,
    ) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', 'X', auto: false)],
        expandKey: SnippetExpandKey.space,
        text: 'ee',
      );
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.text, 'ee');
    });
  });

  group('tabstops', () {
    testWidgets('Tab walks the stops in ascending index order', (tester) async {
      await pumpField(tester, snippets: [snippet('ee', r'a$1b$0c$2d')]);
      await type(tester, 'ee');
      expect(controller.text, 'abcd');
      // $0 sits between b and c.
      expect(controller.selection.baseOffset, 2);
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.selection.baseOffset, 1); // $1
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.selection.baseOffset, 3); // $2
    });

    testWidgets(
      'the Tab that lands on the last stop does not also move focus',
      (tester) async {
        await pumpField(
          tester,
          snippets: [snippet('ee', r'($0)$1')],
          wrap: (field) => Column(
            children: [
              field,
              const TextField(key: Key('next')),
            ],
          ),
        );
        await type(tester, 'ee');
        await press(tester, LogicalKeyboardKey.tab);
        expect(controller.selection.baseOffset, 2);
        expect(focusNode.hasFocus, isTrue);
        // The next one falls through.
        await press(tester, LogicalKeyboardKey.tab);
        expect(focusNode.hasFocus, isFalse);
      },
    );

    testWidgets('typing inside the region carries the later stops along', (
      tester,
    ) async {
      await pumpField(tester, snippets: [snippet('ee', r'($0)$1')]);
      await type(tester, 'ee');
      await type(tester, 'xy');
      expect(controller.text, '(xy)');
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.selection.baseOffset, 4);
    });

    testWidgets('the published marks move along with them', (tester) async {
      // The mark has to follow the character it points at, not stay in the
      // column it was first painted in.
      await pumpField(tester, snippets: [snippet('ee', r'($0)$1')]);
      await type(tester, 'ee');
      expect(_marks(tester).offsets, [2]);
      expect(_marks(tester).nextOffset, 2);
      await type(tester, 'xy');
      expect(_marks(tester).offsets, [4]);
      expect(_marks(tester).nextOffset, 4);
    });

    testWidgets('deleting one of the snippet\'s own characters ends it', (
      tester,
    ) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', r'`$0`$1')],
        wrap: (field) => Column(
          children: [
            field,
            const TextField(key: Key('next')),
          ],
        ),
      );
      await type(tester, 'ee');
      expect(controller.text, '``');
      expect(_marks(tester).nextOffset, 2);
      // The opening backtick, from the caret sitting at $0 between the two.
      await press(tester, LogicalKeyboardKey.backspace);
      expect(controller.text, '`');
      expect(_marks(tester).offsets, isEmpty);
      // Nothing left for Tab to advance to, so it traverses.
      await press(tester, LogicalKeyboardKey.tab);
      expect(focusNode.hasFocus, isFalse);
    });

    testWidgets('deleting text typed into a stop does not', (tester) async {
      await pumpField(tester, snippets: [snippet('ee', r'`$0`$1')]);
      await type(tester, 'ee');
      await type(tester, 'ab');
      expect(controller.text, '`ab`');
      await press(tester, LogicalKeyboardKey.backspace);
      expect(controller.text, '`a`');
      // Still live, and the stop after the closing backtick came back with it.
      expect(_marks(tester).nextOffset, 3);
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.selection.baseOffset, 3);
    });

    testWidgets('a nested expansion is dismantled without taking its parent', (
      tester,
    ) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', r'($0)$1'), snippet('qq', r'[$0]$1')],
      );
      await type(tester, 'ee');
      await type(tester, 'qq');
      expect(controller.text, '([])');
      // The inner brackets are the inner snippet's own characters, but only
      // content as far as the outer one is concerned.
      await press(tester, LogicalKeyboardKey.backspace);
      expect(controller.text, '(])');
      // The outer stop after `)` survives; the inner one after `]` does not.
      expect(_marks(tester).offsets, [3]);
    });

    testWidgets('typing the character a stop already sits behind moves it', (
      tester,
    ) async {
      // "ae" typed at $0 puts an `e` immediately in front of the replacement's
      // own `e`, with $1 between them. Text alone cannot say which of the two
      // is the new one, and reading it the wrong way leaves $1's mark stranded
      // at the caret, looking like a stop the snippet never had.
      await pumpField(
        tester,
        snippets: [snippet('zz', r'a$0e$1i$2o$3testing$4')],
      );
      await type(tester, 'zz');
      expect(controller.text, 'aeiotesting');
      expect(_marks(tester).offsets, [2, 3, 4, 11]);
      await type(tester, 'ae');
      expect(controller.text, 'aaeeiotesting');
      expect(_marks(tester).offsets, [4, 5, 6, 13]);
      expect(_marks(tester).nextOffset, 4);
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.selection.baseOffset, 4);
    });

    testWidgets('deleting it again is charged to the user, not the snippet', (
      tester,
    ) async {
      // The same ambiguity backwards: backspacing the `e` just typed reads as
      // deleting the replacement's own `e`, which would end the session.
      await pumpField(
        tester,
        snippets: [snippet('zz', r'a$0e$1i$2o$3testing$4')],
      );
      await type(tester, 'zz');
      await type(tester, 'ae');
      await press(tester, LogicalKeyboardKey.backspace);
      expect(controller.text, 'aaeiotesting');
      expect(_marks(tester).offsets, [3, 4, 5, 12]);
    });

    testWidgets('deleting inside the region pulls them back', (tester) async {
      await pumpField(tester, snippets: [snippet('ee', r'($0)$1')]);
      await type(tester, 'ee');
      await type(tester, 'xy');
      await press(tester, LogicalKeyboardKey.backspace);
      expect(controller.text, '(x)');
      expect(_marks(tester).nextOffset, 3);
    });

    testWidgets('a single tabstop opens no session, so Tab moves focus', (
      tester,
    ) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', r'($0)')],
        wrap: (field) => Column(
          children: [
            field,
            const TextField(key: Key('next')),
          ],
        ),
      );
      await type(tester, 'ee');
      expect(controller.selection.baseOffset, 1);
      await press(tester, LogicalKeyboardKey.tab);
      expect(focusNode.hasFocus, isFalse);
    });

    testWidgets('moving the caret out of the region clears the session', (
      tester,
    ) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', r'($0)$1')],
        text: 'long tail here ',
        wrap: (field) => Column(
          children: [
            field,
            const TextField(key: Key('next')),
          ],
        ),
      );
      controller.selection = const TextSelection.collapsed(offset: 15);
      await tester.pump();
      await type(tester, 'ee');
      expect(controller.text, 'long tail here ()');
      // Click away, inside the same field but outside the expansion.
      controller.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();
      await press(tester, LogicalKeyboardKey.tab);
      expect(focusNode.hasFocus, isFalse);
    });

    testWidgets('a nested expansion is served innermost first', (tester) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', r'[$0|$1]'), snippet('ff', r'<$0-$1>')],
      );
      await type(tester, 'ee');
      expect(controller.text, '[|]');
      await type(tester, 'ff');
      expect(controller.text, '[<->|]');
      // Inner $1 first.
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.selection.baseOffset, 3);
      // Then the outer one, whose offset moved with the inner insertion.
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.selection.baseOffset, 5);
    });

    testWidgets('Shift+Tab traverses focus rather than going back a stop', (
      tester,
    ) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', r'($0)$1')],
        wrap: (field) => Column(
          children: [
            const TextField(key: Key('previous')),
            field,
          ],
        ),
      );
      await type(tester, 'ee');
      await press(tester, LogicalKeyboardKey.tab, shift: true);
      expect(focusNode.hasFocus, isFalse);
    });

    testWidgets('leaving the field clears the session', (tester) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', r'($0)$1')],
        wrap: (field) => Column(
          children: [
            field,
            const TextField(key: Key('next')),
          ],
        ),
      );
      await type(tester, 'ee');
      focusNode.unfocus();
      await tester.pump();
      focusNode.requestFocus();
      await tester.pump();
      await press(tester, LogicalKeyboardKey.tab);
      expect(focusNode.hasFocus, isFalse);
    });
  });

  group('settings churn', () {
    testWidgets('re-publishing an equal list leaves a live session alone', (
      tester,
    ) async {
      await pumpField(tester, snippets: [snippet('ee', r'($0)$1')]);
      await type(tester, 'ee');
      expect(_marks(tester).offsets, [2]);

      // What `ref.invalidate(settingsProvider)` hands down: the settings row
      // re-read off the database, so a brand-new list of equal snippets. An
      // unrelated write must not cost the user their tabstops.
      await pumpField(
        tester,
        snippets: [snippet('ee', r'($0)$1')],
        preserveValue: true,
      );

      expect(_marks(tester).offsets, [2]);
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.selection.baseOffset, 2);
    });

    testWidgets('editing the list still ends a live session', (tester) async {
      await pumpField(tester, snippets: [snippet('ee', r'($0)$1')]);
      await type(tester, 'ee');
      expect(_marks(tester).offsets, [2]);

      await pumpField(
        tester,
        snippets: [snippet('ee', r'($0)$1'), snippet('xx', 'y')],
        preserveValue: true,
      );

      expect(_marks(tester).offsets, isEmpty);
    });
  });

  group('alongside Vim', () {
    testWidgets('manual expansion is refused outside Insert mode', (
      tester,
    ) async {
      await pumpField(
        tester,
        vimEnabled: true,
        snippets: [snippet('ee', 'X', auto: false)],
        text: 'ee',
        wrap: (field) => Column(
          children: [
            field,
            const TextField(key: Key('next')),
          ],
        ),
      );
      await press(tester, LogicalKeyboardKey.escape); // Normal mode
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.text, 'ee');
      // Tab in Normal mode is focus traversal, exactly as it was before
      // snippets existed.
      expect(focusNode.hasFocus, isFalse);
    });

    testWidgets('tabstops survive a trip through Normal mode', (tester) async {
      await pumpField(
        tester,
        vimEnabled: true,
        snippets: [snippet('ee', r'($0)$1')],
      );
      await type(tester, 'ee');
      expect(controller.text, '()');
      // Esc alone must not clear the session — only leaving the region does.
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.selection.baseOffset, 2);
      expect(focusNode.hasFocus, isTrue);
    });

    testWidgets('a key that changed no text cannot vouch for a later write', (
      tester,
    ) async {
      await pumpField(
        tester,
        vimEnabled: true,
        snippets: [snippet('ea', 'X')],
      );
      await type(tester, 'e');
      await press(tester, LogicalKeyboardKey.escape);
      // `a` enters Insert without typing anything, so the token it records is
      // spent by the selection-only notification that follows it.
      await press(tester, _keyFor('a'));

      // A write the user did not make: a sync pull, a redo, a CRDT merge. It
      // happens to insert the same character the last key press produced, and
      // used to be treated as typing on the strength of that stale token.
      controller.value = const TextEditingValue(
        text: 'ea',
        selection: TextSelection.collapsed(offset: 2),
      );
      await tester.pump();
      expect(controller.text, 'ea');
      // Desktop only: where there is no soft keyboard, a character with no key
      // event behind it is by definition not typing — which is the whole point
      // of the token. See [_hardwareKeyboardTypes].
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Tab in Visual mode leaves the range alone', (tester) async {
      await pumpField(
        tester,
        vimEnabled: true,
        snippets: [snippet('ee', r'($0)$1')],
      );
      await type(tester, 'ee');
      expect(controller.text, '()');
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, _keyFor('v'));
      final selection = controller.selection;
      expect(selection.isCollapsed, isFalse);

      // Advancing a tabstop writes a *collapsed* selection, which Vim would
      // not see: it would still believe it was in Visual mode with a range,
      // and the next motion would re-expand from the stale anchor. So Vim
      // keeps Tab while a range is up.
      //
      // (Entering Visual mode has already ended the snippet session by this
      // point — `_pruneForCaret` clears the stack on any non-collapsed
      // selection — so this is the outer of two guards, not the only one.)
      await press(tester, LogicalKeyboardKey.tab);
      expect(controller.selection, selection);
    });

    testWidgets('Vim Normal Tab still traverses when no session is open', (
      tester,
    ) async {
      await pumpField(
        tester,
        vimEnabled: true,
        snippets: [snippet('ee', r'($0)$1')],
        text: 'plain',
        wrap: (field) => Column(
          children: [
            field,
            const TextField(key: Key('next')),
          ],
        ),
      );
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.tab);
      expect(focusNode.hasFocus, isFalse);
    });
  });

  group('undo', () {
    /// Ctrl+Z, then long enough for [UndoHistory]'s 500ms trailing throttle to
    /// push whatever the press left in the field.
    Future<void> undo(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('a second Ctrl+Z goes past the expansion, not back to it', (
      tester,
    ) async {
      await pumpField(tester, snippets: [snippet('ee', 'expanded')]);
      // [UndoHistory] pushes on a 500ms trailing throttle, so the empty field
      // has to reach the stack before the trigger is typed — as it would in
      // any real editing session, where the user does not type in the same
      // 500ms they focused the box.
      await tester.pump(const Duration(seconds: 1));

      await type(tester, 'ee');
      expect(controller.text, 'expanded');
      // And the expansion has to reach it before the first press.
      await tester.pump(const Duration(seconds: 1));

      await undo(tester);
      expect(controller.text, 'ee');

      // Restoring the trigger by *writing* it back reads to [UndoHistory] as
      // an ordinary edit, so it pushed rather than popped and this press walked
      // forward into the expansion again — with every press after it
      // oscillating between the two, the text before the trigger unreachable.
      await undo(tester);
      expect(controller.text, isNot('expanded'));
      expect(controller.text, '');
    });

    testWidgets('Ctrl+Z puts the trigger back in one step', (tester) async {
      await pumpField(tester, snippets: [snippet('ee', r'($0)$1')]);
      await type(tester, 'ee');
      expect(controller.text, '()');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.text, 'ee');
      expect(controller.selection.baseOffset, 2);
    });

    testWidgets('the undone expansion takes its tabstops with it', (
      tester,
    ) async {
      await pumpField(
        tester,
        snippets: [snippet('ee', r'($0)$1')],
        wrap: (field) => Column(
          children: [
            field,
            const TextField(key: Key('next')),
          ],
        ),
      );
      await type(tester, 'ee');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await press(tester, LogicalKeyboardKey.tab);
      expect(focusNode.hasFocus, isFalse);
    });

    testWidgets('an edit after the expansion hands Ctrl+Z back to the field', (
      tester,
    ) async {
      await pumpField(tester, snippets: [snippet('ee', 'XY')]);
      await type(tester, 'ee');
      await type(tester, 'z');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      // Whatever Flutter's own undo does, it must not be "restore the
      // trigger": that state is stale the moment anything else is typed.
      expect(controller.text, isNot('ee'));
    });

    testWidgets('Normal u reverts a snippet expansion after Esc', (
      tester,
    ) async {
      await pumpField(
        tester,
        vimEnabled: true,
        snippets: [snippet('ee', r'($0)$1')],
      );
      await type(tester, 'ee');
      expect(controller.text, '()');
      expect(_marks(tester).offsets, isNotEmpty);
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, _keyFor('u'));
      expect(controller.text, 'ee');
      expect(controller.selection.baseOffset, 2);
      expect(_marks(tester).offsets, isEmpty);
    });

    testWidgets('Normal u does not restore a stale trigger after a later edit', (
      tester,
    ) async {
      await pumpField(
        tester,
        vimEnabled: true,
        snippets: [snippet('ee', 'XY')],
      );
      await type(tester, 'ee');
      await type(tester, 'z');
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, _keyFor('u'));
      expect(controller.text, isNot('ee'));
    });

    testWidgets('Insert u still types the letter', (tester) async {
      await pumpField(
        tester,
        vimEnabled: true,
        snippets: [snippet('ee', 'X')],
      );
      await type(tester, 'u');
      expect(controller.text, 'u');
    });

    testWidgets('Visual u still lowercases and does not undo the snippet', (
      tester,
    ) async {
      await pumpField(
        tester,
        vimEnabled: true,
        snippets: [snippet('ee', 'AB')],
      );
      await type(tester, 'ee');
      expect(controller.text, 'AB');
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, _keyFor('v'));
      await press(tester, _keyFor('u'));
      expect(controller.text, isNot('ee'));
      expect(controller.text, 'Ab');
    });
  });
}
