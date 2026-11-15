import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';

/// Chats and projects dragged in Gaia's sidebar: a drag holds until newer
/// activity, pinned chats move only by hand, and a newly pinned chat goes
/// to the bottom of its pinned ones.

final _at = DateTime.utc(2026, 11, 14, 12);

GaiaChat _chat(
  String id, {
  String? projectId,
  bool pinned = false,
  int minutes = 0,
}) => GaiaChat(
  id: id,
  title: id,
  createdAt: _at,
  updatedAt: _at,
  lastMessageAt: _at.add(Duration(minutes: minutes)),
  projectId: projectId,
  pinned: pinned,
);

GaiaProject _project(String id) =>
    GaiaProject(id: id, name: id, createdAt: _at, updatedAt: _at, version: 1);

/// [chat] dragged between ranks [above] and [below], at minute [minutes].
GaiaChat _dragged(
  GaiaChat chat,
  double? above,
  double? below, {
  int minutes = 60,
}) => chat.copyWith(
  order: gaiaDropRank(above, below),
  orderedAt: _at.add(Duration(minutes: minutes)),
);

List<String> _ids(List<GaiaForkGroup> groups) => [
  for (final group in groups) group.chat.id,
];

void main() {
  test('a dragged chat holds its place until a newer message bumps it', () {
    final a = _chat('a', minutes: 3);
    final b = _chat('b', minutes: 2);
    final c = _chat('c', minutes: 1);
    // c dragged to the top.
    var chats = [a, b, _dragged(c, null, a.listRank)];
    expect(_ids(gaiaChatSections(chats, const []).chats), ['c', 'a', 'b']);

    // a dragged to the bottom, below b.
    chats = [_dragged(a, b.listRank, null), b, chats[2]];
    expect(_ids(gaiaChatSections(chats, const []).chats), ['c', 'b', 'a']);

    // A message in a after the drag puts it back by recency: on top.
    chats = [
      chats[0].copyWith(lastMessageAt: _at.add(const Duration(minutes: 90))),
      b,
      chats[2],
    ];
    expect(_ids(gaiaChatSections(chats, const []).chats), ['a', 'c', 'b']);
  });

  test('pinning puts a chat at the bottom of its pinned ones, and activity '
      'never moves a pinned chat', () {
    final first = gaiaPinned(_chat('first', minutes: 1), true, const []);
    final second = gaiaPinned(_chat('second', minutes: 5), true, [first]);
    final third = gaiaPinned(_chat('third', minutes: 9), true, [first, second]);
    var chats = [third, second, first, _chat('loose', minutes: 20)];
    var sections = gaiaChatSections(chats, const []);
    expect(_ids(sections.pinned), ['first', 'second', 'third']);
    expect(_ids(sections.chats), ['loose']);

    // A new message doesn't move it.
    chats = [
      third,
      second,
      first.copyWith(lastMessageAt: _at.add(const Duration(hours: 2))),
      chats[3],
    ];
    expect(_ids(gaiaChatSections(chats, const []).pinned), [
      'first',
      'second',
      'third',
    ]);

    // Dragging does: third to the top.
    chats = [_dragged(third, null, first.listRank), second, first, chats[3]];
    sections = gaiaChatSections(chats, const []);
    expect(_ids(sections.pinned), ['third', 'first', 'second']);
  });

  test("a chat pinned in a project goes below that project's pinned chats, "
      'not the loose ones', () {
    final loose = gaiaPinned(_chat('loose'), true, const []);
    final inTrip = gaiaPinned(
      _chat('in trip', projectId: 'trip', minutes: 1),
      true,
      [loose],
    );
    final recent = _chat('recent', projectId: 'trip', minutes: 30);
    final pinned = gaiaPinned(recent, true, [loose, inTrip]);
    final sections = gaiaChatSections(
      [loose, inTrip, pinned],
      [_project('trip')],
    );
    expect(_ids(sections.projects.single.groups), ['in trip', 'recent']);
    expect(_ids(sections.pinned), ['loose']);
  });

  test('unpinning puts a chat back where its recency does', () {
    final pinned = gaiaPinned(_chat('was pinned', minutes: 5), true, const []);
    final chats = [
      gaiaPinned(pinned, false, const []),
      _chat('newer', minutes: 9),
      _chat('older', minutes: 1),
    ];
    expect(chats.first.order, isNull);
    expect(_ids(gaiaChatSections(chats, const []).chats), [
      'newer',
      'was pinned',
      'older',
    ]);
  });

  test('a dragged project holds its place until one of its chats has a '
      'newer message', () {
    final chats = [
      _chat('a', projectId: 'a', minutes: 3),
      _chat('b', projectId: 'b', minutes: 2),
    ];
    final projects = [_project('a'), _project('b')];
    var sections = gaiaChatSections(chats, projects);
    expect(sections.projects.map((s) => s.project.id), ['a', 'b']);

    final moved = projects[1].copyWith(
      order: gaiaDropRank(null, sections.projects[0].rank),
      orderedAt: _at.add(const Duration(minutes: 60)),
    );
    sections = gaiaChatSections(chats, [projects[0], moved]);
    expect(sections.projects.map((s) => s.project.id), ['b', 'a']);

    sections = gaiaChatSections(
      [
        chats[0].copyWith(lastMessageAt: _at.add(const Duration(hours: 2))),
        chats[1],
      ],
      [projects[0], moved],
    );
    expect(sections.projects.map((s) => s.project.id), ['a', 'b']);
  });

  test('the order syncs, and an unpin clears it on the other device', () {
    final pinned = gaiaPinned(_chat('c'), true, const []);
    final remote = mergeGaiaChatFromRemote(
      gaiaChatToFirestore(pinned),
      'c',
      local: _chat('c'),
    );
    expect(remote.order, pinned.order);
    expect(remote.orderedAt, pinned.orderedAt);

    final unpinned = gaiaPinned(pinned, false, const []);
    final cleared = mergeGaiaChatFromRemote(
      gaiaChatToFirestore(unpinned),
      'c',
      local: pinned,
    );
    expect(cleared.order, isNull);
    expect(cleared.orderedAt, isNull);

    final project = _project(
      'p',
    ).copyWith(order: 12, orderedAt: _at.add(const Duration(minutes: 1)));
    final merged = mergeGaiaProjectFromRemote(
      gaiaProjectToFirestore(project),
      'p',
      local: _project('p'),
    );
    expect(merged.order, 12);
    expect(merged.orderedAt, project.orderedAt);
  });

  test('the companion pipe carries the order', () {
    final chat = _dragged(_chat('c'), 1, 3);
    final back = GaiaChat.fromJson(chat.toJson());
    expect(back.order, 2);
    expect(back.orderedAt, chat.orderedAt);
    final project = _project('p').copyWith(order: 4, orderedAt: _at);
    expect(GaiaProject.fromJson(project.toJson()).order, 4);
  });

  testWidgets('dragging in the sidebar reorders chats and projects, and a '
      'chat stops at the pinned line', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sent = <(String, Map<String, Object?>)>[];
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        sent.add((method, params));
        return switch (method) {
          'hello' => {
            'aborted': false,
            'accent': 0xFF7C9EFF,
            'deviceId': 'laptop',
            'settings': GaiaSettings.initial().toJson(),
          },
          'chats' => [
            gaiaPinned(_chat('Pin', minutes: 1), true, const []).toJson(),
            _chat('Top', minutes: 30).toJson(),
            _chat('Mid', minutes: 20).toJson(),
            _chat('Low', minutes: 10).toJson(),
            _chat('In trip', projectId: 'trip', minutes: 25).toJson(),
            _chat('At home', projectId: 'home', minutes: 15).toJson(),
          ],
          'projects' => [_project('trip').toJson(), _project('home').toJson()],
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

    List<String> order(List<String> titles) => [...titles]
      ..sort(
        (a, b) => tester
            .getTopLeft(find.text(a))
            .dy
            .compareTo(tester.getTopLeft(find.text(b)).dy),
      );

    Future<void> drag(String title, double dy) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(title)),
      );
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(Offset(0, dy / 10));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await gesture.up();
      // The drop's settling, then the list as reordered.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    const chats = ['Pin', 'Top', 'Mid', 'Low'];
    expect(order(chats), chats);
    expect(order(['trip', 'home']), ['trip', 'home']);

    // Low up above Top.
    await drag('Low', -2 * 38 - 19);
    expect(order(chats), ['Pin', 'Low', 'Top', 'Mid']);
    expect(sent.where((s) => s.$1 == 'reorderChat').single.$2['chatId'], 'Low');

    // Mid dragged up past the pinned one stops below it.
    await drag('Mid', -3 * 38 - 19);
    expect(order(chats), ['Pin', 'Mid', 'Low', 'Top']);

    // A project dragged above another.
    await drag('home', -38 - 19);
    expect(order(['trip', 'home']), ['home', 'trip']);
    expect(
      sent.where((s) => s.$1 == 'reorderProject').single.$2['projectId'],
      'home',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets("a project's chat dragged to the sidebar's bottom scrolls it", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 500);
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
          for (var i = 0; i < 30; i++)
            _chat('trip $i', projectId: 'trip', minutes: 60 - i).toJson(),
        ],
        'projects' => [_project('trip').toJson()],
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
    await controller.start();
    await controller.openWindow();
    await controller.sidebar.setProjectOpen('trip', true);
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));

    // The sidebar's own scroll, not the project's list's.
    final sidebar = tester
        .stateList<ScrollableState>(
          find.ancestor(
            of: find.text('trip 0'),
            matching: find.byType(Scrollable),
          ),
        )
        .firstWhere((s) => s.position.maxScrollExtent > 0)
        .position;
    expect(sidebar.pixels, 0);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('trip 0')),
    );
    final to = 480 - tester.getCenter(find.text('trip 0')).dy;
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, to / 10));
      await tester.pump(const Duration(milliseconds: 50));
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(sidebar.pixels, greaterThan(20));

    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a row dropped under the mouse stays lit, with no second '
      'flash as it lands', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
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
          _chat('Top', minutes: 30).toJson(),
          _chat('Mid', minutes: 20).toJson(),
          _chat('Low', minutes: 10).toJson(),
          _chat('In trip', projectId: 'trip', minutes: 25).toJson(),
          _chat('At home', projectId: 'home', minutes: 15).toJson(),
        ],
        'projects' => [_project('trip').toJson(), _project('home').toJson()],
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
    await controller.start();
    await controller.openWindow();
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));

    // The row's title as drawn: white while lit, grey once not.
    Color? shade(String title) =>
        DefaultTextStyle.of(tester.element(find.text(title))).style.color;

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    // Picked up and dropped [rows] rows up, by the mouse on its middle.
    Future<void> dropUp(String title, int rows) async {
      await mouse.moveTo(tester.getCenter(find.text(title)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(shade(title), Colors.white);
      await mouse.down(tester.getCenter(find.text(title)));
      for (var i = 0; i < 10; i++) {
        await mouse.moveBy(Offset(0, -38 * rows / 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await mouse.up();
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(shade(title), Colors.white, reason: 'frame $i after the drop');
      }
    }

    await dropUp('Low', 2);
    expect(controller.chats.first.id, 'Low');
    await dropUp('home', 1);
    expect(
      gaiaChatSections(
        controller.chats,
        controller.projects,
      ).projects.first.project.id,
      'home',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
