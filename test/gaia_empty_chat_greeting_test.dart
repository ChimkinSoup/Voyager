import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_sky.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';

import 'fakes/gaia_fakes.dart';

/// A new chat's line (GAIA_GREETINGS_HLD.md §2) holds still while the
/// composer is typed in and the window resized, though both rebuild it.
void main() {
  testWidgets('the line stays through typing and a resize', (tester) async {
    tester.view.physicalSize = const Size(560, 460);
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
          'settings': GaiaSettings.initial()
              .copyWith(userName: 'Juno')
              .toJson(),
        },
        'chats' || 'messages' || 'btws' || 'drafts' => <Object?>[],
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
    await tester.runAsync(() async {
      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    final line = controller.greetingFor(GaiaDraft.newChatId);
    expect(find.text(line), findsOneWidget);

    final field = find.descendant(
      of: find.byType(GaiaTextField),
      matching: find.byType(EditableText),
    );
    for (final text in ['H', 'He', 'Hey']) {
      await tester.enterText(field, text);
      await tester.pump();
      expect(find.text(line), findsOneWidget);
    }

    tester.view.physicalSize = const Size(480, 400);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(line), findsOneWidget);
  });

  // GAIA_SKY_AUDIT.md B4.
  testWidgets('a send undone mid-exit brings the line back with the sky', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(560, 460);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    late FakeGaiaPipe companion;
    final saving = Completer<void>();
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        switch (method) {
          case 'hello':
            return {
              'aborted': false,
              'accent': 0xFF7C9EFF,
              'deviceId': 'laptop',
              'settings': GaiaSettings.initial()
                  .copyWith(userName: 'Juno')
                  .toJson(),
            };
          case 'chats' || 'messages' || 'btws' || 'drafts':
            return <Object?>[];
          case 'putChat':
            // Not kept, so the send is undone.
            await saving.future;
            throw GaiaPipeException('going away');
        }
        return null;
      };
    await main.startCompanion();
    final controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {kGaiaClaudeCodeAdapter: FakeClaudeRunner()},
      cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
      exit: (_) {},
    );
    await tester.runAsync(() async {
      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    // On screen, so its animations run.
    controller.onScreen.value = true;
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    final line = controller.greetingFor(GaiaDraft.newChatId);
    double shown() => tester
        .widget<Opacity>(
          find
              .ancestor(of: find.text(line), matching: find.byType(Opacity))
              .first,
        )
        .opacity;
    expect(shown(), 1);
    // GAIA_SKY_AUDIT.md D4: its clear goes as it does.
    double clear() =>
        tester.widget<GaiaSkyClear>(find.byType(GaiaSkyClear)).opacity;

    // Sent, and part way through the sky's 1 s exit when it's undone.
    unawaited(controller.send('Hey'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(shown(), lessThan(0.9));
    expect(clear(), closeTo(shown(), 1e-9));
    saving.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.messages, isEmpty);
    // Coming back as the stars do, not at once.
    expect(shown(), lessThan(0.9));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(shown(), 1);
  });

  // BUG-443: `/routine`'s card floats over where the line and its keys sit.
  testWidgets('the line and its keys give way to the routine card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    late FakeGaiaPipe companion;
    final now = DateTime.utc(2026, 11, 27);
    final routine = GaiaRoutine(
      id: 'r1',
      createdAt: now,
      updatedAt: now,
      name: 'Job applier',
      instructions: 'Apply.',
      projectId: 'p1',
      skipRules: '',
    );
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
          'settings': GaiaSettings.initial()
              .copyWith(userName: 'Juno')
              .toJson(),
        },
        'chats' || 'messages' || 'btws' || 'drafts' || 'runs' => <Object?>[],
        'routines' => [routine.toJson()],
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
    await tester.runAsync(() async {
      await controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    // On screen, so its animations run.
    controller.onScreen.value = true;
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    final line = controller.greetingFor(GaiaDraft.newChatId);
    expect(find.text(line), findsOneWidget);
    expect(find.text('paste an image'), findsOneWidget);

    await tester.runAsync(() => controller.openRoutineLaunch('job applier'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Routine: Job applier'), findsOneWidget);
    expect(find.text(line), findsNothing);
    expect(find.text('paste an image'), findsNothing);

    controller.closeRoutineLaunch();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(line), findsOneWidget);
  });
}
