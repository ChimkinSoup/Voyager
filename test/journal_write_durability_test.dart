// Regression coverage for the journal's data-loss paths.
//
// Every case here is a way text or a delete could reach the screen — or the
// user's fingers — without reaching SQLite in a form that survives a restart
// or a sync round-trip. They assert against the database rather than the
// widget tree wherever they can, because the editor keeps its own copy of the
// text and the loss is invisible until the process dies.

import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/repositories/weather_api_client.dart';

import 'support/journal_page_harness.dart';

/// A weather client whose refresh never completes until the test says so.
///
/// [WeatherService.refreshIfNeeded] is the long pole in the new-entry path —
/// it can claim a distributed lock and hit the weather HTTP API — so holding it
/// open is what a cold start on a bad network looks like from the page's side.
class _BlockingWeatherApiClient implements WeatherApiClient {
  final refreshGate = Completer<void>();
  var refreshCalls = 0;

  @override
  Future<({double lat, double lon, String label})> geocode(String query) async {
    return (lat: 41.88, lon: -87.63, label: 'Chicago, US');
  }

  @override
  Future<WeatherSnapshot> refreshWeather({
    required double lat,
    required double lon,
    required String deviceId,
    String? locationLabel,
  }) async {
    refreshCalls++;
    await refreshGate.future;
    return WeatherSnapshot(
      icon: 'rain',
      conditionCode: 501,
      tempC: 12,
      fetchedAt: DateTime.now().toUtc(),
      lat: lat,
      lon: lon,
      locationLabel: locationLabel,
      updatedByDeviceId: deviceId,
    );
  }

