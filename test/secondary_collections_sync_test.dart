// The collections that reach Firestore through [SyncedWriteNotifier] rather
// than an explicit push call: calendars, analytics, finance, the notification
// inbox, the bucket list, tag colors, custom words and the settings document.
//
// Two devices share one InMemorySyncRepository (the server) while writing to
// their own databases, which is what makes "device B sees it" a real
// assertion rather than a round trip through a single local table.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/weather_service.dart';

import 'fakes/fake_weather_api_client.dart';

/// One device: its own database and repositories, wired to the shared server.
class _Device {
  _Device(this.syncRepo, String deviceId) {
    db = AppDatabase.inMemory();
    syncedWrites = SyncedWriteNotifier();
    calendars = DriftCalendarRepository(db, syncedWrites: syncedWrites);
    trackers = DriftTrackerRepository(db, syncedWrites: syncedWrites);
    finance = DriftFinanceRepository(db, syncedWrites: syncedWrites);
    notifications = DriftNotificationRepository(db, syncedWrites: syncedWrites);
    bucketList = DriftBucketListRepository(db, syncedWrites: syncedWrites);
    settings = DriftSettingsRepository(db, syncedWrites: syncedWrites);

    sync = RemoteSyncService(
      syncRepository: syncRepo,
      journalRepository: DriftJournalRepository(db),
      dreamRepository: DriftDreamRepository(db),
      todoRepository: DriftTodoRepository(db),
      leetCodeRepository: DriftLeetCodeRepository(db),
      studyRepository: DriftStudyRepository(db),
      workoutRepository: DriftWorkoutRepository(db),
      calendarRepository: calendars,
      trackerRepository: trackers,
      financeRepository: finance,
      notificationRepository: notifications,
      bucketListRepository: bucketList,
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
        _uploads.add(sync.pushRecords(collection, records));
  }

  final InMemorySyncRepository syncRepo;
  late final AppDatabase db;
  late final SyncedWriteNotifier syncedWrites;
  late final DriftCalendarRepository calendars;
  late final DriftTrackerRepository trackers;
  late final DriftFinanceRepository finance;
  late final DriftNotificationRepository notifications;
  late final DriftBucketListRepository bucketList;
  late final DriftSettingsRepository settings;
  late final RemoteSyncService sync;

  final _uploads = <Future<void>>[];

  /// Waits for the uploads the writes so far kicked off. They are started but
  /// not awaited by the repositories, exactly as in the app.
  Future<void> settle() async {
    while (_uploads.isNotEmpty) {
      final pending = List.of(_uploads);
      _uploads.clear();
      await Future.wait(pending);
    }
  }

  Future<void> close() => db.close();
}

void main() {
  late InMemorySyncRepository server;
  late _Device deviceA;
  late _Device deviceB;

  setUp(() {
    server = InMemorySyncRepository();
    deviceA = _Device(server, 'device-a');
    deviceB = _Device(server, 'device-b');
  });

  tearDown(() async {
    await deviceA.close();
    await deviceB.close();
  });

  final now = DateTime.utc(2026, 8, 14, 12);

  Calendar calendar({String id = 'cal-1', String name = 'Work'}) => Calendar(
    id: id,
    name: name,
    createdAt: now,
    updatedAt: now,
  );

  group('records travel between devices', () {
    test('a calendar event written on A arrives on B', () async {
      await deviceA.calendars.upsertCalendar(calendar());
      await deviceA.calendars.upsertEvent(
        CalendarEvent(
          id: 'event-1',
          calendarId: 'cal-1',
          title: 'Standup',
          start: now,
          end: now.add(const Duration(hours: 1)),
          createdAt: now,
          updatedAt: now,
        ),
      );
      await deviceA.settle();

      await deviceB.sync.pullCalendars();
      await deviceB.sync.pullCalendarEvents();

      final events = await deviceB.calendars.listEvents();
      expect(events.single.title, 'Standup');
      expect((await deviceB.calendars.listCalendars()).single.name, 'Work');
    });

    test('a tracker value written on A arrives on B', () async {
      await deviceA.trackers.upsertTracker(
        StatisticTracker(
          id: 'tracker-1',
          name: 'Pushups',
          type: TrackerType.integer,
          cadence: TrackerCadence.daily,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await deviceA.trackers.upsertValue(
        TrackerValue(
          id: 'value-1',
          trackerId: 'tracker-1',
          periodStart: now,
          intValue: 40,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await deviceA.settle();

      await deviceB.sync.pullTrackers();
      await deviceB.sync.pullTrackerValues();

      expect((await deviceB.trackers.listTrackers()).single.name, 'Pushups');
      expect((await deviceB.trackers.listValues('tracker-1')).single.intValue, 40);
    });

    test('a transaction written on A arrives on B', () async {
      await deviceA.finance.upsertTransaction(
        FinancialTransaction(
          id: 'tx-1',
          type: TransactionType.expense,
          amountCents: 1250,
          occurredAt: now,
          note: 'Coffee',
          tags: const ['food'],
          createdAt: now,
          updatedAt: now,
        ),
      );
      await deviceA.settle();

      await deviceB.sync.pullTransactions();

      final transaction = (await deviceB.finance.listTransactions()).single;
      expect(transaction.amountCents, 1250);
      expect(transaction.note, 'Coffee');
      expect(transaction.tags, ['food']);
    });

    test('a bucket list item written on A arrives on B', () async {
      await deviceA.bucketList.upsertItem(
        BucketListItem(
          id: 'bucket-1',
          title: 'See the aurora',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await deviceA.settle();

      await deviceB.sync.pullBucketListItems();

      expect((await deviceB.bucketList.listItems()).single.title,
          'See the aurora');
    });

    test('a tag color set on A arrives on B', () async {
      await deviceA.settings.setTagColor('travel', 0xFF00FF00);
      await deviceA.settle();

      await deviceB.sync.pullTagColors();

      expect(await deviceB.settings.getTagColors(), {'travel': 0xFF00FF00});
    });
  });

  group('removals travel as tombstones', () {
    test('unpinning a note on A removes it on B', () async {
      await deviceA.notifications.upsertPinnedNote(
        PinnedNote(
          id: 'note-1',
          text: 'Call the dentist',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await deviceA.settle();
      await deviceB.sync.pullPinnedNotes();
      expect(await deviceB.notifications.listPinnedNotes(), hasLength(1));

      await deviceA.notifications.deletePinnedNote('note-1');
      await deviceA.settle();
      await deviceB.sync.pullPinnedNotes();

      expect(await deviceB.notifications.listPinnedNotes(), isEmpty);
    });

    test('un-dismissing a notification on A un-dismisses it on B', () async {
      await deviceA.notifications.dismiss('task-7|important');
      await deviceA.settle();
      await deviceB.sync.pullDismissedNotifications();
      expect(await deviceB.notifications.listDismissals(),
          {'task-7|important'});

      await deviceA.notifications.undismiss('task-7|important');
      await deviceA.settle();
      await deviceB.sync.pullDismissedNotifications();

      expect(await deviceB.notifications.listDismissals(), isEmpty);
    });

    test('removing a custom word on A removes it on B', () async {
      await deviceA.settings.addCustomWord('voyager');
      await deviceA.settle();
      await deviceB.sync.pullCustomWords();
      expect(await deviceB.settings.getCustomWords(), {'voyager'});

      await deviceA.settings.removeCustomWord('voyager');
      await deviceA.settle();
      await deviceB.sync.pullCustomWords();

      expect(await deviceB.settings.getCustomWords(), isEmpty);
    });

    test('re-adding a removed word clears the tombstone everywhere', () async {
      await deviceA.settings.addCustomWord('voyager');
      await deviceA.settings.removeCustomWord('voyager');
      await deviceA.settings.addCustomWord('voyager');
      await deviceA.settle();

      await deviceB.sync.pullCustomWords();

      expect(await deviceB.settings.getCustomWords(), {'voyager'});
    });

    test('a soft-deleted transaction stops showing on B', () async {
      await deviceA.finance.upsertTransaction(
        FinancialTransaction(
          id: 'tx-1',
          type: TransactionType.expense,
          amountCents: 500,
          occurredAt: now,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await deviceA.settle();
      await deviceB.sync.pullTransactions();
      expect(await deviceB.finance.listTransactions(), hasLength(1));

      await deviceA.finance.softDeleteTransaction('tx-1');
      await deviceA.settle();
      await deviceB.sync.pullTransactions();

      expect(await deviceB.finance.listTransactions(), isEmpty);
    });
  });

  group('pulls do not echo back as uploads', () {
    test('applying a pulled record raises no upload on the receiver', () async {
      await deviceA.calendars.upsertCalendar(calendar());
      await deviceA.settle();

      var uploadsOnB = 0;
      deviceB.syncedWrites.onWrite = (collection, records) => uploadsOnB++;
      await deviceB.sync.pullCalendars();

      expect(uploadsOnB, 0);
      expect((await deviceB.calendars.listCalendars()).single.name, 'Work');
    });
  });

  group('settings', () {
    test('a preference set on A applies on B', () async {
      final local = await deviceA.settings.getSettings();
      await deviceA.settings.saveSettings(
        local.copyWith(accentColor: 0xFF123456, weekStartsOnMonday: false),
      );
      await deviceA.settle();

      await deviceB.sync.pullSettings();

      final applied = await deviceB.settings.getSettings();
      expect(applied.accentColor, 0xFF123456);
      expect(applied.weekStartsOnMonday, isFalse);
    });

    test('an older remote document does not overwrite a newer local one',
        () async {
      final localA = await deviceA.settings.getSettings();
      await deviceA.settings.saveSettings(
        localA.copyWith(accentColor: 0xFF111111),
      );
      await deviceA.settle();

      // B changes it afterwards, so B's row is the newer of the two.
      final localB = await deviceB.settings.getSettings();
      await deviceB.settings.saveSettings(
        localB.copyWith(
          accentColor: 0xFF222222,
          updatedAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        ),
      );

      await deviceB.sync.pullSettings();

      expect((await deviceB.settings.getSettings()).accentColor, 0xFF222222);
    });

    test('device-local settings never leave the device', () async {
      final local = await deviceA.settings.getSettings();
      await deviceA.settings.saveSettings(
        local.copyWith(
          deviceId: 'device-a',
          devShowFpsCounter: true,
          journalEntryListWidth: 320,
          weatherLocationLabel: 'Reykjavik',
          accentColor: 0xFF654321,
        ),
      );
      await deviceA.settle();

      await deviceB.sync.pullSettings();

      final applied = await deviceB.settings.getSettings();
      expect(applied.accentColor, 0xFF654321, reason: 'preferences do sync');
      expect(applied.deviceId, isNot('device-a'));
      expect(applied.devShowFpsCounter, isFalse);
      expect(applied.journalEntryListWidth, isNull);
      expect(applied.weatherLocationLabel, isNull);
    });

    test('pulling straight back what we just pushed changes nothing', () async {
      final local = await deviceA.settings.getSettings();
      await deviceA.settings.saveSettings(local.copyWith(accentColor: 0xFF010203));
      await deviceA.settle();

      // Firestore echoes our own writes back through the snapshot listener.
      // Re-applying one would rewrite the settings row and invalidate every
      // provider in the app on every save.
      expect(await deviceA.sync.pullSettings(), isFalse);
    });

    test('a settings document with no clock is left alone', () async {
      // What the weather service has been writing to `settings/app` all along,
      // before any of these fields synced.
      await server.upsertRemoteSettings({
        'weatherLat': 64.1,
        'weatherLon': -21.9,
        'weatherLocationLabel': 'Reykjavik',
      });
      final before = await deviceB.settings.getSettings();

      expect(await deviceB.sync.pullSettings(), isFalse);
      expect((await deviceB.settings.getSettings()).accentColor,
          before.accentColor);
    });

    test('a fresh install does not overwrite the account settings', () async {
      final localA = await deviceA.settings.getSettings();
      await deviceA.settings.saveSettings(
        localA.copyWith(accentColor: 0xFFABCDEF),
      );
      await deviceA.settle();

      // Device B has never had its settings row written. Reading it creates
      // one full of defaults — which must not count as the newest settings in
      // the account, or opening the app on a new device would wipe the real
      // ones before the first pull ever ran.
      final defaults = await deviceB.settings.getSettings();
      expect(defaults.updatedAt, isNull);
      await deviceB.settle();
      await deviceB.sync.pullSettings();

      expect((await deviceB.settings.getSettings()).accentColor, 0xFFABCDEF);
      expect(
        (await deviceA.sync.pullSettings()),
        isFalse,
        reason: "device B's defaults never reached the server",
      );
      expect((await deviceA.settings.getSettings()).accentColor, 0xFFABCDEF);
    });

    test('a device-local-only change raises no upload', () async {
      final local = await deviceA.settings.getSettings();
      await deviceA.settings.saveSettings(local.copyWith(accentColor: 0xFF999999));
      await deviceA.settle();

      var uploads = 0;
      deviceA.syncedWrites.onWrite = (collection, records) => uploads++;
      final saved = await deviceA.settings.getSettings();
      await deviceA.settings.saveSettings(
        saved.copyWith(devShowFpsCounter: true, lastSeenNavPage: null),
      );

      expect(uploads, 0);
    });
  });

  group('backfill', () {
    test('uploads rows that predate this device syncing them', () async {
      // Written with the sync layer detached, standing in for rows created
      // before these collections synced at all.
      deviceA.syncedWrites.onWrite = null;
      await deviceA.calendars.upsertCalendar(calendar(name: 'Personal'));
      await deviceA.bucketList.upsertItem(
        BucketListItem(
          id: 'bucket-1',
          title: 'Learn to sail',
          createdAt: now,
          updatedAt: now,
        ),
      );

      await deviceA.sync.backfillSyncedCollections();
      await deviceB.sync.pullCalendars();
      await deviceB.sync.pullBucketListItems();

      expect((await deviceB.calendars.listCalendars()).single.name, 'Personal');
      expect((await deviceB.bucketList.listItems()).single.title,
          'Learn to sail');
    });

    test('runs once, then stops', () async {
      await deviceA.sync.backfillSyncedCollections();
      await deviceA.settle();

      final settings = await deviceA.settings.getSettings();
      expect(settings.syncBackfillVersion, RemoteSyncService.syncBackfillVersion);

      // A second run must be a no-op, or every launch would re-upload
      // everything.
      var uploads = 0;
      deviceA.syncedWrites.onWrite = (collection, records) => uploads++;
      await deviceA.sync.backfillSyncedCollections();
      expect(uploads, 0);
    });
  });

  group('conflict resolution', () {
    test('an older remote version loses to the local record', () {
      final local = FinancialTransaction(
        id: 'tx-1',
        type: TransactionType.expense,
        amountCents: 900,
        occurredAt: now,
        createdAt: now,
        updatedAt: now.add(const Duration(minutes: 5)),
        version: 4,
      );
      final stale = transactionToFirestore(
        local.copyWith(amountCents: 100, version: 3, updatedAt: now),
      );

      expect(
        mergeTransactionFromRemote(stale, 'tx-1', local: local).amountCents,
        900,
      );
    });

    test('clearing a tracker value on another device clears it here', () {
      final local = TrackerValue(
        id: 'value-1',
        trackerId: 'tracker-1',
        periodStart: now,
        intValue: 12,
        createdAt: now,
        updatedAt: now,
        version: 1,
      );
      // A value is exactly one of int/bool/enum, so an emptied one has to
      // land as empty rather than falling back to what we already had.
      final cleared = trackerValueToFirestore(
        TrackerValue(
          id: 'value-1',
          trackerId: 'tracker-1',
          periodStart: now,
          createdAt: now,
          updatedAt: now.add(const Duration(minutes: 1)),
          version: 2,
        ),
      );

      final merged = mergeTrackerValueFromRemote(cleared, 'value-1',
          local: local);
      expect(merged.intValue, isNull);
    });

    test('a local tombstone survives a remote payload that omits it', () {
      final local = PinnedNote(
        id: 'note-1',
        text: 'Call the dentist',
        createdAt: now,
        updatedAt: now,
        version: 2,
        deletedAt: now,
      );
      final remote = {
        'id': 'note-1',
        'text': 'Call the dentist',
        'createdAt': now.toIso8601String(),
        'updatedAt': now.add(const Duration(minutes: 1)).toIso8601String(),
        'version': 3,
      };

      expect(
        mergePinnedNoteFromRemote(remote, 'note-1', local: local).deletedAt,
        isNotNull,
      );
    });
  });

  group('document ids', () {
    test('keys containing characters Firestore rejects survive a round trip',
        () async {
      // A dismissal key is '$itemId|$urgencyTierName', and an id can be a
      // path-like string; a tag is whatever the user typed.
      for (final key in ['a/b|important', 'plain', '.', '..', 'ünïcode']) {
        expect(decodeDocumentId(encodeDocumentId(key)), key);
        expect(encodeDocumentId(key), isNot(contains('/')));
      }
    });

    test('a tag containing a slash still syncs', () async {
      await deviceA.settings.setTagColor('work/urgent', 0xFF0000FF);
      await deviceA.settle();

      await deviceB.sync.pullTagColors();

      expect(await deviceB.settings.getTagColors(), {'work/urgent': 0xFF0000FF});
    });
  });

  group('write volume', () {
    test('a snapshot-only save writes no operation-log entry', () async {
      await deviceA.calendars.upsertCalendar(calendar());
      await deviceA.settle();

      // The operation log exists for character-level text merging; these
      // records have no text to merge, and an entry per save would double
      // every write.
      expect(await server.listOperations('cal-1'), isEmpty);
      expect(
        await server.getDocument(FirestoreCollections.calendars, 'cal-1'),
        isNotNull,
      );
    });
  });
}
