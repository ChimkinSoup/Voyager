// Calendar overlays (CALENDAR_OVERLAY_HLD.md): a calendar that also draws
// other calendars' events while it is open.
//
// A display union, not a second store: the page's view provider concatenates
// the host's own events with those of the calendars it overlays, and every
// event keeps the calendar it belongs to. What is pinned here is the rule
// itself and the data around it — flatness, cleanup on delete, the sync
// mapper, the migration and backup import. The page and the manage dialog are
// in calendar_overlay_page_test.dart.

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/settings/services/data_export_service.dart';
import 'package:voyager/features/settings/services/data_import_service.dart';

import 'fakes/fake_weather_api_client.dart';

Calendar _calendar(
  String id, {
  List<String> overlays = const [],
  DateTime? deletedAt,
}) {
  final now = utcNow();
  return Calendar(
    id: id,
    name: id,
    createdAt: now,
    updatedAt: now,
    overlayCalendarIds: overlays,
    deletedAt: deletedAt,
  );
}

CalendarEvent _event(String id, String calendarId) {
  final now = utcNow();
  return CalendarEvent(
    id: id,
    calendarId: calendarId,
    title: id,
    start: DateTime.utc(2026, 5, 4),
    end: DateTime.utc(2026, 5, 4, 23, 59),
    createdAt: now,
    updatedAt: now,
  );
}

