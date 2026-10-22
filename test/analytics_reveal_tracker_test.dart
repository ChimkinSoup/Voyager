// A tap on a tracker's name in the inbox's Log stats section opens Analytics
// scrolled to that tracker's row, via [revealTrackerRequestProvider].

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/analytics/analytics_page.dart';
import 'package:voyager/features/shell/reveal_request.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets(
    'a reveal request scrolls its tracker into view',
    semanticsEnabled: false,
    (tester) async {
      tester.view.physicalSize = const Size(1000, 600);
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
      final now = DateTime.utc(2026, 10, 1);
      final repo = container.read(trackerRepositoryProvider);
      for (var i = 0; i < 30; i++) {
        await repo.upsertTracker(
          StatisticTracker(
            id: 't$i',
            name: 'Tracker $i',
            type: TrackerType.integer,
            cadence: TrackerCadence.daily,
            sortOrder: i,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
      await container.read(settingsProvider.future);
      await container.read(allJournalEntriesProvider.future);
      await container.read(trackersProvider.future);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: VoyagerTheme.dark(),
            home: const Scaffold(body: AnalyticsPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final target = find.text('Tracker 29');
      final list = find.byType(KeepAliveScrollView);
      bool onScreen() {
        final viewport = tester.getRect(list);
        final row = tester.getRect(target);
        return row.top >= viewport.top && row.bottom <= viewport.bottom;
      }

      expect(onScreen(), isFalse, reason: 'starts below the fold');

      // The flash: a [FadeTransition] lit over the row once it has landed.
      int lit() => tester
          .widgetList<FadeTransition>(find.byType(FadeTransition))
          .where((w) => w.opacity.value > 0.5)
          .length;
      final litBefore = lit();

      container.read(revealTrackerRequestProvider.notifier).state = 't29';
      // The request is taken after a frame, and the scroll starts the next.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(onScreen(), isTrue);
      expect(lit(), litBefore, reason: 'not while it scrolls');

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      expect(lit(), litBefore + 1, reason: 'a beat after it lands');

      await tester.pumpAndSettle();
      expect(lit(), litBefore, reason: 'and then gone');
      expect(onScreen(), isTrue);
      expect(container.read(revealTrackerRequestProvider), isNull);
    },
  );
}
