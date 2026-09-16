import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/snippets/snippet_enabled_scope.dart';
import 'package:voyager/core/snippets/snippet_index.dart';
import 'package:voyager/core/spellcheck/autocorrect_enabled_scope.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/autocorrect_flash_layer.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/domain/models/snippet.dart';

/// The key that types [ch].
LogicalKeyboardKey _keyFor(String ch) {
  const named = <String, LogicalKeyboardKey>{
    ' ': LogicalKeyboardKey.space,
    '\n': LogicalKeyboardKey.enter,
    '.': LogicalKeyboardKey.period,
    ',': LogicalKeyboardKey.comma,
    ';': LogicalKeyboardKey.semicolon,
    "'": LogicalKeyboardKey.quote,
    '#': LogicalKeyboardKey.digit3,
    '`': LogicalKeyboardKey.backquote,
    '-': LogicalKeyboardKey.minus,
    // The shifted characters have no physical key of their own, so they are
    // sent as the unshifted key that carries them, exactly as `#` is.
    '*': LogicalKeyboardKey.digit8,
    '_': LogicalKeyboardKey.minus,
    '=': LogicalKeyboardKey.equal,
    r'$': LogicalKeyboardKey.digit4,
  };
  final named0 = named[ch];
  if (named0 != null) return named0;
  return LogicalKeyboardKey.knownLogicalKeys.firstWhere(
    (k) => k.keyLabel.toLowerCase() == ch.toLowerCase(),
    orElse: () => throw ArgumentError('No key for "$ch"'),
  );
}

