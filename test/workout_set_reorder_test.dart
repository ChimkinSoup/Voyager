import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/workout_prescription_editor.dart';

/// Dragging a set past its neighbour has to *swap* them, not drop it one slot
/// short: `ReorderableListView` reports the two directions differently, and
/// getting that wrong is invisible until the workout materialises in the wrong
/// order.
void main() {
  testWidgets('a set dragged below its neighbour comes back in that order', (
    tester,
  ) async {
    final now = utcNow();
    final exercise = Exercise(
      id: 'bench',
      name: 'Bench Press',
      prescriptionMode: WorkoutPrescriptionMode.custom,
      setPrescriptions: const [
        SetPrescription(segments: [SetSegment(weightKg: 100, reps: 5)]),
        SetPrescription(segments: [SetSegment(weightKg: 80, reps: 10)]),
      ],
      createdAt: now,
      updatedAt: now,
    );

    // Tall window on purpose: the sheet's wheels eat most of a default 600px
    // view, and `ReorderableListView.builder` only builds the rows that fit —
    // with the second set unbuilt there is nothing to drag past.
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    ExercisePrescriptionResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                result = await showExercisePrescriptionEditor(
                  context,
                  exercise: exercise,
                  unit: WeightUnit.kg,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final handles = find.byIcon(PhosphorIconsRegular.dotsSixVertical);
    expect(handles, findsNWidgets(2));
    final firstCardTop = tester.getTopLeft(handles.at(0)).dy;
    final secondCardTop = tester.getTopLeft(handles.at(1)).dy;

    // One card's worth of travel, plus a nudge past the midpoint so the list
    // has committed to the swap rather than hovering on the boundary.
    final travel = secondCardTop - firstCardTop + 20;
    final gesture = await tester.startGesture(tester.getCenter(handles.at(0)));
    await tester.pump(const Duration(milliseconds: 100));
    // Walked down in steps rather than teleported: the list decides the swap
    // from where the dragged row currently overlaps, and a single jump past
    // the whole card can skip the frame that would have registered it.
    for (var i = 1; i <= 5; i++) {
      await gesture.moveBy(Offset(0, travel / 5));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect([for (final p in result!.prescriptions) p.top.reps], [10, 5]);
  });
}
