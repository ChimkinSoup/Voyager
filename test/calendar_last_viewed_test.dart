// The calendar page reopens where it was left — including "all calendars".
//
// Two facts, kept apart: which calendar was open, and whether the all-view was
// on. Folding the second into the first (a sentinel id) would lose the
// calendar a new event is filed under while the all-view is showing, which is
// the mistake the journal page's `ALL_JOURNALS` sentinel made and the v65
// migration had to undo.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test('the pair survives a round trip through the database', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftSettingsRepository(db);

    // Fresh databases open on the default calendar with the all-view off.
    final fresh = await repo.getSettings();
    expect(fresh.lastViewedCalendarId, isNull);
    expect(fresh.calendarShowAllCalendars, isFalse);

    await repo.saveSettings(
      fresh.copyWith(
        lastViewedCalendarId: 'work',
        calendarShowAllCalendars: true,
      ),
    );

    final reopened = await repo.getSettings();
    // Both, not one or the other: the all-view still has to remember which
    // calendar a new event belongs to.
    expect(reopened.lastViewedCalendarId, 'work');
    expect(reopened.calendarShowAllCalendars, isTrue);
  });

  // Stored, but not synced: where this device is looking is not a preference.
  // While it synced, switching calendars moved the settings clock and a stale
  // device re-uploaded every other setting over newer edits made elsewhere.
  test('the pair stays on this device', () {
    final remote = AppSettings(
      lastViewedCalendarId: 'work',
      calendarShowAllCalendars: true,
      updatedAt: DateTime.utc(2026, 8, 29, 12),
    );
    final local = AppSettings(
      lastViewedCalendarId: 'home',
      updatedAt: DateTime.utc(2026, 8, 29, 11),
    );

    final merged = mergeSettingsFromRemote(settingsToFirestore(remote), local);
    expect(merged.lastViewedCalendarId, 'home');
    expect(merged.calendarShowAllCalendars, isFalse);
  });
}
