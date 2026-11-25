import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';
import 'narrow_window_harness.dart';

/// A temporary chat's header fits a floater, beside a project's crumb and
/// an untested CLI's chip.
void main() {
  final at = DateTime.utc(2026, 11, 24);

  for (final width in [560.0, 1200.0]) {
    testWidgets('fits a ${width.toInt()} wide floater', (tester) async {
      await loadRealFonts(tester);
      tester.view.physicalSize = Size(width, 460);
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
                GaiaChat(
                  id: 'c1',
                  title: 'Trip planning',
                  createdAt: at,
                  updatedAt: at,
                  lastMessageAt: at,
                  tier: GaiaTier.standard,
                  temporaryAt: at,
                ).toJson(),
              ];
            case 'projects':
              return [
                GaiaProject(
                  id: 'p1',
                  name: 'Voyager',
                  createdAt: at,
                  updatedAt: at,
                ).toJson(),
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
        cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 331)},
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
      expect(controller.currentChat?.temporary, isTrue);
      expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);
      // Its label where there's room for it; an overflow fails the test as
      // it's laid out.
      expect(
        find.text('Temporary'),
        width < 1000 ? findsNothing : findsOneWidget,
      );
    });
  }
}
