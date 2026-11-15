import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';

import 'fakes/gaia_fakes.dart';

/// The floater's title opens the recent chats to switch to, as it has no
/// sidebar.
void main() {
  final at = DateTime.utc(2026, 11, 14);

  GaiaChat chat(String id, String title, int minutes) => GaiaChat(
    id: id,
    title: title,
    createdAt: at,
    updatedAt: at,
    lastMessageAt: at.add(Duration(minutes: minutes)),
    tier: GaiaTier.standard,
  );

  testWidgets('a click on the title lists the other chats, newest first', (
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
              'settings': GaiaSettings.initial().toJson(),
            };
          case 'chats':
            return [
              chat('c1', 'Parser', 3).toJson(),
              chat('c2', 'Older trip', 1).toJson(),
              chat('c3', 'Newer trip', 2).toJson(),
            ];
          case 'messages' || 'btws' || 'drafts':
            return <Object?>[];
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
      await controller.onHotkey('small');
      await controller.selectChat('c1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.layout, GaiaMode.small);

    // The header's taps wait out a double click, so the menu opens a frame
    // late and needs its own second to grow.
    await tester.tap(find.text('Parser'));
    for (var i = 0; i < 2; i++) {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
    final newer = tester.getTopLeft(find.text('Newer trip'));
    final older = tester.getTopLeft(find.text('Older trip'));
    expect(newer.dy, lessThan(older.dy));
    expect(find.text('Search chats'), findsOneWidget);
    // The current chat's title is the header's alone.
    expect(find.text('Parser'), findsOneWidget);

    await tester.tap(find.text('Older trip'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentChatId, 'c2');
    expect(find.text('Search chats'), findsNothing);
  });
}
