// Progress tracking on rankings: one "where I stopped" bookmark per entry,
// pointing at one of its units. Covers the time parsing, the actions — the
// delete/undo rule and Finished → next — the sync merge, and the schema-142
// upgrade.

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
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_actions.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.utc(2026, 8, 1);

Future<({RankingsActions actions, DriftRankingRepository repo})>
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
  return (
    actions: RankingsActions.detached(container),
    repo: DriftRankingRepository(db),
  );
}

RankingCategory _category() => RankingCategory(
  id: newId(),
  name: 'TV',
  colorValue: 0xFF7C9EFF,
  childUnitsEnabled: true,
  progressEnabled: true,
  createdAt: _now,
  updatedAt: _now,
);

Future<({RankingCategory category, RankingParent parent})> _seedShow(
  ({RankingsActions actions, DriftRankingRepository repo}) h,
) async {
  final category = _category();
  await h.repo.upsertCategory(category);
  final parent = await h.actions.createParent(
    categoryId: category.id,
    title: 'Family Guy',
    queueSortOrder: 0,
  );
  return (category: category, parent: parent);
}

void main() {
  group('time', () {
    test('reads minutes, m:ss and h:mm:ss; empty is the start', () {
      expect(parseRankingProgressTime('32'), (seconds: 32 * 60));
      expect(parseRankingProgressTime('14:32'), (seconds: 14 * 60 + 32));
      expect(parseRankingProgressTime(' 1:02:30 '), (seconds: 3750));
      expect(parseRankingProgressTime(''), (seconds: null));
    });

    test('refuses what is not a time', () {
      expect(parseRankingProgressTime('abc'), isNull);
      expect(parseRankingProgressTime('14:75'), isNull);
      expect(parseRankingProgressTime('1:2:3:4'), isNull);
      expect(parseRankingProgressTime('-5'), isNull);
    });

    test('the box refuses, at the keystroke, what can never be a time', () {
      for (final ok in [
        '',
        '1',
        '14',
        '14:',
        '14:3',
        '14:32',
        '1:02:',
        '1:02:30',
      ]) {
        expect(rankingProgressTimeTyping.hasMatch(ok), isTrue, reason: ok);
      }
      for (final bad in [
        'a',
        '14a',
        ':',
        '14:99',
        '14:60',
        '1:2:3:4',
        '1234',
        '1::2',
        // A third group can't be followed by anything.
        '1:02:30:',
      ]) {
        expect(rankingProgressTimeTyping.hasMatch(bad), isFalse, reason: bad);
      }
    });

    test('prints m:ss, and h:mm:ss past the hour', () {
      expect(formatRankingProgressTime(0), '0:00');
      expect(formatRankingProgressTime(872), '14:32');
      expect(formatRankingProgressTime(3750), '1:02:30');
    });
  });

  test('the next unit name moves the last number on, padding kept', () {
    RankingChild unit(String name) => RankingChild(
      id: 'c',
      parentId: 'p',
      name: name,
      createdAt: _now,
      updatedAt: _now,
    );
    expect(
      rankingNextChildName(unit('S3E07'), label: 'Episode', count: 7),
      'S3E08',
    );
    expect(
      rankingNextChildName(unit('Episode 9'), label: 'Episode', count: 9),
      'Episode 10',
    );
    // The title after the code is that unit's own, not the next one's.
    expect(
      rankingNextChildName(
        unit('S3E07 Emission Impossible'),
        label: 'Episode',
        count: 7,
      ),
      'S3E08',
    );
    expect(
      rankingNextChildName(
        unit('Episode 9 Finale'),
        label: 'Episode',
        count: 9,
      ),
      'Episode 10',
    );
    expect(
      rankingNextChildName(unit('Pilot'), label: 'Episode', count: 1),
      'Episode 2',
    );
    // Past an int's range.
    expect(
      rankingNextChildName(
        unit('20240101123045678901 clip'),
        label: 'Episode',
        count: 1,
      ),
      '20240101123045678902',
    );
  });

  test('a new unit on the bookmark starts at its beginning', () {
    final parent = RankingParent(
      id: 'p',
      categoryId: 'c',
      title: 'Show',
      progressChildId: 'a',
      progressSeconds: 600,
      createdAt: _now,
      updatedAt: _now,
    );
    final moved = parent.copyWith(progressChildId: 'b');
    expect(moved.progressChildId, 'b');
    expect(moved.progressSeconds, isNull);
    final timed = moved.copyWith(progressSeconds: 90);
    expect(timed.progressChildId, 'b');
    expect(timed.progressSeconds, 90);
    final cleared = timed.copyWith(clearProgress: true);
    expect(cleared.progressChildId, isNull);
    expect(cleared.progressSeconds, isNull);
  });

  test('moving the bookmark from the start to 0:00 is stamped', () {
    final atStart = RankingParent(
      id: 'p',
      categoryId: 'c',
      title: 'Show',
      progressChildId: 'a',
      createdAt: _now,
      updatedAt: _now,
      fieldUpdatedAt: {'progress': _now},
    );
    final atZero = atStart.copyWith(progressChildId: 'a', progressSeconds: 0);
    expect(atZero.fieldUpdatedAt['progress']!.isAfter(_now), isTrue);
  });

  test('units sharing a place have a fixed next between them', () {
    RankingChild unit(String id, DateTime created) => RankingChild(
      id: id,
      parentId: 'p',
      name: id,
      sortOrder: 5,
      createdAt: created,
      updatedAt: created,
    );
    final older = unit('b', _now);
    final newer = unit('a', _now.add(const Duration(seconds: 1)));
    for (final children in [
      [older, newer],
      [newer, older],
    ]) {
      expect(rankingNextChild(older, children)?.id, newer.id);
      expect(rankingNextChild(newer, children), isNull);
    }
  });

  group('actions', () {
    test('set and clear persist on the entry', () async {
      final h = await _harness();
      final show = await _seedShow(h);
      final ep = await h.actions.createChild(
        parent: show.parent,
        name: 'S3E07',
        sortOrder: 0,
      );

      await h.actions.setProgress(show.parent.id, ep.id, seconds: 872);
      var stored = (await h.repo.getParent(show.parent.id))!;
      expect(stored.progressChildId, ep.id);
      expect(stored.progressSeconds, 872);

      await h.actions.clearProgress(show.parent.id);
      stored = (await h.repo.getParent(show.parent.id))!;
      expect(stored.progressChildId, isNull);
      expect(stored.progressSeconds, isNull);
    });

    test('deleting the bookmarked unit hides the bookmark, and undo brings '
        'it back', () async {
      final h = await _harness();
      final show = await _seedShow(h);
      final ep = await h.actions.createChild(
        parent: show.parent,
        name: 'S3E07',
        sortOrder: 0,
      );
      await h.actions.setProgress(show.parent.id, ep.id, seconds: 872);

      final stamps = await h.actions.deleteChild(ep.id);
      var parent = (await h.repo.getParent(show.parent.id))!;
      expect(
        rankingProgressChild(parent, await h.repo.listChildren(parent.id)),
        isNull,
      );

      await h.actions.restoreChild(ep.id, stamps);
      parent = (await h.repo.getParent(show.parent.id))!;
      expect(
        rankingProgressChild(parent, await h.repo.listChildren(parent.id))?.id,
        ep.id,
      );
      expect(parent.progressSeconds, 872);
    });

    test(
      'a bookmark set while the unit was deleted wins over its undo',
      () async {
        final h = await _harness();
        final show = await _seedShow(h);
        final first = await h.actions.createChild(
          parent: show.parent,
          name: 'S3E07',
          sortOrder: 0,
        );
        final second = await h.actions.createChild(
          parent: show.parent,
          name: 'S3E08',
          sortOrder: 1,
        );
        await h.actions.setProgress(show.parent.id, first.id, seconds: 872);

        final stamps = await h.actions.deleteChild(first.id);
        await h.actions.setProgress(show.parent.id, second.id, seconds: 60);
        await h.actions.restoreChild(first.id, stamps);

        final parent = (await h.repo.getParent(show.parent.id))!;
        expect(parent.progressChildId, second.id);
        expect(parent.progressSeconds, 60);
      },
    );

    test(
      'Finished moves to the start of the next unit in saved order',
      () async {
        final h = await _harness();
        final show = await _seedShow(h);
        final first = await h.actions.createChild(
          parent: show.parent,
          name: 'S3E07',
          sortOrder: 0,
        );
        final second = await h.actions.createChild(
          parent: show.parent,
          name: 'S3E08',
          sortOrder: 1,
        );
        await h.actions.setProgress(show.parent.id, first.id, seconds: 872);

        final next = await h.actions.finishProgress(
          show.parent.id,
          show.category,
        );

        expect(next?.id, second.id);
        final parent = (await h.repo.getParent(show.parent.id))!;
        expect(parent.progressChildId, second.id);
        expect(parent.progressSeconds, isNull);
      },
    );

    test(
      'Finished on the last unit adds the next one and bookmarks it',
      () async {
        final h = await _harness();
        final show = await _seedShow(h);
        final last = await h.actions.createChild(
          parent: show.parent,
          name: 'S3E07',
          sortOrder: 4,
        );
        await h.actions.setProgress(show.parent.id, last.id, seconds: 872);

        final next = await h.actions.finishProgress(
          show.parent.id,
          show.category,
        );

        expect(next?.name, 'S3E08');
        final children = await h.repo.listChildren(show.parent.id);
        expect(children.map((c) => c.name), containsAll(['S3E07', 'S3E08']));
        expect(children.firstWhere((c) => c.id == next!.id).sortOrder, 5);
        final parent = (await h.repo.getParent(show.parent.id))!;
        expect(parent.progressChildId, next!.id);
      },
    );

    test('two quick Finisheds on the last unit move on twice', () async {
      final h = await _harness();
      final show = await _seedShow(h);
      final last = await h.actions.createChild(
        parent: show.parent,
        name: 'S3E07',
        sortOrder: 0,
      );
      await h.actions.setProgress(show.parent.id, last.id);

      final results = await Future.wait([
        h.actions.finishProgress(show.parent.id, show.category),
        h.actions.finishProgress(show.parent.id, show.category),
      ]);

      expect(results.map((c) => c?.name), ['S3E08', 'S3E09']);
      final children = await h.repo.listChildren(show.parent.id);
      expect(
        children.map((c) => c.name),
        unorderedEquals(['S3E07', 'S3E08', 'S3E09']),
      );
      final parent = (await h.repo.getParent(show.parent.id))!;
      expect(parent.progressChildId, results.last!.id);
    });

    test('bookmarking a unit starts a queued entry', () async {
      final h = await _harness();
      final show = await _seedShow(h);
      // Written straight to the store: adding a unit by the action would
      // start the entry itself.
      final unit = RankingChild(
        id: newId(),
        parentId: show.parent.id,
        name: 'E1',
        createdAt: _now,
        updatedAt: _now,
      );
      await h.repo.upsertChild(unit);
      expect(
        (await h.repo.getParent(show.parent.id))!.status,
        RankingStatus.queued,
      );

      await h.actions.setProgress(show.parent.id, unit.id, seconds: 720);

      expect(
        (await h.repo.getParent(show.parent.id))!.status,
        RankingStatus.inProgress,
      );
    });

    test('Cancel takes back its own bookmark, never one moved since', () async {
      final h = await _harness();
      final show = await _seedShow(h);
      final e3 = await h.actions.createChild(
        parent: show.parent,
        name: 'E3',
        sortOrder: 0,
      );
      final e4 = await h.actions.createChild(
        parent: show.parent,
        name: 'E4',
        sortOrder: 1,
      );
      final e5 = await h.actions.createChild(
        parent: show.parent,
        name: 'E5',
        sortOrder: 2,
      );
      await h.actions.setProgress(show.parent.id, e3.id, seconds: 60);
      const opening = (childId: null, seconds: null);

      // Still what the dialog wrote: put back.
      await h.actions.setProgress(show.parent.id, e4.id, seconds: 90);
      await h.actions.revertProgress(
        show.parent.id,
        from: (childId: e4.id, seconds: 90),
        to: (childId: e3.id, seconds: 60),
      );
      var parent = (await h.repo.getParent(show.parent.id))!;
      expect((parent.progressChildId, parent.progressSeconds), (e3.id, 60));

      // Moved elsewhere since: left alone.
      await h.actions.setProgress(show.parent.id, e5.id);
      await h.actions.revertProgress(
        show.parent.id,
        from: (childId: e4.id, seconds: 90),
        to: opening,
      );
      parent = (await h.repo.getParent(show.parent.id))!;
      expect(parent.progressChildId, e5.id);
    });

    test('Finished with no live bookmark does nothing', () async {
      final h = await _harness();
      final show = await _seedShow(h);
      expect(
        await h.actions.finishProgress(show.parent.id, show.category),
        isNull,
      );
    });
  });

  group('sync', () {
    RankingParent at(DateTime stamp, {String? childId, int? seconds}) =>
        RankingParent(
          id: 'p1',
          categoryId: 'c1',
          title: 'Family Guy',
          progressChildId: childId,
          progressSeconds: seconds,
          createdAt: _now,
          updatedAt: stamp,
          version: 3,
          fieldUpdatedAt: {'progress': stamp},
        );

    test('the later bookmark wins, unit and time together', () {
      final local = at(_now, childId: 'a', seconds: 100);
      final remote = at(
        _now.add(const Duration(minutes: 1)),
        childId: 'b',
        seconds: 200,
      );
      final merged = mergeRankingParentFromRemote(
        rankingParentToFirestore(remote),
        'p1',
        local: local,
      );
      expect(merged.progressChildId, 'b');
      expect(merged.progressSeconds, 200);

      final kept = mergeRankingParentFromRemote(
        rankingParentToFirestore(local),
        'p1',
        local: remote,
      );
      expect(kept.progressChildId, 'b');
      expect(kept.progressSeconds, 200);
    });

    test('a bookmark cleared on another device clears here', () {
      final local = at(_now, childId: 'a', seconds: 100);
      final remote = at(_now.add(const Duration(minutes: 1)));
      final payload = rankingParentToFirestore(remote);
      expect(payload.containsKey('progressChildId'), isTrue);
      final merged = mergeRankingParentFromRemote(payload, 'p1', local: local);
      expect(merged.progressChildId, isNull);
      expect(merged.progressSeconds, isNull);
    });

    test('the category toggle round-trips', () {
      final category = _category();
      final back = mergeRankingCategoryFromRemote(
        rankingCategoryToFirestore(category),
        category.id,
      );
      expect(back.progressEnabled, isTrue);
    });
  });

  test('a schema-141 database upgrades with no bookmark and the toggle '
      'off', () async {
    final dir = Directory.systemTemp.createTempSync('voyager_progress_mig');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/voyager.sqlite');

    final seed = AppDatabase(NativeDatabase(file));
    final category = RankingCategory(
      id: newId(),
      name: 'TV',
      colorValue: 0xFF7C9EFF,
      createdAt: _now,
      updatedAt: _now,
    );
    await DriftRankingRepository(seed).upsertCategory(category);
    await DriftRankingRepository(seed).upsertParent(
      RankingParent(
        id: newId(),
        categoryId: category.id,
        title: 'Family Guy',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    for (final statement in [
      'ALTER TABLE ranking_categories_table DROP COLUMN progress_enabled',
      'ALTER TABLE ranking_parents_table DROP COLUMN progress_child_id',
      'ALTER TABLE ranking_parents_table DROP COLUMN progress_seconds',
      'PRAGMA user_version = 141',
    ]) {
      await seed.customStatement(statement);
    }
    await seed.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final repository = DriftRankingRepository(db);
    final parent = (await repository.listParents(category.id)).single;
    expect(parent.title, 'Family Guy');
    expect(parent.progressChildId, isNull);
    expect(
      (await repository.getCategory(category.id))!.progressEnabled,
      isFalse,
    );
  });
}
