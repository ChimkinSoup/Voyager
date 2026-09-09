// Tightening a step has to move the scores already stored under the looser
// one (HLD §8.1), and the count it moves is what the warning dialog asks the
// user about before any of it happens. Both live in RankingsActions, so both
// are exercised here against a real repository rather than through the sheet.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/features/rankings/rankings_actions.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.utc(2026, 8, 1);

const _plot = RankingTemplateField(
  id: 'plot',
  label: 'Plot',
  sortOrder: 0,
  scoreMax: 10,
);

/// A field that has stepped out from under the overall, onto tenths of its
/// own — the case §8.1 leaves alone when the overall changes.
const _pace = RankingTemplateField(
  id: 'pace',
  label: 'Pace',
  sortOrder: 1,
  scoreMax: 10,
  inheritPrecision: false,
  scorePrecision: RankingScorePrecision.tenths,
);

RankingCategory _category({
  RankingScorePrecision parent = RankingScorePrecision.tenths,
  RankingScorePrecision child = RankingScorePrecision.tenths,
}) => RankingCategory(
  id: newId(),
  name: 'Shows',
  colorValue: 0xFF7C9EFF,
  childUnitsEnabled: true,
  parentScoreMax: 10,
  childScoreMax: 10,
  parentScorePrecision: parent,
  childScorePrecision: child,
  parentTemplate: const [_plot, _pace],
  childTemplate: const [_plot],
  createdAt: _now,
  updatedAt: _now,
);

Future<({ProviderContainer container, DriftRankingRepository repo})> _harness(
  WidgetTester tester,
) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  return (container: container, repo: DriftRankingRepository(db));
}

