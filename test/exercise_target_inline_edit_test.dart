// The exercise detail view's target row is editable in place — no Edit button,
// no sheet, no Save. That means the field itself is the commit surface, so
// these pin the three things that used to be the modal's job: writing through
// on a pause, clamping a typed number to the range the wheels enforce, and
// showing the clamped value rather than the rejected one.

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

/// The editable field sitting under the [label] caption in the target row.
Finder _targetField(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first,
  matching: find.byType(VoyagerTextField),
);

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
                onPressed: () =>
                    openExerciseDetailView(context, exercise, Rect.zero),
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

  testWidgets('the target row has no edit button — the numbers are the editor', (
    tester,
  ) async {
    await _pumpDetailView(tester);

    expect(find.text('Edit'), findsNothing);
    expect(_targetField('Sets'), findsOneWidget);
    expect(_targetField('Reps'), findsOneWidget);
    expect(_targetField('Weight'), findsOneWidget);
    expect(
      find.text('Applies to every day this movement is planned on'),
      findsOneWidget,
      reason: 'the global reach of the edit must survive losing the tooltip',
    );
  });

  testWidgets('typing a target writes it through without any confirmation', (
    tester,
  ) async {
    final db = await _pumpDetailView(tester);

    await tester.enterText(_targetField('Sets'), '5');
    await tester.enterText(_targetField('Reps'), '12');
    // Past the debounce, with nothing tapped and nothing dismissed.
    await tester.pump(const Duration(milliseconds: 800));

    final stored = await _storedExercise(tester, db);
    expect(stored?.targetSets, 5);
    expect(stored?.targetReps, 12);
  });

  testWidgets('a number past the range is clamped, and the field says so', (
    tester,
  ) async {
    final db = await _pumpDetailView(tester);

    await tester.enterText(_targetField('Sets'), '999');
    // Leaving the field commits immediately rather than waiting out the pause.
    await tester.tap(_targetField('Reps'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('$kMaxSets'),
      findsOneWidget,
      reason: 'the field should show what was stored, not what was rejected',
    );
    expect((await _storedExercise(tester, db))?.targetSets, kMaxSets);
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

  testWidgets('clearing the weight stores a bodyweight target rather than failing', (
    tester,
  ) async {
    final db = await _pumpDetailView(tester);

    await tester.enterText(_targetField('Weight'), '');
    await tester.pump(const Duration(milliseconds: 800));

    expect((await _storedExercise(tester, db))?.targetWeightKg, 0);
  });
}
