import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/workout_models.dart';

Exercise _bench({
  WorkoutPrescriptionMode mode = WorkoutPrescriptionMode.custom,
  List<SetPrescription> prescriptions = const [
    SetPrescription(
      segments: [
        SetSegment(weightKg: 100, reps: 8),
        SetSegment(weightKg: 80, reps: 8),
      ],
    ),
  ],
  int version = 0,
}) {
  final now = utcNow();
  return Exercise(
    id: 'bench',
    name: 'Bench Press',
    prescriptionMode: mode,
    setPrescriptions: prescriptions,
    createdAt: now,
    updatedAt: now,
    version: version,
  );
}

void main() {
  test('exercise firestore round-trip keeps custom drops', () {
    final exercise = _bench();

    final remote = exerciseToFirestore(exercise);
    final merged = mergeExerciseFromRemote(remote, exercise.id);
    expect(merged.prescriptionMode, WorkoutPrescriptionMode.custom);
    expect(merged.setPrescriptions.single.hasDrops, isTrue);
    expect(merged.setPrescriptions.single.drops.single.weightKg, 80);
  });

  test('legacy exercise payloads stay inherit with empty prescriptions', () {
    final merged = mergeExerciseFromRemote({
      'name': 'Bench Press',
      'sortOrder': 0,
      'createdAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': '2026-01-01T00:00:00.000Z',
      'version': 1,
    }, 'legacy');
    expect(merged.prescriptionMode, WorkoutPrescriptionMode.inherit);
    expect(merged.setPrescriptions, isEmpty);
  });

  test('a payload with no prescription keys leaves the local recipe alone', () {
    // What a build that predates recipes-on-the-movement uploads when it
    // merely renames the lift. Reading its silence as "inherit, no sets" would
    // wipe the recipe this device has.
    final local = _bench(version: 1);

    final merged = mergeExerciseFromRemote({
      'name': 'Bench',
      'sortOrder': 3,
      'createdAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': '2099-01-01T00:00:00.000Z',
      'version': 5,
    }, local.id, local: local);

    expect(merged.sortOrder, 3);
    expect(merged.prescriptionMode, WorkoutPrescriptionMode.custom);
    expect(merged.setPrescriptions.single.drops.single.weightKg, 80);
  });

  test('an explicit clear to inherit still lands', () {
    final local = _bench(
      prescriptions: const [
        SetPrescription(segments: [SetSegment(weightKg: 100, reps: 8)]),
      ],
      version: 1,
    );

    final merged = mergeExerciseFromRemote({
      'name': 'Bench Press',
      'sortOrder': 0,
      'prescriptionMode': 'inherit',
      'setPrescriptions': const <Map<String, dynamic>>[],
      'createdAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': '2099-01-01T00:00:00.000Z',
      'version': 5,
    }, local.id, local: local);

    expect(merged.prescriptionMode, WorkoutPrescriptionMode.inherit);
    expect(merged.setPrescriptions, isEmpty);
  });

  test('workout set log firestore round-trip keeps drop segments', () {
    final now = utcNow();
    final log = WorkoutSetLog(
      id: 'l1',
      sessionId: 's1',
      exerciseId: 'bench',
      exerciseOrder: 0,
      setIndex: 0,
      weightKg: 100,
      reps: 8,
      plannedWeightKg: 100,
      plannedReps: 8,
      dropSegments: const [SetSegment(weightKg: 80, reps: 8)],
      plannedDropSegments: const [SetSegment(weightKg: 80, reps: 8)],
      completed: true,
      completedAt: now,
      createdAt: now,
      updatedAt: now,
    );

    final remote = workoutSetLogToFirestore(log);
    final merged = mergeWorkoutSetLogFromRemote(remote, log.id);
    expect(merged.dropSegments, hasLength(1));
    expect(merged.plannedDropSegments.single.reps, 8);
    expect(merged.volumeKg, 100 * 8 + 80 * 8);
  });
}
