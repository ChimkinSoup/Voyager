import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';

/// Renaming a chat in its sidebar row.

final _at = DateTime.utc(2026, 11, 22, 12);

void main() {
  testWidgets('a click on the composer ends the rename, keeping the name', (
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
            id: 'Alpha',
            title: 'Alpha',
            createdAt: _at,
            updatedAt: _at,
            lastMessageAt: _at,
          ).toJson(),
        ],
        'drafts' || 'messages' => <Object?>[],
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
    await controller.start();
    await controller.openWindow();
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));

    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    await tester.tap(find.text('Alpha'), buttons: kSecondaryButton);
    await settle();
    await tester.tap(find.text('Rename'));
    await settle();
    final fields = find.byType(EditableText);
    final rename = find.byWidgetPredicate(
      (widget) => widget is EditableText && widget.controller.text == 'Alpha',
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

    expect(fields, findsOneWidget);
    expect(controller.chats.single.title, 'Renamed');
    expect(find.text('Renamed'), findsOneWidget);
  });
}
