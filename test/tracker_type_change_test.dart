// BUG-100: readings logged under one tracker type must not be read as
// answers of another after the type changes.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/analytics/tracker_entry_row.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test(
    'a Number tracker turned Boolean hides its numbers until turned back',
    () async {
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
      final repo = container.read(trackerRepositoryProvider);
      final now = DateTime.now().toUtc();
      StatisticTracker tracker(TrackerType type) => StatisticTracker(
        id: 'pages',
        createdAt: now,
        updatedAt: now,
        name: 'Pages read',
        type: type,
        cadence: TrackerCadence.daily,
      );
      await repo.upsertTracker(tracker(TrackerType.integer));
      for (final day in [27, 28, 29, 30]) {
        await repo.upsertValue(
          TrackerValue(
            id: 'pages-$day',
            trackerId: 'pages',
            periodStart: DateTime(2026, 9, day),
            intValue: day.toDouble(),
            createdAt: now,
            updatedAt: now,
          ),
        );
      }

      Future<List<TrackerValue>> values() async {
        container.invalidate(trackersProvider);
        container.invalidate(trackerValuesProvider('pages'));
        return container.read(trackerValuesProvider('pages').future);
      }

      expect(await values(), hasLength(4));

      await repo.upsertTracker(tracker(TrackerType.boolean));
      expect(await values(), isEmpty);

      await repo.upsertTracker(tracker(TrackerType.integer));
      expect(
        (await values()).map((v) => v.intValue),
        unorderedEquals([27, 28, 29, 30]),
      );
    },
  );

  // The row id is derived from tracker + date, so logging the new type on a
  // day with a hidden reading writes that same row. Driven through
  // [TrackerEntryRow] so it exercises the real save path.
  testWidgets('logging a number on a day with a hidden Boolean answer keeps '
      'the answer', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final repo = container.read(trackerRepositoryProvider);
    final createdAt = DateTime.utc(2026, 8, 1);
    final date = DateTime(2026, 8, 14);
    StatisticTracker tracker(TrackerType type) => StatisticTracker(
      id: 'gym',
      name: 'Gym',
      type: type,
      cadence: TrackerCadence.daily,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    // Logged as Boolean, then the tracker became a Number.
    await repo.upsertValue(
      TrackerValue(
        id: trackerValueId('gym', date),
        trackerId: 'gym',
        periodStart: date,
        boolValue: true,
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
    await repo.upsertTracker(tracker(TrackerType.integer));
    await tester.runAsync(() => container.read(settingsProvider.future));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: TrackerEntryRow(
              tracker: tracker(TrackerType.integer),
              date: date,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, '42');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    // Runs out the row's two-second "saved" flash.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    final saved = await repo.getValue(trackerValueId('gym', date));
    expect(saved!.intValue, 42);
    expect(saved.boolValue, isTrue);
  });
}
