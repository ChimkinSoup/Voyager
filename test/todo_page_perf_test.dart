@Tags(['manual'])
library;

// Benchmark harness for the To-Do page with a large list.
//
//   flutter test --run-skipped test/todo_page_perf_test.dart
//
// Tagged `manual` so it doesn't run in the normal suite: it reports a
// measurement rather than asserting a threshold.
//
// It counts widgets rebuilt, not wall-clock time. Timing the same interaction
// on a desktop under load swings by 3x between runs — enough to hide a real
// 2x regression — whereas the rebuild count is exact, reproducible, and is
// what the optimisation work here is actually moving.
//
// Two interactions are measured:
//   * `rebuild` - one full `_TodoPageState.build`, i.e. what any setState on
//                 the page costs.
//   * `hover`   - moving the mouse from one row to the next. This is the one
//                 that dominates in practice: it fires for every row the
//                 pointer crosses while skimming, and once per frame all the
//                 way through a scroll, since rows slide under a stationary
//                 cursor.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/todo/todo_page.dart';

import 'support/todo_page_harness.dart';

Future<int> _countRebuilds(Future<void> Function() action) async {
  var count = 0;
  debugOnRebuildDirtyWidget = (_, _) => count++;
  try {
    await action();
  } finally {
    debugOnRebuildDirtyWidget = null;
  }
  return count;
}

/// Widgets rebuilt by one full page rebuild.
Future<int> _rebuildCost(WidgetTester tester) async {
  final root = tester.binding.rootElement!;
  final pipeline = tester.binding.rootPipelineOwner;
  final element = find.byType(TodoPage).evaluate().first;

  void frame() {
    element.markNeedsBuild();
    tester.binding.buildOwner!.buildScope(root);
    pipeline.flushLayout();
    pipeline.flushCompositingBits();
    pipeline.flushPaint();
    tester.binding.buildOwner!.finalizeTree();
  }

  // Warm up, so first-build-only work isn't counted as steady state.
  for (var i = 0; i < 3; i++) {
    frame();
  }
  return _countRebuilds(() async => frame());
}

/// Widgets rebuilt by moving the mouse from one row to the next.
Future<int> _hoverStepCost(WidgetTester tester) async {
  final titles = find.textContaining('Task ').evaluate().toList();
  expect(titles.length, greaterThan(4));
  final centers = <Offset>[
    for (final element in titles.take(6))
      tester.getCenter(find.byWidget(element.widget)),
  ];

  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(centers.first));
  await tester.pump();
  await tester.pump();

  final counts = <int>[];
  for (var i = 1; i < centers.length; i++) {
    counts.add(
      await _countRebuilds(() async {
        await tester.sendEventToBinding(pointer.hover(centers[i]));
        await tester.pump();
        // Clearing hover is deliberately deferred one frame, so a second
        // frame is part of the real cost of one row step.
        await tester.pump();
      }),
    );
  }
  counts.sort();
  return counts[counts.length ~/ 2];
}

/// Widgets rebuilt per frame while wheel-scrolling the list with the pointer
/// resting over the rows. Rows sliding under a stationary cursor produce a
/// hover enter/exit every frame, so this is the worst-case sustained load the
/// page ever sees. (A press-and-drag over the active list starts a
/// drag-reorder rather than a scroll, so it can't be used here.)
Future<int> _scrollFrameCost(WidgetTester tester) async {
  final at = tester.getCenter(find.byType(CustomScrollView));
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(at));
  await tester.pump();

  final counts = <int>[];
  for (var i = 0; i < 12; i++) {
    counts.add(
      await _countRebuilds(() async {
        await tester.sendEventToBinding(
          pointer.scroll(const Offset(0, 24)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }),
    );
  }
  counts.sort();
  return counts[counts.length ~/ 2];
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  // The last two hold `active` fixed and vary only the completed count, so
  // the difference between them is exactly what a collapsed completed section
  // costs. It should be nothing — collapsing takes the whole SliverList out of
  // the tree, so those rows are never built, laid out, or painted.
  for (final size in const [
    (active: 8, done: 4),
    (active: 200, done: 300),
    (active: 20, done: 4),
    (active: 20, done: 1500),
  ]) {
    final label =
        'active=${size.active.toString().padLeft(3)} '
        'completed=${size.done.toString().padLeft(4)}';

    for (final expanded in const [true, false]) {
      final state = expanded ? 'expanded ' : 'collapsed';
      testWidgets('completed $state - $label', (tester) async {
        await pumpTodoPage(
          tester,
          active: size.active,
          done: size.done,
          completedExpanded: expanded,
        );
        final rebuild = await _rebuildCost(tester);
        final hover = await _hoverStepCost(tester);
        final scroll = await _scrollFrameCost(tester);
        debugPrint(
          '[perf] $label $state '
          'rebuild=$rebuild  hover=$hover  scrollframe=$scroll',
        );
      });
    }
  }
}
