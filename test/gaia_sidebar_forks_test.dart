import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';

GaiaChat _chat(String id, int day, {String? forkOf, bool pinned = false}) {
  final at = DateTime.utc(2026, 10, day);
  return GaiaChat(
    id: id,
    title: id,
    createdAt: at,
    updatedAt: at,
    lastMessageAt: at,
    forkOf: forkOf,
    pinned: pinned,
  );
}

/// A fork sits under its original chat in Gaia's sidebar, unless it's
/// pinned, and folds away with the original's chevron.
void main() {
  test('groups forks under their original, pinned forks on their own', () {
    final groups = gaiaForkGroups([
      _chat('Pinned fork', 20, forkOf: 'Root', pinned: true),
      _chat('Fork A', 30, forkOf: 'Root'),
      _chat('Fork B', 28, forkOf: 'Root'),
      _chat('Other', 27),
      _chat('Root', 25),
      _chat('Orphan', 24, forkOf: 'Deleted'),
    ]);
    expect(
      [
        for (final group in groups)
          [group.chat.id, for (final fork in group.forks) fork.id],
      ],
      [
        ['Pinned fork'],
        ['Other'],
        ['Root', 'Fork A', 'Fork B'],
        ['Orphan'],
      ],
    );
  });

  test('forkOf syncs', () {
    final chat = _chat('Fork', 1, forkOf: 'Root');
    expect(
      mergeGaiaChatFromRemote(gaiaChatToFirestore(chat), 'Fork').forkOf,
      'Root',
    );
    expect(GaiaChat.fromJson(chat.toJson()).forkOf, 'Root');
  });

  testWidgets('forks list under the original, fold, and follow its pin', (
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
          _chat('Pinned fork', 20, forkOf: 'Root', pinned: true).toJson(),
          _chat('Fork A', 30, forkOf: 'Root').toJson(),
          _chat('Fork B', 28, forkOf: 'Root').toJson(),
          _chat('Other', 27).toJson(),
          _chat('Root', 25).toJson(),
        ],
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

    List<String> order() {
      final shown = [
        for (final id in ['Pinned fork', 'Fork A', 'Fork B', 'Other', 'Root'])
          if (find.text(id).evaluate().isNotEmpty) id,
      ];
      return shown..sort(
        (a, b) => tester
            .getTopLeft(find.text(a))
            .dy
            .compareTo(tester.getTopLeft(find.text(b)).dy),
      );
    }

    Future<void> pick(String title, String item) async {
      await tester.tap(find.text(title), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text(item));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    Finder chevron(String label) => find.byWidgetPredicate(
      (widget) => widget is Icon && widget.semanticLabel == label,
    );

    expect(order(), ['Pinned fork', 'Other', 'Root', 'Fork A', 'Fork B']);
    final root = tester.getTopLeft(find.text('Root')).dx;
    expect(tester.getTopLeft(find.text('Fork A')).dx, greaterThan(root));
    expect(tester.getTopLeft(find.text('Pinned fork')).dx, root);
    // Only the original has one.
    expect(chevron('Hide forks'), findsOneWidget);

    await tester.tap(chevron('Hide forks'));
    await tester.pump(const Duration(seconds: 1));
    expect(order(), ['Pinned fork', 'Other', 'Root']);
    expect(controller.sidebar.collapsed, {'Root'});
    // Folding didn't open it.
    expect(controller.currentChatId, isNot('Root'));

    await tester.tap(chevron('Show forks'));
    await tester.pump(const Duration(seconds: 1));
    expect(order(), ['Pinned fork', 'Other', 'Root', 'Fork A', 'Fork B']);

    // Unpinned, it goes back under its original.
    await pick('Pinned fork', 'Unpin');
    expect(order(), ['Other', 'Root', 'Fork A', 'Fork B', 'Pinned fork']);

    // The original pinned takes its forks with it.
    await pick('Root', 'Pin');
    expect(order(), ['Root', 'Fork A', 'Fork B', 'Pinned fork', 'Other']);

    // A fork pinned goes up on its own.
    await pick('Fork B', 'Pin');
    expect(order(), ['Fork B', 'Root', 'Fork A', 'Pinned fork', 'Other']);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
