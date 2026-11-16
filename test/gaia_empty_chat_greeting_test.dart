import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';

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
}
