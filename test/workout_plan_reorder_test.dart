// BUG-203: a planned day's cards can be put in order. A card dropped on
// another goes just above it; dropped on its own day elsewhere, it goes last.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/workout_actions.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late AppDatabase db;
  late DriftWorkoutRepository repo;
  late WidgetRef widgetRef;

  Future<List<String>> day(int dayIndex) async => [
    for (final e
        in (await repo.listPlanEntries(kWeeklyWorkoutPlanId))
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
      if (e.dayIndex == dayIndex) e.exerciseId,
  ];

  Future<WorkoutPlanEntry> entryFor(String exerciseId) async =>
      (await repo.listPlanEntries(
        kWeeklyWorkoutPlanId,
      )).firstWhere((e) => e.exerciseId == exerciseId);

  Future<void> pumpHarness(WidgetTester tester) async {
    db = AppDatabase.inMemory();
    addTearDown(db.close);
    repo = DriftWorkoutRepository(db);
    await tester.runAsync(() async {
      await repo.ensureSeeded();
      final now = utcNow();
      for (final (i, (dayIndex, id)) in [
        (1, 'a'),
        (1, 'b'),
        (1, 'c'),
        (2, 'd'),
      ].indexed) {
        await repo.upsertExercise(
          Exercise(id: id, name: id, createdAt: now, updatedAt: now),
        );
        await repo.upsertPlanEntry(
          WorkoutPlanEntry(
            id: 'entry-$id',
            planId: kWeeklyWorkoutPlanId,
            dayIndex: dayIndex,
            exerciseId: id,
            sortOrder: i,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            widgetRef = ref;
            return const SizedBox();
          },
        ),
      ),
    );
  }

  testWidgets('a card dropped on another goes just above it', (tester) async {
    await pumpHarness(tester);
    await tester.runAsync(() async {
      await WorkoutActions(widgetRef).movePlanEntryBefore(
        entry: await entryFor('c'),
        before: await entryFor('a'),
      );
      expect(await day(1), ['c', 'a', 'b']);

      // From another day, into the middle.
      await WorkoutActions(widgetRef).movePlanEntryBefore(
        entry: await entryFor('d'),
        before: await entryFor('a'),
      );
      expect(await day(1), ['c', 'd', 'a', 'b']);
      expect(await day(2), isEmpty);

      // Dropped on the card below it, or on itself: nothing moves.
      await WorkoutActions(widgetRef).movePlanEntryBefore(
        entry: await entryFor('c'),
        before: await entryFor('d'),
      );
      await WorkoutActions(widgetRef).movePlanEntryBefore(
        entry: await entryFor('a'),
        before: await entryFor('a'),
      );
      expect(await day(1), ['c', 'd', 'a', 'b']);
    });
  });

  testWidgets('a card dropped on its own day goes last', (tester) async {
    await pumpHarness(tester);
    await tester.runAsync(() async {
      await WorkoutActions(
        widgetRef,
      ).movePlanEntry(entry: await entryFor('a'), dayIndex: 1);
      expect(await day(1), ['b', 'c', 'a']);

      final before = await entryFor('a');
      await WorkoutActions(widgetRef).movePlanEntry(entry: before, dayIndex: 1);
      expect((await entryFor('a')).version, before.version);
    });
  });
}