List<BackupCollection> _collectionsFor(AppDatabase db) =>
    buildBackupCollections(
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
      settingsRepository: DriftSettingsRepository(db),
    );

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  group('the view', () {
    late AppDatabase db;
    late ProviderContainer container;
    late DriftCalendarRepository repo;

    setUp(() async {
      db = AppDatabase.inMemory();
      addTearDown(db.close);
      repo = DriftCalendarRepository(db);
      for (final id in [legacyCalendarId, 'holidays', 'work', 'shifts']) {
        await repo.upsertCalendar(_calendar(id));
        await repo.upsertEvent(_event('$id-event', id));
      }
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        ],
      );
      addTearDown(container.dispose);
    });

    Future<void> overlay(String host, List<String> ids) async {
      await repo.upsertCalendar(
        (await repo.getCalendar(host))!.copyWith(overlayCalendarIds: ids),
      );
      container.invalidate(calendarsProvider);
    }

    Future<List<String>> shownOn(String? calendarId) async {
      final events = await container.read(
        calendarViewEventsProvider(calendarId).future,
      );
      return events.map((e) => e.id).toList()..sort();
    }

    test('a calendar with no overlays shows only its own events', () async {
      expect(await shownOn(legacyCalendarId), ['$legacyCalendarId-event']);
    });

    test("the host shows the overlay's events, one way only", () async {
      await overlay(legacyCalendarId, ['holidays']);

      expect(await shownOn(legacyCalendarId), [
        '$legacyCalendarId-event',
        'holidays-event',
      ]);
      expect(await shownOn('holidays'), ['holidays-event']);
    });

    test('borrowed events keep their own calendar', () async {
      await overlay(legacyCalendarId, ['holidays']);

      final events = await container.read(
        calendarViewEventsProvider(legacyCalendarId).future,
      );
      expect(
        events.firstWhere((e) => e.id == 'holidays-event').calendarId,
        'holidays',
      );
    });

    test('is flat: an overlay\'s own overlays are not followed', () async {
      await overlay(legacyCalendarId, ['holidays']);
      await overlay('holidays', ['work']);

      expect(await shownOn(legacyCalendarId), [
        '$legacyCalendarId-event',
        'holidays-event',
      ]);
    });

    test('a cycle shows each side plus the other, once', () async {
      await overlay('work', ['shifts']);
      await overlay('shifts', ['work']);

      expect(await shownOn('work'), ['shifts-event', 'work-event']);
      expect(await shownOn('shifts'), ['shifts-event', 'work-event']);
    });

    test('ignores unknown and soft-deleted ids', () async {
      await repo.upsertCalendar(
        (await repo.getCalendar(
          'shifts',
        ))!.copyWith(deletedAt: utcNow()),
      );
      await overlay(legacyCalendarId, ['ghost', 'shifts', 'holidays']);

      expect(await shownOn(legacyCalendarId), [
        '$legacyCalendarId-event',
        'holidays-event',
      ]);
    });

    test('the all-view ignores overlay lists', () async {
      await overlay(legacyCalendarId, ['holidays']);

      expect(await shownOn(null), [
        '$legacyCalendarId-event',
        'holidays-event',
        'shifts-event',
        'work-event',
      ]);
    });

    test('ownership queries are untouched by overlays', () async {
      await overlay(legacyCalendarId, ['holidays']);

      final owned = await container.read(
        calendarEventsProvider(legacyCalendarId).future,
      );
      expect(owned.map((e) => e.id), ['$legacyCalendarId-event']);
    });

    test('an event deleted at its source leaves every host', () async {
      await overlay(legacyCalendarId, ['holidays']);
      await shownOn(legacyCalendarId);

      await repo.softDeleteEvent('holidays-event');
      container.invalidate(calendarEventsProvider);

      expect(await shownOn(legacyCalendarId), ['$legacyCalendarId-event']);
    });

    test('deleting an overlaid calendar drops it from every list, and moved '
        'events are the default calendar\'s own', () async {
      await overlay(legacyCalendarId, ['holidays', 'work']);
      await overlay('shifts', ['holidays']);
      final defaultVersion = (await repo.getCalendar(
        legacyCalendarId,
      ))!.version;

      await repo.reassignEventsCalendar('holidays', legacyCalendarId);
      await repo.softDeleteCalendar('holidays');
      container
        ..invalidate(calendarsProvider)
        ..invalidate(calendarEventsProvider);

      final host = (await repo.getCalendar(legacyCalendarId))!;
      expect(host.overlayCalendarIds, ['work']);
      expect(
        host.version,
        greaterThan(defaultVersion),
        reason: 'versioned, so the cleanup syncs',
      );
      expect((await repo.getCalendar('shifts'))!.overlayCalendarIds, isEmpty);

      final moved = (await container.read(
        calendarViewEventsProvider(legacyCalendarId).future,
      )).firstWhere((e) => e.id == 'holidays-event');
      expect(moved.calendarId, legacyCalendarId);

      // A restore does not bring the link back.
      await repo.upsertCalendar(_calendar('holidays'));
      expect(
        (await repo.getCalendar(legacyCalendarId))!.overlayCalendarIds,
        ['work'],
      );
    });
  });

  test('a write drops the host itself and repeats, keeping order', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftCalendarRepository(db);
    await repo.upsertCalendar(
      _calendar('host', overlays: ['b', 'host', 'a', 'b']),
    );

    expect((await repo.getCalendar('host'))!.overlayCalendarIds, ['b', 'a']);
  });

  group('sync mapper', () {
    test('round-trips the list', () {
      final local = _calendar('host', overlays: ['a', 'b']);
      final payload = calendarToFirestore(local);
      expect(payload['overlayCalendarIds'], ['a', 'b']);

      final merged = mergeCalendarFromRemote(payload, 'host');
      expect(merged.overlayCalendarIds, ['a', 'b']);
    });

    test('a document without the field reads as empty with nothing local', () {
      final payload = calendarToFirestore(_calendar('host'))
        ..remove('overlayCalendarIds');

      expect(mergeCalendarFromRemote(payload, 'host').overlayCalendarIds, []);
    });

    test('a document without the field keeps the local list', () {
      final local = _calendar('host', overlays: ['a']);
      final payload = calendarToFirestore(local)
        ..remove('overlayCalendarIds')
        ..['version'] = local.version + 1;

      final merged = mergeCalendarFromRemote(payload, 'host', local: local);
      expect(merged.overlayCalendarIds, ['a']);
    });

    test('an explicit empty list from a newer version clears it', () {
      final local = _calendar('host', overlays: ['a']);
      final payload = {
        ...calendarToFirestore(local),
        'overlayCalendarIds': <String>[],
        'version': local.version + 1,
      };

      final merged = mergeCalendarFromRemote(payload, 'host', local: local);
      expect(merged.overlayCalendarIds, isEmpty);
    });
  });

  group('migration', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('voyager_calendar_overlay');
      file = File('${dir.path}/voyager.sqlite');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<List<String>> calendarColumns(AppDatabase db) async => [
      for (final row in await db
          .customSelect("SELECT name FROM pragma_table_info('calendars_table')")
          .get())
        row.read<String>('name'),
    ];

    // Rewinds the file to [version]: the overlay column taken out, and at 104
    // the show-in-default flag that version added put back.
    Future<void> rewindTo(int version) async {
      final db = AppDatabase(NativeDatabase(file));
      await DriftCalendarRepository(
        db,
      ).upsertCalendar(_calendar('host', overlays: ['a']));
      await db.customStatement(
        'ALTER TABLE calendars_table DROP COLUMN overlay_calendar_ids',
      );
      if (version == 104) {
        await db.customStatement(
          'ALTER TABLE calendars_table ADD COLUMN show_in_default '
          'INTEGER NOT NULL DEFAULT 0',
        );
      }
      await db.customStatement('PRAGMA user_version = $version');
      await db.close();
    }

    for (final version in [103, 104]) {
      test('a schema-$version calendar reads with no overlays', () async {
        await rewindTo(version);

        final db = AppDatabase(NativeDatabase(file));
        addTearDown(db.close);
        final calendar = await DriftCalendarRepository(db).getCalendar('host');

        expect(calendar!.name, 'host');
        expect(calendar.overlayCalendarIds, isEmpty);
        final columns = await calendarColumns(db);
        expect(columns, contains('overlay_calendar_ids'));
        expect(columns, isNot(contains('show_in_default')));
      });
    }
  });

  test('importing a backup drops overlay ids that point nowhere', () async {
    final source = AppDatabase.inMemory();
    addTearDown(source.close);
    final sourceRepo = DriftCalendarRepository(source);
    await sourceRepo.upsertCalendar(_calendar('holidays'));
    await sourceRepo.upsertCalendar(
      _calendar('old', deletedAt: utcNow()),
    );
    await sourceRepo.upsertCalendar(
      _calendar('host', overlays: ['ghost', 'holidays', 'old']),
    );
    final contents = await DataExportService(
      collections: _collectionsFor(source),
      settingsRepository: DriftSettingsRepository(source),
    ).buildArchiveContents();
    final zip = File(
      '${Directory.systemTemp.path}/voyager_calendar_overlay_import.zip',
    );
    await zip.writeAsBytes(generateBackupZipIsolate(contents));
    addTearDown(zip.delete);

    final target = AppDatabase.inMemory();
    addTearDown(target.close);
    await DataImportService(
      db: target,
      collections: _collectionsFor(target),
      settingsRepository: DriftSettingsRepository(target),
      pushRecords: (_, _) async {},
      pushSettings: (_) async {},
    ).importFromZip(zip);

    final host = await DriftCalendarRepository(target).getCalendar('host');
    expect(host!.overlayCalendarIds, ['holidays']);
  });
}
