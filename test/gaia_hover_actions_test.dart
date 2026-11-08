import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';

/// The faint icons under a message while the cursor's over it, as in
/// Claude's desktop app: copy, edit (the user's), fork, rewind, pin as
/// chapter.
void main() {
  final at = DateTime.utc(2026, 11, 7);

  final messages = [
    for (var seq = 0; seq < 4; seq++)
      GaiaMessage(
        id: 'm$seq',
        chatId: 'c1',
        seq: seq,
        role: seq.isEven ? GaiaMessageRole.user : GaiaMessageRole.assistant,
        parts: [GaiaTextPart('Message $seq')],
        status: GaiaMessageStatus.complete,
        createdAt: at,
        updatedAt: at,
      ),
  ];

  Future<void> pump(WidgetTester tester) async {
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
        'messages' => [for (final message in messages) message.toJson()],
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
  }

  Future<void> hover(WidgetTester tester, String text) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text(text)));
    await tester.pump(const Duration(milliseconds: 300));
  }

  const all = [
    'Copy',
    'Edit & resend',
    'Fork from here',
    'Rewind to here',
    'Pin as chapter',
  ];

  testWidgets('none until a message is hovered, then the prompt\'s five', (
    tester,
  ) async {
    await pump(tester);
    for (final label in all) {
      expect(find.byTooltip(label), findsNothing);
    }
    await hover(tester, 'Message 0');
    for (final label in all) {
      expect(find.byTooltip(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('fades in rather than popping in', (tester) async {
    await pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Message 0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byTooltip('Copy'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, inExclusiveRange(0, 1));
  });

  testWidgets('spaced as in Claude\'s desktop app: 32px boxes, 4px below '
      'the bubble, flush with its right', (tester) async {
    await pump(tester);
    await hover(tester, 'Message 0');
    final bubble = tester.getRect(
      find
          .ancestor(
            of: find.text('Message 0'),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Container && widget.decoration is BoxDecoration,
            ),
          )
          .first,
    );
    final copy = tester.getRect(find.byTooltip('Copy'));
    final pin = tester.getRect(find.byTooltip('Pin as chapter'));
    expect(copy.size, const Size(32, 32));
    expect(copy.top - bubble.bottom, 4);
    expect(pin.right, bubble.right);
  });

  testWidgets('a reply\'s sit as far under its text, its bubble unseen', (
    tester,
  ) async {
    await pump(tester);
    await hover(tester, 'Message 1');
    final text = tester.getRect(find.text('Message 1'));
    expect(tester.getRect(find.byTooltip('Copy')).top - text.bottom, 4);
    // Its last line clear of the faint bubble's bottom.
    final bubble = tester.getRect(
      find
          .ancestor(
            of: find.text('Message 1'),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Container && widget.decoration is BoxDecoration,
            ),
          )
          .first,
    );
    expect(bubble.bottom - text.bottom, 4);
  });

  testWidgets('reached with Tab: focusing a message shows its bar, Tab goes '
      'into it, and Enter presses', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(tester);
    final row = find
        .ancestor(
          of: find.text('Message 0'),
          matching: find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_HoverActions',
          ),
        )
        .first;
    final region = find
        .descendant(of: row, matching: find.byType(MouseRegion))
        .first;
    Focus.of(tester.element(region)).requestFocus();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Copy'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(copied, 'Message 0');
  });

  testWidgets('a reply has no Edit, and the last message no Rewind', (
    tester,
  ) async {
    await pump(tester);
    await hover(tester, 'Message 3');
    expect(find.byTooltip('Copy'), findsOneWidget);
    expect(find.byTooltip('Fork from here'), findsOneWidget);
    expect(find.byTooltip('Pin as chapter'), findsOneWidget);
    expect(find.byTooltip('Edit & resend'), findsNothing);
    expect(find.byTooltip('Rewind to here'), findsNothing);
  });

  testWidgets('Copy puts the message on the clipboard and ticks', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(tester);
    await hover(tester, 'Message 1');
    await tester.tap(find.byTooltip('Copy'));
    await tester.pump();
    expect(copied, 'Message 1');
    expect(find.byTooltip('Copied'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byTooltip('Copy'), findsOneWidget);
  });

  testWidgets('Pin as chapter pins it, and is offered no more', (tester) async {
    await pump(tester);
    await hover(tester, 'Message 2');
    await tester.tap(find.byTooltip('Pin as chapter'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_ChapterDivider',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Pin as chapter'), findsNothing);
  });
}