void main() {
  testWidgets('tightening the entry step re-rounds what no longer fits', (
    tester,
  ) async {
    final harness = await _harness(tester);
    final category = _category();
    await harness.repo.upsertCategory(category);

    final parent = RankingParent(
      id: newId(),
      categoryId: category.id,
      title: 'Severance',
      overallScore: 8.4,
      fieldValues: const {
        'plot': RankingFieldValue(score: 7.3),
        'pace': RankingFieldValue(score: 6.1),
      },
      createdAt: _now,
      updatedAt: _now,
    );
    await harness.repo.upsertParent(parent);

    final actions = RankingsActions.detached(harness.container);
    final moved = await actions.setOverallPrecision(
      category,
      isParent: true,
      precision: RankingScorePrecision.half,
    );

    // The overall and the inheriting field move; the field on its own tenths
    // does not.
    expect(moved, 2);
    final saved = (await harness.repo.listParents(category.id)).single;
    expect(saved.overallScore, 8.5);
    expect(saved.fieldValues['plot']!.score, 7.5);
    expect(saved.fieldValues['pace']!.score, 6.1);

    final savedCategory = (await harness.repo.listCategories()).single;
    expect(savedCategory.parentScorePrecision, RankingScorePrecision.half);
  });

  testWidgets('the entry step leaves the units on their own', (tester) async {
    final harness = await _harness(tester);
    final category = _category();
    await harness.repo.upsertCategory(category);

    final parent = RankingParent(
      id: newId(),
      categoryId: category.id,
      title: 'Severance',
      overallScore: 8.4,
      createdAt: _now,
      updatedAt: _now,
    );
    await harness.repo.upsertParent(parent);
    await harness.repo.upsertChild(
      RankingChild(
        id: newId(),
        parentId: parent.id,
        name: 'ep 1',
        overallScore: 7.3,
        createdAt: _now,
        updatedAt: _now,
      ),
    );

    await RankingsActions.detached(harness.container).setOverallPrecision(
      category,
      isParent: true,
      precision: RankingScorePrecision.integers,
    );

    expect(
      (await harness.repo.listParents(category.id)).single.overallScore,
      8,
    );
    // The two settings are independent (§3.2): a unit keeps its tenth.
    expect(
      (await harness.repo.listChildren(parent.id)).single.overallScore,
      7.3,
    );
  });

  testWidgets('the count is asked before anything is written', (tester) async {
    final harness = await _harness(tester);
    final category = _category();
    await harness.repo.upsertCategory(category);
    await harness.repo.upsertParent(
      RankingParent(
        id: newId(),
        categoryId: category.id,
        title: 'Severance',
        overallScore: 8.4,
        createdAt: _now,
        updatedAt: _now,
      ),
    );

    final actions = RankingsActions.detached(harness.container);
    final affected = await actions.countScoresOffStep(
      category.copyWith(parentScorePrecision: RankingScorePrecision.integers),
      previous: category,
    );
    expect(affected, 1);
    // Counting is a dry run — the score is untouched until the user agrees.
    expect(
      (await harness.repo.listParents(category.id)).single.overallScore,
      8.4,
    );
  });

  testWidgets('loosening a step moves nothing', (tester) async {
    final harness = await _harness(tester);
    final category = _category(parent: RankingScorePrecision.half);
    await harness.repo.upsertCategory(category);
    await harness.repo.upsertParent(
      RankingParent(
        id: newId(),
        categoryId: category.id,
        title: 'Severance',
        overallScore: 8.5,
        createdAt: _now,
        updatedAt: _now,
      ),
    );

    final moved = await RankingsActions.detached(harness.container)
        .setOverallPrecision(
          category,
          isParent: true,
          precision: RankingScorePrecision.tenths,
        );
    // Every half is already a tenth, so there is nothing to warn about.
    expect(moved, 0);
    expect(
      (await harness.repo.listParents(category.id)).single.overallScore,
      8.5,
    );
  });

  testWidgets('a field opting out onto a coarser step re-rounds its own '
      'values only', (tester) async {
    final harness = await _harness(tester);
    final category = _category();
    await harness.repo.upsertCategory(category);
    await harness.repo.upsertParent(
      RankingParent(
        id: newId(),
        categoryId: category.id,
        title: 'Severance',
        overallScore: 8.4,
        fieldValues: const {
          'plot': RankingFieldValue(score: 7.3),
          'pace': RankingFieldValue(score: 6.1),
        },
        createdAt: _now,
        updatedAt: _now,
      ),
    );

    final moved = await RankingsActions.detached(harness.container)
        .setFieldPrecision(
          category,
          _plot,
          isParentTemplate: true,
          inherit: false,
          precision: RankingScorePrecision.integers,
        );

    expect(moved, 1);
    final saved = (await harness.repo.listParents(category.id)).single;
    expect(saved.fieldValues['plot']!.score, 7);
    expect(saved.overallScore, 8.4);
    expect(saved.fieldValues['pace']!.score, 6.1);

    final field = (await harness.repo.listCategories()).single.parentTemplate
        .firstWhere((f) => f.id == 'plot');
    expect(field.inheritPrecision, isFalse);
    expect(field.scorePrecision, RankingScorePrecision.integers);
  });

  testWidgets('the average from units rounds to the entry step', (
    tester,
  ) async {
    final harness = await _harness(tester);
    // Units keep tenths; the entry does not — the average lands on the
    // entry's step, not on the units' (§8.3).
    final category = _category(parent: RankingScorePrecision.half);
    await harness.repo.upsertCategory(category);

    final parent = RankingParent(
      id: newId(),
      categoryId: category.id,
      title: 'Severance',
      createdAt: _now,
      updatedAt: _now,
    );
    await harness.repo.upsertParent(parent);
    for (final (index, score) in [8.3, 8.4, null].indexed) {
      await harness.repo.upsertChild(
        RankingChild(
          id: newId(),
          parentId: parent.id,
          name: 'ep $index',
          overallScore: score,
          sortOrder: index,
          createdAt: _now,
          updatedAt: _now,
        ),
      );
    }

    final children = await harness.repo.listChildren(parent.id);
    await RankingsActions.detached(
      harness.container,
    ).averageFromChildren(parent, category, children);

    // 8.3 and 8.4 mean 8.35, which on halves is 8.5. The unscored unit is not
    // a zero.
    expect(
      (await harness.repo.listParents(category.id)).single.overallScore,
      8.5,
    );
  });
}
