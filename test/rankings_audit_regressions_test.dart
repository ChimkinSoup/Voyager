// Regressions for the Rankings audit (AUDIT.md), below the widget layer: the
// actions, the repository, and the sync paths they reach. The page-level ones
// — flushes from dispose, the panel and the filters — live in
// rankings_page_test.dart beside the harness they need.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/restore_contract.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_actions.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.utc(2026, 8, 1);

/// A backend that never acknowledges a batch — what Firestore looks like to a
/// caller awaiting `batch.commit()` while the device is offline.
class _OfflineSyncRepository extends InMemorySyncRepository {
  @override
  Future<void> upsertDocumentsBatch(
    String collection,
    Map<String, Map<String, dynamic>> documentsById,
  ) => Completer<void>().future;
}

/// A backend that refuses every batch.
class _RejectingSyncRepository extends InMemorySyncRepository {
  @override
  Future<void> upsertDocumentsBatch(
    String collection,
    Map<String, Map<String, dynamic>> documentsById,
  ) async => throw StateError('rejected');
}

Future<({ProviderContainer container, DriftRankingRepository repo})> _harness({
  InMemorySyncRepository? sync,
}) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(
        sync ?? InMemorySyncRepository(),
      ),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  return (container: container, repo: DriftRankingRepository(db));
}

RankingCategory _category({
  List<RankingTemplateField> parentTemplate = const [],
  List<RankingTemplateField> childTemplate = const [],
  int parentScoreMax = 10,
  int childScoreMax = 10,
}) => RankingCategory(
  id: newId(),
  name: 'Shows',
  colorValue: 0xFF7C9EFF,
  childUnitsEnabled: true,
  parentScoreMax: parentScoreMax,
  childScoreMax: childScoreMax,
  parentScorePrecision: RankingScorePrecision.half,
  childScorePrecision: RankingScorePrecision.half,
  parentTemplate: parentTemplate,
  childTemplate: childTemplate,
  createdAt: _now,
  updatedAt: _now,
);

RankingParent _parent(
  String categoryId, {
  String title = 'Severance',
  double? score,
  Map<String, RankingFieldValue> fieldValues = const {},
  int queueSortOrder = 0,
  DateTime? deletedAt,
}) => RankingParent(
  id: newId(),
  categoryId: categoryId,
  title: title,
  overallScore: score,
  fieldValues: fieldValues,
  queueSortOrder: queueSortOrder,
  createdAt: _now,
  updatedAt: _now,
  deletedAt: deletedAt,
);

RankingChild _child(
  String parentId, {
  String name = 'Pilot',
  double? score,
  Map<String, RankingFieldValue> fieldValues = const {},
}) => RankingChild(
  id: newId(),
  parentId: parentId,
  name: name,
  overallScore: score,
  fieldValues: fieldValues,
  createdAt: _now,
  updatedAt: _now,
);

const _plot = RankingTemplateField(
  id: 'plot',
  label: 'Plot',
  sortOrder: 0,
  scoreMax: 10,
);

