import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';

/// Picking several chats in the sidebar with Ctrl+ and Shift+click, Select
/// all, and the menu that's done to them all.

final _at = DateTime.utc(2026, 11, 22, 12);

GaiaChat _chat(String id, int minutes) => GaiaChat(
  id: id,
  title: id,
  createdAt: _at,
  updatedAt: _at,
  lastMessageAt: _at.add(Duration(minutes: minutes)),
);

void main() {
  testWidgets('Ctrl+ and Shift+click pick chats; Select all; one Delete '
      'for them all, and one undo', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final requests = <(String, Map<String, Object?>)>[];
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        if (method case 'deleteChats' || 'restoreChat') {
          requests.add((method, params));
        }
        return switch (method) {
          'hello' => {
            'aborted': false,
            'accent': 0xFF7C9EFF,
            'deviceId': 'laptop',
            'settings': GaiaSettings.initial().toJson(),
          },
          'chats' => [
            _chat('Alpha', 2).toJson(),
            _chat('Beta', 1).toJson(),
            _chat('Gamma', 0).toJson(),
          ],
          'drafts' || 'messages' => <Object?>[],
          'deleteChats' => {
            for (final id in params['chatIds']! as List) id as String: null,
          },
          _ => null,
        };
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

    Future<void> click(String title, [LogicalKeyboardKey? held]) async {
      if (held != null) await tester.sendKeyDownEvent(held);
      await tester.tap(find.text(title));
      if (held != null) await tester.sendKeyUpEvent(held);
      await settle();
    }

    const ctrl = LogicalKeyboardKey.controlLeft;
    const shift = LogicalKeyboardKey.shiftLeft;

    expect(find.textContaining('selected'), findsNothing);

    // Ctrl picks; a plain click opens the chat and lets go of them. The
    // rows stay put as the bar shows, for the next click.
    final beta = tester.getTopLeft(find.text('Beta'));
    await click('Alpha', ctrl);
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Beta')), beta);
    expect(controller.currentChatId, isNull);
    await click('Beta');
    expect(find.textContaining('selected'), findsNothing);
    expect(controller.currentChatId, 'Beta');

    // Shift picks the range from the last one picked, as shown.
    await click('Alpha', ctrl);
    await click('Gamma', shift);
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.text('Select all'), findsNothing);
    await tester.tap(find.byTooltip('Clear selection'));
    await settle();
    expect(find.textContaining('selected'), findsNothing);

    // Select all, once anything's picked.
    await click('Gamma', ctrl);
    await tester.tap(find.text('Select all'));
    await settle();
    expect(find.text('3 selected'), findsOneWidget);

    // A picked chat's menu is for them all.
    await tester.tap(find.text('Alpha'), buttons: kSecondaryButton);
    await settle();
    expect(find.text('Rename'), findsNothing);
    await tester.tap(find.text('Delete 3 chats'));
    await settle();
    expect(requests.single.$1, 'deleteChats');
    expect(requests.single.$2['chatIds'], ['Alpha', 'Beta', 'Gamma']);
    expect(find.text('Alpha'), findsNothing);
    expect(find.textContaining('selected'), findsNothing);

    await tester.tap(find.text('Deleted 3 chats'));
    await settle();
    expect(
      [
        for (final (method, params) in requests.skip(1))
          if (method == 'restoreChat') params['chatId'],
      ],
      ['Alpha', 'Beta', 'Gamma'],
    );
    expect(find.text('Alpha'), findsOneWidget);
    expect(controller.currentChatId, 'Beta');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
