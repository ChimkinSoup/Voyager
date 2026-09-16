// The quote a new entry is assigned has to be on screen the moment the page
// switches to it, not only once the entry has been reopened.

import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/weather_models.dart';

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
}
