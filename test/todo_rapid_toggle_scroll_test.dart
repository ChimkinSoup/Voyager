// Ticking the top task of a long list several times quickly used to throw the
// list far down: a click landing on a row still collapsing un-ticks it, which
// arms the page's stable-view scroll correction, and that correction re-added
// the same growth on every layout retry until the viewport gave up after 20
// cycles (BUG-068).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/todo_page_harness.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets(
    'a burst of clicks on the top checkbox keeps the list at the top',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpTodoPage(tester, active: 200, done: 0);

      // The leftmost control on the row; tapped by position, as a real burst of
      // clicks lands on whatever row is under the pointer at that moment.
      final topRow = tester.getRect(find.text('Task 0'));
      final topCheckbox = Offset(topRow.left - 24, topRow.center.dy);
      for (var click = 0; click < 10; click++) {
        await tester.tapAt(topCheckbox);
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(tester.takeException(), isNull);
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scrollable.position.pixels, lessThan(200));
    },
  );
}
