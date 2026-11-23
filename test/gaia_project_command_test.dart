import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';

import 'fakes/gaia_fakes.dart';

/// `/project` and `/move` (GAIA_PROJECTS_HLD.md §7.5): the palette lists the
/// projects, the rest of the line filters them, and Enter moves the chat,
/// with a toast to undo it.
void main() {
  final at = DateTime.utc(2026, 11, 9);

  GaiaProject project(String id, String name) =>
      GaiaProject(id: id, name: name, createdAt: at, updatedAt: at);

  late List<(String, Map<String, Object?>)> requests;

  Future<GaiaController> pump(
    WidgetTester tester, {
    List<GaiaProject>? projects,
    String? chatProject,
  }) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    requests = [];
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        requests.add((method, {...params}));
        switch (method) {
          case 'hello':
            return {
              'aborted': false,
              'accent': 0xFF7C9EFF,
              'deviceId': 'laptop',
              'settings': GaiaSettings.initial().toJson(),
            };
          case 'projects':
            return [
              for (final p
                  in projects ??
                      [project('p1', 'Trip'), project('p2', 'Taxes')])
                p.toJson(),
            ];
          case 'chats':
            return [
              GaiaChat(
                id: 'c1',
                title: 'Parser',
                createdAt: at,
                updatedAt: at,
                lastMessageAt: at,
                tier: GaiaTier.standard,
                projectId: chatProject,
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
    return controller;
  }

  // The toast's ring never settles.
  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(GaiaTextField), text);
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> enter(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 500));
  }

  List<String> rows(WidgetTester tester) => [
    for (final item
        in tester.widget<GaiaPalette>(find.byType(GaiaPalette)).items)
      '${item.label}${item.accented ?? ''}',
  ];

  List<Map<String, Object?>> moves() => [
    for (final (method, params) in requests)
      if (method == 'setProject') params,
  ];

  testWidgets('picked from the palette, it lists the projects; the line '
      'filters them and Enter moves the chat, with a toast to undo', (
    tester,
  ) async {
    final controller = await pump(tester);
    await type(tester, '/proj');
    await enter(tester);
    expect(controller.draft.text, '/project ');
    expect(rows(tester), unorderedEquals(['Move to Trip', 'Move to Taxes']));

    await type(tester, '/project tax');
    expect(rows(tester), ['Move to Taxes']);
    await enter(tester);
    expect(controller.draft.text, '');
    expect(controller.currentChat!.projectId, 'p2');
    expect(moves().single['projectId'], 'p2');

    await tester.tap(find.text('Click to undo'));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentChat!.projectId, isNull);
    expect(moves().last['projectId'], isNull);
  });

  testWidgets('/move does the same, keeping the rest of the draft', (
    tester,
  ) async {
    final controller = await pump(tester);
    await type(tester, 'hello there /move');
    await enter(tester);
    expect(controller.draft.text, '/project \nhello there ');

    await type(tester, '/project trip\nhello there ');
    await enter(tester);
    expect(controller.currentChat!.projectId, 'p1');
    expect(controller.draft.text, 'hello there ');

    // Typed out whole, it's the same.
    await type(tester, '/move tax');
    expect(rows(tester), ['Move to Taxes']);
  });

  testWidgets('in a project: that one is left out, and Remove from project '
      'is offered', (tester) async {
    final controller = await pump(tester, chatProject: 'p1');
    await type(tester, '/project ');
    expect(rows(tester), ['Move to Taxes', 'Remove from project']);
    await type(tester, '/project rem');
    await enter(tester);
    expect(controller.currentChat!.projectId, isNull);
  });

  testWidgets('with no project matching, Enter neither moves nor sends', (
    tester,
  ) async {
    final controller = await pump(tester);
    await type(tester, '/project zzz');
    expect(find.byType(GaiaPalette), findsNothing);
    await enter(tester);
    expect(controller.draft.text, '/project zzz');
    expect(moves(), isEmpty);
    expect(controller.messages, isEmpty);
  });

  testWidgets('a new chat sets the project its first send goes in', (
    tester,
  ) async {
    final controller = await pump(tester);
    controller.newChat();
    await tester.pump();
    await type(tester, '/project trip');
    await enter(tester);
    expect(controller.newChatProject, 'p1');
    expect(moves(), isEmpty);
  });

  testWidgets('two projects of one name both show', (tester) async {
    await pump(
      tester,
      projects: [project('p1', 'Trip'), project('p2', 'Trip')],
    );
    await type(tester, '/project ');
    expect(rows(tester), ['Move to Trip', 'Move to Trip']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recalled with Up, Enter picks it as typed', (tester) async {
    final controller = await pump(tester);
    await type(tester, '/project tax');
    await enter(tester);
    expect(controller.currentChat!.projectId, 'p2');

    await type(tester, '/project rem');
    await enter(tester);
    expect(controller.currentChat!.projectId, isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.draft.text, '/project tax');
    // Its rows shut, the send key sends it (GAIA_HISTORY_HLD.md §4.4).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.currentChat!.projectId, 'p2');
    expect(controller.draft.text, '');
  });

  testWidgets('picked again over its own line, it doesn\'t add another', (
    tester,
  ) async {
    final controller = await pump(tester);
    await type(tester, 'hello /proj');
    await enter(tester);
    expect(controller.draft.text, '/project \nhello ');
    await type(tester, '/project \nhello /proj');
    await enter(tester);
    expect(controller.draft.text, '/project \nhello ');
  });

  testWidgets('its undo leaves a later move alone', (tester) async {
    final controller = await pump(tester);
    await type(tester, '/project tax');
    await enter(tester);
    await tester.runAsync(() => controller.moveChat('c1', 'p1'));
    await tester.tap(find.text('Click to undo'));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentChat!.projectId, 'p1');
  });

  testWidgets('the queue key leaves a /project draft be', (tester) async {
    final controller = await pump(tester);
    await type(tester, '/project \nhello');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.draft.text, '/project \nhello');
    expect([for (final (m, _) in requests) m], isNot(contains('enqueue')));
  });
}
