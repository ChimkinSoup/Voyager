import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';

/// Archived chats: off the chat lists, project and pinned ones too, into a
/// folded Archived section; unpinned on the way; back on a new message, a
/// pin, or Unarchive.

final _at = DateTime.utc(2026, 11, 14, 12);

GaiaChat _chat(
  String id, {
  String? projectId,
  bool pinned = false,
  int minutes = 0,
  String? forkOf,
}) => GaiaChat(
  forkOf: forkOf,
  id: id,
  title: id,
  createdAt: _at,
  updatedAt: _at,
  lastMessageAt: _at.add(Duration(minutes: minutes)),
  projectId: projectId,
  pinned: pinned,
);

List<String> _ids(List<GaiaForkGroup> groups) => [
  for (final group in groups) group.chat.id,
];

void main() {
  test('an archived chat leaves its list, keeping its project, and is '
      'unpinned', () {
    final pinned = gaiaPinned(_chat('pinned'), true, const []);
    final chats = [
      gaiaArchived(pinned, true),
      gaiaArchived(_chat('in trip', projectId: 'trip'), true),
      _chat('loose'),
      _chat('also in trip', projectId: 'trip'),
    ];
    expect(chats[0].pinned, isFalse);
    expect(chats[0].order, isNull);
    expect(chats[1].projectId, 'trip');
    final sections = gaiaChatSections(chats, [
      GaiaProject(id: 'trip', name: 'Trip', createdAt: _at, updatedAt: _at),
    ]);
    expect(sections.pinned, isEmpty);
    expect(_ids(sections.chats), ['loose']);
    expect(_ids(sections.projects.single.groups), ['also in trip']);
    expect(sections.projects.single.count, 1);
    expect(_ids(sections.archived), unorderedEquals(['pinned', 'in trip']));
  });

  test('a message after archiving, a pin, or Unarchive brings it back', () {
    final archived = gaiaArchived(_chat('c'), true);
    expect(archived.archived, isTrue);

    final messaged = archived.copyWith(
      lastMessageAt: archived.archivedAt!.add(const Duration(seconds: 1)),
    );
    expect(messaged.archived, isFalse);
    expect(_ids(gaiaChatSections([messaged], const []).chats), ['c']);

    expect(gaiaPinned(archived, true, const []).archived, isFalse);
    expect(gaiaArchived(archived, false).archived, isFalse);
    expect(gaiaArchived(archived, false).archivedAt, isNull);
  });

  test('a chat\'s forks are archived and unarchived with it', () {
    final parent = _chat('plan');
    final fork = _chat('plan (before rewind)', forkOf: 'plan');
    final other = _chat('other');

    final archived = gaiaArchivedWithForks(parent, true, [parent, fork, other]);
    expect([for (final chat in archived) chat.id], ['plan', fork.id]);
    expect(archived.every((chat) => chat.archived), isTrue);
    final sections = gaiaChatSections([...archived, other], const []);
    expect(_ids(sections.chats), ['other']);
    expect(_ids(sections.archived), ['plan']);
    expect(sections.archived.single.forks.single.id, fork.id);

    final back = gaiaArchivedWithForks(archived[0], false, archived);
    expect(back.any((chat) => chat.archived), isFalse);
    expect(back, hasLength(2));

    // A fork archived on its own goes alone.
    expect(gaiaArchivedWithForks(fork, true, [parent, fork]), hasLength(1));
  });

  test('a last message stamped ahead by another clock still archives', () {
    final ahead = _chat('c').copyWith(
      lastMessageAt: DateTime.now().toUtc().add(const Duration(minutes: 3)),
    );
    expect(gaiaArchived(ahead, true).archived, isTrue);
  });

  test('archiving syncs, and an unarchive clears it on the other device', () {
    final archived = gaiaArchived(_chat('c'), true);
    final remote = mergeGaiaChatFromRemote(
      gaiaChatToFirestore(archived),
      'c',
      local: _chat('c'),
    );
    expect(remote.archivedAt, archived.archivedAt);
    expect(remote.archived, isTrue);

    final cleared = mergeGaiaChatFromRemote(
      gaiaChatToFirestore(gaiaArchived(archived, false)),
      'c',
      local: archived,
    );
    expect(cleared.archivedAt, isNull);

    // The companion pipe carries it too.
    expect(
      GaiaChat.fromJson(archived.toJson()).archivedAt,
      archived.archivedAt,
    );
  });

  testWidgets('the menu archives a chat into the folded Archived section, '
      'and unarchives it', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final writes = <Map<String, Object?>>[];
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        if (method == 'setArchived') writes.add(params);
        return switch (method) {
          'hello' => {
            'aborted': false,
            'accent': 0xFF7C9EFF,
            'deviceId': 'laptop',
            'settings': GaiaSettings.initial().toJson(),
          },
          'chats' => [
            _chat('Newer', minutes: 1).toJson(),
            _chat('Older').toJson(),
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

    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> pick(String title, String item) async {
      await tester.tap(find.text(title), buttons: kSecondaryButton);
      await settle();
      await tester.tap(find.text(item));
      await settle();
    }

    expect(find.text('Archived'), findsNothing);

    await pick('Older', 'Archive');
    expect(writes.single, {'chatId': 'Older', 'archived': true});
    expect(find.text('Archived'), findsOneWidget);
    // Folded away at first.
    expect(find.text('Older'), findsNothing);
    expect(find.text('Newer'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.expand_more));
    await settle();
    expect(find.text('Older'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Archived')).dy,
      lessThan(tester.getTopLeft(find.text('Older')).dy),
    );

    await pick('Older', 'Unarchive');
    expect(writes.last, {'chatId': 'Older', 'archived': false});
    expect(find.text('Archived'), findsNothing);
    expect(find.text('Older'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  test('a chat archived as it was made, as an Ask Gaia chat is, stays '
      'archived through its messages until it is unarchived '
      '(GAIA_SETTINGS_HLD.md §7.2)', () {
    final made = _chat('about').copyWith(archivedAt: _at);
    expect(made.archived, isTrue);
    final answered = made.copyWith(
      lastMessageAt: _at.add(const Duration(minutes: 5)),
    );
    expect(answered.archived, isTrue);
    expect(gaiaArchived(answered, false).archived, isFalse);
    // Archived again later, a message brings it back as any other.
    final again = gaiaArchived(gaiaArchived(answered, false), true);
    expect(
      again
          .copyWith(
            lastMessageAt: DateTime.now().toUtc().add(
              const Duration(minutes: 1),
            ),
          )
          .archived,
      isFalse,
    );
    expect(
      GaiaChat.fromJson(answered.toJson()).archived,
      isTrue,
      reason: 'as it syncs',
    );
  });
}
