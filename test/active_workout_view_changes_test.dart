// The live view with the GAPS.md additions on screen: last time's numbers
// beside the set, the Skip button, and the strip that reorders and adds.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/active_workout_view.dart';
import 'package:voyager/features/workout/workout_session_controller.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('shows last time, Skip, and a strip that adds', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftWorkoutRepository(db);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ],
    );
    addTearDown(container.dispose);

    late WorkoutPlan plan;
    await tester.runAsync(() async {
      final now = utcNow();
      await repo.ensureSeeded();
      plan = (await repo.listPlans()).first;
      for (final (i, id) in ['bench', 'squat'].indexed) {
        await repo.upsertExercise(
          Exercise(
            id: id,
            name: id == 'bench' ? 'Bench Press' : 'Squat',
            targetWeightKg: 60,
            createdAt: now,
            updatedAt: now,
          ),
        );
        await repo.upsertPlanEntry(
          WorkoutPlanEntry(
            id: 'e$i',
            planId: plan.id,
            dayIndex: 0,
            exerciseId: id,
            sortOrder: i,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
      final before = DateTime.utc(2026, 9, 1);
      await repo.createSessionWithLogs(
        WorkoutSession(
          id: 'before',
          date: workoutStoredDate(DateTime(2026, 9, 1)),
          startedAt: before,
          endedAt: before,
          createdAt: before,
          updatedAt: before,
        ),
        [
          WorkoutSetLog(
            id: 'old',
            sessionId: 'before',
            exerciseId: 'bench',
            exerciseOrder: 0,
            setIndex: 0,
            weightKg: 100,
            reps: 5,
            plannedWeightKg: 100,
            plannedReps: 5,
            completed: true,
            createdAt: before,
            updatedAt: before,
          ),
        ],
      );
      container.read(workoutSessionControllerProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await container
          .read(workoutSessionControllerProvider.notifier)
          .startFromPlan(plan: plan, dayIndex: 0, date: DateTime.now());
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ActiveWorkoutView())),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 80));
    }

    expect(tester.takeException(), isNull);
    expect(find.text('Last 220.5 × 5'), findsOneWidget);
    expect(find.textContaining('last 220.5 × 5'), findsNWidgets(3));
    expect(find.text('Skip exercise'), findsOneWidget);
    expect(find.text('Squat'), findsOneWidget);
    expect(find.text('Exercise'), findsOneWidget);
  });
}
