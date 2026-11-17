import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/page/gaia_page.dart';
import 'package:voyager/features/gaia/page/gaia_providers.dart';

/// The Memories tab's topic tree (GAIA_MEMORY_TOPICS_HLD.md §3.2, Phase 4):
/// browsing by topic, dragging memories and topics on the desktop, the
/// topic chips, search, and the phone's menus.

final _at = DateTime.utc(2026, 11, 16, 12);

GaiaMemoryTopic _topic(String id, String name, {String? parentId}) =>
    GaiaMemoryTopic(
      id: id,
      name: name,
      parentId: parentId,
      createdAt: _at,
      updatedAt: _at,
      version: 1,
    );

GaiaMemory _memory(String id, String text, List<String> topicIds) => GaiaMemory(
  id: id,
  text: text,
  status: GaiaMemoryStatus.active,
  topicIds: topicIds,
  createdAt: _at,
  updatedAt: _at,
  version: 1,
);

final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  late AppDatabase db;
  late DriftGaiaRepository repository;

  /// The Gaia page on its Memories tab, over University › CS246 › Final
  /// exam and Obsidian, with a memory in each of CS246, Final exam and
  /// Obsidian, and one Unsorted.
  /// [suggested] offers a new topic for memories, by id.
  Future<void> pump(
    WidgetTester tester, {
    double width = 1300,
    Map<String, GaiaSuggestedTopic> suggested = const {},
    List<Override> overrides = const [],
    Future<void> Function()? seed,
  }) async {
    tester.view.physicalSize = Size(width, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    db = AppDatabase.inMemory();
    repository = DriftGaiaRepository(db);
    await tester.runAsync(
      () => repository.upsertMemoryTopics(
        [
          _topic('uni', 'University'),
          _topic('cs246', 'CS246', parentId: 'uni'),
          _topic('exam', 'Final exam', parentId: 'cs246'),
          _topic('obs', 'Obsidian'),
        ],
        [
          for (final memory in [
            _memory('m1', 'Submit with marmoset', ['cs246']),
            _memory('m2', 'Exam is in PAC', ['exam']),
            _memory('m3', 'Vault lives in Dropbox', ['obs']),
            _memory('m4', 'Likes tea', []),
          ])
            memory.copyWith(suggestedTopic: suggested[memory.id]),
        ],
      ),
    );
    if (seed != null) await tester.runAsync(seed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gaiaRepositoryProvider.overrideWithValue(repository),
          ...overrides,
        ],
        child: MaterialApp(
          theme: VoyagerTheme.light(),
          home: const Scaffold(body: GaiaPage()),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Memories'));
    await settle(tester);
  }

  tearDown(() async => db.close());

  Future<List<String>> topicsOf(WidgetTester tester, String id) async =>
      (await tester.runAsync(() => repository.getMemory(id)))!.topicIds;

  Future<GaiaMemoryTopic> topic(WidgetTester tester, String id) async =>
      (await tester.runAsync(() => repository.getMemoryTopic(id)))!;

  /// The tree's row for [name].
  Finder row(String name) => find.widgetWithText(ListTile, name).first;

  Future<void> drag(WidgetTester tester, Finder from, Finder onto) async {
    final gesture = await tester.startGesture(
      tester.getCenter(from),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(onto));
    await tester.pump();
    await gesture.up();
    await settle(tester);
  }

  testWidgets("a topic lists its subtopics' memories, each labelled with its "
      'path; without subtopics only its own (§18.4)', (tester) async {
    await pump(tester);
    expect(find.text('Unsorted'), findsOneWidget);
    await tester.tap(row('CS246'));
    await settle(tester);
    expect(find.text('Submit with marmoset'), findsOneWidget);
    expect(find.text('Exam is in PAC'), findsOneWidget);
    expect(find.text('University › CS246 › Final exam'), findsOneWidget);
    expect(find.text('Vault lives in Dropbox'), findsNothing);
    expect(find.text('Global'), findsNothing);

    await tester.tap(find.byType(Checkbox));
    await settle(tester);
    expect(find.text('Exam is in PAC'), findsNothing);
    expect(find.text('Submit with marmoset'), findsOneWidget);

    await tester.tap(row('Unsorted'));
    await settle(tester);
    expect(find.text('Likes tea'), findsOneWidget);
    expect(find.text('Submit with marmoset'), findsNothing);
  }, variant: _desktop);

  testWidgets(
    'dragging a memory onto a topic moves it within the selected subtree; '
    'Ctrl+drag adds it',
    (tester) async {
      await pump(tester);
      await tester.tap(row('University'));
      await settle(tester);
      await drag(tester, find.text('Exam is in PAC'), row('CS246'));
      expect(await topicsOf(tester, 'm2'), ['cs246']);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await drag(tester, find.text('Exam is in PAC'), row('Obsidian'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(await topicsOf(tester, 'm2'), ['cs246', 'obs']);
    },
    variant: _desktop,
  );

  testWidgets(
    'a topic dragged onto another goes under it, onto All memories to the '
    'root, and onto its own subtopic is refused',
    (tester) async {
      await pump(tester);
      await drag(tester, row('CS246'), row('Final exam'));
      expect((await topic(tester, 'cs246')).parentId, 'uni');

      await drag(tester, row('Obsidian'), row('CS246'));
      expect((await topic(tester, 'obs')).parentId, 'cs246');

      await drag(tester, row('Obsidian'), row('All memories'));
      expect((await topic(tester, 'obs')).parentId, isNull);
    },
    variant: _desktop,
  );

  testWidgets(
    "a topic chip's × takes the memory out; the search filters both panes",
    (tester) async {
      await pump(tester);
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Submit with marmoset'),
          matching: find.byTooltip('Remove from topic'),
        ),
      );
      await settle(tester);
      expect(await topicsOf(tester, 'm1'), isEmpty);
      expect(await topicsOf(tester, 'm2'), ['exam']);

      await tester.enterText(find.byType(TextField).first, 'dropbox');
      await settle(tester);
      expect(find.text('Vault lives in Dropbox'), findsOneWidget);
      expect(find.text('Likes tea'), findsNothing);
      expect(row('Obsidian'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'University'), findsNothing);

      // A topic's name finds its memories too, and the topics above it.
      await tester.enterText(find.byType(TextField).first, 'final');
      await settle(tester);
      expect(find.text('Exam is in PAC'), findsOneWidget);
      expect(find.text('Vault lives in Dropbox'), findsNothing);
      expect(row('University'), findsOneWidget);
    },
    variant: _desktop,
  );

  testWidgets(
    'a new topic offered for a memory shows as a chip that makes it, or × '
    "drops it; only an Unsorted memory with none offered has Suggest "
    '(GAIA_MEMORY_TOPICS_HLD.md §5)',
    (tester) async {
      await pump(
        tester,
        suggested: {
          'm3': (name: 'Plugins', parentId: 'obs'),
          'm1': (name: 'Tools', parentId: null),
        },
      );
      Finder suggest(String text) => find.descendant(
        of: find.widgetWithText(ListTile, text),
        matching: find.byTooltip('Suggest topics'),
      );
      expect(suggest('Likes tea'), findsOneWidget);
      expect(suggest('Exam is in PAC'), findsNothing);
      await tester.tap(find.text('+ New topic: Plugins under Obsidian'));
      await settle(tester);
      final made = (await tester.runAsync(
        repository.listMemoryTopics,
      ))!.singleWhere((topic) => topic.name == 'Plugins');
      expect(made.parentId, 'obs');
      expect(await topicsOf(tester, 'm3'), ['obs', made.id]);
      expect(find.textContaining('New topic: Plugins'), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(Container, '+ New topic: Tools'),
          matching: find.byIcon(PhosphorIconsRegular.x),
        ),
      );
      await settle(tester);
      final m1 = (await tester.runAsync(() => repository.getMemory('m1')))!;
      expect(m1.suggestedTopic, isNull);
      expect(m1.topicIds, ['cs246']);
    },
    variant: _desktop,
  );

  testWidgets(
    "a narrow desktop window, with the tree in a dialog, has a memory's "
    'Move to topic… menu',
    (tester) async {
      await pump(tester, width: 600);
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Likes tea'),
          matching: find.byTooltip('More'),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('Move to topic…'));
      await settle(tester);
      await tester.tap(find.widgetWithText(SimpleDialogOption, 'Obsidian'));
      await settle(tester);
      expect(await topicsOf(tester, 'm4'), ['obs']);
    },
    variant: _desktop,
  );

  testWidgets('right-click → New subtopic, Rename (also F2) and Delete', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(row('Obsidian'), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('New subtopic'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'Plugins');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(row('Plugins'), findsOneWidget);

    // The new one is selected; F2 renames it.
    await tester.tap(row('Plugins'));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'Community plugins');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(row('Community plugins'), findsOneWidget);

    await tester.tap(row('CS246'), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect(find.textContaining('subtopics move up to University'), findsOne);
    await tester.tap(find.text('Delete').last);
    await settle(tester);
    expect((await topic(tester, 'cs246')).isDeleted, isTrue);
    expect((await topic(tester, 'exam')).parentId, 'uni');
    expect(await topicsOf(tester, 'm1'), isEmpty);
  }, variant: _desktop);

  testWidgets(
    'right-click → Merge into… merges after asking, leaving the topic itself '
    'out of the list (Phase 6)',
    (tester) async {
      await pump(tester);
      await tester.tap(row('Final exam'), buttons: kSecondaryButton);
      await settle(tester);
      await tester.tap(find.text('Merge into…'));
      await settle(tester);
      expect(
        find.widgetWithText(SimpleDialogOption, 'Final exam'),
        findsNothing,
      );
      await tester.tap(find.widgetWithText(SimpleDialogOption, 'CS246'));
      await settle(tester);
      expect(find.textContaining('goes to the trash'), findsOneWidget);
      await tester.tap(find.text('Merge').last);
      await settle(tester);
      expect((await topic(tester, 'exam')).isDeleted, isTrue);
      expect(await topicsOf(tester, 'm2'), ['cs246']);
    },
    variant: _desktop,
  );

  testWidgets(
    "Unsorted's Sort these shows where each would go; × leaves a topic out, "
    'Accept files it, Skip drops it, and nothing moves before (§6)',
    (tester) async {
      final asked = <List<String>>[];
      await pump(
        tester,
        seed: () =>
            repository.upsertMemory(_memory('m5', 'Plays the cello', [])),
        overrides: [
          gaiaSortMemoriesProvider.overrideWithValue((memories) async {
            asked.add([for (final memory in memories) memory.id]);
            return {
              'm4': (
                topicIds: const ['obs', 'cs246'],
                suggested: null,
                tags: const ['drink'],
              ),
              'm5': (
                topicIds: const <String>[],
                suggested: (name: 'Music', parentId: null),
                tags: const <String>[],
              ),
            };
          }),
        ],
      );
      expect(find.text('Sort these'), findsNothing);
      await tester.tap(row('Unsorted'));
      await settle(tester);
      await tester.tap(find.text('Sort these'));
      await settle(tester);
      expect(asked.single, unorderedEquals(['m4', 'm5']));
      expect(find.text('Suggested:'), findsNWidgets(2));
      expect(find.text('Accept all (2)'), findsOneWidget);
      expect(await topicsOf(tester, 'm4'), isEmpty);

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(Container, 'Obsidian'),
          matching: find.byTooltip('Leave this topic out'),
        ),
      );
      await settle(tester);
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Likes tea'),
          matching: find.text('Accept'),
        ),
      );
      await settle(tester);
      final m4 = (await tester.runAsync(() => repository.getMemory('m4')))!;
      expect(m4.topicIds, ['cs246']);
      expect(m4.tags, ['drink']);
      expect(find.text('Likes tea'), findsNothing, reason: 'sorted now');

      await tester.tap(find.text('Skip'));
      await settle(tester);
      expect(find.text('Suggested:'), findsNothing);
      expect(await topicsOf(tester, 'm5'), isEmpty);
    },
    variant: _desktop,
  );

  testWidgets(
    'a memory filed some other way loses its Sort these suggestion, so back '
    'in Unsorted it shows none and is asked about again (§6)',
    (tester) async {
      final asked = <List<String>>[];
      await pump(
        tester,
        seed: () =>
            repository.upsertMemory(_memory('m5', 'Plays the cello', [])),
        overrides: [
          gaiaSortMemoriesProvider.overrideWithValue((memories) async {
            asked.add([for (final memory in memories) memory.id]);
            return {
              for (final memory in memories)
                memory.id: (
                  topicIds: const ['cs246'],
                  suggested: null,
                  tags: const <String>[],
                ),
            };
          }),
        ],
      );
      await tester.tap(row('Unsorted'));
      await settle(tester);
      await tester.tap(find.text('Sort these'));
      await settle(tester);
      expect(find.text('Suggested:'), findsNWidgets(2));

      Future<void> file(List<String> topicIds) => tester.runAsync(() async {
        final m4 = (await repository.getMemory('m4'))!;
        await repository.upsertMemory(m4.copyWith(topicIds: topicIds));
      });
      await file(['obs']);
      await settle(tester);
      await file([]);
      await settle(tester);
      expect(find.text('Likes tea'), findsOneWidget);
      expect(find.text('Suggested:'), findsOneWidget, reason: 'm5 only');

      await tester.tap(find.text('Sort these'));
      await settle(tester);
      expect(asked.last, ['m4']);
    },
    variant: _desktop,
  );

  testWidgets(
    "Accept all files each, making a new topic offered; one's new topic is "
    'made once (§6)',
    (tester) async {
      await pump(
        tester,
        seed: () =>
            repository.upsertMemory(_memory('m5', 'Plays the cello', [])),
        overrides: [
          gaiaSortMemoriesProvider.overrideWithValue(
            (memories) async => {
              for (final memory in memories)
                memory.id: (
                  topicIds: const <String>[],
                  suggested: (name: 'Hobbies', parentId: null),
                  tags: const <String>[],
                ),
            },
          ),
        ],
      );
      await tester.tap(row('Unsorted'));
      await settle(tester);
      await tester.tap(find.text('Sort these'));
      await settle(tester);
      await tester.tap(find.text('Accept all (2)'));
      await settle(tester);
      final hobbies = (await tester.runAsync(
        repository.listMemoryTopics,
      ))!.where((topic) => topic.name == 'Hobbies').toList();
      expect(hobbies, hasLength(1));
      expect(await topicsOf(tester, 'm4'), [hobbies.single.id]);
      expect(await topicsOf(tester, 'm5'), [hobbies.single.id]);
    },
    variant: _desktop,
  );

  testWidgets(
    "the inbox suggests a pin from this device's recall history, with Pin "
    'and Not now, and a merge, with Merge and Keep both (§3.3, §5)',
    (tester) async {
      await pump(
        tester,
        seed: () async {
          for (var i = 0; i < 8; i++) {
            await repository.recordRecall('c$i', ['m3'], _at);
          }
          await repository.upsertMemoryTopic(_topic('obs2', 'obsidian'));
        },
      );
      expect(find.text('Inbox (2)'), findsOneWidget);
      expect(
        find.text('Pin this? Recalled in 8 of the last 8 chats.'),
        findsOneWidget,
      );
      expect(find.text('Merge "obsidian" into "Obsidian"?'), findsOneWidget);

      await tester.tap(find.text('Keep both'));
      await settle(tester);
      expect(find.textContaining('Merge "obsidian"'), findsNothing);
      await tester.tap(find.text('Pin'));
      await settle(tester);
      expect(
        (await tester.runAsync(() => repository.getMemory('m3')))!.pinned,
        isTrue,
      );
      expect(find.textContaining('Pin this?'), findsNothing);
    },
    variant: _desktop,
  );

  testWidgets("on the phone, a memory's menu moves it and a topic's menu "
      'moves the topic', (tester) async {
    await pump(tester);
    Finder more(String text) => find.descendant(
      of: find.ancestor(
        of: find.text(text).first,
        matching: find.byType(ListTile),
      ),
      matching: find.byTooltip('More'),
    );
    await tester.tap(more('Likes tea'));
    await settle(tester);
    await tester.tap(find.text('Move to topic…'));
    await settle(tester);
    await tester.tap(find.widgetWithText(SimpleDialogOption, 'Obsidian'));
    await settle(tester);
    expect(await topicsOf(tester, 'm4'), ['obs']);

    await tester.tap(more('Obsidian'));
    await settle(tester);
    await tester.tap(find.text('Move under…'));
    await settle(tester);
    expect(
      find.widgetWithText(SimpleDialogOption, 'Obsidian'),
      findsNothing,
      reason: 'not under itself',
    );
    await tester.tap(find.widgetWithText(SimpleDialogOption, 'University'));
    await settle(tester);
    expect((await topic(tester, 'obs')).parentId, 'uni');
  });
}

/// Lets the database's writes and reads land, then rebuilds.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 400));
}
