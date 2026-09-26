// The workout history modal: finished sessions listed, one opened and its
// sets ticked and retyped in place, and a workout done without the app logged
// after the fact.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/workout_history.dart';

import 'fakes/fake_weather_api_client.dart';

Future<void> _settle(WidgetTester tester) async {
  // Not pumpAndSettle: the modal's zoom keeps ticking while providers resolve.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<AppDatabase> _pumpHistory(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftWorkoutRepository(db);

  await tester.runAsync(() async {
    await repo.ensureSeeded();
    final now = utcNow();
    await repo.upsertExercise(
      Exercise(
        id: 'bench',
        name: 'Bench Press',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final plans = await repo.listPlans();
    final weekly = plans.firstWhere((p) => p.mode == WorkoutPlanMode.weekly);
    await repo.setActivePlan(weekly.id);
    for (var day = 0; day < 7; day++) {
      await repo.upsertPlanEntry(
        WorkoutPlanEntry(
          id: 'entry$day',
          planId: weekly.id,
          dayIndex: day,
          exerciseId: 'bench',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    final started = DateTime.utc(2026, 9, 20, 18);
    await repo.createSessionWithLogs(
      WorkoutSession(
        id: 'past',
        date: workoutStoredDate(DateTime(2026, 9, 20)),
        startedAt: started,
        endedAt: started,
        createdAt: started,
        updatedAt: started,
      ),
      [
        WorkoutSetLog(
          id: 'set0',
          sessionId: 'past',
          exerciseId: 'bench',
          exerciseOrder: 0,
          setIndex: 0,
          weightKg: 60,
          reps: 8,
          plannedWeightKg: 60,
          plannedReps: 8,
          createdAt: started,
          updatedAt: started,
        ),
      ],
    );
  });

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => openWorkoutHistory(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
  return db;
}

Future<T> _read<T>(WidgetTester tester, Future<T> Function() read) async {
  late T value;
  await tester.runAsync(() async => value = await read());
  return value;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a past session opens, ticks off and retypes in place', (
    tester,
  ) async {
    final db = await _pumpHistory(tester);
    final repo = DriftWorkoutRepository(db);

    expect(find.text('Sun, Sep 20, 2026'), findsOneWidget);
    expect(find.text('Bench Press'), findsOneWidget);
    expect(find.textContaining('0 of 1 sets'), findsOneWidget);

    await tester.tap(find.text('Sun, Sep 20, 2026'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await _settle(tester);
    expect(find.text('Set 1'), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await _settle(tester);
    expect(
      (await _read(tester, () => repo.getSetLog('set0')))!.completed,
      isTrue,
    );

    await tester.enterText(find.byType(VoyagerTextField).at(1), '10');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect((await _read(tester, () => repo.getSetLog('set0')))!.reps, 10);
  });

  testWidgets('a past workout is logged finished, on its date', (tester) async {
    final db = await _pumpHistory(tester);
    final repo = DriftWorkoutRepository(db);

    await tester.tap(find.text('Log past workout'));
    await _settle(tester);
    expect(find.text('Bench Press'), findsOneWidget);

    await tester.tap(find.text('Create'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await _settle(tester);

    final sessions = await _read(tester, repo.listSessions);
    expect(sessions, hasLength(2));
    final logged = sessions.firstWhere((s) => s.id != 'past');
    expect(logged.endedAt, isNotNull);
    expect(
      workoutCalendarDate(logged.date),
      DateUtils.dateOnly(DateTime.now()),
    );
    expect(find.text('Set 1'), findsOneWidget, reason: 'opens in the editor');
  });
}
