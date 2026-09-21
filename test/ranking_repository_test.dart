import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/ranking_models.dart';

void main() {
  late AppDatabase db;
  late DriftRankingRepository repository;

  final now = DateTime.utc(2026, 8, 1);

  setUp(() {
    db = AppDatabase.inMemory();
    repository = DriftRankingRepository(db);
  });

  tearDown(() => db.close());

  Future<RankingCategory> makeCategory({String name = 'Shows'}) async {
    final category = RankingCategory(
      id: newId(),
      name: name,
      colorValue: 0xFF7C9EFF,
      childUnitsEnabled: true,
      createdAt: now,
      updatedAt: now,
    );
    await repository.upsertCategory(category);
    return category;
  }

  Future<RankingParent> makeParent(
    String categoryId, {
    String title = 'Severance',
    int queueSortOrder = 0,
  }) async {
    final parent = RankingParent(
      id: newId(),
      categoryId: categoryId,
      title: title,
      queueSortOrder: queueSortOrder,
      createdAt: now,
      updatedAt: now,
    );
    await repository.upsertParent(parent);
    return parent;
  }

  Future<RankingChild> makeChild(
    String parentId, {
    String name = 'Pilot',
    int sortOrder = 0,
  }) async {
    final child = RankingChild(
      id: newId(),
      parentId: parentId,
      name: name,
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
    );
    await repository.upsertChild(child);
    return child;
  }

  group('Round trip', () {
    test('a category keeps its templates and page prefs', () async {
      final category = RankingCategory(
        id: newId(),
        name: 'Restaurants',
        colorValue: 0xFF4CAF50,
        iconKey: 'forkKnife',
        childUnitsEnabled: true,
        childUnitLabel: 'Dish',
        imagesOnChild: true,
        parentScoreMax: 10,
        childScorePrecision: RankingScorePrecision.integers,
        parentTemplate: const [
          RankingTemplateField(
            id: 'f1',
            label: 'Service',
            sortOrder: 0,
            scoreMax: 10,
          ),
          RankingTemplateField(
            id: 'f2',
            label: 'Value',
            sortOrder: 1,
            notesEnabled: false,
          ),
        ],
        childTemplate: const [
          RankingTemplateField(id: 'c1', label: 'Portion', sortOrder: 0),
        ],
        sortMode: RankingSortMode.customField,
        sortFieldId: 'f1',
        sortAscending: true,
        createdAt: now,
        updatedAt: now,
      );
      await repository.upsertCategory(category);

      final read = (await repository.getCategory(category.id))!;
      expect(read.childUnitLabel, 'Dish');
      expect(read.imagesOnChild, isTrue);
      expect(read.parentScoreMax, 10);
      expect(read.childScorePrecision, RankingScorePrecision.integers);
      expect(read.parentTemplate.map((f) => f.label), ['Service', 'Value']);
      expect(read.parentTemplate.first.scoreMax, 10);
      expect(read.parentTemplate.last.notesEnabled, isFalse);
      expect(read.childTemplate.single.label, 'Portion');
      expect(read.sortMode, RankingSortMode.customField);
      expect(read.sortFieldId, 'f1');
      expect(read.sortAscending, isTrue);
    });

    test(
      'an entry keeps its field values, including notes-only ones',
      () async {
        final category = await makeCategory();
        final parent = (await makeParent(category.id)).copyWith(
          overallScore: 8.5,
          notes: 'slow burn #scifi',
          fieldValues: const {
            'f1': RankingFieldValue(score: 9, notes: 'tight'),
            'f2': RankingFieldValue(notes: 'no score yet'),
          },
        );
        await repository.upsertParent(parent);

        final read = (await repository.getParent(parent.id))!;
        expect(read.overallScore, 8.5);
        expect(read.fieldValues['f1']!.score, 9);
        expect(read.fieldValues['f1']!.notes, 'tight');
        expect(read.fieldValues['f2']!.score, isNull);
        expect(read.fieldValues['f2']!.notes, 'no score yet');
      },
    );

    test('an empty field value is not stored at all', () async {
      final category = await makeCategory();
      final parent = (await makeParent(
        category.id,
      )).copyWith(fieldValues: const {'f1': RankingFieldValue()});
      await repository.upsertParent(parent);

      // Storing an empty value would make an untouched field indistinguishable
      // from a scored one at the point a custom-field sort asks.
      expect((await repository.getParent(parent.id))!.fieldValues, isEmpty);
    });

    test('structured tags survive, in the order they were added', () async {
      final category = await makeCategory();
      final parent = (await makeParent(
        category.id,
      )).copyWith(tags: ['rom-com', 'a24']);
      await repository.upsertParent(parent);

      expect((await repository.getParent(parent.id))!.tags, ['rom-com', 'a24']);
    });

    test('an entry written before tags existed reads as untagged', () async {
      final category = await makeCategory();
      final parent = await makeParent(category.id);
      expect((await repository.getParent(parent.id))!.tags, isEmpty);
    });
  });

  group('Ordering', () {
    test('children come back in their saved order', () async {
      final category = await makeCategory();
      final parent = await makeParent(category.id);
      final a = await makeChild(parent.id, name: 'A', sortOrder: 0);
      final b = await makeChild(parent.id, name: 'B', sortOrder: 1);
      final c = await makeChild(parent.id, name: 'C', sortOrder: 2);

      final written = await repository.reorderChildren([c.id, a.id, b.id]);
      // Only the rows that actually moved are written back, so the caller
      // pushes the minimum.
      expect(written.map((child) => child.id), containsAll([c.id, a.id]));

      final read = await repository.listChildren(parent.id);
      expect(read.map((child) => child.name), ['C', 'A', 'B']);
    });

    test('reordering the queue renumbers only what moved', () async {
      final category = await makeCategory();
      final a = await makeParent(category.id, title: 'A', queueSortOrder: 0);
      final b = await makeParent(category.id, title: 'B', queueSortOrder: 1);

      final written = await repository.reorderQueue([b.id, a.id]);
      expect(written, hasLength(2));
      expect((await repository.getParent(b.id))!.queueSortOrder, 0);
      expect((await repository.getParent(a.id))!.queueSortOrder, 1);

      expect(await repository.reorderQueue([b.id, a.id]), isEmpty);
    });

    test('categories come back in their sort order', () async {
      final first = await makeCategory(name: 'Shows');
      final second = await makeCategory(name: 'Restaurants');
      await repository.reorderCategories([second.id, first.id]);

      final read = await repository.listCategories();
      expect(read.map((category) => category.name), ['Restaurants', 'Shows']);
    });
  });

  group('Soft delete', () {
    test('deleting an entry takes its children with it', () async {
      final category = await makeCategory();
      final parent = await makeParent(category.id);
      await makeChild(parent.id);

      final result = await repository.softDeleteParent(parent.id);
      expect(result.children, hasLength(1));
      expect(await repository.listParents(category.id), isEmpty);
      expect(await repository.listChildren(parent.id), isEmpty);

      await repository.restoreParent(parent.id);
      expect(await repository.listParents(category.id), hasLength(1));
      expect(await repository.listChildren(parent.id), hasLength(1));
    });

    test('deleting a category cascades to entries and units', () async {
      final category = await makeCategory();
      final parent = await makeParent(category.id);
      await makeChild(parent.id);

      final result = await repository.softDeleteCategory(category.id);
      expect(result.parents, hasLength(1));
      expect(result.children, hasLength(1));
      expect(await repository.listCategories(), isEmpty);
      expect(await repository.listParents(category.id), isEmpty);
    });

    test(
      'restoring a category brings back only what its cascade took',
      () async {
        final category = await makeCategory();
        final kept = await makeParent(category.id, title: 'Kept');
        final removedEarlier = await makeParent(category.id, title: 'Gone');

        // Deleted on its own, before the category went. Restoring the category
        // must not resurrect it — the user deleted this one deliberately.
        await repository.softDeleteParent(removedEarlier.id);
        await repository.softDeleteCategory(category.id);
        await repository.restoreCategory(category.id);

        final live = await repository.listParents(category.id);
        expect(live.map((parent) => parent.title), ['Kept']);
        expect((await repository.getParent(kept.id))!.deletedAt, isNull);
        expect(
          (await repository.getParent(removedEarlier.id))!.deletedAt,
          isNotNull,
        );
      },
    );

    test(
      'a tombstone keeps its content so the undo has something to restore',
      () async {
        final category = await makeCategory();
        final parent = (await makeParent(
          category.id,
        )).copyWith(notes: 'worth keeping');
        await repository.upsertParent(parent);
        await repository.softDeleteParent(parent.id);

        final tombstone = (await repository.getParent(parent.id))!;
        expect(tombstone.deletedAt, isNotNull);
        expect(tombstone.notes, 'worth keeping');
      },
    );

    test('purge drops tombstones past the retention window', () async {
      final category = await makeCategory();
      final parent = await makeParent(category.id);
      await makeChild(parent.id);
      await repository.softDeleteCategory(category.id);

      // Well inside the window: nothing goes yet.
      await repository.purgeExpiredDeleted(now.add(const Duration(days: 5)));
      expect(
        await repository.getAllCategories(includeDeleted: true),
        hasLength(1),
      );

      await repository.purgeExpiredDeleted(now.add(const Duration(days: 120)));
      expect(await repository.getAllCategories(includeDeleted: true), isEmpty);
      expect(await repository.getAllParents(includeDeleted: true), isEmpty);
      expect(await repository.getAllChildren(includeDeleted: true), isEmpty);
    });
  });
}
