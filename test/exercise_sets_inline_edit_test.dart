// The exercise detail view's sets are editable in place — one row per set,
// drops beneath it, no sheet and no Save. The fields are the commit surface,
// so these pin what a modal would otherwise have done: writing through on a
// pause, clamping a typed number, showing the clamped value, and storing the
// list in whichever shape (uniform target or custom recipe) it amounts to.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/exercise_detail_view.dart';

import 'fakes/fake_weather_api_client.dart';

const _exerciseId = 'bench';

/// Weight or reps field of the [set]th set's top segment (0-based), in a
/// card whose sets have no drops. Fields run weight, reps, weight, reps… with
/// the form cues last.
Finder _weightField(int set) => find.byType(VoyagerTextField).at(set * 2);
Finder _repsField(int set) => find.byType(VoyagerTextField).at(set * 2 + 1);

Future<AppDatabase> _pumpDetailView(WidgetTester tester) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftWorkoutRepository(db);
  final now = utcNow();
  final exercise = Exercise(
    id: _exerciseId,
    name: 'Bench Press',
    sortOrder: 0,
    targetSets: 3,
    targetReps: 8,
    targetWeightKg: 60,
    createdAt: now,
    updatedAt: now,
  );
  await repo.upsertExercise(exercise);

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      // The detail card captures the sync service on mount, which builds the
      // real weather client and reaches for Firebase.
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
                onPressed: () => openExerciseDetailView(context, exercise),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  // Not pumpAndSettle: the overlay's zoom controller keeps ticking while the
  // providers resolve. A few frames covers both.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
  expect(find.text('Bench Press'), findsOneWidget);
  return db;
}

/// Reads the movement back through a fresh repository, off the fake clock so
/// the pending drift write actually lands.
Future<Exercise?> _storedExercise(WidgetTester tester, AppDatabase db) async {
  Exercise? found;
  await tester.runAsync(() async {
    found = await DriftWorkoutRepository(db).getExercise(_exerciseId);
  });
  return found;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('one list of sets, no target row and no edit button', (
    tester,
  ) async {
    await _pumpDetailView(tester);

    expect(find.text('Target'), findsNothing);
    expect(find.text('Custom sets'), findsNothing);
    expect(find.text('Set 1'), findsOneWidget);
    expect(find.text('Set 3'), findsOneWidget);
    expect(
      find.text('Applies to every day this movement is planned on'),
      findsOneWidget,
      reason: 'the global reach of the edit must survive losing the sheet',
    );
  });

  testWidgets('editing every set alike keeps the uniform target', (
    tester,
  ) async {
    final db = await _pumpDetailView(tester);

    for (var i = 0; i < 3; i++) {
      await tester.enterText(_repsField(i), '12');
    }
    // Past the debounce, with nothing tapped and nothing dismissed.
    await tester.pump(const Duration(milliseconds: 800));

    final stored = await _storedExercise(tester, db);
    expect(stored?.prescriptionMode, WorkoutPrescriptionMode.inherit);
    expect(stored?.targetSets, 3);
    expect(stored?.targetReps, 12);
  });

  testWidgets('one set differing stores a custom recipe', (tester) async {
    final db = await _pumpDetailView(tester);

    await tester.enterText(_repsField(2), '5');
    await tester.pump(const Duration(milliseconds: 800));

    final stored = await _storedExercise(tester, db);
    expect(stored?.prescriptionMode, WorkoutPrescriptionMode.custom);
    expect([for (final p in stored!.setPrescriptions) p.top.reps], [8, 8, 5]);
  });

  testWidgets('adding a drop and a set saves at once', (tester) async {
    final db = await _pumpDetailView(tester);

    await tester.tap(find.byTooltip('Add drop').last);
    await tester.pump();
    await tester.tap(find.text('Add set'));
    await tester.pump();

    expect(find.text('  ↳ Drop 1'), findsOneWidget);
    final stored = await _storedExercise(tester, db);
    expect(stored?.prescriptionMode, WorkoutPrescriptionMode.custom);
    expect(
      [for (final p in stored!.setPrescriptions) p.segments.length],
      [1, 1, 2, 1],
    );
  });

  testWidgets('removing sets back to a uniform list returns to the target', (
    tester,
  ) async {
    final db = await _pumpDetailView(tester);

    await tester.tap(find.byTooltip('Remove set').first);
    await tester.pump();

    final stored = await _storedExercise(tester, db);
    expect(stored?.prescriptionMode, WorkoutPrescriptionMode.inherit);
    expect(stored?.targetSets, 2);
  });

  testWidgets('a number past the range is clamped, and the field says so', (
    tester,
  ) async {
    final db = await _pumpDetailView(tester);

    await tester.enterText(_repsField(0), '999');
    for (var i = 1; i < 3; i++) {
      await tester.enterText(_repsField(i), '999');
    }
    // Leaving the field commits immediately rather than waiting out the pause.
    await tester.tap(_weightField(0));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('$kMaxReps'),
      findsNWidgets(3),
      reason: 'the field should show what was stored, not what was rejected',
    );
    expect((await _storedExercise(tester, db))?.targetReps, kMaxReps);
  });

  testWidgets('opening and closing the card leaves the weight untouched', (
    tester,
  ) async {
    // 60 kg is shown as 132.3 lb and parses back as 60.01 — a field that
    // writes what it parsed would walk the target every time it was viewed.
    final db = await _pumpDetailView(tester);

    await tester.tap(find.byTooltip('Close'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }

    expect((await _storedExercise(tester, db))?.targetWeightKg, 60);
  });

  testWidgets('clearing the weight stores bodyweight rather than failing', (
    tester,
  ) async {
    final db = await _pumpDetailView(tester);

    for (var i = 0; i < 3; i++) {
      await tester.enterText(_weightField(i), '');
    }
    await tester.pump(const Duration(milliseconds: 800));

    expect((await _storedExercise(tester, db))?.targetWeightKg, 0);
  });
}