/// [testWidgets] with the desktop key rules in force for the body.
///
/// Set and cleared inside the body rather than from `setUp`/`tearDown`: the
/// binding asserts no foundation debug variable is still set when the test
/// body returns, and that check runs before `tearDown` does.
void _desktopWidgets(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// [testWidgets] on a platform with no hardware keyboard, where
/// `AutocorrectSession._wasTyped` cannot read the diff and has to be told what
/// is typing (AUTOCORRECT.md §5.2).
void _mobileWidgets(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

EditableTextState _fieldState(WidgetTester tester) =>
    tester.state<EditableTextState>(
      find.descendant(
        of: find.byType(LabeledTextField),
        matching: find.byType(EditableText),
      ),
    );

/// Exercises the real widget path, on the desktop key rules: keys go through
/// `VimTextScope`'s ancestor [Focus] before the character reaches the field,
/// which is the only thing that tells typing apart from a programmatic write
/// (see `AutocorrectSession._wasTyped`). Without the platform override the
/// mobile branch waves every write through and the gates pass vacuously.
void main() {
  late TextEditingController controller;
  late FocusNode focusNode;
  late VoyagerSpellCheckService service;

  /// The `_lastText`-style field every list-aware host keeps for
  /// [applyListEditing].
  late String lastText;

  setUp(() {
    lastText = '';
    controller = TextEditingController();
    focusNode = FocusNode();
    service = VoyagerSpellCheckService()
      ..updateDictionary({
        'with',
        'hello',
        'there',
        'said',
        'the',
        'code',
        'search',
        'and',
        'a',
      });
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  Future<void> pumpField(
    WidgetTester tester, {
    bool enabled = true,
    bool vimEnabled = false,
    bool autocorrectAllowed = true,
    int? maxLines,
    List<Snippet> snippets = const [],
    String text = '',
    ValueChanged<String>? onChanged,
  }) async {
    controller.text = text;
    controller.selection = TextSelection.collapsed(offset: text.length);
    lastText = text;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voyagerSpellCheckServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: vimEnabled,
            child: AutocorrectEnabledScope(
              // The service travels with the scope whether or not the setting
              // is on, exactly as `autocorrectScopeProvider` builds it: the
              // toggle gates the speculative cascade, not the session
              // (`FLAGGED_WORDS.md` §5.1).
              data: AutocorrectScopeData(enabled: enabled, service: service),
              child: SnippetEnabledScope(
                data: SnippetScopeData(
                  enabled: snippets.isNotEmpty,
                  expandKey: SnippetExpandKey.tab,
                  index: SnippetIndex.from(snippets),
                ),
                child: Scaffold(
                  body: LabeledTextField(
                    label: 'Body',
                    controller: controller,
                    focusNode: focusNode,
                    maxLines: maxLines,
                    autocorrectAllowed: autocorrectAllowed,
                    onChanged: onChanged,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pump();
  }

  /// Types [input] the way the platform does: the key event first — which the
  /// embedder dispatches before handing the character to the text input plugin
  /// — then the committed editing value. Corrections are queued on a
  /// microtask, so every keystroke is pumped.
  Future<void> type(WidgetTester tester, String input) async {
    final state = _fieldState(tester);
    for (final ch in input.split('')) {
      await tester.sendKeyEvent(_keyFor(ch), character: ch);
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

  /// A key that edits without typing a character: Backspace, Escape.
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
  }) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  /// Backspace as the field would apply it, when nothing above it claimed the
  /// key. [press] alone only delivers the key event; the deletion itself is
  /// the platform's follow-up, and the whole point of the revert is that it
  /// never arrives.
  Future<void> backspace(WidgetTester tester) async {
    final before = controller.value;
    await press(tester, LogicalKeyboardKey.backspace);
    if (controller.value != before) return; // claimed and handled above
    final caret = before.selection.baseOffset;
    if (caret <= 0) return;
    _fieldState(tester).updateEditingValue(
      TextEditingValue(
        text: before.text.replaceRange(caret - 1, caret, ''),
        selection: TextSelection.collapsed(offset: caret - 1),
      ),
    );
    await tester.pump();
  }

  Snippet snippet(String trigger, String replacement, {bool auto = true}) =>
      Snippet(
        id: trigger,
        trigger: trigger,
        replacement: replacement,
        autoExpand: auto,
      );

  group('correcting', () {
    _desktopWidgets('a unique transposition is fixed on space', (tester) async {
      await pumpField(tester);
      await type(tester, 'hello wtih ');
      expect(controller.text, 'hello with ');
      expect(controller.selection.baseOffset, 'hello with '.length);
    });

    _desktopWidgets('sentence punctuation is a boundary too', (tester) async {
      await pumpField(tester);
      await type(tester, 'wtih.');
      expect(controller.text, 'with.');
    });

    _desktopWidgets('a newline is a boundary', (tester) async {
      await pumpField(tester);
      await type(tester, 'wtih\n');
      expect(controller.text, 'with\n');
    });

    _desktopWidgets('the first letter keeps its case', (tester) async {
      await pumpField(tester);
      await type(tester, 'Wtih ');
      expect(controller.text, 'With ');
    });

    _desktopWidgets('a word edited with keystrokes is corrected', (
      tester,
    ) async {
      // AUTOCORRECT.md §4.3: not "typed from scratch" — typed *into*.
      await pumpField(tester, text: 'hello wih');
      await type(tester, 't ');
      expect(controller.text, 'hello with ');
    });

    _desktopWidgets('a hyphen ends the run rather than completing a word', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, 'wtih-');
      expect(controller.text, 'wtih-');
    });
  });

  group('declining', () {
    _desktopWidgets('a known word is left alone', (tester) async {
      await pumpField(tester);
      await type(tester, 'hello ');
      expect(controller.text, 'hello ');
    });

    _desktopWidgets('an acronym is left alone', (tester) async {
      await pumpField(tester);
      await type(tester, 'WTIH ');
      expect(controller.text, 'WTIH ');
    });

    _desktopWidgets('a token under three characters is left alone', (
      tester,
    ) async {
      service.updateDictionary({'he'});
      await pumpField(tester);
      await type(tester, 'eh ');
      expect(controller.text, 'eh ');
    });

    _desktopWidgets('an ambiguous typo is left to the squiggle', (
      tester,
    ) async {
      service.updateDictionary({'bac', 'acb'});
      await pumpField(tester);
      await type(tester, 'abc ');
      expect(controller.text, 'abc ');
    });

    _desktopWidgets('a word only shortened is left alone', (tester) async {
      // §12: deleting characters is not typing into the token.
      await pumpField(tester, text: 'hello wtihh');
      await backspace(tester);
      expect(controller.text, 'hello wtih');
      await type(tester, ' ');
      expect(controller.text, 'hello wtih ');
    });

    _desktopWidgets('a word the caret only visited is left alone', (
      tester,
    ) async {
      await pumpField(tester, text: 'hello wtih');
      controller.selection = const TextSelection.collapsed(offset: 10);
      await tester.pump();
      await type(tester, ' ');
      expect(controller.text, 'hello wtih ');
    });

    _desktopWidgets('typing on after leaving the word does not correct it', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, 'hello wtih');
      // Away into the previous word and back: the caret entering the token
      // again is what clears the flag (AUTOCORRECT.md §4.3).
      controller.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();
      controller.selection = const TextSelection.collapsed(offset: 10);
      await tester.pump();
      await type(tester, ' ');
      expect(controller.text, 'hello wtih ');
    });

    _desktopWidgets('a #tag is left alone', (tester) async {
      await pumpField(tester);
      await type(tester, '#wtih ');
      expect(controller.text, '#wtih ');
    });

    _desktopWidgets('inline code is left alone', (tester) async {
      await pumpField(tester);
      await type(tester, '`wtih` ');
      expect(controller.text, '`wtih` ');
    });

    _desktopWidgets('an unclosed backtick excludes what follows it', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, '`code and wtih ');
      expect(controller.text, '`code and wtih ');
    });

    _desktopWidgets('a field that opted out never corrects', (tester) async {
      await pumpField(tester, autocorrectAllowed: false);
      await type(tester, 'wtih ');
      expect(controller.text, 'wtih ');
    });

    _desktopWidgets('a single-line field never corrects', (tester) async {
      await pumpField(tester, maxLines: 1);
      await type(tester, 'wtih ');
      expect(controller.text, 'wtih ');
    });

    _desktopWidgets('the setting switches it off everywhere', (tester) async {
      await pumpField(tester, enabled: false);
      await type(tester, 'wtih ');
      expect(controller.text, 'wtih ');
    });

    _desktopWidgets('an empty dictionary corrects nothing', (tester) async {
      service.updateDictionary(const {});
      await pumpField(tester);
      await type(tester, 'wtih ');
      expect(controller.text, 'wtih ');
    });

    _desktopWidgets('a space typed after text that arrived programmatically', (
      tester,
    ) async {
      // A sync pull or a paste never marks the token as typed into.
      await pumpField(tester);
      controller.value = const TextEditingValue(
        text: 'hello wtih',
        selection: TextSelection.collapsed(offset: 10),
      );
      await tester.pump();
      await type(tester, ' ');
      expect(controller.text, 'hello wtih ');
    });
  });

  group('emphasis', () {
    // EMPHASIS_FORMATTING.md §6.2: the markers close a word, and the text
    // inside them is ordinary prose.
    _desktopWidgets('a closing asterisk completes the word', (tester) async {
      await pumpField(tester);
      await type(tester, '*wtih*');
      expect(controller.text, '*with*');
    });

    _desktopWidgets('the first closing asterisk of a bold pair does it', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, '**wtih**');
      expect(controller.text, '**with**');
    });

    _desktopWidgets('a word is still corrected inside a span', (tester) async {
      await pumpField(tester);
      await type(tester, '**hello wtih** ');
      expect(controller.text, '**hello with** ');
    });

    _desktopWidgets('the second underscore of a closer completes the word', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, '__wtih__');
      expect(controller.text, '__with__');
    });

    _desktopWidgets('the second equals of a closer completes the word', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, '==wtih==');
      expect(controller.text, '==with==');
    });

    _desktopWidgets('one underscore inside a word completes nothing', (
      tester,
    ) async {
      // `snake_case`: `_` is inside the word as far as the reader is
      // concerned, which is why it never joins kAutocorrectBoundaryChars.
      await pumpField(tester);
      await type(tester, 'wtih_case ');
      expect(controller.text, 'wtih_case ');
    });

    _desktopWidgets(r'a word inside $...$ is left alone', (tester) async {
      // Seeded and then edited, because the exclusion needs the closing `$`
      // to exist by the time the boundary is typed. An unpaired `$` is not
      // math — `it cost $5 and wtih ` has to keep correcting — and unlike a
      // backtick it gets no suppress-to-end-of-document rule (§4.3).
      await pumpField(tester, text: r'$x wti y$');
      controller.selection = const TextSelection.collapsed(offset: 6);
      await tester.pump();
      await type(tester, 'h,');
      expect(controller.text, r'$x wtih, y$');
    });

    _desktopWidgets('backspace after a paired-closer correction reverts it', (
      tester,
    ) async {
      // The character the revert deletes is the second `_`, one past the end
      // of the corrected word — not the word's own end.
      await pumpField(tester);
      await type(tester, '__wtih__');
      expect(controller.text, '__with__');
      await backspace(tester);
      expect(controller.text, '__wtih_');
    });
  });

  group('snippets', () {
    _desktopWidgets('a token that is a trigger is exempt', (tester) async {
      await pumpField(tester, snippets: [snippet('wtih', 'X', auto: false)]);
      await type(tester, 'wtih ');
      expect(controller.text, 'wtih ');
    });

    _desktopWidgets('expansion output is never autocorrected', (tester) async {
      await pumpField(tester, snippets: [snippet('zzz', 'wtih')]);
      await type(tester, 'zzz');
      expect(controller.text, 'wtih');
      await type(tester, ' ');
      expect(controller.text, 'wtih ');
    });

    _mobileWidgets('expansion output is never autocorrected off desktop', (
      tester,
    ) async {
      // The mobile branch of `_wasTyped` waves every write through, so the
      // expansion has to identify itself: `wtih` shares `wti`'s prefix and is
      // one character longer, which is shaped exactly like a typed `h`.
      await pumpField(tester, snippets: [snippet('wti', 'wtih')]);
      await type(tester, 'wti');
      expect(controller.text, 'wtih');
      await type(tester, ' ');
      expect(controller.text, 'wtih ');
    });

    _desktopWidgets('a trigger ending in a boundary still expands when the '
        'snippet session was created second', (tester) async {
      // `hasPendingExpansion` only becomes true inside the snippet session's
      // own listener, so the synchronous poll is answered correctly only while
      // that listener registered first. Building the field with no snippets
      // and adding one afterwards registers it second, for the life of the
      // field.
      await pumpField(tester);
      await pumpField(tester, snippets: [snippet('h.', 'HH')]);
      await type(tester, 'wtih.');
      expect(controller.text, 'wtiHH');
    });
  });

  group('list lines', () {
    /// What every list-aware field does from `onChanged`: writes the
    /// continuation marker back, so one Enter produces two controller
    /// notifications and the second lands before the correction's microtask.
    void listEditing(String _) {
      applyListEditing(controller: controller, previousText: lastText);
      lastText = controller.text;
    }

    _desktopWidgets('Enter still corrects the word before it', (tester) async {
      await pumpField(tester, text: '- ', onChanged: listEditing);
      await type(tester, 'wtih\n');
      expect(controller.text, '- with\n- ');
    });

    _desktopWidgets('reverting keeps the continuation marker', (tester) async {
      // The recorded boundary — the newline — is no longer the character this
      // Backspace would have deleted, so the keystroke only puts the typo back.
      await pumpField(tester, text: '- ', onChanged: listEditing);
      await type(tester, 'wtih\n');
      expect(controller.text, '- with\n- ');
      await backspace(tester);
      expect(controller.text, '- wtih\n- ');
    });
  });

  group('dictionary loading', () {
    _desktopWidgets('custom words alone are not a dictionary', (tester) async {
      // The two halves of `knownWords` load independently and the local
      // custom-word read usually settles first. In that window every real word
      // reads as unknown and the user's own additions are the only targets.
      service = VoyagerSpellCheckService()..updateCustomWords({'with'});
      await pumpField(tester);
      await type(tester, 'wtih ');
      expect(controller.text, 'wtih ');
      expect(service.dictionaryLoaded, isFalse);
    });
  });

  group('rejecting', () {
    _desktopWidgets('backspace straight after reverts and drops the boundary', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, 'hello wtih ');
      expect(controller.text, 'hello with ');
      await backspace(tester);
      expect(controller.text, 'hello wtih');
      expect(controller.selection.baseOffset, 'hello wtih'.length);
    });

    _desktopWidgets('a second backspace deletes normally', (tester) async {
      await pumpField(tester);
      await type(tester, 'wtih ');
      await backspace(tester);
      expect(controller.text, 'wtih');
      await backspace(tester);
      expect(controller.text, 'wti');
    });

    _desktopWidgets('moving the caret does not cancel the revert', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, 'hello wtih ');
      // Somewhere the correction did *not* leave it: offset 11 is where the
      // correction already put it, so the controller would not even notify.
      controller.selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();
      await backspace(tester);
      expect(controller.text, 'hello wtih');
    });

    _desktopWidgets('any other edit does cancel it', (tester) async {
      await pumpField(tester);
      await type(tester, 'wtih ');
      await type(tester, 'x');
      await backspace(tester);
      expect(controller.text, 'with ');
    });

    _desktopWidgets('a rejected typo is not corrected again in this field', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, 'wtih ');
      await backspace(tester);
      expect(controller.text, 'wtih');
      for (var i = 0; i < 4; i++) {
        await backspace(tester);
      }
      expect(controller.text, '');
      await type(tester, 'wtih ');
      expect(controller.text, 'wtih ');
    });

    _desktopWidgets('suppression is cleared when the field loses focus', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, 'wtih ');
      await backspace(tester);
      focusNode.unfocus();
      await tester.pump();
      focusNode.requestFocus();
      await tester.pump();
      controller.selection = const TextSelection.collapsed(offset: 4);
      await tester.pump();
      await type(tester, ' ');
      // The token still has to be typed into after the refocus, so this only
      // proves the suppression set went: retype it.
      await type(tester, 'wtih ');
      expect(controller.text, endsWith('with '));
    });
  });

  group('undo', () {
    _desktopWidgets('Ctrl+Z restores the typo and the boundary', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, 'hello wtih ');
      expect(controller.text, 'hello with ');
      await press(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(controller.text, 'hello wtih ');
    });

    _desktopWidgets('Ctrl+Z still works after the caret has moved', (
      tester,
    ) async {
      // Clicking away before undoing is ordinary, and `UndoHistory`'s 500ms
      // trailing throttle means Flutter's own undo has nothing to hand back.
      await pumpField(tester);
      await type(tester, 'hello wtih ');
      controller.selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(controller.text, 'hello wtih ');
    });
  });

  group('vim', () {
    _desktopWidgets('nothing is corrected in Normal mode', (tester) async {
      await pumpField(tester, vimEnabled: true);
      await type(tester, 'hello wtih');
      await press(tester, LogicalKeyboardKey.escape);
      // Space is a motion in Normal mode: no text change, so no boundary.
      await press(tester, _keyFor(' '));
      expect(controller.text, 'hello wtih');
    });

    _desktopWidgets('Insert mode corrects as usual', (tester) async {
      await pumpField(tester, vimEnabled: true);
      await type(tester, 'hello wtih ');
      expect(controller.text, 'hello with ');
    });

    _desktopWidgets('Normal mode keeps Backspace as a left motion', (
      tester,
    ) async {
      // Esc steps the caret back one character without editing, so the
      // correction is still the most recent mutation. Only the mode gate stops
      // autocorrect claiming a key that means something else here.
      await pumpField(tester, vimEnabled: true);
      await type(tester, 'hello wtih ');
      expect(controller.text, 'hello with ');
      await press(tester, LogicalKeyboardKey.escape);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(controller.text, 'hello with ');
      expect(controller.selection.baseOffset, 9);
    });
  });

  group('non-ASCII', () {
    _desktopWidgets('the ASCII tail of an accented word is left alone', (
      tester,
    ) async {
      // `é` has no logical key to send, so it starts in the field; `wtih` is
      // still typed into, which is the whole of the §4.3 rule.
      await pumpField(tester, text: 'café');
      await type(tester, 'wtih ');
      expect(controller.text, 'caféwtih ');
    });
  });

  group('alphanumeric runs', () {
    _desktopWidgets('a letter run touching a digit is left alone', (
      tester,
    ) async {
      // The squiggle drops `3wtih` whole because the run holds a digit, so
      // the correction has to stay off it too — otherwise autocorrect
      // rewrites a model number the checker says nothing about.
      await pumpField(tester, text: '3');
      await type(tester, 'wtih ');
      expect(controller.text, '3wtih ');
    });

    _desktopWidgets('a digit typed after the word does not stop it', (
      tester,
    ) async {
      // Sanity check the guard is about the run and not about digits being
      // anywhere in the field.
      await pumpField(tester, text: '3 ');
      await type(tester, 'wtih ');
      expect(controller.text, '3 with ');
    });
  });

  // `FLAGGED_WORDS.md` §5: a flagged word is unknown, and a flag that stores a
  // replacement is a rule the user wrote rather than a guess the cascade made.
  group('flagged words', () {
    void flag(Map<String, String?> pairs, {Set<String> dictionary = const {}}) {
      if (dictionary.isNotEmpty) service.updateDictionary(dictionary);
      service.updateFlaggedWords(pairs);
    }

    _desktopWidgets('a stored pair rewrites the token on a boundary', (
      tester,
    ) async {
      flag({'neve': 'never'}, dictionary: {'neve', 'never', 'nerve'});
      await pumpField(tester);
      await type(tester, 'neve ');
      expect(controller.text, 'never ');
      expect(controller.selection.baseOffset, 'never '.length);
    });

    _desktopWidgets('a pair applies with autocorrect switched off', (
      tester,
    ) async {
      // §5.1: the toggle gates the speculative cascade only. The pair is not a
      // guess, so turning autocorrect off does not forget it.
      flag({'neve': 'never'}, dictionary: {'neve', 'never', 'wtih', 'with'});
      await pumpField(tester, enabled: false);
      await type(tester, 'neve ');
      expect(controller.text, 'never ');
      // ...and the cascade really is off in the same field.
      await type(tester, 'wtih ');
      expect(controller.text, 'never wtih ');
    });

    _desktopWidgets('a pair wins over a unique cascade hit', (tester) async {
      // The cascade would have said `from`. The user said `shape`.
      flag({'form': 'shape'}, dictionary: {'form', 'from', 'shape'});
      await pumpField(tester);
      await type(tester, 'form ');
      expect(controller.text, 'shape ');
    });

    _desktopWidgets('a flag with no pair still cascades when it is unique', (
      tester,
    ) async {
      // §5.3 step 4: the cascade does not know about flags, only that the
      // token is not in `known`. `form` transposes uniquely to `from`.
      flag({'form': null}, dictionary: {'form', 'from'});
      await pumpField(tester);
      await type(tester, 'form ');
      expect(controller.text, 'from ');
    });

    _desktopWidgets('an ambiguous flag with no pair is left alone', (
      tester,
    ) async {
      // `neve` inserts to both `never` and `nerve`, so there is no unique hit
      // and flagging it does not quietly become "replace it with never".
      flag({'neve': null}, dictionary: {'neve', 'never', 'nerve'});
      await pumpField(tester);
      await type(tester, 'neve ');
      expect(controller.text, 'neve ');
    });

    _desktopWidgets('a wrong-letter flag with no pair is never guessed', (
      tester,
    ) async {
      // `than` is a substitution away, which is not in the cascade's model at
      // all — flagging `then` only squiggles it.
      flag({'then': null}, dictionary: {'then', 'than'});
      await pumpField(tester);
      await type(tester, 'then ');
      expect(controller.text, 'then ');
    });

    _desktopWidgets('a pair keeps the first letter case', (tester) async {
      flag({'neve': 'never'}, dictionary: {'neve', 'never'});
      await pumpField(tester);
      await type(tester, 'Neve ');
      expect(controller.text, 'Never ');
    });

    _desktopWidgets('an all-caps token is not rewritten by a pair', (
      tester,
    ) async {
      flag({'neve': 'never'}, dictionary: {'neve', 'never'});
      await pumpField(tester);
      await type(tester, 'NEVE ');
      expect(controller.text, 'NEVE ');
    });

    _desktopWidgets('a snippet trigger beats the pair', (tester) async {
      flag({'neve': 'never'}, dictionary: {'neve', 'never'});
      await pumpField(tester, snippets: [snippet('neve', 'X', auto: false)]);
      await type(tester, 'neve ');
      expect(controller.text, 'neve ');
    });

    _desktopWidgets('a pair does not fire on programmatic text', (
      tester,
    ) async {
      flag({'neve': 'never'}, dictionary: {'neve', 'never'});
      await pumpField(tester);
      controller.value = const TextEditingValue(
        text: 'neve',
        selection: TextSelection.collapsed(offset: 4),
      );
      await tester.pump();
      await type(tester, ' ');
      expect(controller.text, 'neve ');
    });

    _desktopWidgets('a pair rewrite flashes like any other correction', (
      tester,
    ) async {
      flag({'neve': 'never'}, dictionary: {'neve', 'never'});
      await pumpField(tester);
      await type(tester, 'neve ');
      final layer = tester.widget<AutocorrectFlashLayer>(
        find.byType(AutocorrectFlashLayer),
      );
      final flash = layer.session.flashListenable.value;
      expect(flash, isNotNull);
      expect(flash!.range, const TextRange(start: 0, end: 5));
    });

    _desktopWidgets('backspace reverts a pair and suppresses it', (
      tester,
    ) async {
      flag({'neve': 'never'}, dictionary: {'neve', 'never'});
      await pumpField(tester);
      await type(tester, 'neve ');
      expect(controller.text, 'never ');
      await backspace(tester);
      // The boundary goes with the revert, exactly as it does for a cascade
      // correction.
      expect(controller.text, 'neve');
      await type(tester, ' ');
      expect(controller.text, 'neve ');
    });

    _desktopWidgets('a flagged word is not a landing site for other typos', (
      tester,
    ) async {
      // §4: the flag comes out of `knownWords`, which is the set the cascade
      // searches — so `nvee` can no longer be "corrected" to `neve`.
      service.updateDictionary({'neve', 'hello'});
      await pumpField(tester);
      await type(tester, 'nvee ');
      expect(controller.text, 'neve ');

      flag({'neve': null});
      controller.value = const TextEditingValue(text: '');
      await tester.pump();
      await type(tester, 'nvee ');
      expect(controller.text, 'nvee ');
    });

    _desktopWidgets('the offered replacement flashes and reverts too', (
      tester,
    ) async {
      // The "Replace this one" path (§6), which goes through the same apply as
      // a boundary rewrite, so §5.4's flash and revert come for free.
      flag({'neve': 'never'}, dictionary: {'neve', 'never'});
      await pumpField(tester, text: 'a neve day');
      final layer = tester.widget<AutocorrectFlashLayer>(
        find.byType(AutocorrectFlashLayer),
      );
      final applied = layer.session.applyReplacementAt(
        const TextRange(start: 2, end: 6),
        'never',
      );
      await tester.pump();
      expect(applied, isTrue);
      expect(controller.text, 'a never day');
      expect(
        layer.session.flashListenable.value!.range,
        const TextRange(start: 2, end: 7),
      );
      await backspace(tester);
      // No boundary character was typed, so the keystroke is spent entirely on
      // putting the flagged spelling back.
      expect(controller.text, 'a neve day');
    });
  });

  group('flash', () {
    _desktopWidgets('a correction publishes a span for the layer', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, 'hello wtih ');
      final layer = tester.widget<AutocorrectFlashLayer>(
        find.byType(AutocorrectFlashLayer),
      );
      final flash = layer.session.flashListenable.value;
      expect(flash, isNotNull);
      expect(flash!.range, const TextRange(start: 6, end: 10));
    });

    _desktopWidgets('a revert takes the mark away', (tester) async {
      await pumpField(tester);
      await type(tester, 'hello wtih ');
      await backspace(tester);
      final layer = tester.widget<AutocorrectFlashLayer>(
        find.byType(AutocorrectFlashLayer),
      );
      expect(layer.session.flashListenable.value, isNull);
    });

    _desktopWidgets('the geometry is laid out once, not once a frame', (
      tester,
    ) async {
      // The fade drives the painter through `CustomPainter.repaint`, so the
      // `CustomPaint` is not rebuilt per tick and the painter — which caches
      // the boxes it laid out — is the same object across the whole fade.
      await pumpField(tester);
      await type(tester, 'hello wtih ');
      final painted = find.descendant(
        of: find.byType(AutocorrectFlashLayer),
        matching: find.byType(CustomPaint),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final first = tester.widget<CustomPaint>(painted).painter;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<CustomPaint>(painted).painter, same(first));
    });

    _desktopWidgets('the mark paints while it fades, and stops after', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, 'hello wtih ');
      final painted = find.descendant(
        of: find.byType(AutocorrectFlashLayer),
        matching: find.byType(CustomPaint),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(painted, findsOneWidget);
      await tester.pump(AutocorrectFlashLayer.fadeDuration);
      await tester.pump();
      expect(painted, findsNothing);
      final layer = tester.widget<AutocorrectFlashLayer>(
        find.byType(AutocorrectFlashLayer),
      );
      expect(layer.session.flashListenable.value, isNotNull);
    });
  });
}
