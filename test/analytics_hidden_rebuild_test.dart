// The Analytics page is a preloaded shell branch: mounted behind every other
// section, watching the journal entries that every journal save invalidates.
// Out of sight it must keep what it last built rather than rebuild — that
// rebuild cost 12–20ms a frame during journal hotkey use — and rebuild from
// current data when it is back in sight, but only if that data moved on.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/features/analytics/analytics_page.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('rebuilds only while in sight', semanticsEnabled: false, (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
    await container.read(allJournalEntriesProvider.future);
    await container.read(trackersProvider.future);

    final inSight = ValueNotifier(true);
    addTearDown(inSight.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: inSight,
              builder: (_, enabled, child) =>
                  TickerMode(enabled: enabled, child: child!),
              child: const AnalyticsPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Widget page() => tester.widget(find.byType(KeepAliveScrollView));
    Future<void> journalSaved() async {
      container.invalidate(allJournalEntriesProvider);
      await tester.runAsync(
        () => container.read(allJournalEntriesProvider.future),
      );
      await tester.pump();
      await tester.pump();
    }

    final shown = page();
    await journalSaved();
    expect(page(), isNot(same(shown)), reason: 'in sight: rebuilds');

    inSight.value = false;
    await tester.pump();
    final hidden = page();
    await journalSaved();
    await journalSaved();
    expect(page(), same(hidden), reason: 'out of sight: keeps its build');

    inSight.value = true;
    await tester.pump();
    final back = page();
    expect(back, isNot(same(hidden)), reason: 'back, changed: rebuilds');

    inSight.value = false;
    await tester.pump();
    inSight.value = true;
    await tester.pump();
    expect(page(), same(back), reason: 'back, unchanged: keeps its build');
  });
}
