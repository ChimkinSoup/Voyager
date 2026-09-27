// Analytics stays mounted behind every other page, and its Tasks chip moves
// with every to-do tick. Watching the counts at the page level would rebuild
// the whole page, tracker grid included, twice per tick while To-Do was in
// use; only the chip should rebuild.

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

final _stats = StateProvider<Map<String, ({int active, int completed})>>(
  (ref) => {'list': (active: 3, completed: 1)},
);

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets(
    'a to-do change rebuilds the counts, not the page',
    semanticsEnabled: false,
    (tester) async {
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
          journalsProvider.overrideWith((ref) async => []),
          todoListStatsProvider.overrideWith((ref) async => ref.watch(_stats)),
        ],
      );
      addTearDown(container.dispose);
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

      expect(find.text('3 open'), findsOneWidget);

      Widget page() => tester.widget(find.byType(KeepAliveScrollView));
      final shown = page();
      final rebuilt = <String>[];
      debugOnRebuildDirtyWidget = (element, _) =>
          rebuilt.add(element.widget.runtimeType.toString());
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      container.read(_stats.notifier).state = {
        'list': (active: 7, completed: 1),
      };
      await tester.pump();
      await tester.pump();

      expect(find.text('7 open'), findsOneWidget);
      expect(rebuilt, contains('_TasksChip'));
      expect(page(), same(shown), reason: 'the page keeps its build');

      await tester.tap(find.text('7 open'));
      await tester.pumpAndSettle();
      expect(find.text('Completed tasks'), findsOneWidget);
      expect(find.text('13%'), findsOneWidget);
    },
  );
}