void main() {
  group('actions never wait on the network', () {
    test('a queue drag lands and refreshes while offline', () async {
      final harness = await _harness(sync: _OfflineSyncRepository());
      final category = _category();
      await harness.repo.upsertCategory(category);
      final a = _parent(category.id, title: 'A');
      final b = _parent(category.id, title: 'B', queueSortOrder: 1);
      await harness.repo.upsertParent(a);
      await harness.repo.upsertParent(b);
      await harness.container.read(rankingParentsProvider(category.id).future);

      await RankingsActions.detached(
        harness.container,
      ).reorderQueue([b.id, a.id]).timeout(const Duration(seconds: 2));

      final shown = await harness.container.read(
        rankingParentsProvider(category.id).future,
      );
      expect(
        {for (final p in shown) p.title: p.queueSortOrder},
        {'B': 0, 'A': 1},
      );
    });

    test('a cascade delete finishes while offline', () async {
      final harness = await _harness(sync: _OfflineSyncRepository());
      final category = _category();
      await harness.repo.upsertCategory(category);
      final parent = _parent(category.id);
      await harness.repo.upsertParent(parent);
      await harness.repo.upsertChild(_child(parent.id));

      await RankingsActions.detached(
        harness.container,
      ).deleteParent(parent.id).timeout(const Duration(seconds: 2));

      expect(await harness.repo.listParents(category.id), isEmpty);
    });

    test('a rejected batch does not escape the action', () async {
      final harness = await _harness(sync: _RejectingSyncRepository());
      final category = _category();
      await harness.repo.upsertCategory(category);
      final a = _parent(category.id, title: 'A');
      final b = _parent(category.id, title: 'B', queueSortOrder: 1);
      await harness.repo.upsertParent(a);
      await harness.repo.upsertParent(b);

      final errors = <Object>[];
      await runZonedGuarded(() async {
        await RankingsActions.detached(
          harness.container,
        ).reorderQueue([b.id, a.id]);
        // Past the retry policy's backoff, so the failure has happened.
        await Future<void>.delayed(const Duration(seconds: 2));
      }, (error, _) => errors.add(error));

      expect(errors, isEmpty);
    });
  });

  group('soft deletes', () {
    test('a second delete cannot restamp the cascade', () async {
      final harness = await _harness();
      final category = _category();
      await harness.repo.upsertCategory(category);
      final parent = _parent(category.id);
      await harness.repo.upsertParent(parent);
      await harness.repo.upsertChild(_child(parent.id));

      await harness.repo.softDeleteParent(parent.id);
      await expectLater(
        harness.repo.softDeleteParent(parent.id),
        throwsStateError,
      );
      await expectLater(
        harness.repo.softDeleteCategory(category.id).then((_) {
          return harness.repo.softDeleteCategory(category.id);
        }),
        throwsStateError,
      );
    });

    test('a unit cannot come back under a deleted entry', () async {
      final harness = await _harness();
      final category = _category();
      await harness.repo.upsertCategory(category);
      final parent = _parent(category.id);
      await harness.repo.upsertParent(parent);
      final child = _child(parent.id);
      await harness.repo.upsertChild(child);

      await harness.repo.softDeleteChild(child.id);
      await harness.repo.softDeleteParent(parent.id);

      await expectLater(harness.repo.restoreChild(child.id), throwsStateError);
      expect((await harness.repo.getChild(child.id))!.isDeleted, isTrue);
    });

    test('restoring a unit already back says so', () async {
      final harness = await _harness();
      final category = _category();
      await harness.repo.upsertCategory(category);
      final parent = _parent(category.id);
      await harness.repo.upsertParent(parent);
      final child = _child(parent.id);
      await harness.repo.upsertChild(child);

      await expectLater(
        harness.repo.restoreChild(child.id),
        throwsA(isA<RestoreSuperseded>()),
      );
    });

    test('an entry cannot come back into a deleted category', () async {
      final harness = await _harness();
      final category = _category();
      await harness.repo.upsertCategory(category);
      final parent = _parent(category.id);
      await harness.repo.upsertParent(parent);

      await harness.repo.softDeleteParent(parent.id);
      await harness.repo.softDeleteCategory(category.id);

      await expectLater(
        harness.repo.restoreParent(parent.id),
        throwsStateError,
      );
    });
  });

  group('rescales', () {
    test(
      'a field rescale confirmed twice halves once, deleted rows too',
      () async {
        final harness = await _harness();
        final category = _category(parentTemplate: const [_plot]);
        await harness.repo.upsertCategory(category);
        final live = _parent(
          category.id,
          fieldValues: const {'plot': RankingFieldValue(score: 8)},
        );
        final trashed = _parent(
          category.id,
          title: 'Trashed',
          fieldValues: const {'plot': RankingFieldValue(score: 6)},
          deletedAt: _now,
        );
        await harness.repo.upsertParent(live);
        await harness.repo.upsertParent(trashed);

        final actions = RankingsActions.detached(harness.container);
        await Future.wait([
          actions.rescaleTemplateField(
            category.id,
            'plot',
            scoreMax: 5,
            isParentTemplate: true,
          ),
          actions.rescaleTemplateField(
            category.id,
            'plot',
            scoreMax: 5,
            isParentTemplate: true,
          ),
        ]);

        expect(
          (await harness.repo.getParent(live.id))!.fieldValues['plot']!.score,
          4,
        );
        expect(
          (await harness.repo.getParent(
            trashed.id,
          ))!.fieldValues['plot']!.score,
          3,
        );
        final saved = (await harness.repo.getCategory(category.id))!;
        expect(saved.parentTemplate.single.scoreMax, 5);
      },
    );

    test('a field rescale leaves a category change made meanwhile', () async {
      final harness = await _harness();
      final category = _category(parentTemplate: const [_plot]);
      await harness.repo.upsertCategory(category);
      await harness.repo.upsertCategory(
        category.copyWith(sortMode: RankingSortMode.createdAt),
      );

      await RankingsActions.detached(harness.container).rescaleTemplateField(
        category.id,
        'plot',
        scoreMax: 5,
        isParentTemplate: true,
      );

      expect(
        (await harness.repo.getCategory(category.id))!.sortMode,
        RankingSortMode.createdAt,
      );
    });

    test('changing the entry scale carries the overall scores', () async {
      final harness = await _harness();
      final category = _category();
      await harness.repo.upsertCategory(category);
      final parent = _parent(category.id, score: 8.5);
      final trashed = _parent(
        category.id,
        title: 'Trashed',
        score: 7,
        deletedAt: _now,
      );
      await harness.repo.upsertParent(parent);
      await harness.repo.upsertParent(trashed);
      final child = _child(parent.id, score: 9);
      await harness.repo.upsertChild(child);

      final actions = RankingsActions.detached(harness.container);
      await actions.rescaleOverall(category.id, scoreMax: 5, isParent: true);
      await actions.rescaleOverall(category.id, scoreMax: 5, isParent: true);

      // 8.5 of 10 is 4.25 of 5, which on halves rounds to 4.5.
      expect((await harness.repo.getParent(parent.id))!.overallScore, 4.5);
      expect((await harness.repo.getParent(trashed.id))!.overallScore, 3.5);
      // The unit scale is its own setting.
      expect((await harness.repo.getChild(child.id))!.overallScore, 9);
      expect((await harness.repo.getCategory(category.id))!.parentScoreMax, 5);
    });

    test('a unit field rescale reaches units under deleted entries', () async {
      final harness = await _harness();
      final category = _category(childTemplate: const [_plot]);
      await harness.repo.upsertCategory(category);
      final parent = _parent(category.id);
      await harness.repo.upsertParent(parent);
      final child = _child(
        parent.id,
        fieldValues: const {'plot': RankingFieldValue(score: 10)},
      );
      await harness.repo.upsertChild(child);
      await harness.repo.softDeleteParent(parent.id);

      await RankingsActions.detached(harness.container).rescaleTemplateField(
        category.id,
        'plot',
        scoreMax: 5,
        isParentTemplate: false,
      );

      expect(
        (await harness.repo.getChild(child.id))!.fieldValues['plot']!.score,
        5,
      );
    });

    test('a step change re-rounds the trash as well', () async {
      final harness = await _harness();
      final category = _category().copyWith(
        parentScorePrecision: RankingScorePrecision.tenths,
      );
      await harness.repo.upsertCategory(category);
      final trashed = _parent(category.id, score: 7.3, deletedAt: _now);
      await harness.repo.upsertParent(trashed);

      await RankingsActions.detached(harness.container).setOverallPrecision(
        category,
        isParent: true,
        precision: RankingScorePrecision.half,
      );

      expect((await harness.repo.getParent(trashed.id))!.overallScore, 7.5);
    });
  });

  group('writes patch the row on disk, not the caller\'s copy', () {
    test('a save built on a stale copy keeps what was saved since', () async {
      final harness = await _harness();
      final category = _category(parentTemplate: const [_plot]);
      await harness.repo.upsertCategory(category);
      final snapshot = _parent(category.id);
      await harness.repo.upsertParent(snapshot);
      final actions = RankingsActions.detached(harness.container);

      // The panel saves a note…
      await actions.saveParent(
        snapshot.copyWith(notes: 'slow burn'),
        previous: snapshot,
      );
      // …and a row control still holding the old copy scores a field.
      await actions.saveParent(
        snapshot.copyWith(
          fieldValues: const {'plot': RankingFieldValue(score: 7)},
        ),
        previous: snapshot,
      );

      final saved = (await harness.repo.getParent(snapshot.id))!;
      expect(saved.notes, 'slow burn');
      expect(saved.fieldValues['plot']!.score, 7);
    });

    test('quick edits to one entry queue behind each other', () async {
      final harness = await _harness();
      final category = _category(parentTemplate: const [_plot]);
      await harness.repo.upsertCategory(category);
      final parent = _parent(category.id);
      await harness.repo.upsertParent(parent);
      final actions = RankingsActions.detached(harness.container);

      await Future.wait([
        actions.toggleStar(parent.id),
        actions.saveParent(
          parent.copyWith(title: 'Severance S2'),
          previous: parent,
        ),
        actions.setStatus(parent.id, RankingStatus.inProgress),
      ]);

      final saved = (await harness.repo.getParent(parent.id))!;
      expect(saved.starred, isTrue);
      expect(saved.title, 'Severance S2');
      expect(saved.status, RankingStatus.inProgress);
    });

    test('a late edit cannot bring a deleted entry back', () async {
      final harness = await _harness();
      final category = _category();
      await harness.repo.upsertCategory(category);
      final parent = _parent(category.id);
      await harness.repo.upsertParent(parent);
      final actions = RankingsActions.detached(harness.container);

      await actions.deleteParent(parent.id);
      final saved = await actions.saveParent(
        parent.copyWith(notes: 'typed into the stale panel'),
        previous: parent,
      );
      await actions.toggleStar(parent.id);

      expect(saved, isNull);
      final onDisk = (await harness.repo.getParent(parent.id))!;
      expect(onDisk.isDeleted, isTrue);
      expect(onDisk.notes, isEmpty);
      expect(onDisk.starred, isFalse);
    });

    test('a unit save does not un-rank its entry', () async {
      final harness = await _harness();
      final category = _category();
      await harness.repo.upsertCategory(category);
      final opened = _parent(category.id);
      await harness.repo.upsertParent(opened);
      final child = _child(opened.id);
      await harness.repo.upsertChild(child);
      // Ranked by a pull while the unit's editor was open on the old copy.
      await harness.repo.upsertParent(opened.copyWith(overallScore: 9));

      await RankingsActions.detached(
        harness.container,
      ).saveChild(child.copyWith(notes: 'cold open'), previous: child);

      final parent = (await harness.repo.getParent(opened.id))!;
      expect(parent.overallScore, 9);
      expect(parent.isRanked, isTrue);
      expect((await harness.repo.getChild(child.id))!.notes, 'cold open');
    });
  });

  group('"Last updated" is user edits only', () {
    test('a queue drag and a unit reorder leave updatedAt alone', () async {
      final harness = await _harness();
      final category = _category();
      await harness.repo.upsertCategory(category);
      final a = _parent(category.id, title: 'A');
      final b = _parent(category.id, title: 'B', queueSortOrder: 1);
      await harness.repo.upsertParent(a);
      await harness.repo.upsertParent(b);
      final first = _child(a.id, name: 'one');
      final second = _child(a.id, name: 'two').copyWith(sortOrder: 1);
      await harness.repo.upsertChild(first);
      await harness.repo.upsertChild(second);

      final actions = RankingsActions.detached(harness.container);
      await actions.reorderQueue([b.id, a.id]);
      await actions.reorderChildren([second.id, first.id]);

      for (final parent in await harness.repo.listParents(category.id)) {
        expect(parent.updatedAt.toUtc(), _now, reason: parent.title);
      }
      final moved = (await harness.repo.getChild(second.id))!;
      expect(moved.sortOrder, 0);
      expect(moved.updatedAt.toUtc(), second.updatedAt.toUtc());
      // The version still moves, so sync still sees the write.
      expect(moved.version, greaterThan(second.version));
    });

    test('one panel save is one version', () {
      final queued = _parent('cat');
      final next = applyRankingEditRules(
        queued,
        queued.copyWith(overallScore: 4),
      );
      expect(next.version, queued.version + 1);
    });
  });

  group('small things', () {
    test('a new category goes after the highest sort order', () {
      final categories = [
        _category().copyWith(sortOrder: 1),
        _category().copyWith(sortOrder: 2),
      ];
      expect(rankingNextCategorySortOrder(categories), 3);
      expect(rankingNextCategorySortOrder(const []), 0);
    });

    test('an infinite score clamps instead of throwing', () {
      expect(
        roundRankingScore(
          double.infinity,
          scoreMax: 5,
          precision: RankingScorePrecision.half,
        ),
        5,
      );
      expect(
        roundRankingScore(
          double.negativeInfinity,
          scoreMax: 5,
          precision: RankingScorePrecision.half,
        ),
        0,
      );
    });

    test('a snapped slider bound keeps the entry sitting on it', () {
      final entry = _parent('cat', score: 1.4);
      const max = 5;
      const divisions = 50;
      // What RangeSlider hands back for the 14th stop: 1.4000000000000001.
      final raw = max * (14 / divisions);
      final snapped = roundRankingScore(
        raw,
        scoreMax: max,
        precision: RankingScorePrecision.tenths,
      );
      List<RankingParent> passing(double low) => filterRankingParents(
        [entry],
        childrenByParent: const {},
        query: '',
        filters: RankingFilters(scoreMin: low),
      );
      expect(passing(raw), isEmpty, reason: 'the float drift this guards');
      expect(passing(snapped), [entry]);
    });

    test('the category counts come from one grouped query', () async {
      final harness = await _harness();
      final shows = _category();
      final food = _category();
      await harness.repo.upsertCategory(shows);
      await harness.repo.upsertCategory(food);
      await harness.repo.upsertParent(_parent(shows.id));
      await harness.repo.upsertParent(_parent(shows.id, title: 'Andor'));
      await harness.repo.upsertParent(_parent(food.id, deletedAt: _now));

      expect(await harness.repo.countParentsByCategory(), {shows.id: 2});
    });

    test('one query lists every unit in a category', () async {
      final harness = await _harness();
      final category = _category();
      await harness.repo.upsertCategory(category);
      final other = _category();
      await harness.repo.upsertCategory(other);
      final a = _parent(category.id);
      final b = _parent(category.id, title: 'Andor');
      final elsewhere = _parent(other.id);
      for (final parent in [a, b, elsewhere]) {
        await harness.repo.upsertParent(parent);
        await harness.repo.upsertChild(_child(parent.id));
      }

      final byParent = await harness.container.read(
        rankingChildrenByParentProvider(category.id).future,
      );
      expect(byParent.keys, unorderedEquals([a.id, b.id]));
      expect(byParent[a.id], hasLength(1));
      expect(byParent[b.id], hasLength(1));
    });
  });
}
