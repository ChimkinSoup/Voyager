// Behavioural guards for the parts of the To-Do page that were reworked for
// performance: row hover is now driven by a notifier the page never rebuilds
// for, and right-click menu entries are built when the menu opens rather than
// on every row build. Both are invisible when they work and obvious when they
// don't, so they are pinned here.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';

import 'support/todo_page_harness.dart';

/// The background colour the row containing [title] is currently painting.
Color? _rowColor(WidgetTester tester, String title) {
  final container = tester.widget<AnimatedContainer>(
    find
        .ancestor(
          of: find.text(title),
          matching: find.byType(AnimatedContainer),
        )
        .last,
  );
  return (container.decoration as BoxDecoration?)?.color;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('row highlights on hover and clears when the pointer leaves', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 6, done: 2);

    final context = tester.element(find.text('Task 0'));
    final hoverColor = VoyagerListItemSurface.hoverColor(context);

    expect(_rowColor(tester, 'Task 0'), isNot(hoverColor));

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('Task 0'))),
    );
    await tester.pumpAndSettle();
    expect(
      _rowColor(tester, 'Task 0'),
      hoverColor,
      reason: 'hovered row should paint the hover surface',
    );

    // Moving to another row hands the highlight over: exactly one row is ever
    // highlighted, and the row left behind clears (its clear is deferred a
    // frame on purpose, hence pumpAndSettle rather than a single pump).
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('Task 2'))),
    );
    await tester.pumpAndSettle();
    expect(_rowColor(tester, 'Task 0'), isNot(hoverColor));
    expect(_rowColor(tester, 'Task 2'), hoverColor);

    // Leaving the list entirely clears it.
    await tester.sendEventToBinding(pointer.hover(const Offset(5, 5)));
    await tester.pumpAndSettle();
    expect(_rowColor(tester, 'Task 2'), isNot(hoverColor));
  });

  testWidgets('right-click opens the row menu with its entries', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 6, done: 2);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Task 1')),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    // Built by the itemsBuilder at open time — if that were skipped the menu
    // would come up empty.
    expect(find.text('Star'), findsOneWidget);
    expect(find.text('Send to bottom'), findsOneWidget);
    expect(find.text('Move task to'), findsOneWidget);
    expect(find.text('Delete task'), findsOneWidget);
  });

  testWidgets('collapsing the completed section hides its rows', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 3, done: 4, completedExpanded: true);
    expect(find.text('Completed (4)'), findsOneWidget);
    expect(find.text('Task 4'), findsOneWidget);

    await tester.tap(find.text('Completed (4)'));
    await tester.pumpAndSettle();

    expect(find.text('Completed (4)'), findsOneWidget);
    expect(
      find.text('Task 4'),
      findsNothing,
      reason: 'collapsed completed rows should not be built at all',
    );
    expect(find.text('Task 0'), findsOneWidget);
  });
}
