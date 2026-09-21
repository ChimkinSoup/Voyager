// Snippets and experience snippets sync as records of their own rather than as
// lists inside the settings document (DATA_INTEGRITY_AUDIT_REPORT.md P1-1,
// option C). The whole-document clock let any device that changed any setting
// re-upload its stale copy of both lists over snippets added elsewhere.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/ordered_list_edit.dart';
import 'package:voyager/domain/services/weather_service.dart';

import 'fakes/fake_weather_api_client.dart';

const _a = Snippet(id: 'a', trigger: 'ee', replacement: 'expanded');
const _b = Snippet(id: 'b', trigger: 'brb', replacement: 'be right back');
const _c = Snippet(id: 'c', trigger: 'omw', replacement: 'on my way');

/// One device: its own database, a settings repository whose synced writes
/// go straight to its sync service, and that service.
class _Device {
  _Device(InMemorySyncRepository syncRepo, String deviceId)
    : db = AppDatabase.inMemory() {
    final syncedWrites = SyncedWriteNotifier();
    settings = DriftSettingsRepository(db, syncedWrites: syncedWrites);
    service = RemoteSyncService(
      syncRepository: syncRepo,
      journalRepository: DriftJournalRepository(db),
      dreamRepository: DriftDreamRepository(db),
      todoRepository: DriftTodoRepository(db),
      leetCodeRepository: DriftLeetCodeRepository(db),
      studyRepository: DriftStudyRepository(db),
      workoutRepository: DriftWorkoutRepository(db),
      jobRepository: DriftJobRepository(db),
      rankingRepository: DriftRankingRepository(db),
      calendarRepository: DriftCalendarRepository(db),
      trackerRepository: DriftTrackerRepository(db),
      financeRepository: DriftFinanceRepository(db),
      notificationRepository: DriftNotificationRepository(db),
      reminderRepository: DriftReminderRepository(db),
      bucketListRepository: DriftBucketListRepository(db),
      mediaRepository: DriftMediaRepository(db),
      settingsRepository: settings,
      weatherService: WeatherService(
        settingsRepository: settings,
        syncRepository: syncRepo,
        weatherApiClient: FakeWeatherApiClient(),
        deviceId: deviceId,
      ),
      syncEngine: SyncEngine(
        syncRepository: syncRepo,
        deviceId: deviceId,
        debouncer: Debouncer(delay: Duration.zero),
      ),
      deviceId: deviceId,
      uploadDebounceDelay: Duration.zero,
    );
    syncedWrites.onWrite = (collection, records) =>
        uploads.add(service.pushRecords(collection, records));
  }

  final AppDatabase db;
  late final DriftSettingsRepository settings;
  late final RemoteSyncService service;
  final uploads = <Future<void>>[];

  Future<void> settle() async {
    while (uploads.isNotEmpty) {
      final pending = List.of(uploads);
      uploads.clear();
      await Future.wait(pending);
    }
  }

  Future<List<Snippet>> snippets() async =>
      (await settings.getSettings()).snippets;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  group('planOrderedListEdit', () {
    OrderedListEdit<Snippet> plan(
      List<Snippet> before,
      List<Snippet> after, {
      Map<String, double>? stored,
    }) {
      return planOrderedListEdit(
        before: before,
        after: after,
        idOf: (s) => s.id,
        storedPositions:
            stored ??
            {
              for (var i = 0; i < before.length; i++)
                before[i].id: i.toDouble(),
            },
      );
    }

    test('dragging one item rewrites only that item', () {
      final edit = plan(const [_a, _b, _c], const [_b, _c, _a]);
      expect(edit.removedIds, isEmpty);
      expect(edit.written.map((w) => w.item.id), ['a']);
      expect(edit.written.single.position, greaterThan(2));
    });

    test('adding or removing an item moves nothing else', () {
      expect(
        plan(const [_a, _b], const [_a, _c, _b]).written.map((w) => w.item.id),
        ['c'],
      );
      final removal = plan(const [_a, _b, _c], const [_b, _c]);
      expect(removal.written, isEmpty);
      expect(removal.removedIds, ['a']);
    });

    test('an item deleted elsewhere is not brought back by a reorder', () {
      final edit = plan(
        const [_a, _b, _c],
        const [_c, _a, _b],
        stored: {'b': 1, 'c': 2},
      );
      expect(edit.written.map((w) => w.item.id), ['c']);
    });
  });

  group('the settings repository', () {
    late AppDatabase db;
    late DriftSettingsRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftSettingsRepository(db);
    });

    tearDown(() => db.close());

    test(
      'an edit round-trips in order, and an emptied list stays empty',
      () async {
        await repo.applySnippetEdit(const [], const [_c, _a, _b]);
        expect((await repo.getSettings()).snippets, const [_c, _a, _b]);

        await repo.applySnippetEdit(const [_c, _a, _b], const []);
        expect((await repo.getSettings()).snippets, isEmpty);
        expect(
          await repo.getSnippetRecords(includeDeleted: true),
          hasLength(3),
        );
      },
    );

    test(
      'saving settings read before a snippet arrived keeps that snippet',
      () async {
        final stale = await repo.getSettings();
        await repo.applySnippetEdit(const [], const [_a]);

        await repo.saveSettings(stale.copyWith(journalEntryListWidth: 300));

        expect((await repo.getSettings()).snippets, const [_a]);
      },
    );

