import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';

/// A chat in Gaia's sidebar pins and unpins from its right-click menu, and a
/// pinned one wears a pin.
void main() {
  testWidgets('the menu pins and unpins a chat, its pin showing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    GaiaChat chat(String id, DateTime at) => GaiaChat(
      id: id,
      title: id,
      createdAt: at,
      updatedAt: at,
      lastMessageAt: at,
    );
    final writes = <Map<String, Object?>>[];
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        if (method == 'setPinned') writes.add(params);
        return switch (method) {
          'hello' => {
            'aborted': false,
            'accent': 0xFF7C9EFF,
            'deviceId': 'laptop',
            'settings': GaiaSettings.initial().toJson(),
          },
          'chats' => [
            chat('Newer', DateTime.utc(2026, 10, 30)).toJson(),
            chat('Older', DateTime.utc(2026, 10, 29)).toJson(),
          ],
          'drafts' => <Object?>[],
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

    final pin = find.byWidgetPredicate(
      (widget) => widget is Icon && widget.semanticLabel == 'Pinned',
    );
    Future<void> pick(String title, String item) async {
      // Twice: the menu's entrance starts on the first frame.
      await tester.tap(find.text(title), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text(item));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    expect(pin, findsNothing);
    expect(
      tester.getTopLeft(find.text('Newer')).dy,
      lessThan(tester.getTopLeft(find.text('Older')).dy),
    );

    await pick('Older', 'Pin');
    expect(writes.single, {'chatId': 'Older', 'pinned': true});
    expect(pin, findsOneWidget);
    expect(
      tester.getCenter(pin).dy,
      moreOrLessEquals(tester.getCenter(find.text('Older')).dy, epsilon: 1),
    );
    expect(
      tester.getTopLeft(find.text('Older')).dy,
      lessThan(tester.getTopLeft(find.text('Newer')).dy),
    );

    Color? pinColor() => tester.widget<Icon>(pin).color;
    Color accent() => Theme.of(tester.element(pin)).colorScheme.primary;
    expect(pinColor(), accent());
    final was = pinColor();
    controller.accent.value = 0xFFFF5722;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(pinColor(), isNot(was));
    expect(pinColor(), accent());

    await pick('Older', 'Unpin');
    expect(writes.last, {'chatId': 'Older', 'pinned': false});
    expect(pin, findsNothing);
    expect(
      tester.getTopLeft(find.text('Newer')).dy,
      lessThan(tester.getTopLeft(find.text('Older')).dy),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
