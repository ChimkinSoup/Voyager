// Schema 76 gives the collections that used to be local-only the shape the
// sync layer needs: a version/updatedAt pair to order two devices' edits, and
// a deletedAt so a removal can travel. Existing databases carry rows written
// before any of those columns existed, and the upgrade has to leave them
// intact and usable rather than merely not crashing.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/domain/models/notification_models.dart';

/// Every column schema 76 adds, by table.
const _addedColumns = {
  'calendar_events_table': ['version'],
  'trackers_table': ['version'],
  'tracker_values_table': ['version'],
  'pinned_notes_table': ['updated_at', 'version', 'deleted_at'],
  'dismissed_notifications_table': ['updated_at', 'version', 'deleted_at'],
  'bucket_list_items_table': ['version', 'deleted_at'],
  'tag_colors_table': ['updated_at', 'version'],
  'custom_words_table': [
    'created_at',
    'updated_at',
    'version',
    'deleted_at',
  ],
  'settings_table': ['updated_at', 'sync_backfill_version'],
};

/// Rewinds a schema-76 database to look like a schema-75 one: drops the new
/// columns and resets user_version, so reopening it runs the real onUpgrade
/// path rather than a hand-written approximation of it.
Future<void> _rewindToSchema75(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  for (final entry in _addedColumns.entries) {
    for (final column in entry.value) {
      await db.customStatement(
        'ALTER TABLE ${entry.key} DROP COLUMN $column',
      );
    }
  }
  await db.customStatement('PRAGMA user_version = 75');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_sync_migration_test');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  final now = DateTime.utc(2026, 8, 14, 9);

  test('75→76 keeps the rows that predate the sync columns', () async {
    final seed = AppDatabase(NativeDatabase(file));
    final calendars = DriftCalendarRepository(seed);
    await calendars.upsertCalendar(
      Calendar(id: 'cal-1', name: 'Work', createdAt: now, updatedAt: now),
    );
    await calendars.upsertEvent(
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
    final trackers = DriftTrackerRepository(seed);
    await trackers.upsertTracker(
      StatisticTracker(
        id: 'tracker-1',
        name: 'Pushups',
        type: TrackerType.integer,
        cadence: TrackerCadence.daily,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await trackers.upsertValue(
      TrackerValue(
        id: 'value-1',
        trackerId: 'tracker-1',
        periodStart: now,
        intValue: 40,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await DriftNotificationRepository(seed).upsertPinnedNote(
      PinnedNote(
        id: 'note-1',
        text: 'Call the dentist',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await DriftNotificationRepository(seed).dismiss('task-7|important');
    await DriftBucketListRepository(seed).upsertItem(
      BucketListItem(
        id: 'bucket-1',
        title: 'See the aurora',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final settings = DriftSettingsRepository(seed);
    await settings.setTagColor('travel', 0xFF00FF00);
    await settings.addCustomWord('voyager');
    await settings.saveSettings(
      (await settings.getSettings()).copyWith(accentColor: 0xFFABCDEF),
    );
    await seed.close();

    await _rewindToSchema75(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);

    final upgradedCalendars = DriftCalendarRepository(upgraded);
    expect((await upgradedCalendars.listCalendars()).single.name, 'Work');
    expect((await upgradedCalendars.listEvents()).single.title, 'Standup');

    final upgradedTrackers = DriftTrackerRepository(upgraded);
    expect((await upgradedTrackers.listTrackers()).single.name, 'Pushups');
    expect(
      (await upgradedTrackers.listValues('tracker-1')).single.intValue,
      40,
    );

    final notifications = DriftNotificationRepository(upgraded);
    expect((await notifications.listPinnedNotes()).single.text,
        'Call the dentist');
    expect(await notifications.listDismissals(), {'task-7|important'});

    expect((await DriftBucketListRepository(upgraded).listItems()).single.title,
        'See the aurora');

    final upgradedSettings = DriftSettingsRepository(upgraded);
    expect(await upgradedSettings.getTagColors(), {'travel': 0xFF00FF00});
    expect(await upgradedSettings.getCustomWords(), {'voyager'});
    expect((await upgradedSettings.getSettings()).accentColor, 0xFFABCDEF);
  });

  test('75→76 leaves migrated rows un-tombstoned and un-versioned', () async {
    final seed = AppDatabase(NativeDatabase(file));
    await DriftNotificationRepository(seed).upsertPinnedNote(
      PinnedNote(
        id: 'note-1',
        text: 'Call the dentist',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await seed.close();
    await _rewindToSchema75(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);

    final note = (await DriftNotificationRepository(upgraded)
            .listPinnedNotes(includeDeleted: true))
        .single;
    expect(note.deletedAt, isNull, reason: 'an existing note is not deleted');
    expect(note.version, 0);

    // The settings clock stays null until a synced setting actually changes,
    // so upgrading doesn't make this device's settings the newest in the
    // account and overwrite the ones on every other device.
    expect(
      (await DriftSettingsRepository(upgraded).getSettings()).updatedAt,
      isNull,
    );
  });
}
