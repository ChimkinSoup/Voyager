import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_btw.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_markdown.dart';
import 'package:voyager/features/gaia/companion/gaia_steady_list.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';
import 'package:voyager/features/gaia/gaia_text_settings.dart';

import 'fakes/gaia_fakes.dart';

/// The side questions' chip and dock (GAIA_BTW_HLD.md §8): the chip opens
/// them at the newest, Up and Down move along them, and X clears them.
void main() {
  final at = DateTime.utc(2026, 11, 9);

  GaiaBtw btw(String id, String question, String answer, int minutes) =>
      GaiaBtw(
        id: id,
        chatId: 'c1',
        question: question,
        answer: answer,
        status: GaiaMessageStatus.complete,
        anchorSeq: 1,
        deviceId: 'laptop',
        createdAt: at.add(Duration(minutes: minutes)),
        updatedAt: at.add(Duration(minutes: minutes)),
      );

  late List<String> requests;
  late List<GaiaBtw> stored;
  late FakeClaudeRunner runner;

  Future<GaiaController> pump(
    WidgetTester tester, {
    int count = 2,
    List<GaiaBtw>? btws,
    List<GaiaMessage> messages = const [],
    Size size = const Size(1100, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    requests = [];
    stored =
        btws ??
        (count == 2
            ? [
                btw('b1', 'Older question?', 'Older answer.', 0),
                btw('b2', 'Newer question?', 'Newer answer.', 1),
              ]
            : [
                for (var i = 1; i <= count; i++)
                  btw('b$i', 'Question $i?', 'Answer $i.', i),
              ]);
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        requests.add(method);
        switch (method) {
          case 'hello':
            return {
              'aborted': false,
              'accent': 0xFF7C9EFF,
              'deviceId': 'laptop',
              'settings': GaiaSettings.initial().toJson(),
            };
          case 'chats':
            return [
              GaiaChat(
                id: 'c1',
                title: 'Parser',
                createdAt: at,
                updatedAt: at,
                lastMessageAt: at,
                tier: GaiaTier.standard,
              ).toJson(),
            ];
          case 'messages':
            return [for (final message in messages) message.toJson()];
          case 'btws':
            return [for (final btw in stored) btw.toJson()];
          case 'clearBtws':
            final ids = [for (final btw in stored) btw.id];
            stored = [];
            return ids;
          case 'drafts':
            return <Object?>[];
          case 'remember':
            return {'saved': true};
        }
        return null;
      };
    await main.startCompanion();
    runner = FakeClaudeRunner();
    final controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {kGaiaClaudeCodeAdapter: runner},
      cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
      exit: (_) {},
    );
    await tester.runAsync(() async {
      await controller.start();
      await controller.openWindow();
      await controller.selectChat('c1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    return controller;
  }

  String answerShown(WidgetTester tester) =>
      tester.widget<GaiaMarkdown>(find.byType(GaiaMarkdown).last).text;

  testWidgets('the chip opens them at the newest; the keys move and clear', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('2 btws'), findsOneWidget);
    final field = tester.getRect(find.byType(GaiaTextField));

    await tester.tap(find.text('2 btws'));
    await tester.pumpAndSettle();
    expect(find.text('Newer question?'), findsWidgets);
    expect(answerShown(tester), 'Newer answer.');

    // Floating on the field's top edge, as wide as it, with nothing pushed
    // up and no dialog over the chat; its clear is Gaia's.
    expect(find.byType(ModalBarrier), findsOneWidget);
    expect(tester.getRect(find.byType(GaiaTextField)), field);
    final dock = tester.getRect(find.byType(GaiaBtwDock));
    expect(dock.bottom, field.top);
    expect(dock.left, field.left);
    expect(dock.right, field.right);
    expect(
      find.descendant(
        of: find.byTooltip('Clear history (Alt+X)'),
        matching: find.byType(GaiaButton),
      ),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(answerShown(tester), 'Older answer.');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(answerShown(tester), 'Newer answer.');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(requests, contains('clearBtws'));
    expect(
      find.text(
        'No side questions in this chat yet. Ask one with /btw <question>.',
      ),
      findsOneWidget,
    );
    expect(find.text('Cleared side questions'), findsOneWidget);

    // Esc closes it; with none left, so does the chip.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('2 btws'), findsNothing);
  });

  testWidgets('five show; Up and Down from the composer move along them, '
      'scrolling the one selected into view', (tester) async {
    await pump(tester, count: 8);
    await tester.tap(find.text('8 btws'));
    await tester.pumpAndSettle();
    final list = find.descendant(
      of: find.byType(GaiaBtwDock),
      matching: find.byType(ListView),
    );
    bool shown(String question) {
      final row = find.descendant(of: list, matching: find.text(question));
      if (row.evaluate().isEmpty) return false;
      final box = tester.getRect(list);
      final rect = tester.getRect(row);
      return rect.top >= box.top && rect.bottom <= box.bottom;
    }

    // Newest first: 8 down to 4 in view, 3 below.
    expect([
      for (var i = 8; i >= 4; i--) shown('Question $i?'),
    ], everyElement(isTrue));
    expect(shown('Question 3?'), isFalse);

    // In the composer, the arrows still go to them.
    await tester.tap(find.byType(GaiaTextField));
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(answerShown(tester), 'Answer 2.');
    expect(shown('Question 2?'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(answerShown(tester), 'Answer 3.');
  });

  testWidgets('a letter types rather than acting; a wrapped draft keeps the '
      'arrows; Esc from the composer closes them', (tester) async {
    final controller = await pump(tester);
    await tester.tap(find.text('2 btws'));
    await tester.pumpAndSettle();

    // From the panel, F goes to the composer, not to a fork.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(controller.draft.text, 'f');
    expect(find.byType(GaiaBtwDock), findsOneWidget);
    expect(answerShown(tester), 'Newer answer.');

    // A draft wrapped over lines, with none broken: Down is the caret's.
    await tester.enterText(find.byType(GaiaTextField), 'word ' * 80);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(answerShown(tester), 'Newer answer.');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(GaiaMarkdown), findsNothing);
  });

  testWidgets('with Vim, Esc in Insert goes to Normal; the next closes them', (
    tester,
  ) async {
    final controller = await pump(tester);
    controller.textSettings.value = const GaiaTextSettings(vim: true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 btws'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(GaiaTextField));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('NORMAL'), findsOneWidget);
    expect(find.byType(GaiaBtwDock), findsOneWidget);
    expect(answerShown(tester), 'Newer answer.');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(GaiaMarkdown), findsNothing);
  });

  testWidgets('a shorter answer shows whole, with no scrollbar', (
    tester,
  ) async {
    final long = [for (var i = 1; i <= 9; i++) 'Paragraph $i of it.'];
    final controller = await pump(
      tester,
      btws: [btw('b1', 'Long?', long.join('\n\n'), 0)],
      size: const Size(1100, 560),
    );
    controller.openBtws();
    await tester.pumpAndSettle();
    expect(answerShown(tester), long.join('\n\n'));

    final answer = find.descendant(
      of: find.byType(GaiaBtwDock),
      matching: find.byType(SingleChildScrollView),
    );
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: answer, matching: find.byType(Scrollable)).first,
        )
        .position;
    expect(position.maxScrollExtent, 0);
    expect(
      find.descendant(of: answer, matching: find.byType(Scrollbar)),
      findsNothing,
    );
    // Under the header still.
    expect(tester.getRect(find.byType(GaiaBtwDock)).top, greaterThan(53));
  });

  testWidgets('a long answer stops at 420px and scrolls, the list aside', (
    tester,
  ) async {
    final long = [for (var i = 1; i <= 40; i++) 'Paragraph $i of it.'];
    final controller = await pump(
      tester,
      btws: [
        btw('b1', 'Short?', 'Short.', 0),
        btw('b2', 'Long?', long.join('\n\n'), 1),
      ],
      size: const Size(1100, 1200),
    );
    controller.openBtws();
    await tester.pumpAndSettle();
    expect(answerShown(tester), long.join('\n\n'));

    final answer = find.descendant(
      of: find.byType(GaiaBtwDock),
      matching: find.byType(SingleChildScrollView),
    );
    expect(tester.getSize(answer).height, 420);
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: answer, matching: find.byType(Scrollable)).first,
        )
        .position;
    expect(position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('a row lights under the mouse', (tester) async {
    await pump(tester);
    await tester.tap(find.text('2 btws'));
    await tester.pumpAndSettle();
    Color? color() =>
        tester.widget<Text>(find.text('Older question?')).style?.color;
    expect(color(), isNot(Colors.white));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Older question?')));
    await tester.pumpAndSettle();
    expect(color(), Colors.white);
  });

  testWidgets('a code block\'s copy button shows its tooltip on hover', (
    tester,
  ) async {
    await pump(
      tester,
      btws: [btw('b1', 'Code?', 'Here:\n\n```\nfoo()\n```', 0)],
    );
    await tester.tap(find.text('1 btw'));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byTooltip('Copy code')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Copy code'), findsOneWidget);
  });

  // The composer's chips float over the chat's foot (GAIA_BTW_HLD.md §8.2).
  final chat = [
    for (var seq = 1; seq <= 20; seq++)
      GaiaMessage(
        id: 'm$seq',
        chatId: 'c1',
        seq: seq,
        role: seq.isOdd ? GaiaMessageRole.user : GaiaMessageRole.assistant,
        parts: [
          GaiaTextPart(
            [for (var i = 0; i < 6; i++) 'line $i of $seq'].join('\n\n'),
          ),
        ],
        status: GaiaMessageStatus.complete,
        createdAt: at,
        updatedAt: at,
      ),
  ];
  Rect lastLine(WidgetTester tester) => tester.getRect(
    find.textContaining('line 5 of 20', findRichText: true).last,
  );

  testWidgets('at the bottom, the last message clears the chips by as much '
      'as it clears the field without them', (tester) async {
    await pump(tester, btws: [], messages: chat);
    await tester.pumpAndSettle();
    final field = tester.getRect(find.byType(GaiaTextField));
    final bare = field.top - lastLine(tester).bottom;

    await pump(tester, messages: chat);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(GaiaTextField)), field);
    // As far under the top chip as under the field without it.
    final chip = tester.getRect(find.byType(GaiaBtwChip));
    expect(chip.top - lastLine(tester).bottom, closeTo(bare, 0.5));
  });

  testWidgets('scrolled up, the text runs under the chips, and stays put '
      'as one comes', (tester) async {
    final controller = await pump(tester, messages: chat);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(GaiaSteadyList), const Offset(0, 300));
    await tester.pumpAndSettle();
    final field = tester.getRect(find.byType(GaiaTextField));
    final chip = tester.getRect(find.text('2 btws'));
    // The list runs on down to the field, under the chips.
    expect(
      tester.getRect(find.byType(GaiaSteadyList)).bottom,
      closeTo(field.top, 0.5),
    );
    expect(chip.bottom, lessThan(field.top));
    final line = find.textContaining('line 0 of 19', findRichText: true);
    final before = tester.getRect(line.last);

    controller.attachMessage(chat[3]);
    await tester.pumpAndSettle();
    expect(tester.getRect(line.last), before);
    // Still clickable over the text.
    await tester.tap(find.text('2 btws'));
    await tester.pumpAndSettle();
    expect(answerShown(tester), 'Newer answer.');
  });

  testWidgets('scrolled up, the to-bottom button rises only over what floats '
      'under it', (tester) async {
    final controller = await pump(tester, messages: chat);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(GaiaSteadyList), const Offset(0, 300));
    await tester.pumpAndSettle();
    Rect button() => tester.getRect(
      find
          .ancestor(
            of: find.byIcon(Icons.keyboard_double_arrow_down_rounded),
            matching: find.byType(Material),
          )
          .first,
    );
    final field = tester.getRect(find.byType(GaiaTextField));
    // The btws chip is off to the left: nothing's under it.
    expect(button().bottom, closeTo(field.top - 20, 0.5));

    // A quote long enough to run under it.
    controller.attachMessage(
      chat.first.copyWith(parts: [GaiaTextPart('a long quote ' * 20)]),
    );
    await tester.pumpAndSettle();
    final quote = tester.getRect(
      find
          .ancestor(
            of: find.byIcon(Icons.format_quote),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(quote.right, greaterThan(button().left));
    expect(button().bottom, closeTo(quote.top - 20, 0.5));
  });

  testWidgets('the arrows move along them', (tester) async {
    await pump(tester);
    await tester.tap(find.text('2 btws'));
    await tester.pumpAndSettle();
    expect(find.text('Older question?'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(answerShown(tester), 'Older answer.');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('/btw alone opens them', (tester) async {
    final controller = await pump(tester);
    controller.send('/btw');
    await tester.pumpAndSettle();
    expect(answerShown(tester), 'Newer answer.');
  });

  testWidgets('/btw picked from the palette with no question opens them', (
    tester,
  ) async {
    final controller = await pump(tester);
    await tester.enterText(find.byType(GaiaTextField), '/btw');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(GaiaMarkdown), findsWidgets);
    expect(answerShown(tester), 'Newer answer.');
    expect(controller.draft.text, '');
  });

  testWidgets('a click in the composer keeps them open; one outside both '
      'closes them', (tester) async {
    final controller = await pump(tester);
    await tester.tap(find.text('2 btws'));
    await tester.pumpAndSettle();
    expect(controller.btwPanelOpen, isTrue);

    await tester.tap(find.byType(GaiaTextField));
    await tester.pumpAndSettle();
    expect(controller.btwPanelOpen, isTrue);

    await tester.tapAt(const Offset(550, 120));
    await tester.pumpAndSettle();
    expect(controller.btwPanelOpen, isFalse);
    expect(find.byType(GaiaMarkdown), findsNothing);
  });

  testWidgets('they open again at the one last viewed', (tester) async {
    final controller = await pump(tester);
    controller.openBtws();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(answerShown(tester), 'Older answer.');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    controller.openBtws();
    await tester.pumpAndSettle();
    expect(answerShown(tester), 'Older answer.');
  });

  testWidgets('mid-reply, the button sends /btw, /queue and /remember rather '
      'than stopping the reply', (tester) async {
    final controller = await pump(tester);
    // A reply that hangs, mid-stream.
    runner.turns.add([
      const ClaudeTextStart(),
      const ClaudeTextDelta('Working on it'),
    ]);
    controller.send('Do the thing');
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentRunning, isTrue);
    expect(find.byIcon(Icons.stop), findsOneWidget);

    controller.draft.text = '/btw what is it doing?';
    await tester.pump();
    runner.turns.add([
      const ClaudeTextStart(),
      const ClaudeTextDelta('Partly'),
    ]);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump(const Duration(seconds: 1));
    expect(runner.stopped, isEmpty);
    expect(controller.currentRunning, isTrue);
    expect(controller.draft.text, '');
    expect(
      controller.btwsFor('c1').map((btw) => btw.question),
      contains('what is it doing?'),
    );

    // So do /queue and /remember, which also never stop the reply.
    for (final (draft, method) in [
      ('/queue then this', 'enqueue'),
      ('/remember I like tea', 'remember'),
    ]) {
      controller.draft.text = draft;
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump(const Duration(seconds: 1));
      expect(requests, contains(method), reason: draft);
      expect(runner.stopped, isEmpty, reason: draft);
      expect(controller.currentRunning, isTrue, reason: draft);
      expect(controller.draft.text, '', reason: draft);
    }

    // Any other draft: the button is the reply's stop again.
    controller.draft.text = 'later';
    await tester.pump();
    expect(find.byIcon(Icons.arrow_upward), findsNothing);

    // Both runs ended, so none of their timers outlives the test.
    for (final btw in controller.btwsFor('c1')) {
      if (controller.btwRunning(btw.id)) unawaited(controller.stopBtw(btw.id));
    }
    unawaited(controller.stop('c1'));
    await tester.pump(const Duration(seconds: 10));
  });
}
