// BUG-079: changing a calendar's colour left its events in the old colour,
// because every event stores the colour it was created with. The change now
// moves the events still on the old calendar colour along with it, in the same
// transaction as the calendar row.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';

const _pink = 4294228196;
const _green = 0xFF8BC34A;
const _blue = 0xFF7C9EFF;

Calendar _calendar(String id, int color) {
  final now = utcNow();
  return Calendar(
    id: id,
    name: id,
    colorValue: color,
    createdAt: now,
    updatedAt: now,
  );
}

CalendarEvent _event(String id, String calendarId, int color) {
  final now = utcNow();
  return CalendarEvent(
    id: id,
    calendarId: calendarId,
    title: id,
    start: DateTime.utc(2026, 10, 1),
    end: DateTime.utc(2026, 10, 1, 23, 59),
    colorValue: color,
    createdAt: now,
    updatedAt: now,
  );
}

/// Fails the second event write once, as a full disk or a crash would.
class _FailingSecondWriteRepository extends DriftCalendarRepository {
  _FailingSecondWriteRepository(super.db, {super.syncedWrites});

  var _writes = 0;
  var failing = true;

  @override
  Future<void> upsertEvent(
    CalendarEvent event, {
    bool recordLocalActivity = true,
  }) {
    if (failing && ++_writes == 2) throw StateError('disk full');
    return super.upsertEvent(event, recordLocalActivity: recordLocalActivity);
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  Future<Map<String, int>> colors(DriftCalendarRepository repo) async => {
    for (final e in await repo.listEvents(includeDeleted: true))
      e.id: e.colorValue,
  };

  test(
    'events still on the old colour follow it; others keep theirs',
    () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final uploads = <String, List<String>>{};
      final repo = DriftCalendarRepository(
        db,
        syncedWrites: SyncedWriteNotifier()
          ..onWrite = (collection, records) => (uploads[collection] ??= [])
              .addAll(records.map((r) => (r as dynamic).id as String)),
      );
      await repo.upsertCalendar(_calendar('holidays', _pink));
      await repo.upsertEvent(_event('hol-1', 'holidays', _pink));
      await repo.upsertEvent(_event('hol-2', 'holidays', _pink));
      await repo.upsertEvent(_event('hol-own', 'holidays', _blue));
      await repo.upsertEvent(_event('other', 'work', _pink));
      await repo.upsertEvent(_event('hol-trashed', 'holidays', _pink));
      await repo.softDeleteEvent('hol-trashed');

      uploads.clear();
      await repo.recolorCalendar(_calendar('holidays', _green), _pink);

      // The calendar and every recoloured event are queued for upload.
      expect(uploads, {
        FirestoreCollections.calendars: ['holidays'],
        FirestoreCollections.calendarEvents: unorderedEquals([
          'hol-1',
          'hol-2',
          'hol-trashed',
        ]),
      });
      expect((await repo.getCalendar('holidays'))!.colorValue, _green);
      expect(await colors(repo), {
        'hol-1': _green,
        'hol-2': _green,
        'hol-own': _blue,
        'other': _pink,
        // So a restore from the trash comes back in the calendar's colour.
        'hol-trashed': _green,
      });
    },
  );

  test('a failure part way changes nothing, and a retry finishes', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final uploads = <String>[];
    final repo = _FailingSecondWriteRepository(
      db,
      syncedWrites: SyncedWriteNotifier()
        ..onWrite = (collection, _) => uploads.add(collection),
    )..failing = false;
    await repo.upsertCalendar(_calendar('holidays', _pink));
    await repo.upsertEvent(_event('hol-1', 'holidays', _pink));
    await repo.upsertEvent(_event('hol-2', 'holidays', _pink));
    repo.failing = true;
    uploads.clear();

    await expectLater(
      repo.recolorCalendar(_calendar('holidays', _green), _pink),
      throwsStateError,
    );
    // Nothing rolled back is uploaded.
    expect(uploads, isEmpty);
    // The calendar keeps the old colour, so choosing green again still
    // matches the events that have yet to move.
    expect((await repo.getCalendar('holidays'))!.colorValue, _pink);
    expect(await colors(repo), {'hol-1': _pink, 'hol-2': _pink});

    await repo.recolorCalendar(_calendar('holidays', _green), _pink);
    expect((await repo.getCalendar('holidays'))!.colorValue, _green);
    expect(await colors(repo), {'hol-1': _green, 'hol-2': _green});
  });
}
