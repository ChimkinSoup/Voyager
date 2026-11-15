import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';

import 'fakes/gaia_fakes.dart';

/// Up and Down through what the composer sent (GAIA_HISTORY_HLD.md §3–4).
void main() {
  final at = DateTime.utc(2026, 11, 14);

  GaiaChat chat(String id) => GaiaChat(
    id: id,
    title: id,
    createdAt: at,
    updatedAt: at,
    lastMessageAt: at,
    tier: GaiaTier.standard,
  );

  Future<GaiaController> pump(
    WidgetTester tester, {
    List<String> history = const [],
    bool btws = false,
  }) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async => switch (method) {
        'hello' => {
          'aborted': false,
          'accent': 0xFF7C9EFF,
          'deviceId': 'laptop',
          'settings': GaiaSettings.initial().toJson(),
        },
        'chats' => [chat('c1').toJson(), chat('c2').toJson()],
        'btws' when btws && params['chatId'] != 'c2' => [
          GaiaBtw(
            id: 'b1',
            chatId: 'c1',
            question: 'Side?',
            answer: 'Answer.',
            status: GaiaMessageStatus.complete,
            anchorSeq: 1,
            deviceId: 'laptop',
            createdAt: at,
            updatedAt: at,
          ).toJson(),
        ],
        'messages' || 'drafts' || 'btws' => <Object?>[],
        'remember' => {'saved': true},
        _ => null,
      };
    await main.startCompanion();
    final controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {kGaiaClaudeCodeAdapter: FakeClaudeRunner()},
      cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
      exit: (_) {},
    );
    for (final text in history) {
      controller.history.add(text);
    }
    await tester.runAsync(() async {
      await controller.start();
      await controller.openWindow();
      await controller.selectChat('c1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byType(GaiaTextField));
    await tester.pump();
    return controller;
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  Future<void> up(WidgetTester tester) =>
      key(tester, LogicalKeyboardKey.arrowUp);
  Future<void> down(WidgetTester tester) =>
      key(tester, LogicalKeyboardKey.arrowDown);

  Future<void> send(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(GaiaTextField), text);
    await tester.pump();
  }

  /// [testWidgets], letting the draft's save and the tree's timers finish.
  void check(String description, WidgetTesterCallback body) =>
      testWidgets(description, (tester) async {
        await body(tester);
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
      });

  List<String> texts(GaiaController controller) => [
    for (final entry in controller.history.entries) entry.text,
  ];

  check('Up from empty recalls the newest, caret at its end; Down past '
      'the newest empties', (tester) async {
    final controller = await pump(tester, history: ['one', 'two']);
    final draft = controller.draft;
    await down(tester);
    expect(draft.text, '');
    await up(tester);
    expect(draft.text, 'two');
    expect(draft.selection, const TextSelection.collapsed(offset: 3));
    await up(tester);
    expect(draft.text, 'one');
    await up(tester);
    expect(draft.text, 'one', reason: 'nothing older');
    await down(tester);
    expect(draft.text, 'two');
    await down(tester);
    expect(draft.text, '');
    // Over: Down does nothing, and Up starts at the newest again.
    await down(tester);
    expect(draft.text, '');
    await up(tester);
    expect(draft.text, 'two');
  });

  check('an untouched multi-line entry steps from any line', (tester) async {
    final controller = await pump(tester, history: ['a', 'l1\nl2\nl3']);
    final draft = controller.draft;
    await up(tester);
    expect(draft.text, 'l1\nl2\nl3');
    await up(tester);
    expect(draft.text, 'a', reason: 'from its last line');
    await down(tester);
    draft.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    await down(tester);
    expect(draft.text, '', reason: 'from its first line');
  });

  check('an edited multi-line entry moves the caret to its edge, then '
      'steps, its edit gone', (tester) async {
    final controller = await pump(tester, history: ['a', 'l1\nl2\nl3']);
    final draft = controller.draft;
    await up(tester);
    draft.value = const TextEditingValue(
      text: 'l1\nl2\nl3x',
      selection: TextSelection.collapsed(offset: 9),
    );
    await tester.pump();
    await up(tester);
    expect(draft.text, 'l1\nl2\nl3x');
    expect(draft.selection.baseOffset, lessThan(6));
    await up(tester);
    expect(draft.text, 'l1\nl2\nl3x');
    expect(draft.selection.baseOffset, lessThan(3));
    await up(tester);
    expect(draft.text, 'a');
    await down(tester);
    expect(draft.text, 'l1\nl2\nl3', reason: 'as recorded');
  });

  check('wrapped lines count as lines for an edited entry', (tester) async {
    final long = 'word ' * 80;
    final controller = await pump(tester, history: ['a', long]);
    final draft = controller.draft;
    await up(tester);
    draft.value = TextEditingValue(
      text: '${long}x',
      selection: TextSelection.collapsed(offset: long.length + 1),
    );
    await tester.pump();
    await up(tester);
    expect(draft.text, '${long}x', reason: 'the caret moved up instead');
  });

  check('a recalled /new keeps its palette shut, and sends', (tester) async {
    final controller = await pump(tester, history: ['/window', 'b']);
    final draft = controller.draft;
    await up(tester);
    await up(tester);
    expect(draft.text, '/window');
    expect(find.byKey(const ValueKey('/window')), findsNothing);
    // Its Down steps rather than moving a highlight.
    await down(tester);
    expect(draft.text, 'b');
    await up(tester);
    await send(tester);
    expect(draft.text, '');
    expect(texts(controller), ['/window', 'b', '/window']);
  });

  check('once the browse ends, the recalled command typed by hand opens '
      'the palette', (tester) async {
    final controller = await pump(tester, history: ['/window']);
    await up(tester);
    expect(controller.draft.text, '/window');
    await down(tester);
    expect(controller.draft.text, '');
    await type(tester, '/window');
    expect(find.byKey(const ValueKey('/window')), findsOneWidget);
  });

  check('undo after a browse goes back to the recalled entry, not through '
      'those passed', (tester) async {
    final controller = await pump(tester, history: ['one', 'two']);
    final draft = controller.draft;
    await up(tester);
    await tester.pump(const Duration(seconds: 1));
    await up(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(draft.text, 'one');
    controller.draftUndo.undo();
    await tester.pump();
    expect(draft.text, 'one');
  });

  check('with the side questions open, Up and Down never browse', (
    tester,
  ) async {
    final controller = await pump(tester, history: ['one'], btws: true);
    await tester.tap(find.text('1 btw'));
    await tester.pumpAndSettle();
    expect(controller.btwPanelOpen, isTrue);
    await up(tester);
    await down(tester);
    expect(controller.draft.text, '');
  });

  check('a typed draft never starts a browse', (tester) async {
    final controller = await pump(tester, history: ['one']);
    await type(tester, 'hello');
    await up(tester);
    expect(controller.draft.text, 'hello');
  });

  check('sends that happen are recorded as typed; turned away, not', (
    tester,
  ) async {
    final controller = await pump(tester);
    await type(tester, '/remember the floater');
    await send(tester);
    expect(texts(controller), ['/remember the floater']);

    await type(tester, '/zzzunknown');
    await send(tester);
    expect(controller.draft.text, '/zzzunknown');
    expect(texts(controller), ['/remember the floater']);

    // Picked from the palette, by its name.
    await type(tester, '/windo');
    await key(tester, LogicalKeyboardKey.enter);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(texts(controller).last, '/window');
  });

  check('a chat switch ends the browse; its text stays as a draft', (
    tester,
  ) async {
    final controller = await pump(tester, history: ['one', 'two']);
    await up(tester);
    expect(controller.draft.text, 'two');
    await tester.runAsync(() => controller.selectChat('c2'));
    await tester.pump();
    await tester.runAsync(() => controller.selectChat('c1'));
    await tester.pump();
    await tester.tap(find.byType(GaiaTextField));
    await tester.pump();
    expect(controller.draft.text, 'two');
    await up(tester);
    expect(controller.draft.text, 'two', reason: 'a typed draft now');
  });
}
