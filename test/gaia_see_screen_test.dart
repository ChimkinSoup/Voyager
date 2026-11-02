import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';
import 'narrow_window_harness.dart';

/// The composer's *can see screen* toggle and its warning (GAIA_HLD.md §15.6).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final at = DateTime.utc(2026, 11, 1);

  // The window buttons ask whether it's maximized.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (_) async => false,
        );
  });

  Future<(GaiaController, List<Map<String, Object?>>, List<GaiaChat>)> pump(
    WidgetTester tester, {
    Map<String, GaiaGrant> grants = const {},
    bool withChat = true,
  }) async {
    tester.view.physicalSize = const Size(560, 460);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadRealFonts(tester);
    final calls = <Map<String, Object?>>[];
    final created = <GaiaChat>[];
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        if (method == 'setSeeScreen') calls.add(params);
        if (method == 'putChat') {
          created.add(GaiaChat.fromJson((params['chat']! as Map).cast()));
        }
        return switch (method) {
          'hello' => {
            'aborted': false,
            'accent': 0xFF7C9EFF,
            'deviceId': 'laptop',
            'settings': GaiaSettings.initial().toJson(),
          },
          'chats' => [
            if (withChat)
              GaiaChat(
                id: 'c1',
                title: 'The chat',
                createdAt: at,
                updatedAt: at,
                lastMessageAt: at,
                tier: GaiaTier.standard,
                grants: grants,
              ).toJson(),
          ],
          'messages' => <Object?>[],
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
    await tester.runAsync(() async {
      await controller.start();
      await controller.openWindow();
      if (withChat) await controller.selectChat('c1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    return (controller, calls, created);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  Finder warning() => find.textContaining('obey');
  Finder eye({required bool on}) =>
      find.byIcon(on ? Icons.visibility : Icons.visibility_off_outlined);

  testWidgets('off by default; one click turns it on, with the warning on one '
      'line, each time', (tester) async {
    final (controller, calls, _) = await pump(tester);
    expect(controller.canSeeScreen, isFalse);
    expect(warning(), findsNothing);

    await tester.tap(eye(on: false));
    await tester.pump();
    expect(controller.canSeeScreen, isTrue);
    expect(calls.single, {'chatId': 'c1', 'on': true});
    expect(warning(), findsOneWidget);
    // One line, at the small floater's width.
    expect(tester.getSize(warning()).height, lessThan(24));

    await tester.tap(eye(on: true));
    await tester.pump();
    expect(controller.canSeeScreen, isFalse);
    expect(calls.last, {'chatId': 'c1', 'on': false});
    expect(warning(), findsNothing);

    await tester.tap(eye(on: false));
    await tester.pump();
    expect(warning(), findsOneWidget);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('clicking the eye or the hand leaves the caret in the composer '
      '(BUG-341)', (tester) async {
    final (controller, _, _) = await pump(tester);
    await tester.tap(
      find.byType(EditableText).last,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    final composer = FocusManager.instance.primaryFocus;
    expect(composer?.context?.widget, isNotNull);
    expect(
      tester.widget<EditableText>(find.byType(EditableText).last).focusNode,
      composer,
    );

    await tester.tap(eye(on: false), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(controller.canSeeScreen, isTrue);
    expect(FocusManager.instance.primaryFocus, composer);

    await tester.tap(
      find.byIcon(Icons.pan_tool_alt_outlined),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(controller.canControl, isTrue);
    expect(FocusManager.instance.primaryFocus, composer);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a grant given earlier shows on, without the warning', (
    tester,
  ) async {
    final (controller, _, _) = await pump(
      tester,
      grants: {'laptop': GaiaGrant(seeScreen: true, at: at)},
    );
    expect(controller.canSeeScreen, isTrue);
    expect(eye(on: true), findsOneWidget);
    expect(warning(), findsNothing);
    await finish(tester);
  });

  testWidgets("another device's grant shows off here", (tester) async {
    final (controller, _, _) = await pump(
      tester,
      grants: {'phone': GaiaGrant(seeScreen: true, at: at)},
    );
    expect(controller.canSeeScreen, isFalse);
    await finish(tester);
  });

  testWidgets('on a new chat, it waits for the first message and goes with '
      'it; the warning goes too', (tester) async {
    final (controller, calls, created) = await pump(tester, withChat: false);
    await tester.tap(eye(on: false));
    await tester.pump();
    expect(controller.canSeeScreen, isTrue);
    expect(warning(), findsOneWidget);
    expect(calls, isEmpty);

    await tester.runAsync(() async {
      await controller.send('What is on my screen?');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(created.single.grants['laptop']!.seeScreen, isTrue);
    expect(controller.canSeeScreen, isTrue);
    expect(warning(), findsNothing);
    await finish(tester);
  });

  testWidgets('on a new chat left unsent, the next new chat starts off', (
    tester,
  ) async {
    final (controller, _, _) = await pump(tester);
    controller.moveDraftToNewChat();
    await tester.pump();
    await tester.tap(eye(on: false));
    await tester.pump();
    expect(controller.canSeeScreen, isTrue);
    await tester.runAsync(() => controller.selectChat('c1'));
    controller.moveDraftToNewChat();
    await tester.pump();
    expect(controller.canSeeScreen, isFalse);
    await finish(tester);
  });
}
