import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/page/gaia_page.dart';
import 'package:voyager/features/gaia/page/gaia_providers.dart';

/// The Memories tab's topic tree (GAIA_MEMORY_TOPICS_HLD.md §3.2, Phase 4) on
/// the phone, the one platform that still has the page's tabs
/// (GAIA_SETTINGS_HLD.md §9).

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
    await tester.tap(find.textContaining(RegExp(r'^Memories')));
    await settle(tester);
  }

  tearDown(() async => db.close());

  Future<List<String>> topicsOf(WidgetTester tester, String id) async =>
      (await tester.runAsync(() => repository.getMemory(id)))!.topicIds;

  Future<GaiaMemoryTopic> topic(WidgetTester tester, String id) async =>
      (await tester.runAsync(() => repository.getMemoryTopic(id)))!;

  testWidgets(
    'a memory revealed as the page opens is scrolled to once the memories '
    'load (BUG-383)',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      db = AppDatabase.inMemory();
      repository = DriftGaiaRepository(db);
      await tester.runAsync(
        () => repository.upsertMemoryTopics(const [], [
          for (var i = 0; i < 60; i++) _memory('m$i', 'Memory number $i', []),
        ]),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gaiaRepositoryProvider.overrideWithValue(repository),
            gaiaRevealMemoryProvider.overrideWith((ref) => 'm0'),
          ],
          child: MaterialApp(
            theme: VoyagerTheme.light(),
            home: const Scaffold(body: GaiaPage()),
          ),
        ),
      );
      await settle(tester);
      final shown = tester.getRect(find.text('Memory number 0'));
      expect(shown.top, greaterThanOrEqualTo(0));
      expect(shown.bottom, lessThanOrEqualTo(800));
    },
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
