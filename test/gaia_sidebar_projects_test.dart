import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';

/// Gaia's sidebar groups chats by project (GAIA_PROJECTS_HLD.md §7.1): a
/// project folds open to its chats, a chat moves into one from its menu, and
/// a project deletes from its own, its chats with it when asked.
void main() {
  testWidgets('a project opens to its chats, takes a chat moved in, and '
      'deletes with them', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final at = DateTime.utc(2026, 11, 10);
    GaiaChat chat(String id, {String? projectId}) => GaiaChat(
      id: id,
      title: id,
      createdAt: at,
      updatedAt: at,
      lastMessageAt: at,
      projectId: projectId,
    );
    final writes = <(String, Map<String, Object?>)>[];
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        if (method case 'setProject' || 'deleteProject') {
          writes.add((method, params));
        }
        return switch (method) {
          'hello' => {
            'aborted': false,
            'accent': 0xFF7C9EFF,
            'deviceId': 'laptop',
            'settings': GaiaSettings.initial().toJson(),
          },
          'chats' => [
            chat('Loose').toJson(),
            chat('Planned', projectId: 'p1').toJson(),
          ],
          'projects' => [
            GaiaProject(
              id: 'p1',
              name: 'Trip',
              createdAt: at,
              updatedAt: at,
            ).toJson(),
          ],
          'drafts' || 'messages' => <Object?>[],
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

    Future<void> menu(String title) async {
      await tester.tap(find.text(title).first, buttons: kSecondaryButton);
      await settle();
    }

    // Folded shut: its chats hidden, and counted.
    expect(find.text('Planned'), findsNothing);
    expect(find.text('1 chat'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Trip')).dy,
      lessThan(tester.getTopLeft(find.text('Loose')).dy),
    );

    await tester.tap(find.text('Trip'));
    await settle();
    expect(find.text('Planned'), findsOneWidget);
    expect(find.text('1 chat'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Planned')).dy,
      lessThan(tester.getTopLeft(find.text('Chats')).dy),
    );

    await menu('Loose');
    await tester.tap(find.text('Move to project'));
    await settle();
    // The menu's row, over the sidebar's.
    await tester.tap(find.text('Trip').last);
    await settle();
    expect(writes.single.$1, 'setProject');
    expect(writes.single.$2, {'chatId': 'Loose', 'projectId': 'p1'});
    // Now under the project, and no Chats section left.
    expect(find.text('Chats'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Loose')).dy,
      greaterThan(tester.getTopLeft(find.text('Trip')).dy),
    );

    await menu('Trip');
    await tester.tap(find.text('Delete project…'));
    await settle();
    expect(find.text('Delete "Trip"?'), findsOneWidget);
    expect(
      find.text('Its 2 chats will stay, as chats with no project.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Also delete its 2 chats'));
    await settle();
    expect(
      find.text('Its 2 chats will go to the trash with it.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete'));
    await settle();
    expect(writes.last.$1, 'deleteProject');
    expect(writes.last.$2, {'projectId': 'p1', 'withChats': true});
    expect(find.text('Loose'), findsNothing);
    expect(find.text('Planned'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets("the header's project crumb picks a new chat's project and "
      'moves a chat in and out', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final at = DateTime.utc(2026, 11, 10);
    final writes = <Map<String, Object?>>[];
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        if (method == 'setProject') writes.add(params);
        return switch (method) {
          'hello' => {
            'aborted': false,
            'accent': 0xFF7C9EFF,
            'deviceId': 'laptop',
            'settings': GaiaSettings.initial().toJson(),
          },
          'chats' => [
            GaiaChat(
              id: 'Loose',
              title: 'Loose',
              createdAt: at,
              updatedAt: at,
              lastMessageAt: at,
            ).toJson(),
          ],
          'projects' => [
            GaiaProject(
              id: 'p1',
              name: 'Trip',
              createdAt: at,
              updatedAt: at,
            ).toJson(),
          ],
          'drafts' || 'messages' => <Object?>[],
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

    // The header's taps wait out its double click (which maximises), so
    // the menu opens a frame late and needs its own second to grow.
    Future<void> openCrumb(String tooltip) async {
      await tester.tap(find.byTooltip(tooltip));
      await settle();
      await settle();
    }

    // A new chat: no project yet, then Trip for its first send.
    expect(find.text('No project'), findsNothing);
    await openCrumb('Add to project');
    await tester.tap(find.text('Move to Trip'));
    await settle();
    expect(controller.newChatProject, 'p1');
    expect(find.byTooltip('Trip'), findsOneWidget);
    expect(writes, isEmpty);

    // A sent chat moves in from its header, and back out.
    await tester.tap(find.text('Loose'));
    await settle();
    expect(controller.currentChatId, 'Loose');
    await openCrumb('Add to project');
    await tester.tap(find.text('Move to Trip'));
    await settle();
    expect(writes.last, {'chatId': 'Loose', 'projectId': 'p1'});
    await openCrumb('Trip');
    expect(find.text('New chat in project'), findsOneWidget);
    await tester.tap(find.text('Remove from project'));
    await settle();
    expect(writes.last, {'chatId': 'Loose', 'projectId': null});
    expect(find.byTooltip('Add to project'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });
}
