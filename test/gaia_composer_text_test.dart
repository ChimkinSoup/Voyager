import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/media/media_clipboard.dart';
import 'package:voyager/core/spellcheck/autocorrect_enabled_scope.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/models/snippet.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_composer_text.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/features/gaia/gaia_text_settings.dart';

import 'fakes/gaia_fakes.dart';

/// A clipboard holding an image, and text too if [hasText], which counts how
/// many times the image was asked for.
class _FakeClipboard extends MediaClipboard {
  _FakeClipboard({required this.hasText});

  final bool hasText;
  var reads = 0;

  @override
  Future<({bool hasText, bool hasImage})> peek() async =>
      (hasText: hasText, hasImage: true);

  @override
  Future<MediaClipboardContents> read() async {
    reads++;
    return MediaClipboardContents.empty;
  }
}

/// The composer's text (§9.5): Voyager's Vim, snippets, spellcheck and
/// autocorrect, on the settings the main instance sends.
void main() {
  String skipped(String text) => [
    for (final zone in gaiaComposerSkipZones(text))
      text.substring(zone.start, zone.end),
  ].join('|');

  group('gaiaComposerSkipZones', () {
    test('commands, labels, paths and URLs', () {
      expect(skipped('/remember teh thing'), '/remember');
      expect(skipped('see [image 2] here'), '[image 2]');
      expect(
        skipped(r'open C:\Users\Juno\notez.txt and lib/foo_bar.dart'),
        r'C:\Users\Juno\notez.txt|lib/foo_bar.dart',
      );
      expect(skipped('at https://exmaple.com/a ok'), 'https://exmaple.com/a');
      expect(skipped('at www.exmaple.com ok'), 'www.exmaple.com');
      expect(skipped('plain prose here'), '');
    });

    test('a long run with no slash is quick', () {
      final watch = Stopwatch()..start();
      expect(skipped('a' * 100000), '');
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a fence, closed or still being typed', () {
      expect(skipped('Fix:\n```\nfoo bar\n```\nafter'), '```\nfoo bar\n```');
      expect(skipped('Fix:\n```py\nfoo bar\nbaz'), '```py\nfoo bar\nbaz');
    });
  });

  group('a checker with skip zones', () {
    final service = VoyagerSpellCheckService(skipZones: gaiaComposerSkipZones)
      ..updateDictionary({'the', 'see', 'at', 'and', 'ok'});

    List<String> flagged(String text, List<SuggestionSpan> spans) => [
      for (final span in spans)
        text.substring(span.range.start, span.range.end),
    ];

    test('flags nothing inside them, all at once or as it grows', () {
      const text = 'teh /comand at www.exmaple.com and `codez` ok';
      expect(flagged(text, service.checkTextSync(text)), ['teh']);
      const before = 'teh /coman';
      expect(
        flagged(
          text,
          service.checkIncremental(
            oldText: before,
            oldSpans: service.checkTextSync(before),
            newText: text,
          ),
        ),
        ['teh'],
      );
      expect(service.skips(text, 5, 11), isTrue);
      expect(service.skips(text, 0, 3), isFalse);
    });
  });

  test('the settings go over the pipe and back unchanged', () {
    const settings = GaiaTextSettings(
      vim: true,
      autocorrect: true,
      snippetsEnabled: true,
      expandKey: SnippetExpandKey.space,
      snippets: [
        Snippet(
          id: 's1',
          trigger: 'brb',
          replacement: 'be right back',
          autoExpand: true,
          wordBoundary: true,
        ),
      ],
      customWords: {'voyager'},
      flaggedWords: {'recieve': 'receive'},
    );
    final back = GaiaTextSettings.fromJson(settings.toJson());
    expect(back.sameAs(settings), isTrue);
    expect(back.snippets.single.replacement, 'be right back');
    expect(back.flaggedWords, {'recieve': 'receive'});
  });

  group('the composer', () {
    late FakeGaiaPipe main;
    late FakeGaiaPipe companion;
    late GaiaController controller;
    late FakeGaiaWindow window;
    final requests = <String>[];

    Future<void> start(
      WidgetTester tester,
      GaiaTextSettings text, {
      FakeClaudeRunner? runner,
    }) async {
      requests.clear();
      main = FakeGaiaPipe.main();
      main
        ..onLaunch = (end, _) {
          companion = end;
        }
        ..onRequest = (method, params) async {
          requests.add('$method ${params.values.join(' ')}');
          return switch (method) {
            'hello' => {
              'aborted': false,
              'accent': 0xFF7C9EFF,
              'deviceId': 'laptop',
              'settings': GaiaSettings.initial().toJson(),
              'text': text.toJson(),
            },
            'chats' || 'drafts' || 'messages' => <Object?>[],
            _ => null,
          };
        };
      await main.startCompanion();
      controller = GaiaController(
        pipe: companion,
        window: window = FakeGaiaWindow(),
        runners: {kGaiaClaudeCodeAdapter: runner ?? FakeClaudeRunner()},
        cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
        exit: (_) {},
      );
      await controller.start();
      // In real time: the bundled dictionary loads from the assets on an
      // isolate, which fake time never finishes.
      await tester.runAsync(() async {
        await tester.pumpWidget(GaiaApp(controller: controller));
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await tester.pump();
      await tester.tap(find.byType(GaiaTextField));
      await tester.pump();
    }

    EditableTextState field(WidgetTester tester) =>
        tester.state<EditableTextState>(
          find.descendant(
            of: find.byType(GaiaTextField),
            matching: find.byType(EditableText),
          ),
        );

    LogicalKeyboardKey keyFor(String ch) => ch == '\n'
        ? LogicalKeyboardKey.enter
        : LogicalKeyboardKey.knownLogicalKeys.firstWhere(
            (key) => key.keyLabel.toLowerCase() == ch.toLowerCase(),
          );

    /// Typed as a keyboard does it: the key, then the character it puts in.
    Future<void> type(WidgetTester tester, String input) async {
      final state = field(tester);
      for (final ch in input.split('')) {
        await tester.sendKeyEvent(keyFor(ch), character: ch);
        final value = controller.draft.value;
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

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }

    group('/this (§15.5)', () {
      const button = GaiaElementPart(
        controlType: 'Button',
        name: 'Submit assignment',
        app: 'Google Chrome',
        left: 1,
        top: 2,
        width: 3,
        height: 4,
      );

      Future<void> send(WidgetTester tester, String text) async {
        await tester.enterText(
          find.descendant(
            of: find.byType(GaiaTextField),
            matching: find.byType(EditableText),
          ),
          text,
        );
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
        // In real time: a send's first steps aren't all in fake time.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
      }

      testWidgets('alone, it shows as a chip the user can take off', (
        tester,
      ) async {
        await start(tester, const GaiaTextSettings());
        companion.onEvent!('pointed', {'control': button.toJson()});
        await tester.pump();
        await send(tester, '/this');
        expect(controller.draftControl?.label, button.label);
        expect(find.text(button.label), findsOneWidget);
        expect(controller.draft.text, isEmpty);
        await settle(tester);
      });

      testWidgets('with a question after it, the question goes with the '
          'control on it', (tester) async {
        await start(tester, const GaiaTextSettings());
        companion.onEvent!('pointed', {'control': button.toJson()});
        await tester.pump();
        await send(tester, '/this what does it do?');
        final question = controller.messages.first;
        expect(question.text, 'what does it do?');
        expect(
          question.parts.whereType<GaiaElementPart>().single.name,
          button.name,
        );
        expect(controller.draftControl, isNull);
        expect(find.text(button.label), findsOneWidget);
        await settle(tester);
      });

      testWidgets('refused, the typed question stays in the draft, unsent', (
        tester,
      ) async {
        await start(tester, const GaiaTextSettings());
        companion.onEvent!('pointed', {'refused': 'sensitive'});
        await tester.pump();
        final toasts = <GaiaRunToast>[];
        final listening = controller.toasts.listen(toasts.add);
        addTearDown(listening.cancel);
        await send(tester, '/this what is it?');
        expect(toasts.single.body, contains('password'));
        expect(controller.draft.text, '/this what is it?');
        expect(controller.messages, isEmpty);
        await settle(tester);
      });
    });

    testWidgets('Vim from the settings: Esc to Normal, x deletes', (
      tester,
    ) async {
      await start(tester, const GaiaTextSettings(vim: true));
      await type(tester, 'hello');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'x');
      await tester.pump();
      expect(controller.draft.text, 'hell');
      await settle(tester);
    });

    testWidgets('Vim comes on when the main instance says so', (tester) async {
      await start(tester, GaiaTextSettings.off);
      expect(find.byType(VimTextOverlay), findsNothing);
      main.notify('text', const GaiaTextSettings(vim: true).toJson());
      await tester.pump();
      await tester.pump();
      expect(find.byType(VimTextOverlay), findsOneWidget);
      await settle(tester);
    });

    testWidgets("the user's snippets expand", (tester) async {
      await start(
        tester,
        const GaiaTextSettings(
          snippetsEnabled: true,
          expandKey: SnippetExpandKey.space,
          snippets: [
            Snippet(
              id: 's1',
              trigger: 'brb',
              replacement: 'be right back',
              autoExpand: true,
              wordBoundary: true,
            ),
          ],
        ),
      );
      await type(tester, 'brb ');
      await tester.pump();
      expect(controller.draft.text, 'be right back ');
      await settle(tester);
    });

    testWidgets('autocorrect fixes prose, not a command', (tester) async {
      await start(
        tester,
        const GaiaTextSettings(
          autocorrect: true,
          flaggedWords: {'recieve': 'receive'},
        ),
      );
      final scope = tester.widget<AutocorrectEnabledScope>(
        find.byType(AutocorrectEnabledScope),
      );
      expect(scope.data.service!.dictionaryLoaded, isTrue);
      await type(tester, 'recieve ');
      await tester.pump();
      expect(controller.draft.text, 'receive ');
      controller.draft.clear();
      await tester.pump();
      await type(tester, '/recieve ');
      await tester.pump();
      expect(controller.draft.text, '/recieve ');
      await settle(tester);
    });

    testWidgets("with Vim on, Esc closes the palette and stays in Insert", (
      tester,
    ) async {
      await start(tester, const GaiaTextSettings(vim: true));
      await type(tester, '/ne');
      expect(find.byKey(const ValueKey('/new')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('/new')), findsNothing);
      await type(tester, 'x');
      expect(controller.draft.text, '/nex');
      await settle(tester);
    });

    testWidgets('the palette still opens once a drain has given the field back', (
      tester,
    ) async {
      await start(tester, GaiaTextSettings.off);
      controller.draining = 1;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      controller.notifyListeners();
      await tester.pump();
      await tester.pump();
      expect(find.byType(GaiaTextField), findsNothing);
      controller.draining = null;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      controller.notifyListeners();
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byType(GaiaTextField));
      await tester.pump();
      await type(tester, '/ne');
      expect(find.byKey(const ValueKey('/new')), findsOneWidget);
      await settle(tester);
    });

    Future<void> pressUndo(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    testWidgets("undo doesn't bring one chat's draft into another", (
      tester,
    ) async {
      await start(tester, GaiaTextSettings.off);
      await type(tester, 'secret');
      await tester.pump(const Duration(seconds: 1));
      await controller.selectChat('c1');
      await tester.pump(const Duration(seconds: 1));
      expect(controller.draft.text, '');
      await pressUndo(tester);
      expect(controller.draft.text, '');
      // Back in its own chat, the draft is as it was left.
      controller.newChat();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.draft.text, 'secret');
      await settle(tester);
    });

    testWidgets('each chat keeps its own undo history', (tester) async {
      Future<void> pause() => tester.pump(const Duration(seconds: 1));
      await start(tester, GaiaTextSettings.off);
      await type(tester, 'one');
      await pause();
      await type(tester, 'two');
      await pause();
      await controller.selectChat('c1');
      await pause();
      await type(tester, 'x');
      await pause();
      controller.newChat();
      await pause();
      await pressUndo(tester);
      expect(controller.draft.text, 'one');
      await controller.selectChat('c1');
      await pause();
      expect(controller.draft.text, 'x');
      await pressUndo(tester);
      expect(controller.draft.text, '');
      // At the start of this chat's history: nothing of the other's is next.
      await pressUndo(tester);
      expect(controller.draft.text, '');
      controller.newChat();
      await pause();
      expect(controller.draft.text, 'one');
      // Redo came back with it too.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.draft.text, 'onetwo');
      await settle(tester);
    });

    testWidgets("undo doesn't bring a moved draft back to the chat it left", (
      tester,
    ) async {
      await start(tester, GaiaTextSettings.off);
      await controller.selectChat('c1');
      await tester.pump(const Duration(seconds: 1));
      await type(tester, 'moved');
      await tester.pump(const Duration(seconds: 1));
      controller.moveDraftToNewChat();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.draft.text, 'moved');
      // Undo here would lose it: its images have moved too.
      await pressUndo(tester);
      expect(controller.draft.text, 'moved');
      await controller.selectChat('c1');
      await tester.pump(const Duration(seconds: 1));
      await pressUndo(tester);
      expect(controller.draft.text, '');
      await settle(tester);
    });

    testWidgets("undo doesn't bring a sent message back", (tester) async {
      await start(tester, GaiaTextSettings.off);
      await type(tester, 'sent');
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump(const Duration(seconds: 1));
      expect(controller.draft.text, '');
      await tester.tap(find.byType(GaiaTextField));
      await tester.pump();
      await pressUndo(tester);
      expect(controller.draft.text, '');
      await settle(tester);
    });

    testWidgets("undo doesn't bring a removed image's token back", (
      tester,
    ) async {
      await start(tester, GaiaTextSettings.off);
      controller.draft.text = 'look at [image 1]';
      await tester.pump(const Duration(seconds: 1));
      controller.removeDraftImage(1);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.draft.text, 'look at');
      await pressUndo(tester);
      expect(controller.draft.text, 'look at');
      await settle(tester);
    });

    testWidgets('undo and redo still step through the draft in view', (
      tester,
    ) async {
      await start(tester, GaiaTextSettings.off);
      await type(tester, 'one');
      await tester.pump(const Duration(seconds: 1));
      await type(tester, 'two');
      await tester.pump(const Duration(seconds: 1));
      await pressUndo(tester);
      expect(controller.draft.text, 'one');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.draft.text, 'onetwo');
      await settle(tester);
    });

    group('lists, as in the notes', () {
      testWidgets('Enter continues a numbered list and leaves it empty', (
        tester,
      ) async {
        await start(tester, GaiaTextSettings.off);
        await type(tester, '1. one\n');
        expect(controller.draft.text, '1. one\n2. ');
        await type(tester, 'two\n\n');
        expect(controller.draft.text, '1. one\n2. two\n');
        await settle(tester);
      });

      testWidgets('a bullet continues too', (tester) async {
        await start(tester, GaiaTextSettings.off);
        await type(tester, '- a\n');
        expect(controller.draft.text, '- a\n- ');
        await settle(tester);
      });

      testWidgets('Tab and Shift+Tab indent a list line', (tester) async {
        await start(tester, GaiaTextSettings.off);
        await type(tester, '- one\ntwo');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(controller.draft.text, '- one\n  - two');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(controller.draft.text, '- one\n- two');
        await settle(tester);
      });

      testWidgets('Backspace just past a marker takes it away', (tester) async {
        await start(tester, GaiaTextSettings.off);
        await type(tester, '- a\n');
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        expect(controller.draft.text, '- a\n');
        await settle(tester);
      });

      testWidgets('a draft put in from code is left as it is', (tester) async {
        await start(tester, GaiaTextSettings.off);
        controller.draft.text = '3. c\n';
        await tester.pump();
        expect(controller.draft.text, '3. c\n');
        await settle(tester);
      });

      testWidgets('undo steps back over a continued line', (tester) async {
        await start(tester, GaiaTextSettings.off);
        await type(tester, '1. one');
        await tester.pump(const Duration(seconds: 1));
        await type(tester, '\n');
        await tester.pump(const Duration(seconds: 1));
        await pressUndo(tester);
        expect(controller.draft.text, '1. one');
        await settle(tester);
      });
    });

    testWidgets("Vim's u doesn't cross chats either, and works within one", (
      tester,
    ) async {
      await start(tester, const GaiaTextSettings(vim: true));
      await type(tester, 'one');
      await tester.pump(const Duration(seconds: 1));
      await type(tester, 'two');
      await tester.pump(const Duration(seconds: 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU, character: 'u');
      await tester.pump();
      expect(controller.draft.text, 'one');
      await controller.selectChat('c1');
      await tester.pump(const Duration(seconds: 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU, character: 'u');
      await tester.pump();
      expect(controller.draft.text, '');
      await settle(tester);
    });

    group("Vim's Ctrl+V with an image on the clipboard", () {
      Future<int> paste(WidgetTester tester, {required bool withText}) async {
        final clipboard = _FakeClipboard(hasText: withText);
        gaiaClipboard = clipboard;
        addTearDown(() => gaiaClipboard = const MediaClipboard());
        await start(tester, const GaiaTextSettings(vim: true));
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData' && withText
              ? {'text': 'words'}
              : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        await tester.pump();
        return clipboard.reads;
      }

      testWidgets('attaches it', (tester) async {
        expect(await paste(tester, withText: false), 1);
        await settle(tester);
      });

      testWidgets('leaves it when text came with it, as Insert does', (
        tester,
      ) async {
        expect(await paste(tester, withText: true), 0);
        await settle(tester);
      });
    });

    testWidgets("Vim's Ctrl+V takes a Windows line ending as a newline", (
      tester,
    ) async {
      gaiaClipboard = _FakeClipboard(hasText: true);
      addTearDown(() => gaiaClipboard = const MediaClipboard());
      await start(tester, const GaiaTextSettings(vim: true));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => switch (call.method) {
          'Clipboard.getData' => {'text': 'one\r\ntwo'},
          'Clipboard.hasStrings' => {'value': true},
          _ => null,
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();
      expect(controller.draft.text, 'one\ntwo');
      await settle(tester);
    });

    testWidgets("the hint's M is the size the Normal block repaints it at", (
      tester,
    ) async {
      await start(tester, const GaiaTextSettings(vim: true));
      final hint = tester.widget<Text>(find.text('Message Gaia'));
      expect(hint.style!.fontSize, field(tester).widget.style.fontSize);
      expect(hint.style!.height, field(tester).widget.style.height);
      await settle(tester);
    });

    testWidgets('the composer eats Esc; with nothing focused it hides', (
      tester,
    ) async {
      await start(tester, const GaiaTextSettings(vim: true));
      window.shown = GaiaMode.small;
      // Insert to Normal, then Esc again in Normal: still shown, still Vim.
      await type(tester, 'hi');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(window.shown, GaiaMode.small);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'x');
      await tester.pump();
      expect(controller.draft.text, 'h');
      // No text box focused: Esc hides the floater.
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(window.shown, isNull);
      await settle(tester);
    });

    testWidgets('Vim switched off while in Normal leaves a plain field', (
      tester,
    ) async {
      await start(tester, const GaiaTextSettings(vim: true));
      await type(tester, 'hi');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      main.notify('text', GaiaTextSettings.off.toJson());
      await tester.pump();
      await tester.pump();
      expect(find.byType(VimTextOverlay), findsNothing);
      // Typing goes in where Normal left the caret: on the i.
      await type(tester, 'x');
      expect(controller.draft.text, 'hxi');
      await settle(tester);
    });

    testWidgets('without Vim the composer eats Esc too', (tester) async {
      await start(tester, GaiaTextSettings.off);
      window.shown = GaiaMode.small;
      await type(tester, 'hi');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(window.shown, GaiaMode.small);
      expect(controller.draft.text, 'hi');
      await settle(tester);
    });

    testWidgets('Add to dictionary asks the main instance', (tester) async {
      await start(tester, GaiaTextSettings.off);
      await controller.addWord('Voyager');
      expect(requests, contains('addWord Voyager'));
      await settle(tester);
    });

    // GAIA_NATIVE_COMMANDS.md §5.
    group("Enter on a CLI's command", () {
      Future<_NativeRunner> startNative(WidgetTester tester) async {
        final runner = _NativeRunner()..sendError = StateError('not run');
        await start(tester, GaiaTextSettings.off, runner: runner);
        // The CLI's list is read on the palette's first look.
        controller.nativeCommands;
        await tester.pump();
        return runner;
      }

      testWidgets('sends one that takes no arguments', (tester) async {
        final runner = await startNative(tester);
        await type(tester, '/cont');
        expect(find.byKey(const ValueKey('/context')), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(runner.sent.single.prompt, '/context');
        await settle(tester);
      });

      testWidgets('waits for the arguments of one that takes them', (
        tester,
      ) async {
        final runner = await startNative(tester);
        await type(tester, '/compa');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(controller.draft.text, '/compact ');
        expect(runner.sent, isEmpty);
        await settle(tester);
      });

      testWidgets("a standalone command of the user's sends too", (
        tester,
      ) async {
        final runner = await startNative(tester);
        controller.commands = const [
          GaiaCommand(name: 'tidy', template: 'Tidy it', standalone: true),
        ];
        await type(tester, '/tid');
        expect(find.byKey(const ValueKey('/tidy')), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump(const Duration(seconds: 1));
        expect(runner.sent.single.prompt, contains('Tidy it'));
        await settle(tester);
      });

      testWidgets('mid-reply, picking one waits rather than stopping it', (
        tester,
      ) async {
        final runner = await startNative(tester);
        runner
          ..sendError = null
          ..turns.add([const ClaudeTextStart()]);
        controller.send('hi');
        await tester.pump();
        expect(controller.currentRunning, isTrue);
        await type(tester, '/cont');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump(const Duration(seconds: 1));
        expect(runner.stopped, isEmpty);
        expect(controller.draft.text, '/context');
        await controller.stop(controller.currentChatId!);
        await settle(tester);
      });

      testWidgets('beside attachments, picking one gives them back unsent', (
        tester,
      ) async {
        final runner = await startNative(tester);
        await controller.attachPaths(['C:/notes.txt']);
        await type(tester, '/cont');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump(const Duration(seconds: 1));
        expect(runner.sent, isEmpty);
        expect(controller.draft.text, '/context');
        expect(controller.draftFiles, hasLength(1));
        await settle(tester);
      });

      testWidgets('Tab only completes it', (tester) async {
        final runner = await startNative(tester);
        await type(tester, '/cont');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(controller.draft.text, '/context ');
        expect(runner.sent, isEmpty);
        await settle(tester);
      });

      testWidgets("/usage is Gaia's, and shows the usage bars", (tester) async {
        final runner = await startNative(tester);
        await type(tester, '/usage');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(find.text('Usage'), findsOneWidget);
        expect(runner.sent, isEmpty);
        expect(controller.draft.text, isEmpty);
        await settle(tester);
      });
    });
  });
}

/// A Claude runner whose CLI has commands of its own.
class _NativeRunner extends FakeClaudeRunner implements GaiaNativeCommander {
  @override
  Future<List<GaiaNativeCommand>> nativeCommands(GaiaAccount? account) async =>
      const [
        (name: 'context', description: 'Show context usage', argumentHint: ''),
        (
          name: 'compact',
          description: 'Free up context',
          argumentHint: '<instructions>',
        ),
        (name: 'usage', description: "The CLI's usage", argumentHint: ''),
      ];
}