    test(
      'an edit made from a stale list only applies what it changed',
      () async {
        await repo.applySnippetEdit(const [], const [_a]);
        // Another device's snippet lands after this editor read the list.
        await repo.applySnippetEdit(const [_a], const [_a, _b]);

        final renamed = _a.copyWith(replacement: 'changed');
        await repo.applySnippetEdit(const [_a], [renamed]);

        expect((await repo.getSettings()).snippets, [renamed, _b]);
      },
    );
  });

  group('two devices', () {
    late InMemorySyncRepository syncRepo;
    late _Device deviceA;
    late _Device deviceB;

    setUp(() {
      syncRepo = InMemorySyncRepository();
      deviceA = _Device(syncRepo, 'device-a');
      deviceB = _Device(syncRepo, 'device-b');
    });

    tearDown(() async {
      await deviceA.db.close();
      await deviceB.db.close();
    });

    test('snippets added on both devices both survive', () async {
      await deviceA.settings.applySnippetEdit(const [], const [_a]);
      await deviceB.settings.applySnippetEdit(const [], const [_b]);
      await deviceA.settle();
      await deviceB.settle();

      await deviceA.service.pullSnippets();
      await deviceB.service.pullSnippets();

      expect(await deviceA.snippets(), unorderedEquals(const [_a, _b]));
      expect(await deviceB.snippets(), unorderedEquals(const [_a, _b]));
    });

    test(
      "changing a setting on a stale device keeps the other's snippet",
      () async {
        await deviceB.settings.applySnippetEdit(const [], const [_b]);
        await deviceB.settle();

        final stale = await deviceA.settings.getSettings();
        await deviceA.settings.saveSettings(
          stale.copyWith(showDreamStatistics: !stale.showDreamStatistics),
        );
        await deviceA.service.pushSettings(
          await deviceA.settings.getSettings(),
        );
        await deviceA.settle();

        await deviceB.service.pullSettings();
        await deviceB.service.pullSnippets();
        await deviceA.service.pullSnippets();
        expect(await deviceB.snippets(), const [_b]);
        expect(await deviceA.snippets(), const [_b]);
      },
    );

    test('a deletion reaches the other device', () async {
      await deviceA.settings.applySnippetEdit(const [], const [_a, _b]);
      await deviceA.settle();
      await deviceB.service.pullSnippets();

      await deviceB.settings.applySnippetEdit(const [_a, _b], const [_b]);
      await deviceB.settle();
      await deviceA.service.pullSnippets();

      expect(await deviceA.snippets(), const [_b]);
    });

    test('a list only an older build wrote is adopted and uploaded', () async {
      await syncRepo.upsertRemoteSettings({
        'settingsUpdatedAt': DateTime.utc(2026, 9, 1).toIso8601String(),
        'snippets': [_a.toJson()],
      });

      await deviceA.service.pullSettings();
      await deviceA.settle();

      expect(await deviceA.snippets(), const [_a]);
      expect(
        await syncRepo.getDocument(FirestoreCollections.snippets, 'a'),
        isNotNull,
      );
    });

    test(
      'an adopted snippet defers to a record another device already has',
      () async {
        await deviceB.settings.applySnippetEdit(const [], const [_a]);
        await deviceB.settings.applySnippetEdit(const [_a], const []);
        await deviceB.settle();
        // An older build still carries the deleted snippet in its list.
        await syncRepo.upsertRemoteSettings({
          'settingsUpdatedAt': DateTime.utc(2030).toIso8601String(),
          'snippets': [_a.toJson()],
        });

        await deviceA.service.pullSettings();
        await deviceA.settle();

        expect(await deviceA.snippets(), isEmpty);
        final remote = await syncRepo.getDocument(
          FirestoreCollections.snippets,
          'a',
        );
        expect(remote?['deletedAt'], isNotNull);
      },
    );
  });

  test('mapping a record round-trips, and an unusable one is skipped', () {
    final record = SyncedListItem(
      item: _b,
      position: 1.5,
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 2),
      version: 3,
    );
    final merged = mergeSnippetFromRemote(snippetToFirestore(record), 'b')!;
    expect(merged.item, _b);
    expect(merged.position, 1.5);
    expect(merged.version, 3);

    expect(mergeSnippetFromRemote({'version': 4}, 'x'), isNull);
    expect(
      settingsSyncPayload(const AppSettings()).containsKey('snippets'),
      isFalse,
    );
  });

  test('the v115 migration moves both lists into their tables', () async {
    final dir = Directory.systemTemp.createTempSync('voyager_snippets_115');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/voyager.sqlite');

    final seed = AppDatabase(NativeDatabase(file));
    await DriftSettingsRepository(seed).getSettings();
    await seed.customStatement('DROP TABLE snippets_table');
    await seed.customStatement('DROP TABLE job_experience_snippets_table');
    await seed.customStatement(
      'UPDATE settings_table SET snippets_json = ?, '
      'job_experience_snippets_json = ? WHERE id = 1',
      [
        jsonEncode([_b.toJson(), _a.toJson()]),
        jsonEncode([
          const JobExperienceSnippet(
            id: 'j',
            name: 'Initech',
            description: 'Reports',
          ).toJson(),
        ]),
      ],
    );
    await seed.customStatement('PRAGMA user_version = 114');
    await seed.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final settings = await DriftSettingsRepository(upgraded).getSettings();

    expect(settings.snippets, const [_b, _a]);
    expect(settings.jobExperienceSnippets.single.name, 'Initech');
    final row = await upgraded
        .customSelect('SELECT snippets_json FROM settings_table')
        .getSingle();
    expect(row.read<String?>('snippets_json'), isNull);
  });
}
