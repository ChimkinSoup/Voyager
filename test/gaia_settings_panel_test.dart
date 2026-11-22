import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';

import 'fakes/gaia_fakes.dart';

/// The settings panel's shell, Actions and Queue tabs (GAIA_SETTINGS_HLD.md
/// Phase 1): it opens over the sidebar and chat and gives them back as they
/// were, and each tab reads and writes through the pipe.
void main() {
  final at = DateTime.utc(2026, 11, 22);

  GaiaChat chat(String id, String title, {bool drain = false}) => GaiaChat(
    id: id,
    title: title,
    createdAt: at,
    updatedAt: at,
    lastMessageAt: at,
    tier: GaiaTier.standard,
    drain: drain,
  );

  GaiaQueueItem queued(String id, String text, double order, {String? chatId}) =>
      GaiaQueueItem(
        id: id,
        chatId: chatId,
        text: text,
        order: order,
        createdAt: at,
        updatedAt: at,
      );

  GaiaMessage committed({bool undone = false}) => GaiaMessage(
    id: 'm1',
    chatId: 'c2',
    seq: 1,
    role: GaiaMessageRole.assistant,
    parts: [
      GaiaCardPart(
        id: 'card',
        kind: GaiaCardKind.proposal,
        tool: 'propose_todo',
        proposal: const GaiaProposal(
          entity: GaiaProposalEntity.todo,
          fields: {'title': 'Call the dentist'},
        ),
      ).decided(GaiaCardState.accepted, {
        'fields': {'title': 'Call the dentist'},
        'committed': {'id': 't1'},
        'undoneAt': ?(undone ? at.toIso8601String() : null),
      }),
    ],
    status: GaiaMessageStatus.complete,
    createdAt: at,
    updatedAt: at,
  );

  late List<(String, Map<String, Object?>)> requests;
  late List<GaiaQueueItem> queue;
  late bool undone;
  late FakeGaiaPipe main;

  int asked(String method) =>
      requests.where((request) => request.$1 == method).length;

  Future<GaiaController> pump(
    WidgetTester tester, {
    GaiaSettingsPanel? panel,
  }) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    requests = [];
    undone = false;
    queue = [
      queued('q1', 'First global', 1),
      queued('q2', 'Second global', 2),
      queued('q3', 'Parser follow-up', 1, chatId: 'c1'),
    ];
    late FakeGaiaPipe companion;
    main = FakeGaiaPipe.main()
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        requests.add((method, params));
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
              chat('c1', 'Parser', drain: true).toJson(),
              chat('c2', 'Errands').toJson(),
            ];
          case 'messages':
          case 'drafts':
          case 'btws':
            return <Object?>[];
          case 'queue':
            return [for (final item in queue) item.toJson()];
          case 'actions':
            return [
              {
                'chat': chat('c2', 'Errands').toJson(),
                'message': committed(undone: undone).toJson(),
                'cardId': 'card',
              },
            ];
          case 'undoAction':
            if (undone) throw GaiaPipeException('Undone already.');
            undone = true;
            return null;
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
      panel: panel,
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

  /// Lets the pipe's answers in, then the frames they cause.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pressCtrlComma(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
  }

  Finder tab(String label) => find.descendant(
    of: find.byType(GaiaSettingsPanelView),
    matching: find.text(label),
  );

  testWidgets('Ctrl+, opens it over the chat; Esc gives the chat back with '
      'its draft', (tester) async {
    final controller = await pump(tester);
    controller.draft.text = 'half a thought';
    await tester.pump();
    expect(find.text('Parser'), findsWidgets);

    await pressCtrlComma(tester);
    expect(controller.panel.open, isTrue);
    expect(find.byType(GaiaSettingsPanelView), findsOneWidget);
    // The header's title and the tab.
    expect(find.text('Settings'), findsNWidgets(2));
    for (final label in [
      'Memories',
      'Actions',
      'Queue',
      'Status',
      'Setup',
      'Settings',
    ]) {
      expect(tab(label), findsOneWidget, reason: label);
    }
    // The chat is kept underneath, hidden, rather than rebuilt.
    expect(find.text('half a thought'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(controller.panel.open, isFalse);
    expect(find.byType(GaiaSettingsPanelView), findsNothing);
    expect(controller.currentChatId, 'c1');
    expect(find.text('half a thought'), findsOneWidget);

    // Ctrl+, again toggles it, both ways.
    await pressCtrlComma(tester);
    expect(controller.panel.open, isTrue);
    await pressCtrlComma(tester);
    expect(controller.panel.open, isFalse);
  });

  testWidgets('the stars behind it stop while it covers them', (tester) async {
    final controller = await pump(tester);
    controller.focused.value = true;
    expect(controller.skyActive.value, isTrue);
    await pressCtrlComma(tester);
    expect(controller.skyActive.value, isFalse);
    await pressCtrlComma(tester);
    expect(controller.skyActive.value, isTrue);
    controller.focused.value = false;
    expect(controller.skyActive.value, isFalse);
  });

  testWidgets("the sidebar's gear opens it, and × closes it", (tester) async {
    final controller = await pump(tester);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await settle(tester);
    expect(controller.panel.open, isTrue);

    await tester.tap(
      find.descendant(
        of: find.byType(GaiaSettingsPanelView),
        matching: find.byIcon(Icons.close),
      ),
    );
    await settle(tester);
    expect(controller.panel.open, isFalse);
  });

  testWidgets('from a floater, it opens in the Gaia window', (tester) async {
    final controller = await pump(tester);
    await tester.runAsync(() => controller.onHotkey('small'));
    await tester.pump();
    expect(controller.layout, isNot(GaiaMode.window));

    await tester.runAsync(() => controller.openPanel());
    await settle(tester);
    expect(controller.layout, GaiaMode.window);
    expect(find.byType(GaiaSettingsPanelView), findsOneWidget);
  });

  testWidgets('Ctrl+1 to Ctrl+6 pick the tabs', (tester) async {
    final controller = await pump(tester);
    await pressCtrlComma(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(controller.panel.tab, GaiaPanelTab.queue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(controller.panel.tab, GaiaPanelTab.actions);
  });

  group('Actions', () {
    testWidgets('lists the log, asks again on `changed`, and undoes', (
      tester,
    ) async {
      final controller = await pump(tester);
      await pressCtrlComma(tester);
      expect(controller.panel.tab, GaiaPanelTab.actions);
      expect(find.text('New task "Call the dentist"'), findsOneWidget);
      expect(find.text('Errands'), findsWidgets);
      final before = asked('actions');

      main.notify('changed');
      await settle(tester);
      expect(asked('actions'), before + 1);

      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(
        requests.where((r) => r.$1 == 'undoAction').single.$2,
        {'messageId': 'm1', 'cardId': 'card'},
      );
      // Read again: struck through, with no Undo.
      expect(find.text('Undo'), findsNothing);
      final title = tester.widget<Text>(
        find.text('New task "Call the dentist"'),
      );
      expect(title.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('a tab out of view does not ask again on `changed`', (
      tester,
    ) async {
      await pump(tester);
      await pressCtrlComma(tester);
      await tester.tap(tab('Queue'));
      await settle(tester);
      final before = asked('actions');
      main.notify('changed');
      await settle(tester);
      expect(asked('actions'), before);
    });

    testWidgets("a refused undo says why", (tester) async {
      await pump(tester);
      undone = false;
      await pressCtrlComma(tester);
      // Undone elsewhere meanwhile.
      undone = true;
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(find.text("Couldn't undo"), findsOneWidget);
      expect(find.text('Undone already.'), findsOneWidget);
    });

    testWidgets('its chat opens that chat and closes the panel', (
      tester,
    ) async {
      final controller = await pump(tester);
      await pressCtrlComma(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(GaiaSettingsPanelView),
          matching: find.text('Errands'),
        ),
      );
      await settle(tester);
      expect(controller.panel.open, isFalse);
      expect(controller.currentChatId, 'c2');
    });
  });

  group('Queue', () {
    Future<GaiaController> openQueue(WidgetTester tester) async {
      final controller = await pump(tester);
      await pressCtrlComma(tester);
      await tester.tap(tab('Queue'));
      await settle(tester);
      return controller;
    }

    testWidgets('groups by chat, with the global queue', (tester) async {
      await openQueue(tester);
      expect(find.text('Global queue'), findsOneWidget);
      expect(find.text('First global'), findsOneWidget);
      expect(find.text('Second global'), findsOneWidget);
      expect(find.text('Parser follow-up'), findsOneWidget);
      final drain = tester.widget<Switch>(find.byType(Switch));
      expect(drain.value, isTrue);
    });

    testWidgets('click to edit in place: Enter saves, Esc cancels', (
      tester,
    ) async {
      final controller = await openQueue(tester);
      await tester.tap(find.text('First global'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'First, edited');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(
        requests.where((r) => r.$1 == 'queueEdit').single.$2,
        {'id': 'q1', 'text': 'First, edited'},
      );

      await tester.tap(find.text('Second global'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'never');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(asked('queueEdit'), 1);
      expect(find.byType(TextField), findsNothing);
      // Esc in the field ended the edit, not the panel.
      expect(controller.panel.open, isTrue);
    });

    testWidgets('delete, and the drain switch', (tester) async {
      await openQueue(tester);
      final row = find.ancestor(
        of: find.text('Second global'),
        matching: find.byType(MouseRegion),
      );
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: tester.getCenter(row.first));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byTooltip('Delete').at(1));
      await settle(tester);
      expect(requests.where((r) => r.$1 == 'queueDelete').single.$2, {
        'id': 'q2',
      });

      await tester.tap(find.byType(Switch));
      await settle(tester);
      expect(requests.where((r) => r.$1 == 'setDrain').single.$2, {
        'chatId': 'c1',
        'drain': false,
      });
    });

    testWidgets('dragging a prompt above another reorders it', (tester) async {
      await openQueue(tester);
      final handle = find.byIcon(Icons.drag_indicator).at(1);
      final first = tester.getCenter(find.text('First global'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 100));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(
          Offset(0, (first.dy - tester.getCenter(handle).dy - 20) / 10),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));
      await settle(tester);
      final reorder = requests.where((r) => r.$1 == 'queueReorder').single.$2;
      expect(reorder['id'], 'q2');
      expect(reorder['order'], lessThan(1));
    });
  });

  test('the last tab is kept across restarts', () async {
    final dir = await Directory.systemTemp.createTemp('gaia_panel');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/settings_panel.json');
    final panel = GaiaSettingsPanel(file: file)..setTab(GaiaPanelTab.queue);
    // Its save goes in turn; one more change waits on it.
    panel.setTab(GaiaPanelTab.setup);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final again = GaiaSettingsPanel(file: file);
    await again.load();
    expect(again.tab, GaiaPanelTab.setup);
    expect(again.open, isFalse);
  });
}
