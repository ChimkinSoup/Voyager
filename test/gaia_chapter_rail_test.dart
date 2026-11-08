import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';

/// The chapter rail down the chat's top left (GAIA_CHAPTERS_HLD.md §6.3):
/// a line per chapter, the one being read the longer, opening on hover into
/// the chapters' titles, each glided to on a click.
void main() {
  final at = DateTime.utc(2026, 11, 7);

  /// 60 messages, with chapters at [chapters]' seqs.
  List<GaiaMessage> messages(Map<int, String> chapters) => [
    for (var seq = 0; seq < 60; seq++)
      GaiaMessage(
        id: 'm$seq',
        chatId: 'c1',
        seq: seq,
        role: seq.isEven ? GaiaMessageRole.user : GaiaMessageRole.assistant,
        parts: [GaiaTextPart('Message $seq\n\n${'Some text. ' * 20}')],
        status: GaiaMessageStatus.complete,
        createdAt: at,
        updatedAt: at,
        chapter: chapters[seq],
      ),
  ];

  Future<GaiaController> pump(
    WidgetTester tester,
    List<GaiaMessage> messages, {
    double width = 1000,
  }) async {
    tester.view.physicalSize = Size(width, 700);
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
    // The list's place, then the rail easing to it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return controller;
  }

  Finder rail() => find.byWidgetPredicate(
    (widget) => widget.runtimeType.toString() == '_ChapterRail',
  );

  /// The rail's dashes' widths, top to bottom.
  List<double> dashes(WidgetTester tester) => [
    for (final element
        in find
            .descendant(of: rail(), matching: find.byType(AnimatedContainer))
            .evaluate())
      element.size!.width,
  ];

  Future<TestGesture> hover(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(rail()));
    await tester.pumpAndSettle();
    return mouse;
  }

  testWidgets('no rail without chapters', (tester) async {
    await pump(tester, messages(const {}));
    expect(rail(), findsNothing);
  });

  testWidgets('a line for the start and each chapter, the one being read '
      'longer; hovered, their titles, a click gliding there', (tester) async {
    await pump(tester, messages(const {20: 'Planning', 40: 'Building'}));
    expect(rail(), findsOneWidget);
    // Opened at the newest message: in "Building".
    expect(dashes(tester), [10, 10, 18]);

    final mouse = await hover(tester);
    expect(find.text('Start of chat'), findsOneWidget);
    expect(find.text('Planning'), findsWidgets);
    await tester.tap(find.text('Planning').last);
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(500, 400));
    await tester.pumpAndSettle();

    // Now reading "Planning": its line grown, "Building"'s shrunk.
    expect(find.text('Start of chat'), findsNothing);
    expect(dashes(tester), [10, 18, 10]);
  });

  testWidgets('at the bottom, a chapter too near the end to reach the top is '
      'the one being read; scrolled up off the bottom, it is not', (
    tester,
  ) async {
    await pump(tester, messages(const {20: 'Planning', 59: 'Ending'}));
    expect(dashes(tester), [10, 10, 18]);

    await tester.dragFrom(const Offset(500, 300), const Offset(0, 200));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(dashes(tester), [10, 18, 10]);
  });

  testWidgets('scrolling changes what is over the list without rebuilding '
      'the list', (tester) async {
    await pump(tester, messages(const {20: 'Planning', 40: 'Building'}));
    Widget item() => tester.widget(find.byKey(const ValueKey('m57')));
    final before = item();

    await tester.dragFrom(const Offset(500, 300), const Offset(0, 400));
    await tester.pumpAndSettle();
    // The way back down, and the pinned prompt, now shown.
    expect(
      find.byIcon(Icons.keyboard_double_arrow_down_rounded),
      findsOneWidget,
    );
    expect(identical(item(), before), isTrue);
  });

  testWidgets('in a narrow chat, messages start clear of the rail', (
    tester,
  ) async {
    await pump(
      tester,
      messages(const {20: 'Planning', 40: 'Building'}),
      width: 400,
    );
    final railRight = tester.getTopRight(rail()).dx;
    for (final seq in [58, 59]) {
      expect(
        tester.getTopLeft(find.textContaining('Message $seq').first).dx,
        greaterThanOrEqualTo(railRight),
      );
    }
  });

  testWidgets('no start line where a chapter heads the chat', (tester) async {
    await pump(tester, messages(const {0: 'Opening', 30: 'Later'}));
    expect(dashes(tester), hasLength(2));
  });
}
