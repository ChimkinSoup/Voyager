// End-to-end cover for the Rankings page surface: the two sections split on
// the overall score, the stats band scoped to what is actually on screen, the
// status chips narrowing the queue, the score popover promoting a row out of
// it, and the row menu acting on the entry under the pointer.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_edit_panel.dart';
import 'package:voyager/features/rankings/rankings_header.dart';
import 'package:voyager/features/rankings/rankings_page.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';
import 'package:voyager/features/rankings/rankings_row.dart';
import 'package:voyager/features/rankings/rankings_score_input.dart';
import 'package:voyager/features/rankings/rankings_score_stars.dart';
import 'package:voyager/features/rankings/rankings_tags_field.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.utc(2026, 8, 1);

RankingCategory makeCategory({
  String name = 'Shows',
  bool childUnitsEnabled = true,
  int parentScoreMax = 5,
}) => RankingCategory(
  id: newId(),
  name: name,
  colorValue: 0xFF7C9EFF,
  childUnitsEnabled: childUnitsEnabled,
  parentScoreMax: parentScoreMax,
  createdAt: _now,
  updatedAt: _now,
);

RankingParent makeParent({
  required String categoryId,
  required String title,
  double? score,
  RankingStatus status = RankingStatus.queued,
  int queueSortOrder = 0,
  String notes = '',
  List<String> tags = const [],
}) => RankingParent(
  id: newId(),
  categoryId: categoryId,
  title: title,
  overallScore: score,
  status: status,
  queueSortOrder: queueSortOrder,
  notes: notes,
  tags: tags,
  createdAt: _now,
  updatedAt: _now,
);

/// The band's copy of a status word, not the one a queued row wears.
Finder chipText(String label) => find.descendant(
  of: find.byType(RankingsStatsBand),
  matching: find.text(label),
);

Future<({AppDatabase db, ProviderContainer container})> pumpRankingsPage(
  WidgetTester tester, {
  required Future<void> Function(DriftRankingRepository repo) seed,
}) async {
  // Wide and tall: the band is a long row, and the list sits beside a 420px
  // panel once one is open.
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  await seed(DriftRankingRepository(db));

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  // Warmed here rather than left to the first build: nothing in a widget test
  // drives these to completion on its own, and a cold read returns null.
  await container.read(settingsProvider.future);
  final categories = await container.read(rankingCategoriesProvider.future);
  for (final category in categories) {
    await container.read(rankingParentsProvider(category.id).future);
    await container.read(rankingChildrenByParentProvider(category.id).future);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: RankingsPage()),
    ),
  );
  await tester.pumpAndSettle();
  return (db: db, container: container);
}

