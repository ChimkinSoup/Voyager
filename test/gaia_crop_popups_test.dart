import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_crop_overlay.dart';
import 'package:voyager/features/gaia/companion/gaia_debug_menu.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';

import 'fakes/gaia_fakes.dart';

/// A capture brings Gaia up with nothing over it: a dialog left open over
/// the chat is dismissed, for the crop overlay and the whole screen alike.
void main() {
  late FakeGaiaPipe companion;
  late GaiaController controller;
  late Future<void> closed;

  /// Gaia up with its debug menu open over the chat.
  Future<void> start(WidgetTester tester) async {
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
        'chats' || 'drafts' => <Object?>[],
        'ingestImage' => 'media1',
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
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump();

    closed = showGaiaDebugMenu(
      tester.element(find.byType(Scaffold)),
      controller,
    );
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
  }

  Map<String, Object?> capture(String kind, String path) => {
    'kind': kind,
    'path': path,
    'left': 0,
    'top': 0,
    'width': 1920,
    'height': 1080,
  };

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump();
    }
    // Past the draft's save.
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a region capture dismisses it under the crop overlay', (
    tester,
  ) async {
    await start(tester);
    companion.onEvent!('capture', capture('region', 'shot.bmp'));
    await settle(tester);

    expect(controller.layout, GaiaMode.overlay);
    expect(find.byType(GaiaCropOverlay), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    await closed;
  });

  testWidgets('a capture dismisses a right-click menu too', (tester) async {
    await start(tester);
    Navigator.of(tester.element(find.byType(Dialog))).pop();
    await tester.pumpAndSettle();
    await closed;
    showGaiaMenu(tester.element(find.byType(Scaffold)), Offset.zero, [
      GaiaMenuItem(label: 'Copy', icon: Icons.copy, onPressed: () {}),
    ]);
    await tester.pump();
    expect(find.byType(GaiaMenu), findsOneWidget);

    companion.onEvent!('capture', capture('region', 'shot.bmp'));
    await settle(tester);

    expect(find.byType(GaiaCropOverlay), findsOneWidget);
    expect(find.byType(GaiaMenu), findsNothing);
  });

  testWidgets('a full-screen capture dismisses it as the shot joins the '
      'draft', (tester) async {
    await start(tester);
    final shot = await tester.runAsync(() async {
      final captures = await Directory.systemTemp.createTemp('gaia_captures');
      addTearDown(() => captures.delete(recursive: true));
      return File('${captures.path}/shot.bmp')..writeAsBytesSync([0]);
    });
    // Moved into the drafts on disk, outside the fake clock.
    await tester.runAsync(() async {
      companion.onEvent!('capture', capture('screen', shot!.path));
      for (var i = 0; i < 100 && controller.draftImages.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await settle(tester);

    expect(controller.draftImages, hasLength(1));
    expect(find.byType(Dialog), findsNothing);
    await closed;
  });
}
