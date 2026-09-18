// The exercise detail view's sets are editable in place — no Edit button, no
// sheet, no Save. There is only one list: what used to be a uniform "target"
// plus a separate custom-sets sheet is now the set rows themselves, so these
// pin what both used to be responsible for — writing through on a pause,
// clamping a typed number, showing the clamped value rather than the rejected
// one — plus adding and removing sets, and the per-day override.

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
const _entryId = 'monday-bench';

/// The two number fields of the row captioned [label] — weight first, reps
/// second, as they sit on screen.
Finder _rowFields(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
  matching: find.byType(VoyagerTextField),
);

Finder _weightField(String label) => _rowFields(label).at(0);
Finder _repsField(String label) => _rowFields(label).at(1);

Future<AppDatabase> _pumpDetailView(
  WidgetTester tester, {
  bool fromPlanEntry = false,
}) async {
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

  final entry = WorkoutPlanEntry(
    id: _entryId,
    planId: 'weekly',
    dayIndex: 1,
    exerciseId: _exerciseId,
    createdAt: now,
    updatedAt: now,
  );
  if (fromPlanEntry) await repo.upsertPlanEntry(entry);

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
                onPressed: () => openExerciseDetailView(
                  context,
                  exercise,
                  Rect.zero,
                  entry: fromPlanEntry ? entry : null,
                ),
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

/// Reads back through a fresh repository, off the fake clock so the pending
/// drift write actually lands.
Future<Exercise?> _storedExercise(WidgetTester tester, AppDatabase db) async {
  Exercise? found;
  await tester.runAsync(() async {
    found = await DriftWorkoutRepository(db).getExercise(_exerciseId);
  });
  return found;
}

Future<WorkoutPlanEntry?> _storedEntry(
  WidgetTester tester,
  AppDatabase db,
) async {
  WorkoutPlanEntry? found;
  await tester.runAsync(() async {
    found = await DriftWorkoutRepository(db).getPlanEntry(_entryId);
  });
  return found;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('there is one sets list, seeded from the movement, and no target '
      'row beside it', (tester) async {
    await _pumpDetailView(tester);

    expect(find.text('Target'), findsNothing);
    expect(find.text('Sets'), findsOneWidget);
    // A movement never dialled in set by set still has its three uniform sets
    // to show — the old target is the seed, not a second concept.
    expect(find.text('Set 1'), findsOneWidget);
    expect(find.text('Set 2'), findsOneWidget);
    expect(find.text('Set 3'), findsOneWidget);
    expect(find.text('Set 4'), findsNothing);
    expect(
      find.text('Applies to every day this movement is planned on'),
      findsOneWidget,
      reason: 'the global reach of the edit must survive losing the tooltip',
    );
  });

  testWidgets('typing a set writes it through without any confirmation', (
    tester,
  ) async {
    final db = await _pumpDetailView(tester);

    await tester.enterText(_repsField('Set 1'), '12');
    // Past the debounce, with nothing tapped and nothing dismissed.
    await tester.pump(const Duration(milliseconds: 800));

    final stored = await _storedExercise(tester, db);
    expect(stored?.isCustomPrescription, isTrue);
    expect(stored?.setPrescriptions.first.top.reps, 12);
    expect(
      stored?.setPrescriptions.map((p) => p.top.reps),
      [12, 8, 8],
      reason: 'the first set is adjustable on its own, not in lockstep',
    );
  });

  testWidgets('a number past the range is clamped, and the field says so', (
    tester,
  ) async {
    final db = await _pumpDetailView(tester);

    await tester.enterText(_repsField('Set 1'), '999');
    // Leaving the field commits immediately rather than waiting out the pause.
    await tester.tap(_repsField('Set 2'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('$kMaxReps'),
      findsOneWidget,
      reason: 'the field should show what was stored, not what was rejected',
    );
    final stored = await _storedExercise(tester, db);
    expect(stored?.setPrescriptions.first.top.reps, kMaxReps);
  });

  testWidgets('sets are added and removed one at a time', (tester) async {
    final db = await _pumpDetailView(tester);

    await tester.tap(find.text('Add set'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Set 4'), findsOneWidget);
    expect((await _storedExercise(tester, db))?.setPrescriptions, hasLength(4));

    await tester.tap(find.byTooltip('Remove set').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Set 4'), findsNothing);
    expect((await _storedExercise(tester, db))?.setPrescriptions, hasLength(3));
  });

  testWidgets('a drop hangs off the set it belongs to', (tester) async {
    final db = await _pumpDetailView(tester);

    await tester.tap(find.byTooltip('Add a drop to this set').first);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Drop'), findsOneWidget);
    final stored = await _storedExercise(tester, db);
    expect(stored?.setPrescriptions.first.hasDrops, isTrue);
    expect(
      stored?.setPrescriptions.length,
      3,
      reason: 'a drop is part of its set, not a set of its own',
    );
  });

  testWidgets('opening and closing the card leaves the weight untouched', (
    tester,
  ) async {
    // 60 kg is shown as 132.3 lb and parses back as 60.01 — fields that wrote
    // what they parsed would walk every set every time it was viewed.
    final db = await _pumpDetailView(tester);

    await tester.tap(find.byTooltip('Close'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }

    final stored = await _storedExercise(tester, db);
    expect(stored?.targetWeightKg, 60);
    expect(
      stored?.isCustomPrescription,
      isFalse,
      reason: 'merely looking at a movement must not rewrite it',
    );
  });

  testWidgets('clearing the weight stores a bodyweight set rather than failing',
      (tester) async {
    final db = await _pumpDetailView(tester);

    await tester.enterText(_weightField('Set 1'), '');
    await tester.pump(const Duration(milliseconds: 800));

    final stored = await _storedExercise(tester, db);
    expect(stored?.setPrescriptions.first.top.weightKg, 0);
  });

  // A set row packs a caption, two number fields with suffixes and two icon
  // buttons across one line; a phone is the width where that stops fitting,
  // and an overflow throws here rather than striping the card in the hand.
  testWidgets('a set row fits a phone', (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpDetailView(tester);

    await tester.tap(find.byTooltip('Add a drop to this set').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Drop'), findsOneWidget);
  });

  testWidgets('the per-day override is only offered where there is a day to '
      'deviate on', (tester) async {
    await _pumpDetailView(tester);
    expect(
      find.byType(Switch),
      findsNothing,
      reason: 'opened from the library there is no one placement to bend',
    );
  });

  testWidgets('toggling "only this day" moves the edit onto the placement', (
    tester,
  ) async {
    final db = await _pumpDetailView(tester, fromPlanEntry: true);

    expect(find.byType(Switch), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('Applies to this day only — other days keep the movement’s '
          'sets'),
      findsOneWidget,
    );
    // Turning it on seeds the override from what was already on screen, so
    // the numbers do not jump under the toggle.
    expect(
      (await _storedEntry(tester, db))?.setPrescriptions.map((p) => p.top.reps),
      [8, 8, 8],
    );

    await tester.enterText(_repsField('Set 1'), '5');
    await tester.pump(const Duration(milliseconds: 800));

    expect(
      (await _storedEntry(tester, db))?.setPrescriptions.first.top.reps,
      5,
    );
    final exercise = await _storedExercise(tester, db);
    expect(
      exercise?.isCustomPrescription,
      isFalse,
      reason: 'every other day this movement is planned on is left alone',
    );
  });

  testWidgets('turning the override back off restores the movement\'s sets', (
    tester,
  ) async {
    final db = await _pumpDetailView(tester, fromPlanEntry: true);

    await tester.tap(find.byType(Switch));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(_repsField('Set 1'), '5');
    await tester.pump(const Duration(milliseconds: 800));

    await tester.tap(find.byType(Switch));
    await tester.pump(const Duration(milliseconds: 100));

    expect((await _storedEntry(tester, db))?.hasCustomSets, isFalse);
    // The fields are rebuilt from the movement's recipe, not left showing the
    // day's — otherwise the next keystroke would write the 5 back out.
    expect(find.text('5'), findsNothing);
    expect(
      find.text('Applies to every day this movement is planned on',),
      findsOneWidget,
    );
  });
}
