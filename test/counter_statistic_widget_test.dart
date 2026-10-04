// The counter statistic's surfaces (COUNTER_STATISTIC_HLD.md §7): the card's
// − and +, the detail popup's log, and the notification popover's row.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/analytics/analytics_page.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';

import 'fakes/fake_weather_api_client.dart';

const _name = 'Pushups';

Future<ProviderContainer> _container(
  WidgetTester tester, {
  TrackerCadence cadence = TrackerCadence.weekly,
}) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      deviceIdProvider.overrideWith((ref) => 'device-a'),
    ],
  );
  addTearDown(container.dispose);
  final now = DateTime.now().toUtc();
  await container
      .read(trackerRepositoryProvider)
      .createCounter(
        StatisticTracker(
          id: 'counter-1',
          createdAt: now,
          updatedAt: now,
          name: _name,
          type: TrackerType.counter,
          cadence: cadence,
        ),
        startingValue: 3,
        deviceId: 'device-a',
      );
  await container.read(settingsProvider.future);
  await container.read(trackersProvider.future);
  return container;
}

/// Lets the drift write a press started finish, then rebuilds.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<int> _total(ProviderContainer container) async {
  final rows = await container
      .read(trackerRepositoryProvider)
      .listAdjustments('counter-1');
  return counterTotalThrough(rows, DateTime.now());
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets(
    'the card changes today without opening the detail popup',
    semanticsEnabled: false,
    (tester) async {
      final container = await _container(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: VoyagerTheme.dark(),
            home: const Scaffold(body: AnalyticsPage()),
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('3'), findsWidgets);

      await tester.tap(find.byTooltip('Increase'));
      await _settle(tester);
      await tester.tap(find.byTooltip('Increase'));
      await _settle(tester);
      await tester.tap(find.byTooltip('Decrease'));
      await _settle(tester);

      expect(await tester.runAsync(() => _total(container)), 4);
      expect(find.text('4'), findsWidgets);
      expect(find.text('HISTORY'), findsNothing, reason: 'no detail popup');
    },
  );

  testWidgets(
    'the log hides cancelled days and erasing a day updates totals',
    semanticsEnabled: false,
    (tester) async {
      final container = await _container(tester);
      final repo = container.read(trackerRepositoryProvider);
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final twoDaysAgo = DateTime.now().subtract(const Duration(days: 2));
      // A day whose taps cancel out, and one with a real change.
      for (final delta in [1, -1]) {
        await repo.adjustCounter(
          trackerId: 'counter-1',
          day: twoDaysAgo,
          deviceId: 'device-a',
          delta: delta,
        );
      }
      await repo.adjustCounter(
        trackerId: 'counter-1',
        day: yesterday,
        deviceId: 'device-a',
        delta: 5,
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: VoyagerTheme.dark(),
            home: const Scaffold(body: AnalyticsPage()),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.text(_name));
      await _settle(tester);

      expect(find.text('HISTORY'), findsOneWidget);
      // The creation day's +3 and yesterday's +5; the cancelled day is hidden.
      expect(find.byTooltip('Erase this day'), findsNWidgets(2));
      // Derived running totals, so no counts or streaks of graph points.
      expect(find.text('Highest'), findsOneWidget);
      expect(find.text('Entries logged'), findsNothing);
      expect(find.text('Longest streak'), findsNothing);

      // Newest first, so this is today's starting value.
      await tester.tap(find.byTooltip('Erase this day').first);
      await _settle(tester);

      expect(find.byTooltip('Erase this day'), findsOneWidget);
      expect(await tester.runAsync(() => _total(container)), 5);

      await tester.tap(find.text('Undo'));
      await _settle(tester);

      expect(find.byTooltip('Erase this day'), findsNWidgets(2));
      expect(await tester.runAsync(() => _total(container)), 8);
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets(
    'the popover row saves each press and never adds to the badge',
    semanticsEnabled: false,
    (tester) async {
      // Daily, so the badge would count it if counters weren't skipped.
      final container = await _container(tester, cadence: TrackerCadence.daily);
      final now = DateTime.now().toUtc();
      await container
          .read(trackerRepositoryProvider)
          .upsertTracker(
            StatisticTracker(
              id: 'counter-2',
              createdAt: now,
              updatedAt: now,
              name: 'Weekly counter',
              type: TrackerType.counter,
              cadence: TrackerCadence.weekly,
            ),
          );
      container.invalidate(trackersProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: VoyagerTheme.dark(),
            home: const Scaffold(body: NotificationInboxPopover()),
          ),
        ),
      );
      await _settle(tester);
      expect(
        await tester.runAsync(
          () => container.read(pendingStatEntriesProvider.future),
        ),
        0,
      );

      await tester.tap(find.text('Log stats'));
      await _settle(tester);
      expect(find.text(_name), findsOneWidget);
      // Listed although its graph resolution is weekly.
      expect(find.text('Weekly counter'), findsOneWidget);

      await tester.tap(find.byTooltip('Increase').first);
      await _settle(tester);

      expect(await tester.runAsync(() => _total(container)), 4);
      expect(
        await tester.runAsync(
          () => container.read(pendingStatEntriesProvider.future),
        ),
        0,
      );

      // Torn down here rather than after the test: with a real device id the
      // reminder engine arms a timer, which has to be cancelled before the
      // binding checks for pending ones.
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
}
