// Schema 120 gives a placement its own set recipe again, so one day can be
// trained differently from every other day the movement appears on. An
// existing database has placements written without the column, and the upgrade
// has to leave every one of them following the movement rather than arriving
// with an empty override that overrules it.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/workout_models.dart';

const _exerciseId = 'bench';
const _entryId = 'monday-bench';

/// Rewinds a schema-120 database to look like a schema-119 one: drops the
/// column the upgrade adds and resets user_version, so reopening runs the real
/// onUpgrade rather than a hand-written approximation of it.
Future<void> _rewindToSchema119(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.customStatement(
    'ALTER TABLE workout_plan_entries_table DROP COLUMN set_prescriptions_json',
  );
  await db.customStatement('PRAGMA user_version = 119');
  await db.close();
}

Future<void> _seed(File file) async {
  final now = utcNow();
  final db = AppDatabase(NativeDatabase(file));
  final repository = DriftWorkoutRepository(db);
  await repository.upsertExercise(
    Exercise(
      id: _exerciseId,
      name: 'Bench Press',
      targetSets: 3,
      targetReps: 8,
      targetWeightKg: 60,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await repository.upsertPlanEntry(
    WorkoutPlanEntry(
      id: _entryId,
      planId: 'weekly',
      dayIndex: 1,
      exerciseId: _exerciseId,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_entry_sets_migration');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('a placement written before v120 upgrades to following its movement',
      () async {
    await _seed(file);
    await _rewindToSchema119(file);

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final repository = DriftWorkoutRepository(db);

    final entry = (await repository.getPlanEntry(_entryId))!;
    expect(
      entry.hasCustomSets,
      isFalse,
      reason: 'nothing existing may arrive already overriding its movement',
    );

    final exercise = (await repository.getExercise(_exerciseId))!;
    expect(
      plannedPrescriptions(exercise, entry).map((p) => p.top.reps),
      [8, 8, 8],
      reason: 'the migrated placement still reads the movement’s recipe',
    );
  });

  test('an override written after the upgrade survives a reopen', () async {
    await _seed(file);
    await _rewindToSchema119(file);

    final upgraded = AppDatabase(NativeDatabase(file));
    final entry = (await DriftWorkoutRepository(
      upgraded,
    ).getPlanEntry(_entryId))!;
    await DriftWorkoutRepository(upgraded).upsertPlanEntry(
      entry.copyWith(
        setPrescriptions: const [
          SetPrescription(segments: [SetSegment(weightKg: 100, reps: 5)]),
        ],
      ),
    );
    await upgraded.close();

    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    final stored = (await DriftWorkoutRepository(
      reopened,
    ).getPlanEntry(_entryId))!;
    expect(stored.hasCustomSets, isTrue);
    expect(stored.setPrescriptions.single.top.reps, 5);
  });
}
