// Repeat counts on rankings (RANKINGS_COUNTER_HLD.md): one row per device per
// entry or unit. Covers the total, the repository's one-statement tap and its
// version guard, the actions' floor and in-progress promotion, the two-device
// sync merge, and the schema-143 upgrade and its index.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/features/rankings/rankings_actions.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.utc(2026, 10, 10);

Future<
  ({
    RankingsActions actions,
    DriftRankingRepository repo,
    ProviderContainer container,
  })
>
_harness() async {
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
  container.read(deviceIdProvider.notifier).state = 'device-a';
  return (
    actions: RankingsActions.detached(container),
    repo: DriftRankingRepository(db),
    container: container,
  );
}

Future<int> _total(DriftRankingRepository repo, String entryId) async =>
    rankingCountTotal((await repo.sumCountsByEntry())[entryId] ?? 0);

/// [from]'s rows applied to [to] the way a pull applies them.
Future<void> _pull(
  DriftRankingRepository from,
  DriftRankingRepository to,
) async {
  for (final count in await from.getAllCounts()) {
    await to.upsertCount(
      mergeRankingCountFromRemote(
        rankingCountToFirestore(count),
        count.id,
        local: await to.getCount(count.id),
      ),
      recordLocalActivity: false,
    );
  }
}

void main() {
  test('the total starts at 1 and never reads below it', () {
    expect(rankingCountTotal(0), 1);
    expect(rankingCountTotal(2), 3);
    expect(rankingCountTotal(-1), 1);
  });

  group('repository', () {
    late DriftRankingRepository repo;

    setUp(() {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      repo = DriftRankingRepository(db);
    });

    test('a burst of concurrent taps loses none', () async {
      await Future.wait([
        for (var i = 0; i < 25; i++)
          repo.adjustCount(entryId: 'e1', deviceId: 'a', delta: 1),
      ]);
      final row = (await repo.getCount(rankingCountId('e1', 'a')))!;
      expect(row.delta, 25);
      expect(row.version, 25);
    });

    test('sums by entry, across devices, skipping deleted rows', () async {
      await repo.adjustCount(entryId: 'e1', deviceId: 'a', delta: 2);
      await repo.adjustCount(entryId: 'e1', deviceId: 'b', delta: 3);
      await repo.adjustCount(entryId: 'e2', deviceId: 'a', delta: -1);
      await repo.upsertCount(
        RankingCount(
          id: rankingCountId('e1', 'c'),
          entryId: 'e1',
          deviceId: 'c',
          delta: 100,
          createdAt: _now,
          updatedAt: _now,
          version: 1,
          deletedAt: _now,
        ),
      );
      expect(await repo.sumCountsByEntry(), {'e1': 5, 'e2': -1});
      expect(await repo.sumCountsFor('e1'), 5);
      expect(await repo.sumCountsFor('e2'), -1);
      expect(await repo.sumCountsFor('none'), 0);
    });

    test('an older or equal copy never lowers a row; a newer one '
        'applies', () async {
      final written = await repo.adjustCount(
        entryId: 'e1',
        deviceId: 'a',
        delta: 1,
      );
      await repo.adjustCount(entryId: 'e1', deviceId: 'a', delta: 1);
      // A pull that read the row at version 1, landing after the second tap.
      await repo.upsertCount(written);
      expect((await repo.getCount(written.id))!.delta, 2);

      final current = (await repo.getCount(written.id))!;
      await repo.upsertCount(
        RankingCount(
          id: current.id,
          entryId: 'e1',
          deviceId: 'a',
          delta: 99,
          createdAt: current.createdAt,
          updatedAt: current.updatedAt,
          version: current.version,
        ),
      );
      expect((await repo.getCount(written.id))!.delta, 2);

      await repo.upsertCount(
        RankingCount(
          id: current.id,
          entryId: 'e1',
          deviceId: 'a',
          delta: 7,
          createdAt: current.createdAt,
          updatedAt: current.updatedAt,
          version: current.version + 1,
        ),
      );
      expect((await repo.getCount(written.id))!.delta, 7);
    });

    test(
      'a tap on a deleted row brings it back holding only that tap',
      () async {
        await repo.upsertCount(
          RankingCount(
            id: rankingCountId('e1', 'a'),
            entryId: 'e1',
            deviceId: 'a',
            delta: 4,
            createdAt: _now,
            updatedAt: _now,
            version: 3,
            deletedAt: _now,
          ),
        );
        final row = await repo.adjustCount(
          entryId: 'e1',
          deviceId: 'a',
          delta: 1,
        );
        expect(row.deletedAt, isNull);
        expect(row.delta, 1);
        expect(row.version, 4);
        expect(await repo.sumCountsFor('e1'), 1);
      },
    );
  });

  group('actions', () {
    Future<
      ({
        RankingsActions actions,
        DriftRankingRepository repo,
        ProviderContainer container,
        RankingParent parent,
        RankingChild child,
      })
    >
    seed() async {
      final h = await _harness();
      final category = RankingCategory(
        id: newId(),
        name: 'Food',
        colorValue: 0xFF7C9EFF,
        childUnitsEnabled: true,
        parentCountEnabled: true,
        childCountEnabled: true,
        createdAt: _now,
        updatedAt: _now,
      );
      await h.repo.upsertCategory(category);
      final parent = await h.actions.createParent(
        categoryId: category.id,
        title: 'Pho Hung',
        queueSortOrder: 0,
      );
      final child = RankingChild(
        id: newId(),
        parentId: parent.id,
        name: 'Rare beef pho',
        createdAt: _now,
        updatedAt: _now,
      );
      // Straight to the repository: createChild would start the entry itself.
      await h.repo.upsertChild(child);
      return (
        actions: h.actions,
        repo: h.repo,
        container: h.container,
        parent: parent,
        child: child,
      );
    }

    test('taking one back at 1 writes nothing', () async {
      final s = await seed();
      final made = await s.actions.adjustCount(
        s.parent.id,
        parentId: s.parent.id,
        delta: -1,
      );
      expect(made, 0);
      expect(await s.repo.getAllCounts(), isEmpty);
    });

    test('two quick takes-back at 2 end at 1', () async {
      final s = await seed();
      await s.actions.adjustCount(s.parent.id, parentId: s.parent.id, delta: 1);
      final made = await Future.wait([
        s.actions.adjustCount(s.parent.id, parentId: s.parent.id, delta: -1),
        s.actions.adjustCount(s.parent.id, parentId: s.parent.id, delta: -1),
      ]);
      expect(made, unorderedEquals([-1, 0]));
      expect(await _total(s.repo, s.parent.id), 1);
    });

    test('a move past the floor is cut short at 1', () async {
      final s = await seed();
      await s.actions.adjustCount(s.child.id, parentId: s.parent.id, delta: 2);
      final made = await s.actions.adjustCount(
        s.child.id,
        parentId: s.parent.id,
        delta: -5,
      );
      expect(made, -2);
      expect(await _total(s.repo, s.child.id), 1);
    });

    test('nothing is written before the device id has loaded', () async {
      final s = await seed();
      s.container.read(deviceIdProvider.notifier).state = kUnresolvedDeviceId;
      final made = await s.actions.adjustCount(
        s.parent.id,
        parentId: s.parent.id,
        delta: 1,
      );
      expect(made, 0);
      expect(await s.repo.getAllCounts(), isEmpty);
      expect(
        (await s.repo.getParent(s.parent.id))!.status,
        RankingStatus.queued,
      );
    });

    test('taking a repeat back leaves a queued entry queued', () async {
      final s = await seed();
      // Another device's repeat, so there is one to take back.
      await s.repo.adjustCount(
        entryId: s.child.id,
        deviceId: 'device-b',
        delta: 1,
      );
      final made = await s.actions.adjustCount(
        s.child.id,
        parentId: s.parent.id,
        delta: -1,
      );
      expect(made, -1);
      expect(
        (await s.repo.getParent(s.parent.id))!.status,
        RankingStatus.queued,
      );
    });

    test('a tap on a unit starts its queued entry and leaves the unit row '
        'alone', () async {
      final s = await seed();
      expect(
        (await s.repo.getParent(s.parent.id))!.status,
        RankingStatus.queued,
      );
      await s.actions.adjustCount(s.child.id, parentId: s.parent.id, delta: 1);
      expect(
        (await s.repo.getParent(s.parent.id))!.status,
        RankingStatus.inProgress,
      );
      expect((await s.repo.getChild(s.child.id))!.version, s.child.version);
      expect(await _total(s.repo, s.child.id), 2);
    });

    test('a + at a sum below 0 moves the count shown from 1 to 2', () async {
      final s = await seed();
      // Two devices each took the last repeat back offline.
      await s.repo.adjustCount(entryId: s.child.id, deviceId: 'b', delta: -1);
      expect(await _total(s.repo, s.child.id), 1);
      final made = await s.actions.adjustCount(
        s.child.id,
        parentId: s.parent.id,
        delta: 1,
      );
      expect(made, 2);
      expect(await _total(s.repo, s.child.id), 2);
    });

    test('a take-back that adds leaves a queued entry queued', () async {
      final s = await seed();
      final made = await s.actions.adjustCount(
        s.child.id,
        parentId: s.parent.id,
        delta: 1,
        starts: false,
      );
      expect(made, 1);
      expect(
        (await s.repo.getParent(s.parent.id))!.status,
        RankingStatus.queued,
      );
    });
  });

  group('sync', () {
    test('two devices tapping offline both keep every tap', () async {
      final dbA = AppDatabase.inMemory();
      final dbB = AppDatabase.inMemory();
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final a = DriftRankingRepository(dbA);
      final b = DriftRankingRepository(dbB);

      await a.adjustCount(entryId: 'e1', deviceId: 'a', delta: 1);
      await a.adjustCount(entryId: 'e1', deviceId: 'a', delta: 1);
      await b.adjustCount(entryId: 'e1', deviceId: 'b', delta: 1);

      await _pull(a, b);
      await _pull(b, a);
      // Each device's own row coming back to it changes nothing.
      await _pull(a, b);
      await _pull(b, a);

      expect(await _total(a, 'e1'), 4);
      expect(await _total(b, 'e1'), 4);
    });

    test('an equal version keeps the local row, however new its date', () {
      final local = RankingCount(
        id: rankingCountId('e1', 'a'),
        entryId: 'e1',
        deviceId: 'a',
        delta: 2,
        createdAt: _now,
        updatedAt: _now,
        version: 3,
      );
      final remote = rankingCountToFirestore(
        RankingCount(
          id: local.id,
          entryId: 'e1',
          deviceId: 'a',
          delta: 9,
          createdAt: _now,
          updatedAt: _now.add(const Duration(hours: 1)),
          version: 3,
        ),
      );
      expect(
        identical(
          mergeRankingCountFromRemote(remote, local.id, local: local),
          local,
        ),
        isTrue,
      );
    });

    test('a count row round-trips through the mapper', () {
      final count = RankingCount(
        id: rankingCountId('e1', 'a'),
        entryId: 'e1',
        deviceId: 'a',
        delta: -3,
        createdAt: _now,
        updatedAt: _now,
        version: 4,
      );
      final back = mergeRankingCountFromRemote(
        rankingCountToFirestore(count),
        count.id,
      );
      expect(back.entryId, 'e1');
      expect(back.deviceId, 'a');
      expect(back.delta, -3);
      expect(back.version, 4);
    });

    test('the category toggles round-trip, and a payload without them keeps '
        'the local values', () {
      final category = RankingCategory(
        id: 'c1',
        name: 'Food',
        colorValue: 0xFF7C9EFF,
        parentCountEnabled: true,
        childCountEnabled: true,
        createdAt: _now,
        updatedAt: _now,
      );
      final payload = rankingCategoryToFirestore(category);
      final back = mergeRankingCategoryFromRemote(payload, 'c1');
      expect(back.parentCountEnabled, isTrue);
      expect(back.childCountEnabled, isTrue);

      final older = Map<String, dynamic>.from(payload)
        ..remove('parentCountEnabled')
        ..remove('childCountEnabled');
      final kept = mergeRankingCategoryFromRemote(older, 'c1', local: category);
      expect(kept.parentCountEnabled, isTrue);
      expect(kept.childCountEnabled, isTrue);
    });
  });

  test('a schema-142 database upgrades with the count table and the toggles '
      'off', () async {
    final dir = Directory.systemTemp.createTempSync('voyager_counts_mig');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/voyager.sqlite');

    final seed = AppDatabase(NativeDatabase(file));
    final category = RankingCategory(
      id: newId(),
      name: 'Food',
      colorValue: 0xFF7C9EFF,
      createdAt: _now,
      updatedAt: _now,
    );
    await DriftRankingRepository(seed).upsertCategory(category);
    for (final statement in [
      'DROP INDEX idx_ranking_counts_entry',
      'DROP TABLE ranking_counts_table',
      'ALTER TABLE ranking_categories_table DROP COLUMN parent_count_enabled',
      'ALTER TABLE ranking_categories_table DROP COLUMN child_count_enabled',
      'PRAGMA user_version = 142',
    ]) {
      await seed.customStatement(statement);
    }
    await seed.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final repository = DriftRankingRepository(db);
    final upgraded = (await repository.getCategory(category.id))!;
    expect(upgraded.parentCountEnabled, isFalse);
    expect(upgraded.childCountEnabled, isFalse);
    await repository.adjustCount(entryId: 'e1', deviceId: 'a', delta: 1);
    expect(await repository.sumCountsByEntry(), {'e1': 1});
    final index = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name = 'idx_ranking_counts_entry'",
        )
        .get();
    expect(index, hasLength(1));
  });
}
