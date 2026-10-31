// Un-ticking a completed task holds the view still: the rows on screen above
// it stay put while the gap it leaves closes.
//
// Two ways this used to slide the whole view by about a row:
//  * scrolled to the bottom, holding the view over the row regrowing at the
//    top of the active section needed the offset past the list's end, and the
//    physics sprang it back;
//  * mid-way down a long completed section, the growth was read off
//    `maxScrollExtent`, which is mostly an estimate for rows that aren't laid
//    out — it moved by more than two rows for the one row that moved.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/todo_models.dart';

import 'narrow_window_harness.dart';
import 'support/todo_page_harness.dart';

/// Taps [tapTitle]'s checkbox and checks [anchorTitle] doesn't move on any
/// frame of the toggle or after its write lands.
Future<void> _uncompleteHoldingStill(
  WidgetTester tester, {
  required String tapTitle,
  required String anchorTitle,
}) async {
  double anchorTop() => tester.getRect(find.text(anchorTitle)).top;
  final before = anchorTop();
  final row = tester.getRect(find.text(tapTitle));
  await tester.tapAt(Offset(row.left - 24, row.center.dy));
  for (var frame = 0; frame < 60; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    expect(anchorTop(), before, reason: 'frame $frame');
  }
  // Past the deferred completion write and the sync it kicks off.
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  expect(anchorTop(), before);
}

/// Lets the sync held back while the list scrolled run, which
/// ScrollActivityGate times on the real clock.
Future<void> _settleAfterScrolling(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 700)),
  );
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('uncompleting at the bottom of the list keeps the view still', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpTodoPage(tester, active: 20, done: 10);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    final endTop = tester.getRect(find.text('Task 29')).top;

    await _uncompleteHoldingStill(
      tester,
      tapTitle: 'Task 26',
      anchorTitle: 'Task 15',
    );

    // The blank left at the bottom is given back on the way up, not kept.
    position.jumpTo(0);
    await tester.pump();
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(tester.getRect(find.text('Task 29')).top, endTop);
    await _settleAfterScrolling(tester);
  });

  testWidgets(
    'uncompleting mid-way down a long completed section keeps the view still',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await loadRealFonts(tester);

      // A list shaped like a real one: a few active tasks, the first dated,
      // above a long history of completions, newest first.
      final base = DateTime.utc(2026, 10, 1);
      await pumpTodoPage(
        tester,
        active: 0,
        done: 0,
        theme: VoyagerTheme.dark(),
        seedExtra: (repo) async {
          for (var i = 0; i < 120; i++) {
            final done = i >= 11;
            await repo.upsertTask(
              TodoTask(
                id: 'task-${i.toString().padLeft(5, '0')}',
                listId: todoHarnessListId,
                title: 'Task $i',
                notes: i % 11 == 0 ? 'a note' : null,
                completed: done,
                completedAt: done ? base.subtract(Duration(minutes: i)) : null,
                dueDate: i == 0 ? DateTime.utc(2026, 10, 29) : null,
                sortOrder: 1000000 + i,
                createdAt: base.add(Duration(seconds: i)),
                updatedAt: base,
              ),
            );
          }
        },
      );

      // Wheeled there rather than jumped, so the list has laid out the rows
      // on the way down as it would for a real scroll.
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byType(Scrollable).first)),
      );
      while (position.pixels < 1499) {
        final step = (1500 - position.pixels).clamp(0.0, 100.0);
        await tester.sendEventToBinding(pointer.scroll(Offset(0, step)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await _settleAfterScrolling(tester);

      await _uncompleteHoldingStill(
        tester,
        tapTitle: 'Task 40',
        anchorTitle: 'Task 37',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  // The anchor follows the estimate for the rows of an active list too long to
  // be built, so the view has to hold while that estimate moves.
  testWidgets(
    'uncompleting below a long active list keeps the view still',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await loadRealFonts(tester);

      final base = DateTime.utc(2026, 10, 1);
      await pumpTodoPage(
        tester,
        active: 0,
        done: 0,
        theme: VoyagerTheme.dark(),
        seedExtra: (repo) async {
          for (var i = 0; i < 400; i++) {
            final done = i >= 300;
            await repo.upsertTask(
              TodoTask(
                id: 'task-${i.toString().padLeft(5, '0')}',
                listId: todoHarnessListId,
                title: 'Task $i',
                // Uneven rows, for the estimate to depend on which are built.
                notes: i % 3 == 0 ? 'a note' : null,
                dueDate: i % 7 == 0 ? DateTime.utc(2026, 10, 29) : null,
                completed: done,
                completedAt: done ? base.subtract(Duration(minutes: i)) : null,
                sortOrder: 1000000 + i,
                createdAt: base.add(Duration(seconds: i)),
                updatedAt: base,
              ),
            );
          }
        },
      );

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byType(Scrollable).first)),
      );
      // Down until a completed task is on screen, well below the fold's top.
      while (find.text('Task 305').evaluate().isEmpty ||
          tester.getRect(find.text('Task 305')).top > 700) {
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await _settleAfterScrolling(tester);

      await _uncompleteHoldingStill(
        tester,
        tapTitle: 'Task 305',
        anchorTitle: 'Task 302',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('a shrink while armed never takes the offset past the top', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpTodoPage(tester, active: 6, done: 12);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(20);
    await tester.pump();

    Future<void> tapCheckbox(String title) async {
      final row = tester.getRect(find.text(title));
      await tester.tapAt(Offset(row.left - 24, row.center.dy));
    }

    // One active row leaves, collapsing above the anchor, while an un-tick
    // has the view armed.
    await tapCheckbox('Task 1');
    await tester.pump(const Duration(milliseconds: 16));
    await tapCheckbox('Task 7');
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(position.pixels, greaterThanOrEqualTo(0), reason: 'frame $frame');
    }
    await _settleAfterScrolling(tester);
  });
}
