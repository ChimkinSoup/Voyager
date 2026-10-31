import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

import 'fakes/gaia_fakes.dart';

/// A reply that streams in as the test emits it, until it completes [turn].
class _Streaming extends FakeClaudeRunner {
  void Function(GaiaAgentEvent event)? emit;
  Completer<GaiaTurnResult>? turn;

  @override
  Future<GaiaTurnResult> send({
    required String chatId,
    required String? sessionId,
    required String model,
    required String prompt,
    List<GaiaImageInput> images = const [],
    Set<String> directories = const {},
    GaiaTurnTools? tools,
    String sessionInstructions = '',
    required void Function(GaiaAgentEvent event) onEvent,
  }) {
    emit = onEvent;
    return (turn = Completer<GaiaTurnResult>()).future;
  }
}

/// Scrolling about at random as replies stream in stays free of errors. These
/// seeds each found the pinned prompt's fades colliding.
void main() {
  final at = DateTime.utc(2026, 10, 30);

  GaiaMessage message(int seq) => GaiaMessage(
    id: 'm$seq',
    chatId: 'c1',
    seq: seq,
    role: seq.isOdd ? GaiaMessageRole.user : GaiaMessageRole.assistant,
    parts: [
      GaiaTextPart(
        ['m$seq.', for (var i = 0; i < 12; i++) 'line $i'].join('\n\n'),
      ),
    ],
    status: GaiaMessageStatus.complete,
    createdAt: at,
    updatedAt: at,
  );

  final list = find.byWidgetPredicate(
    (widget) => widget is ListView && widget.reverse,
  );

  for (final seed in [1, 11]) {
    testWidgets('seed $seed', (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final messages = [for (var seq = 1; seq <= 12; seq++) message(seq)];
      final main = FakeGaiaPipe.main();
      final runner = _Streaming();
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
      final controller = GaiaController(
        pipe: companion,
        window: FakeGaiaWindow(),
        runners: {kGaiaClaudeCodeAdapter: runner},
        cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
        exit: (_) {},
      );
      await controller.start();
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }
      controller.onScreen.value = true;
      await tester.pumpWidget(GaiaApp(controller: controller));
      await controller.selectChat('c1');
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }

      final scroll = tester.widget<ListView>(list).controller!;
      final random = Random(seed);

      // Real time too: a run's start writes files.
      Future<void> pumpReal() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }

      for (var round = 0; round < 3; round++) {
        unawaited(controller.send('Question $round'));
        for (var i = 0; i < 6; i++) {
          await pumpReal();
        }
        final emit = runner.emit!;
        emit(const GaiaTextStart());
        for (var step = 0; step < 120; step++) {
          final roll = random.nextDouble();
          if (roll < 0.5) {
            emit(
              GaiaTextDelta(
                'word ${random.nextInt(99)}${random.nextBool() ? '\n\n' : ' '}',
              ),
            );
          } else if (roll < 0.55) {
            emit(GaiaToolUse('Tool${random.nextInt(3)}'));
          } else if (roll < 0.58) {
            emit(const GaiaTextStart());
          } else {
            final position = scroll.position;
            final target = switch (random.nextInt(4)) {
              0 => 0.0,
              1 => position.pixels + random.nextDouble() * 600,
              2 => random.nextDouble() * position.maxScrollExtent,
              _ => max(0.0, position.pixels - random.nextDouble() * 400),
            };
            scroll.jumpTo(target.clamp(0, position.maxScrollExtent));
          }
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.takeException(), isNull);
        }
        runner.turn!.complete(
          const GaiaTurnResult(sessionId: 's', isError: false, text: 'done'),
        );
        for (var i = 0; i < 12; i++) {
          await pumpReal();
          expect(tester.takeException(), isNull);
        }
      }
      // Past what a finished run leaves timed, as its curation.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(hours: 3));
    });
  }
}
