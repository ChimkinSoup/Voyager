import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/workout_models.dart';

void main() {
  test('workout plan entry firestore round-trip keeps custom drops', () {
    final now = utcNow();
    final entry = WorkoutPlanEntry(
      id: 'e1',
      planId: 'p1',
      dayIndex: 2,
      exerciseId: 'bench',
      prescriptionMode: WorkoutPrescriptionMode.custom,
      setPrescriptions: const [
        SetPrescription(
          segments: [
            SetSegment(weightKg: 100, reps: 8),
            SetSegment(weightKg: 80, reps: 8),
          ],
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );

    final remote = workoutPlanEntryToFirestore(entry);
    final merged = mergeWorkoutPlanEntryFromRemote(remote, entry.id);
    expect(merged.prescriptionMode, WorkoutPrescriptionMode.custom);
    expect(merged.setPrescriptions.single.hasDrops, isTrue);
    expect(merged.setPrescriptions.single.drops.single.weightKg, 80);
  });

  test('legacy plan entry payloads stay inherit with empty prescriptions', () {
    final merged = mergeWorkoutPlanEntryFromRemote({
      'planId': 'p',
      'dayIndex': 0,
      'exerciseId': 'e',
      'sortOrder': 0,
      'createdAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': '2026-01-01T00:00:00.000Z',
      'version': 1,
    }, 'legacy');
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