  @override
  Future<WeatherForecast> refreshForecast({
    required double lat,
    required double lon,
    String? locationLabel,
    required int timeZoneOffsetMinutes,
    bool resetArchive = false,
  }) async {
    await refreshGate.future;
    return WeatherForecast(fetchedAt: DateTime.now().toUtc(), periods: const []);
  }
}

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<List<JournalEntry>> entriesIn(AppDatabase db) {
  return DriftJournalRepository(db).listEntries(journalId: journalHarnessId);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a new entry is on disk before its async fields resolve', (
    tester,
  ) async {
    // The row used to be written only at the end of _finalizeNewEntry, after
    // the quote bank loaded and the weather refresh returned. Everything typed
    // before that landed lived in two in-memory maps and died with the process.
    final weather = _BlockingWeatherApiClient();
    final db = await pumpJournalPage(
      tester,
      weatherApiClient: weather,
      configureSettings: (settings) => settings.copyWith(
        weatherLocationLabel: 'Chicago, US',
        weatherLat: 41.88,
        weatherLon: -87.63,
      ),
    );

    await tester.tap(find.text('New entry'));
    await settle(tester);

    expect(
      weather.refreshCalls,
      1,
      reason: 'the weather refresh should be in flight, not finished',
    );
    expect(weather.refreshGate.isCompleted, isFalse);

    final stored = await entriesIn(db);
    expect(
      stored.length,
      2,
      reason: 'the new row must exist in SQLite while the refresh is blocked',
    );

    weather.refreshGate.complete();
    await settle(tester);
    await disposeJournalPage(tester);
  });

  testWidgets('a title edit does not discard the body typed just before it', (
    tester,
  ) async {
    // Both debouncers land in the same window, body first. The metadata save
    // is assigned the later generation, so the body save's turn on the
    // per-document queue is dropped — which was only safe while both writers
    // persisted the same snapshot. The metadata writer carried a pre-edit
    // `baseline.body`, so it wrote the paragraph back out of existence.
    final db = await pumpJournalPage(tester);

    await tester.enterText(
      find.byType(TagHighlightedTextField),
      'a paragraph the user just typed',
    );
    await tester.pump(const Duration(milliseconds: 120));
    await tester.enterText(find.byType(LabeledTextField), 'T');
    await settle(tester, frames: 20);

    final stored = (await entriesIn(db)).single;
    expect(stored.title, 'T');
    expect(stored.body, 'a paragraph the user just typed');

    await disposeJournalPage(tester);
  });

  testWidgets('a body that round-trips back to its saved text leaves no draft '
      'to resurrect', (tester) async {
    // Typing and undoing takes the autosave down its "no changes against the
    // DB baseline" branch, which used to return without dropping
    // `_entryBodyDrafts[id]`. The draft agreed with disk at that point, so
    // nothing looked wrong — until a remote edit moved the row underneath it,
    // after which reselecting the entry laid the stale copy back over the
    // pulled body and pushed it as the local truth.
    final db = await pumpJournalPage(
      tester,
      seedEntries: (now) => [
        for (final id in const ['entry-a', 'entry-b'])
          JournalEntry(
            id: id,
            journalId: journalHarnessId,
            title: id == 'entry-a' ? 'Edited' : 'Other',
            body: id == 'entry-a' ? 'abc' : '',
            entryDate: id == 'entry-a'
                ? now
                : now.subtract(const Duration(days: 1)),
            // Seeded so the entry already carries the weather default. An
            // entry with a null icon takes the autosave *off* the skip path
            // entirely, because `_weatherIcon` is what would be written — which
            // is its own finding, and would mask this one.
            weatherIcon: 'sunny',
            timestamp: now,
            createdAt: now,
            updatedAt: now,
          ),
      ],
    );
    final repo = DriftJournalRepository(db);

    final body = find.byType(TagHighlightedTextField);
    await tester.enterText(body, 'abcd');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(body, 'abc');
    await settle(tester, frames: 20);

    // Switching away flushes, and the flush finds nothing to write — which is
    // the whole point: the entry leaves the editor with the draft still in the
    // map and no save to clear it.
    await tester.tap(find.text('Other'));
    await settle(tester, frames: 12);
    expect((await repo.getEntry('entry-a'))!.body, 'abc');

    // Now a remote edit lands on the row.
    final pulled = (await repo.getEntry('entry-a'))!;
    await repo.upsertEntry(pulled.copyWith(body: 'abc def'));

    // Reopening reads the row fresh from disk — but _entryWithDraftBody
    // prefers a draft unconditionally, so a leftover one is laid straight back
    // over the pulled text.
    await tester.tap(find.text('Edited'));
    await settle(tester, frames: 20);

    expect(
      tester.widget<TagHighlightedTextField>(body).controller.text,
      'abc def',
      reason: 'the editor must show the pulled body, not the stale draft',
    );

    await disposeJournalPage(tester);

    expect(
      (await repo.getEntry('entry-a'))!.body,
      'abc def',
      reason: 'and the next flush must not write the stale draft back',
    );
  });

  group('soft deletes', () {
    late AppDatabase db;
    late DriftJournalRepository repo;

    setUp(() async {
      db = AppDatabase.inMemory();
      repo = DriftJournalRepository(db);
      final now = DateTime.now().toUtc();
      await repo.upsertJournal(
        Journal(id: 'j', name: 'J', createdAt: now, updatedAt: now),
      );
      await repo.upsertEntry(
        JournalEntry(
          id: 'e',
          journalId: 'j',
          title: 'T',
          body: 'B',
          entryDate: now,
          createdAt: now,
          updatedAt: now,
          version: 4,
        ),
      );
    });

    tearDown(() => db.close());

    // A tombstone that does not outrank the live document it replaces is
    // dropped by `remoteVersionWins` on the next device to pull, which then
    // pushes its own higher-versioned live row back and resurrects the entry
    // everywhere. Every path that writes `deletedAt` has to move the version
    // with it.
    test('softDeleteEntry bumps the version with the tombstone', () async {
      await repo.softDeleteEntry('e');

      final row = await repo.getEntry('e');
      expect(row!.deletedAt, isNotNull);
      expect(row.version, greaterThan(4));
    });

    test('softDeleteEntriesInJournal bumps every version', () async {
      await repo.softDeleteEntriesInJournal('j');

      final row = await repo.getEntry('e');
      expect(row!.deletedAt, isNotNull);
      expect(row.version, greaterThan(4));
    });

    test('reassignEntriesJournal bumps the version too', () async {
      await repo.upsertJournal(
        Journal(
          id: 'j2',
          name: 'J2',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      await repo.reassignEntriesJournal('j', 'j2');

      final row = await repo.getEntry('e');
      expect(row!.journalId, 'j2');
      expect(row.version, greaterThan(4));
    });
  });
}
