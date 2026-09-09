// The metadata line under a task title carries, in order, its due date, a
// note icon, its subtask count and — added here — an image icon. Only the
// last is guarded in this file; the rest are covered by the row's own layout
// tests.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';

import 'support/todo_page_harness.dart';

/// Stands in for the reference query, so these tests need no media stack at
/// all — the row only ever asks "does this id have images".
Override withImagesOn(Set<String> taskIds) {
  return mediaOwnersWithImagesProvider(
    FirestoreCollections.todoTasks,
  ).overrideWith((ref) async => taskIds);
}

Finder imageIcon() => find.byIcon(PhosphorIconsRegular.image);

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('no icon when nothing has an image', (tester) async {
    await pumpTodoPage(
      tester,
      active: 3,
      done: 0,
      extraOverrides: [withImagesOn(const {})],
    );

    expect(imageIcon(), findsNothing);
  });

  testWidgets('an icon appears under the task that has one, and only it', (
    tester,
  ) async {
    await pumpTodoPage(
      tester,
      active: 3,
      done: 0,
      extraOverrides: [withImagesOn({'task-00001'})],
    );

    expect(imageIcon(), findsOneWidget);

    // Under the right title, not just somewhere on the page.
    final iconCentre = tester.getCenter(imageIcon());
    final taskOne = tester.getCenter(find.text('Task 1'));
    final taskZero = tester.getCenter(find.text('Task 0'));
    expect(
      (iconCentre.dy - taskOne.dy).abs(),
      lessThan((iconCentre.dy - taskZero.dy).abs()),
      reason: 'the icon should sit under Task 1, not Task 0',
    );
  });

  testWidgets('the image icon trails the note icon', (tester) async {
    await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      withNotes: {'task-00000'},
      extraOverrides: [withImagesOn({'task-00000'})],
    );

    final noteIcon = find.byIcon(PhosphorIconsRegular.note);
    expect(noteIcon, findsOneWidget);
    expect(imageIcon(), findsOneWidget);
    expect(
      tester.getCenter(imageIcon()).dx,
      greaterThan(tester.getCenter(noteIcon).dx),
      reason: 'the order is time · notes · subtasks · images',
    );
    expect(
      tester.getCenter(imageIcon()).dy,
      closeTo(tester.getCenter(noteIcon).dy, 1),
      reason: 'both sit on the same metadata line',
    );
  });
}
