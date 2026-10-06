// The quote a new entry is assigned has to be on screen the moment the page
// switches to it, not only once the entry has been reopened.

import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/features/journal/journal_page.dart';

import 'fakes/fake_weather_api_client.dart';
import 'support/journal_page_harness.dart';

/// Never answers on its own, standing in for the cold-start weather fetch that
/// takes seconds to tens of seconds.
class _HangingWeatherApiClient extends FakeWeatherApiClient {
  final _held = Completer<WeatherSnapshot>();

  void release() {
    if (_held.isCompleted) return;
    _held.complete(
      WeatherSnapshot(
        icon: 'rain',
        conditionCode: 501,
        tempC: 12,
        fetchedAt: DateTime.now().toUtc(),
        lat: 41.88,
        lon: -87.63,
      ),
    );
  }

  @override
  Future<WeatherSnapshot> refreshWeather({
    required double lat,
    required double lon,
    required String deviceId,
    String? locationLabel,
  }) {
    return _held.future;
  }
}

/// Records every entry write in order, so a test can look at the first one.
class _RecordingJournalRepository extends DriftJournalRepository {
  _RecordingJournalRepository(super.db);

  final writes = <JournalEntry>[];

  @override
  Future<void> upsertEntry(
    JournalEntry entry, {
    bool recordLocalActivity = true,
  }) {
    writes.add(entry);
    return super.upsertEntry(entry, recordLocalActivity: recordLocalActivity);
  }
}

Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a new entry shows its quote without being reopened', (
    tester,
  ) async {
    await pumpJournalPage(
      tester,
      extraOverrides: (_) => [
        bundledQuotesProvider.overrideWith(
          (ref) async => const [Quote(id: 'q1', text: 'Harness quote')],
        ),
      ],
    );

    expect(find.text('Harness quote'), findsNothing);

    await tester.tap(find.text('New entry'));
    await settle(tester, frames: 20);

    expect(find.text('Harness quote'), findsOneWidget);

    await disposeJournalPage(tester);
  });

  testWidgets('the quote does not wait on the weather refresh', (tester) async {
    final weather = _HangingWeatherApiClient();
    addTearDown(weather.release);

    await pumpJournalPage(
      tester,
      // Without a location the refresh returns before it reaches the network,
      // which is not the case this is about.
      configureSettings: (settings) => settings.copyWith(
        weatherLat: 41.88,
        weatherLon: -87.63,
        weatherLocationLabel: 'Chicago, US',
      ),
      weatherApiClient: weather,
      extraOverrides: (_) => [
        bundledQuotesProvider.overrideWith(
          (ref) async => const [Quote(id: 'q1', text: 'Harness quote')],
        ),
      ],
    );

    await tester.tap(find.text('New entry'));
    await settle(tester, frames: 40);

    expect(find.text('Harness quote'), findsOneWidget);

    weather.release();
    await settle(tester);
    await disposeJournalPage(tester);
  });

  testWidgets('a new entry carries its quote from its very first write', (
    tester,
  ) async {
    // Frame timing collapses under the test clock, so the jump itself cannot
    // be observed here. Its cause can: the quote used to be written by a
    // second, asynchronous pass, which left the entry on screen without one —
    // and the editor stretched over the space it takes — until that pass
    // landed. The quote has to be on the row the moment it is created.
    late _RecordingJournalRepository repo;
    await pumpJournalPage(
      tester,
      extraOverrides: (db) => [
        journalRepositoryProvider.overrideWith(
          (ref) => repo = _RecordingJournalRepository(db),
        ),
        bundledQuotesProvider.overrideWith(
          (ref) async => const [Quote(id: 'q1', text: 'Harness quote')],
        ),
      ],
    );

    // One throwaway entry first, only to pull the quote bank in — the app's
    // startup warm-up awaits it long before anyone reaches the journal, so a
    // loaded bank is the state that matters.
    await tester.tap(find.text('New entry'));
    await settle(tester, frames: 20);

    repo.writes.clear();
    await tester.tap(find.text('New entry'));
    await settle(tester, frames: 20);

    expect(repo.writes.first.customQuote, 'Harness quote');

    await disposeJournalPage(tester);
  });

  testWidgets('with "Only my quotes" just turned on, the next new entry gets '
      'a custom quote (BUG-054)', (tester) async {
    late _RecordingJournalRepository repo;
    await pumpJournalPage(
      tester,
      extraOverrides: (db) => [
        journalRepositoryProvider.overrideWith(
          (ref) => repo = _RecordingJournalRepository(db),
        ),
        bundledQuotesProvider.overrideWith(
          (ref) async => const [Quote(id: 'b1', text: 'Bundled quote')],
        ),
      ],
    );

    // The bank loaded over the bundled pool, as after the startup warm-up.
    await tester.tap(find.text('New entry'));
    await settle(tester, frames: 20);
    final first = await repo.getEntry(repo.writes.first.id);
    expect(first!.customQuote, 'Bundled quote');

    // Settings → Custom quotes: add one, turn "Only my quotes" on.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(JournalPage)),
    );
    final settingsRepo = container.read(settingsRepositoryProvider);
    final now = DateTime.now().toUtc();
    await settingsRepo.upsertCustomQuote(
      CustomQuote(id: 'c1', text: 'My quote', createdAt: now, updatedAt: now),
    );
    container.invalidate(customQuotesProvider);
    await container
        .read(settingsProvider.notifier)
        .saveSettings(
          (await settingsRepo.getSettings()).copyWith(customQuotesOnly: true),
        );
    await settle(tester);

    repo.writes.clear();
    await tester.tap(find.text('New entry'));
    await settle(tester, frames: 20);

    final created = await repo.getEntry(repo.writes.first.id);
    expect(created!.customQuote, 'My quote');

    await disposeJournalPage(tester);
  });

  testWidgets('an entry without a quote can be given one (BUG-052)', (
    tester,
  ) async {
    // The harness's seeded entry was written without a quote, like one
    // imported or synced from an older build.
    final db = await pumpJournalPage(tester);

    await tester.tap(find.text('Add a quote'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(EditableText),
      ),
      'Typed quote',
    );
    await tester.tap(find.text('Save'));
    await settle(tester, frames: 20);

    expect(find.text('Typed quote'), findsOneWidget);
    expect(find.text('Add a quote'), findsNothing);
    final entry = await DriftJournalRepository(db).getEntry('harness-entry');
    expect(entry!.customQuote, 'Typed quote');

    await disposeJournalPage(tester);
  });

  testWidgets(
    'a new entry waiting for its quote does not flash "Add a quote"',
    (tester) async {
      // The bank never loaded, as on a cold start: the entry is created without
      // a quote and gets one only once the bundled quotes arrive.
      final bundled = Completer<List<Quote>>();
      await pumpJournalPage(
        tester,
        extraOverrides: (_) => [
          bundledQuotesProvider.overrideWith((ref) => bundled.future),
        ],
      );

      await tester.tap(find.text('New entry'));
      await settle(tester);

      final shown = find.text('Add a quote').evaluate().where((element) {
        var hidden = false;
        element.visitAncestorElements((ancestor) {
          final widget = ancestor.widget;
          hidden = widget is Visibility && !widget.visible;
          return !hidden;
        });
        return !hidden;
      });
      expect(shown, isEmpty);

      bundled.complete(const [Quote(id: 'b1', text: 'Late quote')]);
      await settle(tester, frames: 20);
      expect(find.text('Late quote'), findsOneWidget);

      await disposeJournalPage(tester);
    },
  );
}
