// The expanded live workout: the rest countdown shows there too (BUG-202),
// and a very long exercise name stays one ellipsized chip in the strip
// (BUG-205).

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

final _longName = 'L${'x' * 298}Z';

Future<ProviderContainer> _startWorkout(WidgetTester tester) async {
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

  await tester.runAsync(() async {
    final now = utcNow();
    await repo.ensureSeeded();
    final plan = (await repo.listPlans()).first;
    for (final (i, (id, name)) in [
      ('long', _longName),
      ('squat', 'Squat'),
    ].indexed) {
      await repo.upsertExercise(
        Exercise(id: id, name: name, createdAt: now, updatedAt: now),
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
  return container;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('BUG-202: a running rest counts down in the expanded view', (
    tester,
  ) async {
    final container = await _startWorkout(tester);
    final controller = container.read(
      workoutSessionControllerProvider.notifier,
    );

    expect(find.textContaining('Rest '), findsNothing);
    controller.startRest(15);
    await tester.pump();
    expect(find.textContaining('Rest 0:1'), findsOneWidget);

    controller.cancelRest();
    await tester.pump();
    expect(find.textContaining('Rest '), findsNothing);
  });

  testWidgets('BUG-205: a 300-character name leaves the next exercise in '
      'reach', (tester) async {
    await _startWorkout(tester);

    expect(tester.takeException(), isNull);
    final squat = tester.getRect(find.text('Squat'));
    final view = tester.getRect(find.byType(ActiveWorkoutView));
    expect(squat.right, lessThan(view.right));
    // The title is two lines at most, not ten.
    final title = tester.widget<Text>(find.text(_longName).first);
    expect(title.maxLines, 2);
  });
}
