import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';

/// Renaming a chapter in its divider (GAIA_CHAPTERS_HLD.md §6.2).
void main() {
  final at = DateTime.utc(2026, 11, 7);

  testWidgets('a click on the composer ends the rename, keeping the title', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
        'chats' => [
          GaiaChat(
            id: 'c1',
            title: 'The chat',
            createdAt: at,
            updatedAt: at,
            lastMessageAt: at,
            tier: GaiaTier.standard,
          ).toJson(),
        ],
        'messages' => [
          for (var seq = 0; seq < 2; seq++)
            GaiaMessage(
              id: 'm$seq',
              chatId: 'c1',
              seq: seq,
              role: seq.isEven
                  ? GaiaMessageRole.user
                  : GaiaMessageRole.assistant,
              parts: [GaiaTextPart('Message $seq')],
              status: GaiaMessageStatus.complete,
              createdAt: at,
              updatedAt: at,
              chapter: seq == 0 ? 'Intro' : null,
            ).toJson(),
        ],
        'drafts' => <Object?>[],
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
      await controller.openWindow();
      await controller.selectChat('c1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));

    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    final divider = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_ChapterDivider',
    );
    await tester.tap(
      find.descendant(of: divider, matching: find.text('Intro')),
      buttons: kSecondaryButton,
    );
    await settle();
    await tester.tap(find.text('Rename chapter'));
    await settle();
    final rename = find.descendant(
      of: divider,
      matching: find.byType(EditableText),
    );
    expect(rename, findsOneWidget);
    await tester.enterText(rename, 'Renamed');
    await settle();

    final composer = find.byWidgetPredicate(
      (widget) => widget is EditableText && widget.controller.text.isEmpty,
    );
    expect(composer, findsOneWidget);
    await tester.tap(composer);
    await settle();

    expect(rename, findsNothing);
    expect(controller.messages.first.chapter, 'Renamed');
  });
}
