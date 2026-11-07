import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/companion/gaia_activity_chip.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_pinned_prompt.dart';
import 'package:voyager/features/gaia/companion/gaia_steady_list.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

import 'fakes/gaia_fakes.dart';

/// The chat keeps the message being read in place when more arrives below it
/// while scrolled up, and follows the newest at the bottom.
void main() {
  final at = DateTime.utc(2026, 10, 30);

  GaiaMessage message(int seq, {int lines = 12}) => GaiaMessage(
    id: 'm$seq',
    chatId: 'c1',
    seq: seq,
    role: seq.isOdd ? GaiaMessageRole.user : GaiaMessageRole.assistant,
    parts: [
      GaiaTextPart(
        ['marker$seq.', for (var i = 0; i < lines; i++) 'line $i'].join('\n\n'),
      ),
    ],
    status: GaiaMessageStatus.complete,
    createdAt: at,
    updatedAt: at,
  );

  late List<GaiaMessage> messages;
  late FakeGaiaPipe main;
  late FakeClaudeRunner runner;
  late GaiaController controller;

  final list = find.byWidgetPredicate(
    (widget) => widget is ListView && widget.reverse,
  );

  // In the list, not the pinned prompt over it.
  Finder marker(int seq) => find.descendant(
    of: list,
    matching: find.textContaining('marker$seq.', findRichText: true),
  );

  ScrollController scroll(WidgetTester tester) =>
      tester.widget<ListView>(list).controller!;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump();
    }
    // Past the draft's save.
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    messages = [for (var seq = 1; seq <= 30; seq++) message(seq)];
    main = FakeGaiaPipe.main();
    runner = FakeClaudeRunner();
    late FakeGaiaPipe companion;
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
        'chats' => [
          GaiaChat(
            id: 'c1',
            title: 'Hi',
            createdAt: at,
            updatedAt: at,
            lastMessageAt: at,
          ).toJson(),
        ],
        'messages' => [for (final message in messages) message.toJson()],
        'drafts' => <Object?>[],
        _ => null,
      };
    await main.startCompanion();
    controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {kGaiaClaudeCodeAdapter: runner},
      cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
      exit: (_) {},
    );
    await controller.start();
    await settle(tester);
    // Its scrolling animates only on screen.
    controller.onScreen.value = true;
    await tester.pumpWidget(GaiaApp(controller: controller));
    await controller.selectChat('c1');
    await settle(tester);
  }

  /// [changes] arrives from the main instance, and the list settles.
  Future<void> sync(WidgetTester tester, void Function() changes) async {
    changes();
    main.notify('changed');
    await settle(tester);
  }

  /// Scrolled to [offset], the message whose marker's nearest the list's
  /// middle. A long message's can be just off screen.
  Future<int> scrollTo(WidgetTester tester, double offset) async {
    scroll(tester).jumpTo(offset);
    await tester.pump();
    await tester.pump();
    final middle = tester.getCenter(list).dy;
    final built = [
      for (var seq = 1; seq <= messages.length; seq++)
        if (marker(seq).evaluate().isNotEmpty) seq,
    ];
    double away(int seq) => (tester.getTopLeft(marker(seq)).dy - middle).abs();
    return built.reduce((a, b) => away(a) <= away(b) ? a : b);
  }

  for (final offset in [200.0, 1500.0, 6000.0]) {
    testWidgets('a new reply leaves the message at offset $offset in place', (
      tester,
    ) async {
      await start(tester);
      final seq = await scrollTo(tester, offset);
      final before = tester.getTopLeft(marker(seq)).dy;

      await sync(tester, () => messages.add(message(31, lines: 40)));

      expect(tester.getTopLeft(marker(seq)).dy, moreOrLessEquals(before));
    });

    testWidgets('the latest reply growing leaves offset $offset in place', (
      tester,
    ) async {
      await start(tester);
      final seq = await scrollTo(tester, offset);
      final before = tester.getTopLeft(marker(seq)).dy;

      await sync(tester, () => messages.last = message(30, lines: 40));

      expect(tester.getTopLeft(marker(seq)).dy, moreOrLessEquals(before));
    });
  }

  testWidgets('what arrives below never shows the list moved, even a frame', (
    tester,
  ) async {
    await start(tester);
    final seq = await scrollTo(tester, 200);
    final before = tester.getTopLeft(marker(seq)).dy;

    for (var lines = 13; lines < 40; lines++) {
      messages.last = message(30, lines: lines);
      main.notify('changed');
      // Each frame as it was painted, with nothing run after it.
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(marker(seq)).dy, moreOrLessEquals(before));
      }
    }
    await settle(tester);
  });

  testWidgets('a message synced in below, between others, leaves it in place', (
    tester,
  ) async {
    await start(tester);
    final seq = await scrollTo(tester, 1500);
    final before = tester.getTopLeft(marker(seq)).dy;

    await sync(tester, () => messages.insert(seq, message(99)));

    expect(tester.getTopLeft(marker(seq)).dy, moreOrLessEquals(before));
  });

  testWidgets('a reply that grows far past what is built leaves it in place', (
    tester,
  ) async {
    await start(tester);
    final seq = await scrollTo(tester, 200);
    final before = tester.getTopLeft(marker(seq)).dy;

    await sync(tester, () => messages.last = message(30, lines: 400));

    expect(tester.getTopLeft(marker(seq)).dy, moreOrLessEquals(before));
  });

  for (final from in [0.0, 100.0]) {
    testWidgets('the pinned prompt clicked from $from goes to it and stays, '
        'as its reply grows', (tester) async {
      await start(tester);
      // Taller than the list, so its prompt's pinned.
      await sync(tester, () => messages.last = message(30, lines: 80));

      Future<void> click() async {
        await scrollTo(tester, from);
        await tester.pump(const Duration(milliseconds: 200));
        final prompt = tester.widget<GaiaPinnedPrompt>(
          find.byType(GaiaPinnedPrompt),
        );
        expect(prompt.id, 'm29');
        await tester.tap(find.byType(GaiaPinnedPrompt));
      }

      // Where it lands with nothing arriving.
      await click();
      await settle(tester);
      final landed = tester.getTopLeft(marker(29)).dy;
      expect(landed, inInclusiveRange(0, 100));

      // Again, with the reply growing all the way there and after.
      await click();
      var lines = 80;
      for (var i = 0; i < 60; i++) {
        messages.last = message(30, lines: ++lines);
        main.notify('changed');
        await tester.pump(const Duration(milliseconds: 16));
      }
      for (var i = 0; i < 30; i++) {
        messages.last = message(30, lines: ++lines);
        main.notify('changed');
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(marker(29)).dy, moreOrLessEquals(landed));
      }
      await settle(tester);
      expect(tester.getTopLeft(marker(29)).dy, moreOrLessEquals(landed));
    });
  }

  testWidgets('landed on the pinned prompt, the wheel still scrolls away, '
      'and it holds there instead', (tester) async {
    await start(tester);
    await sync(tester, () => messages.last = message(30, lines: 80));
    await scrollTo(tester, 100);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byType(GaiaPinnedPrompt));
    await settle(tester);
    final landed = tester.getTopLeft(marker(29)).dy;

    final wheel = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(wheel.hover(tester.getCenter(list)));
    await tester.sendEventToBinding(wheel.scroll(const Offset(0, -100)));
    await tester.pump();
    final moved = tester.getTopLeft(marker(29)).dy;
    expect(moved, moreOrLessEquals(landed + 100));

    await sync(tester, () => messages.last = message(30, lines: 120));

    expect(tester.getTopLeft(marker(29)).dy, moreOrLessEquals(moved));
  });

  testWidgets('under reduced motion, the pinned prompt clicked goes to it and '
      'stays too', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await start(tester);
    await sync(tester, () => messages.last = message(30, lines: 80));
    await scrollTo(tester, 100);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byType(GaiaPinnedPrompt));
    await settle(tester);
    final landed = tester.getTopLeft(marker(29)).dy;
    expect(landed, inInclusiveRange(0, 100));

    await sync(tester, () => messages.last = message(30, lines: 120));

    expect(tester.getTopLeft(marker(29)).dy, moreOrLessEquals(landed));
  });

  testWidgets('holds through several replies, and from where it was scrolled '
      'to since', (tester) async {
    await start(tester);
    var seq = await scrollTo(tester, 200);
    var before = tester.getTopLeft(marker(seq)).dy;
    await sync(tester, () => messages.add(message(31)));
    await sync(tester, () => messages.add(message(32)));
    expect(tester.getTopLeft(marker(seq)).dy, moreOrLessEquals(before));

    seq = await scrollTo(tester, scroll(tester).offset + 300);
    before = tester.getTopLeft(marker(seq)).dy;
    await sync(tester, () => messages.add(message(33)));
    expect(tester.getTopLeft(marker(seq)).dy, moreOrLessEquals(before));
  });

  testWidgets('closed while Gaia replies, it reopens on the same message', (
    tester,
  ) async {
    await start(tester);
    final seq = await scrollTo(tester, 200);
    final before = tester.getTopLeft(marker(seq)).dy;

    controller.onScreen.value = false;
    await sync(tester, () => messages.add(message(31, lines: 40)));
    await sync(tester, () => messages.add(message(32, lines: 40)));
    controller.onScreen.value = true;
    await settle(tester);

    expect(tester.getTopLeft(marker(seq)).dy, moreOrLessEquals(before));
  });

  testWidgets('at the bottom it follows the newest', (tester) async {
    await start(tester);
    expect(scroll(tester).offset, 0);

    await sync(tester, () => messages.add(message(31)));

    expect(scroll(tester).offset, 0);
    expect(marker(31), findsOneWidget);
  });

  testWidgets('scrolled back to the bottom, it follows again', (tester) async {
    await start(tester);
    await scrollTo(tester, 200);
    await sync(tester, () => messages.add(message(31)));

    scroll(tester).jumpTo(0);
    await settle(tester);
    await sync(tester, () => messages.add(message(32)));

    expect(scroll(tester).offset, 0);
    expect(marker(32), findsOneWidget);
  });

  testWidgets('scrolled up, a button goes back down to the newest', (
    tester,
  ) async {
    await start(tester);
    final button = find.byIcon(Icons.keyboard_double_arrow_down_rounded);
    expect(button, findsNothing);

    await scrollTo(tester, 1500);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(button);
    await settle(tester);

    expect(scroll(tester).offset, 0);
    // Through its fade out.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(button, findsNothing);
  });

  testWidgets('just under 100 px up, there is no button', (tester) async {
    await start(tester);
    scroll(tester).jumpTo(100);
    await settle(tester);

    expect(
      find.byIcon(Icons.keyboard_double_arrow_down_rounded),
      findsNothing,
    );
  });

  testWidgets('fading out, the button no longer takes clicks', (tester) async {
    await start(tester);
    final button = find.byIcon(Icons.keyboard_double_arrow_down_rounded);
    await scrollTo(tester, 1500);
    await tester.pump(const Duration(milliseconds: 200));

    scroll(tester).jumpTo(50);
    // One frame for the list, one for the button to start fading.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(button, findsOneWidget);
    await tester.tap(button, warnIfMissed: false);
    await settle(tester);

    expect(scroll(tester).offset, 50);
  });

  testWidgets('under reduced motion, the button jumps to the newest', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await start(tester);
    await scrollTo(tester, 1500);
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byIcon(Icons.keyboard_double_arrow_down_rounded));
    await tester.pump();

    expect(scroll(tester).offset, 0);
  });

  testWidgets('the latest reply kept built off screen still holds its place', (
    tester,
  ) async {
    await start(tester);
    // Taller than the list, so it's the one across the top.
    await sync(tester, () => messages.last = message(30, lines: 80));
    await scrollTo(tester, 100);
    final before = tester.getTopLeft(marker(30)).dy;
    expect(before, lessThan(0));

    // Still the latest reply, so kept alive when this pushes it out.
    await sync(tester, () => messages.add(message(31, lines: 200)));

    expect(tester.getTopLeft(marker(30)).dy, moreOrLessEquals(before));
  });

  testWidgets('crossing a prompt again before its fade ends is fine', (
    tester,
  ) async {
    await start(tester);
    Future<void> visit(double offset) async {
      scroll(tester).jumpTo(offset);
      // One frame for the list, one for the prompt pinned over it.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
    }

    for (var i = 0; i < 4; i++) {
      await visit(1000);
      await visit(4000);
    }
    // The prompt going and coming back: nothing's pinned at the chat's top.
    await visit(scroll(tester).position.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 200));
    final top = scroll(tester).position.maxScrollExtent;
    for (var i = 0; i < 4; i++) {
      await visit(top - 2000);
      await visit(top);
    }
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('at the bottom, opening and closing tool calls keeps them put', (
    tester,
  ) async {
    await start(tester);
    // Calls whose list runs taller than the chat.
    await sync(
      tester,
      () => messages.last = GaiaMessage(
        id: 'm30',
        chatId: 'c1',
        seq: 30,
        role: GaiaMessageRole.assistant,
        parts: [
          const GaiaTextPart('marker30.'),
          GaiaActivityPart(
            List.filled(40, 'Bash'),
            details: [for (var i = 0; i < 40; i++) 'echo $i'],
          ),
        ],
        status: GaiaMessageStatus.complete,
        createdAt: at,
        updatedAt: at,
      ),
    );
    expect(scroll(tester).offset, 0);
    final chip = find.text('Used Bash ×40');
    final before = tester.getTopLeft(chip).dy;

    await tester.tap(chip);
    await settle(tester);
    expect(find.text('echo 39'), findsOneWidget);
    expect(tester.getTopLeft(chip).dy, moreOrLessEquals(before));

    await tester.tap(chip);
    await settle(tester);
    expect(find.text('echo 39'), findsNothing);
    expect(tester.getTopLeft(chip).dy, moreOrLessEquals(before));
    expect(scroll(tester).offset, moreOrLessEquals(0));
  });

  testWidgets("on Voyager's page too, tool calls open below where they are", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GaiaSteadyList(
            controller: scroll,
            reverse: true,
            padding: const EdgeInsets.all(16),
            children: [
              GaiaActivityChip(
                label: 'Used Bash ×40',
                part: GaiaActivityPart(
                  List.filled(40, 'Bash'),
                  details: [for (var i = 0; i < 40; i++) 'echo $i'],
                ),
              ),
              for (var i = 0; i < 10; i++) const SizedBox(height: 200),
            ],
          ),
        ),
      ),
    );
    final chip = find.text('Used Bash ×40');
    final before = tester.getTopLeft(chip).dy;

    await tester.tap(chip);
    await tester.pump();
    expect(tester.getTopLeft(chip).dy, moreOrLessEquals(before));
    expect(scroll.offset, greaterThan(0));

    await tester.tap(chip);
    await tester.pump();
    expect(tester.getTopLeft(chip).dy, moreOrLessEquals(before));
    expect(scroll.offset, moreOrLessEquals(0));
  });

  testWidgets('a kept result filling in after it opens keeps the call put', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final result = Completer<GaiaToolResult?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GaiaSteadyList(
            controller: scroll,
            reverse: true,
            padding: const EdgeInsets.all(16),
            children: [
              // Room below for what opens, so Show all is on screen.
              const SizedBox(height: 400),
              GaiaActivityChip(
                label: 'Used 1 tool',
                part: const GaiaActivityPart(['os_read_screen'], ids: ['y']),
                hasResult: (_) => true,
                result: (_) => result.future,
              ),
              for (var i = 0; i < 10; i++) const SizedBox(height: 200),
            ],
          ),
        ),
      ),
    );
    final chip = find.text('Used 1 tool');
    final before = tester.getTopLeft(chip).dy;

    await tester.tap(chip);
    await tester.pump();
    expect(tester.getTopLeft(chip).dy, moreOrLessEquals(before));

    result.complete(
      GaiaToolResult(
        text: List.filled(400, 'Button "Save"').join('\n'),
        isError: false,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Show all'), findsOneWidget);
    expect(tester.getTopLeft(chip).dy, moreOrLessEquals(before));

    await tester.tap(find.textContaining('Show all'));
    await tester.pump();
    expect(find.text('Show less'), findsOneWidget);
    expect(tester.getTopLeft(chip).dy, moreOrLessEquals(before));
  });

  testWidgets('a message sent from here still goes down to its reply', (
    tester,
  ) async {
    await start(tester);
    await scrollTo(tester, 200);

    // Without its result, so the reply's still running here.
    runner.turns.add([
      for (final event in claudeFixtureTurns('single_turn.jsonl').single)
        if (event is! ClaudeResult) event,
    ]);
    unawaited(controller.send('Hello'));
    for (var i = 0; i < 30; i++) {
      // Real time too: the run's start writes files.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(scroll(tester).offset, 0);
  });
}