RankingChild makeChild({
  required String parentId,
  required String name,
  double? score,
  int sortOrder = 0,
}) => RankingChild(
  id: newId(),
  parentId: parentId,
  name: name,
  overallScore: score,
  sortOrder: sortOrder,
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  testWidgets('with no categories, offers to make the first one', (
    tester,
  ) async {
    await pumpRankingsPage(tester, seed: (_) async {});

    expect(find.text('No categories yet'), findsOneWidget);
    expect(find.text('Create a category'), findsOneWidget);
  });

  testWidgets('splits entries into the queue and the ranked list', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Severance', score: 4.5),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Andor'),
        );
      },
    );

    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Ranked'), findsOneWidget);
    expect(find.text('Severance'), findsOneWidget);
    expect(find.text('Andor'), findsOneWidget);
    // The queued row wears its status instead of a score. The band carries the
    // word too, so this is the row's copy.
    expect(
      find.descendant(
        of: find.byType(RankingsStatsBand),
        matching: find.text('Queued'),
      ),
      findsOneWidget,
    );
    expect(find.text('Queued'), findsNWidgets(2));
  });

  testWidgets('the band counts and averages only the ranked entries', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'A', score: 4),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'B', score: 5),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'C'),
        );
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'D',
            status: RankingStatus.inProgress,
          ),
        );
      },
    );

    expect(chipText('ranked'), findsOneWidget);
    expect(chipText('2'), findsOneWidget);
    expect(chipText('avg'), findsOneWidget);
    expect(chipText('4.5'), findsOneWidget);
    // One of each unranked kind, counted on its own chip.
    expect(chipText('In progress'), findsOneWidget);
    expect(chipText('1'), findsNWidgets(2));
  });

  testWidgets('the band re-counts against the search, not the category', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Severance', score: 5),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Andor', score: 3),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Andromeda'),
        );
      },
    );

    expect(chipText('2'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'and');
    await tester.pumpAndSettle();

    // One ranked match left, so the average is that entry's own score and the
    // queued match is the only thing the chips can still count.
    expect(chipText('1'), findsNWidgets(2));
    expect(chipText('3'), findsOneWidget);
  });

  testWidgets('a status chip narrows the queue and nothing else', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Severance', score: 5),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Andor'),
        );
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Foundation',
            status: RankingStatus.inProgress,
          ),
        );
      },
    );

    await tester.tap(chipText('In progress'));
    await tester.pumpAndSettle();

    expect(find.text('Foundation'), findsOneWidget);
    expect(find.text('Andor'), findsNothing);
    // A ranked row has no status left to match, so it never leaves.
    expect(find.text('Severance'), findsOneWidget);
    // The counts are measured before the chips, so switching one on does not
    // empty the other.
    expect(chipText('1'), findsNWidgets(3));

    await tester.tap(chipText('In progress'));
    await tester.pumpAndSettle();
    expect(find.text('Andor'), findsOneWidget);
  });

  testWidgets('a constrained score range takes the queue with it', (
    tester,
  ) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Severance', score: 5),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Andor'),
        );
      },
    );

    expect(find.text('Queue'), findsOneWidget);

    harness.container.read(rankingFiltersProvider.notifier).state =
        const RankingFilters(scoreMin: 4);
    await tester.pumpAndSettle();

    // An unranked entry has no score to fall inside the range, so the whole
    // section steps out rather than answering half a question (§5.1).
    expect(find.text('Queue'), findsNothing);
    expect(find.text('Andor'), findsNothing);
    expect(find.text('Severance'), findsOneWidget);

    harness.container.read(rankingFiltersProvider.notifier).state =
        RankingFilters.none;
    await tester.pumpAndSettle();
    expect(find.text('Queue'), findsOneWidget);
  });

  testWidgets('ranked rows number their score tiers, not their positions', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory(parentScoreMax: 10);
        await repo.upsertCategory(category);
        for (final entry in [
          ('A', 10.0),
          ('B', 10.0),
          ('C', 10.0),
          ('D', 9.0),
          ('E', 8.0),
        ]) {
          await repo.upsertParent(
            makeParent(
              categoryId: category.id,
              title: entry.$1,
              score: entry.$2,
            ),
          );
        }
      },
    );

    // The tier states its rank once and the next score down skips past all of
    // it: 10, 10, 10, 9, 8 reads 1, —, —, 4, 5.
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsNothing);
    expect(find.text('#3'), findsNothing);
    expect(find.text('#4'), findsOneWidget);
    expect(find.text('#5'), findsOneWidget);
  });

  testWidgets('ranked entries sort by score, highest first', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Middling', score: 3),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Best', score: 5),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Worst', score: 1),
        );
      },
    );

    final titles = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .where(
          (data) => data == 'Best' || data == 'Middling' || data == 'Worst',
        )
        .toList();
    expect(titles, ['Best', 'Middling', 'Worst']);
  });

  testWidgets('the sort menu answers the change it just made', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Severance', score: 5),
        );
      },
    );

    await tester.tap(find.text('Score'));
    await tester.pumpAndSettle();
    expect(find.text('Descending'), findsOneWidget);

    // The menu is a pushed route, so nothing in the page's own rebuild reaches
    // it — it has to be reading the category itself (§4.2).
    await tester.tap(find.text('Descending'));
    await tester.pumpAndSettle();
    expect(find.text('Ascending'), findsOneWidget);
    expect(find.text('Descending'), findsNothing);

    await tester.tap(find.text('Created'));
    await tester.pumpAndSettle();
    expect(find.text('Ascending'), findsOneWidget);
  });

  testWidgets('scoring a queued row from the list ranks it', (tester) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Andor'),
        );
      },
    );

    // A queued row carries the number too, showing a dash: the score can be
    // set from the list without the entry ever being opened (§6.1).
    final row = find.byType(RankingsRow);
    expect(
      find.descendant(of: row, matching: find.text(rankingUnscoredLabel)),
      findsOneWidget,
    );
    // No strip while unscored — the row says what it is with its status chip.
    expect(
      find.descendant(of: row, matching: find.byType(RankingStars)),
      findsNothing,
    );

    await tester.tap(
      find.descendant(of: row, matching: find.text(rankingUnscoredLabel)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RankingScorePopover), findsOneWidget);

    // Enter with nothing touched commits the midpoint the popover opened on
    // (§7.5), which out of five with half steps is 2.5.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final repo = DriftRankingRepository(harness.db);
    final categories = await repo.listCategories();
    final parents = await repo.listParents(categories.single.id);
    expect(parents.single.overallScore, 2.5);
    expect(parents.single.isRanked, isTrue);

    expect(
      find.descendant(of: find.byType(RankingsRow), matching: find.text('2.5')),
      findsOneWidget,
    );
    expect(find.text('Ranked'), findsOneWidget);
    expect(find.text('Queue'), findsNothing);
  });

  testWidgets('the star strip is decoration and sets nothing', (tester) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Andor', score: 2),
        );
      },
    );

    await tester.tap(find.text('Andor'));
    await tester.pumpAndSettle();

    final stars = find
        .descendant(
          of: find.byType(RankingsEditPanel),
          matching: find.byType(RankingStars),
        )
        .first;
    final box = tester.getRect(stars);
    // Hover, then click at the far right of the strip — the two gestures that
    // used to preview and commit a five.
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(Offset(box.left + box.width * 0.99, box.center.dy)),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(box.left + box.width * 0.99, box.center.dy));
    await tester.pumpAndSettle();

    final repo = DriftRankingRepository(harness.db);
    final categories = await repo.listCategories();
    final parents = await repo.listParents(categories.single.id);
    expect(parents.single.overallScore, 2);
    expect(find.byType(RankingScorePopover), findsNothing);
  });

  testWidgets('an entry scored zero is ranked, not unscored', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Velma', score: 0),
        );
      },
    );

    // Zero is a score (§4): it belongs in the ranked section, prints as `0`,
    // and never as the dash an unscored entry wears.
    expect(find.text('Ranked'), findsOneWidget);
    expect(find.text('Queue'), findsNothing);
    expect(
      find.descendant(of: find.byType(RankingsRow), matching: find.text('0')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(RankingsRow),
        matching: find.text(rankingUnscoredLabel),
      ),
      findsNothing,
    );
  });

  testWidgets('the row menu clears a score and demotes the entry', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Severance', score: 5),
        );
      },
    );

    await tester.tap(find.text('Severance'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Clear score'), findsOneWidget);
    // Status belongs to the unranked side of the split; a ranked row does not
    // offer it (§7.3).
    expect(find.text('Status'), findsNothing);

    await tester.tap(find.text('Clear score'));
    await tester.pumpAndSettle();

    // Clearing lands in progress rather than back in the queue.
    expect(find.text('Ranked'), findsNothing);
    expect(find.text('Queue'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(RankingsStatsBand),
        matching: find.text('In progress'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the queue collapses, and stays collapsed', (tester) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Andor'),
        );
      },
    );

    expect(find.text('Andor'), findsOneWidget);

    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();

    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Andor'), findsNothing);

    final categoryId = (await DriftRankingRepository(
      harness.db,
    ).listCategories()).single.id;
    final settings = await harness.container.read(settingsProvider.future);
    expect(settings.rankingsCollapsedQueueCategories, [categoryId]);

    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('Andor'), findsOneWidget);
  });

  testWidgets('search narrows the list, and clearing it puts things back', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Severance', score: 5),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Andor'),
        );
      },
    );

    await tester.enterText(find.byType(TextField).first, 'andor');
    await tester.pumpAndSettle();

    expect(find.text('Andor'), findsOneWidget);
    expect(find.text('Severance'), findsNothing);
    // Ranked is now empty, so its header goes with it.
    expect(find.text('Ranked'), findsNothing);

    // No Clear button in the toolbar: the search box is cleared by editing it,
    // which is what keeps the row from reflowing as filters come and go (§4).
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    expect(find.text('Severance'), findsOneWidget);
  });

  testWidgets('the subtitle does one job: tags, else progress, else nothing', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        final tagged = makeParent(
          categoryId: category.id,
          title: 'Severance',
          score: 5,
          tags: ['scifi', 'slow-burn'],
        );
        await repo.upsertParent(tagged);
        await repo.upsertChild(
          makeChild(parentId: tagged.id, name: 'Pilot', score: 4),
        );
        final progressed = makeParent(
          categoryId: category.id,
          title: 'Andor',
          score: 4,
        );
        await repo.upsertParent(progressed);
        await repo.upsertChild(
          makeChild(parentId: progressed.id, name: 'Kassa', score: 3),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Dark', score: 3),
        );
      },
    );

    // Tags win the line, and the progress they displaced is nowhere in text.
    expect(find.text('scifi'), findsOneWidget);
    expect(find.text('slow-burn'), findsOneWidget);
    expect(find.text('1/1 scored'), findsOneWidget);

    // No tags but children: the condensed progress, and only that.
    expect(find.textContaining('episode'), findsNothing);

    // The creation date is off the row entirely (§6.1).
    expect(find.textContaining('Aug 1, 2026'), findsNothing);

    // The progress the tags displaced is still reachable, as a tooltip on the
    // chip strip (§6.3).
    expect(find.byTooltip('1/1 scored'), findsOneWidget);
  });

  testWidgets('a row past the cap shows two chips and a +N', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Severance',
            score: 5,
            tags: ['scifi', 'slow-burn', 'apple', 'ensemble'],
          ),
        );
      },
    );

    expect(find.text('scifi'), findsOneWidget);
    expect(find.text('slow-burn'), findsOneWidget);
    expect(find.text('apple'), findsNothing);
    expect(find.text('+2'), findsOneWidget);
    // The two it did not print are named in the overflow marker's tooltip.
    expect(find.byTooltip('apple · ensemble'), findsOneWidget);
  });

  testWidgets('a tag typed into the panel lands on the row', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Severance', score: 5),
        );
      },
    );

    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(RankingTagsField), '#Rom-Com');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // Stored lowercased and without the hash, and on the row at once.
    expect(
      find.descendant(
        of: find.byType(RankingsRow),
        matching: find.text('rom-com'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Enter commits the tag without leaving the field', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Severance', score: 5),
        );
      },
    );

    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(RankingTagsField), 'scifi');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(RankingsRow),
        matching: find.text('scifi'),
      ),
      findsOneWidget,
    );

    // Committing does not blur: the next tag is typed straight after.
    await tester.enterText(find.byType(RankingTagsField), 'slow-burn');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(RankingsRow),
        matching: find.text('slow-burn'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the cap refuses an eleventh tag and says so', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Severance',
            score: 5,
            tags: [for (var i = 0; i < 10; i++) 'tag$i'],
          ),
        );
      },
    );

    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();

    // A full list closes the box rather than letting an eleventh tag be typed
    // and then silently dropped, and the line under it says why.
    expect(find.text('Maximum 10 tags'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(RankingTagsField),
        matching: find.byType(TextField),
      ),
    );
    expect(field.enabled, isFalse);
  });

  testWidgets('a tag-only edit leaves a queued entry queued', (tester) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Andor'),
        );
      },
    );

    await tester.tap(find.text('Andor'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(RankingTagsField), 'spy');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final saved = await DriftRankingRepository(
      harness.db,
    ).listParents(harness.container.read(rankingCategoriesProvider).value!.first.id);
    expect(saved.single.tags, ['spy']);
    expect(saved.single.status, RankingStatus.queued);
  });

  testWidgets('the × takes a tag off the entry', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Severance',
            score: 5,
            tags: ['scifi'],
          ),
        );
      },
    );

    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(RankingTagsField),
        matching: find.byIcon(PhosphorIconsRegular.x),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('scifi'), findsNothing);
  });

  testWidgets('clicking a row chip filters, and clicking it again keeps it', (
    tester,
  ) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Severance',
            score: 5,
            tags: ['scifi'],
          ),
        );
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'The Bear',
            score: 4,
            tags: ['kitchen'],
          ),
        );
      },
    );

    await tester.tap(find.text('scifi'));
    await tester.pumpAndSettle();

    expect(
      harness.container.read(rankingFiltersProvider).tag,
      'scifi',
    );
    expect(find.text('Severance'), findsOneWidget);
    expect(find.text('The Bear'), findsNothing);

    // The chip is not a toggle: a second click on the tag that is already
    // filtering leaves the list where it is rather than widening under the
    // pointer (§6.4).
    await tester.tap(find.text('scifi'));
    await tester.pumpAndSettle();
    expect(harness.container.read(rankingFiltersProvider).tag, 'scifi');
    expect(find.text('The Bear'), findsNothing);
  });

  testWidgets('a chip tap filters without opening the editor panel', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Severance',
            score: 5,
            tags: ['scifi'],
          ),
        );
      },
    );

    await tester.tap(find.text('scifi'));
    await tester.pumpAndSettle();
    expect(find.byType(RankingsEditPanel), findsNothing);
  });

  testWidgets('an empty category says what to do about it', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async => repo.upsertCategory(makeCategory()),
    );

    expect(find.text('Nothing in Shows yet'), findsOneWidget);
  });

  testWidgets('an archived category is hidden from the picker', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        await repo.upsertCategory(makeCategory(name: 'Shows'));
        await repo.upsertCategory(
          makeCategory(name: 'Retired').copyWith(archivedAt: _now),
        );
      },
    );

    expect(find.text('Shows'), findsOneWidget);
    expect(find.text('Retired'), findsNothing);

    await tester.tap(find.text('Shows'));
    await tester.pumpAndSettle();
    expect(find.text('Retired'), findsNothing);
  });

  testWidgets('child rows show a number, not a strip of stars', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        final parent = makeParent(categoryId: category.id, title: 'Severance');
        await repo.upsertParent(parent);
        await repo.upsertChild(
          makeChild(parentId: parent.id, name: 'ep 1', score: 4),
        );
        await repo.upsertChild(
          makeChild(parentId: parent.id, name: 'ep 2', sortOrder: 1),
        );
      },
    );

    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();

    final panel = find.byType(RankingsEditPanel);
    expect(find.descendant(of: panel, matching: find.text('ep 1')), findsOne);
    // The score reads as a number, and an unscored unit says so rather than
    // leaving its slot blank (§8.1). Two dashes: the unscored unit, and the
    // entry's own overall row, which is unscored here too.
    expect(find.descendant(of: panel, matching: find.text('4')), findsOne);
    expect(
      find.descendant(of: panel, matching: find.text(rankingUnscoredLabel)),
      findsNWidgets(2),
    );

    // One strip in the panel — the entry's own overall row. The units below it
    // carry no stars at all.
    expect(
      find.descendant(of: panel, matching: find.byType(RankingStars)),
      findsOne,
    );
  });

  testWidgets('the hairline under a unit is not part of its hover band', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        final parent = makeParent(categoryId: category.id, title: 'Severance');
        await repo.upsertParent(parent);
        await repo.upsertChild(
          makeChild(parentId: parent.id, name: 'ep 1', score: 4),
        );
        await repo.upsertChild(
          makeChild(parentId: parent.id, name: 'ep 2', sortOrder: 1),
        );
      },
    );

    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();

    // The row's own fill, which is the only thing the row paints on hover —
    // the darker tint the user actually sees is this plus the [InkWell]'s ink
    // hover on top of it, and the ink stops at the same edge this does.
    Finder surfaceOf(String name) => find
        .ancestor(
          of: find.text(name),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).borderRadius ==
                    BorderRadius.circular(10),
          ),
        )
        .first;

    Color? fillOf(String name) =>
        (tester.widget<DecoratedBox>(surfaceOf(name)).decoration
                as BoxDecoration)
            .color;

    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer();
    addTearDown(pointer.removePointer);

    final row = tester.getRect(surfaceOf('ep 1'));
    await pointer.moveTo(row.center);
    await tester.pump();
    expect(fillOf('ep 1'), isNot(Colors.transparent));

    // Half a pixel below the row is the hairline between it and the next unit.
    // It is outside the fill and outside the ink, so it must not count as
    // hovering the row: lighting the row up from here drew a highlight the
    // ink never reached, a visibly paler version of the real one.
    await pointer.moveTo(row.bottomCenter + const Offset(0, 0.5));
    await tester.pump();
    expect(fillOf('ep 1'), Colors.transparent);
  });

  testWidgets('the calculator averages the scored units into the entry', (
    tester,
  ) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        final parent = makeParent(categoryId: category.id, title: 'Severance');
        await repo.upsertParent(parent);
        await repo.upsertChild(
          makeChild(parentId: parent.id, name: 'ep 1', score: 4),
        );
        await repo.upsertChild(
          makeChild(parentId: parent.id, name: 'ep 2', score: 5, sortOrder: 1),
        );
      },
    );

    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Average from 2 scored episodes'));
    await tester.pumpAndSettle();

    final repo = DriftRankingRepository(harness.db);
    final categories = await repo.listCategories();
    final parents = await repo.listParents(categories.single.id);
    expect(parents.single.overallScore, 4.5);
  });

  testWidgets('starring a ranked row pins it above a higher score', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Best', score: 5),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Favourite', score: 2),
        );
      },
    );

    await tester.tap(find.byTooltip('Pin to top').at(1), warnIfMissed: false);
    await tester.pumpAndSettle();

    final titles = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .where((data) => data == 'Best' || data == 'Favourite')
        .toList();
    expect(titles, ['Favourite', 'Best']);
  });

  testWidgets('switching categories takes the editor panel with it', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final shows = makeCategory();
        await repo.upsertCategory(shows);
        await repo.upsertParent(
          makeParent(categoryId: shows.id, title: 'Severance'),
        );
        final food = makeCategory(name: 'Restaurants');
        await repo.upsertCategory(food);
        await repo.upsertParent(
          makeParent(categoryId: food.id, title: 'Noodle bar'),
        );
      },
    );

    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();
    expect(find.byType(RankingsEditPanel), findsOne);
    final narrowed = tester.getSize(find.byType(RankingsRow).first).width;

    // The picker is a popover hung off the band's current category.
    await tester.tap(chipText('Shows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restaurants').last);
    await tester.pumpAndSettle();

    // The panel is gone, and so is the width the list gave up for it: the
    // entry it was open on is not in this category at all.
    expect(find.byType(RankingsEditPanel), findsNothing);
    final full = tester.getSize(find.byType(RankingsRow).first).width;
    expect(full, greaterThan(narrowed + rankingsEditPanelWidth / 2));
  });

  testWidgets('undo brings a deleted unit back after its row is gone', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        final parent = makeParent(categoryId: category.id, title: 'Severance');
        await repo.upsertParent(parent);
        await repo.upsertChild(makeChild(parentId: parent.id, name: 'ep 1'));
        await repo.upsertChild(
          makeChild(parentId: parent.id, name: 'ep 2', sortOrder: 1),
        );
      },
    );

    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();

    final panel = find.byType(RankingsEditPanel);
    await tester.tap(
      find.descendant(of: panel, matching: find.text('ep 1')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    // The dialog's confirm; its title reads `Delete "ep 1"?`, so this is the
    // button.
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: panel, matching: find.text('ep 1')),
      findsNothing,
    );

    // The row that asked for the delete is gone by now, which is the whole
    // point: the undo runs off the container, not off that row's `ref`.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.descendant(of: panel, matching: find.text('ep 1')), findsOne);
    // Pressing the button also takes the toast away.
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('an unanswered undo offer takes itself away', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        final parent = makeParent(categoryId: category.id, title: 'Severance');
        await repo.upsertParent(parent);
        await repo.upsertChild(makeChild(parentId: parent.id, name: 'ep 1'));
      },
    );

    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(RankingsEditPanel),
        matching: find.text('ep 1'),
      ),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);

    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing);
  });
  testWidgets('each category remembers its own scroll offset', (tester) async {
    late String longId;
    late String shortId;
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final long = makeCategory(name: 'Long');
        final short = makeCategory(name: 'Short');
        longId = long.id;
        shortId = short.id;
        await repo.upsertCategory(long);
        await repo.upsertCategory(short);
        for (var i = 0; i < 40; i++) {
          await repo.upsertParent(
            makeParent(
              categoryId: long.id,
              title: 'Long entry $i',
              score: 3,
            ),
          );
        }
        await repo.upsertParent(
          makeParent(categoryId: short.id, title: 'Short entry', score: 3),
        );
      },
    );

    // Located without the storage key, so that dropping the key fails the
    // assertions rather than the finder.
    ScrollPosition sectionsPosition() => tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(VoyagerScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;

    Future<void> select(String categoryId) async {
      harness.container.read(rankingSelectedCategoryProvider.notifier).state =
          categoryId;
      await tester.pumpAndSettle();
    }

    await select(longId);
    final long = sectionsPosition();
    expect(long.maxScrollExtent, greaterThan(400));
    long.jumpTo(400);
    await tester.pumpAndSettle();

    // The short category has nothing to scroll, so inheriting the long one's
    // offset would clamp it to zero — and that zero used to come back with us.
    await select(shortId);
    expect(sectionsPosition().pixels, 0);

    await select(longId);
    expect(sectionsPosition().pixels, 400);
  });
}
