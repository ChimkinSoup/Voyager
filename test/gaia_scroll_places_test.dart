import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_pinned_prompt.dart';

import 'fakes/gaia_fakes.dart';

/// Each chat is back where it was left scrolled up to on coming back to it,
/// this run; one left at the bottom is back at its newest.
void main() {
  final at = DateTime.utc(2026, 10, 30);

  GaiaMessage message(String chatId, int seq) => GaiaMessage(
    id: '$chatId-m$seq',
    chatId: chatId,
    seq: seq,
    role: seq.isOdd ? GaiaMessageRole.user : GaiaMessageRole.assistant,
    parts: [
      GaiaTextPart(
        [
          '$chatId-marker$seq.',
          for (var i = 0; i < 12; i++) 'line $i',
        ].join('\n\n'),
      ),
    ],
    status: GaiaMessageStatus.complete,
    createdAt: at,
    updatedAt: at,
  );

  late Map<String, List<GaiaMessage>> messages;
  late FakeGaiaPipe main;
  late GaiaController controller;

  final list = find.byWidgetPredicate(
    (widget) => widget is ListView && widget.reverse,
  );

  Finder marker(String chatId, int seq) => find.descendant(
    of: list,
    matching: find.textContaining('$chatId-marker$seq.', findRichText: true),
  );

  ScrollController scroll(WidgetTester tester) =>
      tester.widget<ListView>(list).controller!;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    messages = {
      for (final chatId in ['a', 'b'])
        chatId: [for (var seq = 1; seq <= 30; seq++) message(chatId, seq)],
    };
    main = FakeGaiaPipe.main();
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
          for (final chatId in ['a', 'b'])
            GaiaChat(
              id: chatId,
              title: chatId,
              createdAt: at,
              updatedAt: at,
              lastMessageAt: at,
            ).toJson(),
        ],
        'messages' => [
          for (final message in messages[(params as Map)['chatId']]!)
            message.toJson(),
        ],
        'drafts' => <Object?>[],
        _ => null,
      };
    await main.startCompanion();
    controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {kGaiaClaudeCodeAdapter: FakeClaudeRunner()},
      cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
      exit: (_) {},
    );
    await controller.start();
    await settle(tester);
    controller.onScreen.value = true;
    await tester.pumpWidget(GaiaApp(controller: controller));
    await controller.selectChat('a');
    await settle(tester);
  }

  /// The message whose marker's nearest the list's middle, and its marker's
  /// top.
  (int, double) reading(WidgetTester tester, String chatId) {
    final middle = tester.getCenter(list).dy;
    double top(int seq) => tester.getTopLeft(marker(chatId, seq)).dy;
    final seq =
        [
          for (var seq = 1; seq <= 31; seq++)
            if (marker(chatId, seq).evaluate().isNotEmpty) seq,
        ].reduce(
          (a, b) => (top(a) - middle).abs() <= (top(b) - middle).abs() ? a : b,
        );
    return (seq, top(seq));
  }

  Future<void> open(WidgetTester tester, String chatId) async {
    await controller.selectChat(chatId);
    await settle(tester);
  }

  for (final offset in [600.0, 6000.0]) {
    testWidgets('scrolled up $offset, a chat is back there after another', (
      tester,
    ) async {
      await start(tester);
      scroll(tester).jumpTo(offset);
      await settle(tester);
      final seq = [
        for (var seq = 1; seq <= 30; seq++)
          if (marker('a', seq).evaluate().isNotEmpty) seq,
      ].first;
      final before = tester.getTopLeft(marker('a', seq)).dy;

      await open(tester, 'b');
      // The other chat isn't scrolled as this one was.
      expect(scroll(tester).offset, 0);
      expect(marker('b', 30), findsOneWidget);

      await open(tester, 'a');
      expect(tester.getTopLeft(marker('a', seq)).dy, moreOrLessEquals(before));
    });
  }

  testWidgets('far up, coming back never shows the newest first, even a '
      'frame', (tester) async {
    await start(tester);
    scroll(tester).jumpTo(6000);
    await settle(tester);
    final (seq, top) = reading(tester, 'a');
    await open(tester, 'b');

    unawaited(controller.selectChat('a'));
    var shown = 0;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      // The nearest over the list: the one hiding it while it's put back.
      final opacity = tester
          .widget<Opacity>(
            find.ancestor(of: list, matching: find.byType(Opacity)).first,
          )
          .opacity;
      if (opacity == 0) continue;
      shown++;
      expect(marker('a', 30), findsNothing);
      expect(tester.getTopLeft(marker('a', seq)).dy, moreOrLessEquals(top));
    }
    expect(shown, greaterThan(0));
    await settle(tester);
  });

  testWidgets('from a chat with a prompt pinned, the next never shows it, '
      'nor fades in its own', (tester) async {
    await start(tester);
    final pinned = find.byType(GaiaPinnedPrompt);
    scroll(tester).jumpTo(1500);
    await settle(tester);
    expect(tester.widget<GaiaPinnedPrompt>(pinned).id, startsWith('a-'));

    unawaited(controller.selectChat('b'));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (pinned.evaluate().isEmpty) continue;
      // At its newest, its last reply's taller than the list: its own
      // prompt's pinned, at once.
      expect(tester.widget<GaiaPinnedPrompt>(pinned).id, 'b-m29');
      final fade = tester.widget<FadeTransition>(
        find.ancestor(of: pinned, matching: find.byType(FadeTransition)).first,
      );
      expect(fade.opacity.value, 1);
    }
    await settle(tester);
  });

  testWidgets('back to a chat with a prompt pinned, it shows without fading '
      'in', (tester) async {
    await start(tester);
    final pinned = find.byType(GaiaPinnedPrompt);
    scroll(tester).jumpTo(1500);
    await settle(tester);
    await open(tester, 'b');

    unawaited(controller.selectChat('a'));
    var seen = 0;
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (pinned.evaluate().isEmpty) continue;
      seen++;
      final fade = tester.widget<FadeTransition>(
        find.ancestor(of: pinned, matching: find.byType(FadeTransition)).first,
      );
      expect(fade.opacity.value, 1);
    }
    expect(seen, greaterThan(0));
    await settle(tester);
  });

  testWidgets('from a chat scrolled up, the next at its newest never shows '
      'the to-bottom button', (tester) async {
    await start(tester);
    final button = find.byIcon(Icons.keyboard_double_arrow_down_rounded);
    scroll(tester).jumpTo(1500);
    await settle(tester);
    expect(button, findsOneWidget);

    unawaited(controller.selectChat('b'));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(button, findsNothing);
    }
    await settle(tester);
  });

  testWidgets('each chat keeps its own place', (tester) async {
    await start(tester);
    scroll(tester).jumpTo(1500);
    await settle(tester);
    final (a, aTop) = reading(tester, 'a');

    await open(tester, 'b');
    scroll(tester).jumpTo(3000);
    await settle(tester);
    final (b, bTop) = reading(tester, 'b');

    await open(tester, 'a');
    expect(tester.getTopLeft(marker('a', a)).dy, moreOrLessEquals(aTop));
    await open(tester, 'b');
    expect(tester.getTopLeft(marker('b', b)).dy, moreOrLessEquals(bTop));
  });

  testWidgets('left at the bottom, a chat is back at its newest', (
    tester,
  ) async {
    await start(tester);
    scroll(tester).jumpTo(1500);
    await settle(tester);
    scroll(tester).jumpTo(0);
    await settle(tester);

    await open(tester, 'b');
    scroll(tester).jumpTo(1500);
    await settle(tester);
    await open(tester, 'a');

    expect(scroll(tester).offset, 0);
    expect(marker('a', 30), findsOneWidget);
  });

  testWidgets('a reply arriving while away still finds the same message', (
    tester,
  ) async {
    await start(tester);
    scroll(tester).jumpTo(600);
    await settle(tester);
    final seq = [
      for (var seq = 1; seq <= 30; seq++)
        if (marker('a', seq).evaluate().isNotEmpty) seq,
    ].first;
    final before = tester.getTopLeft(marker('a', seq)).dy;

    await open(tester, 'b');
    messages['a']!.add(message('a', 31));
    main.notify('changed');
    await settle(tester);
    await open(tester, 'a');

    expect(tester.getTopLeft(marker('a', seq)).dy, moreOrLessEquals(before));
    expect(
      find.byIcon(Icons.keyboard_double_arrow_down_rounded),
      findsOneWidget,
    );
  });

  testWidgets('a search hit picked while a chat is put back shows the hit, '
      'not that place', (tester) async {
    await start(tester);
    scroll(tester).jumpTo(6000);
    await settle(tester);
    await open(tester, 'b');

    double opacity() => tester
        .widget<Opacity>(
          find.ancestor(of: list, matching: find.byType(Opacity)).first,
        )
        .opacity;
    unawaited(controller.selectChat('a'));
    for (var i = 0; i < 10 && opacity() == 1; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Hidden while it's put back.
    expect(opacity(), 0);

    unawaited(controller.revealMessage('b', 'b-m10'));
    // The other chat's shown at once, not hidden till that's put back.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(opacity(), 1);
    }
    await settle(tester);
    final top = tester.getTopLeft(list).dy;
    expect(
      tester.getTopLeft(marker('b', 10)).dy,
      inInclusiveRange(top, top + 120),
    );
  });
}
