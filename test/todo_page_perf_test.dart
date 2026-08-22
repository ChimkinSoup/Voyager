@Tags(['manual'])
library;

// Benchmark harness for the To-Do page with a large list.
//
//   flutter test --run-skipped test/todo_page_perf_test.dart
//
// Tagged `manual` so it doesn't run in the normal suite: it reports a
// measurement rather than asserting a threshold.
//
// It counts work done, not wall-clock time. Timing the same interaction on a
// desktop under load swings by 3x between runs — enough to hide a real 2x
// regression — whereas these counts are exact, reproducible, and are what the
// optimisation work here is actually moving.
//
// Four interactions are measured:
//   * `rebuild` - one full `_TodoPageState.build`, i.e. what any setState on
//                 the page costs.
//   * `hover`   - moving the mouse from one row to the next. This is the one
//                 that dominates in practice: it fires for every row the
//                 pointer crosses while skimming, and once per frame all the
//                 way through a scroll, since rows slide under a stationary
//                 cursor.
//   * `scrollframe` - one frame of a wheel scroll with the pointer resting
//                 over the rows.
//   * `panel reveal` - one frame of the edit panel opening. This one counts
//                 *layouts*, not rebuilds: the reveal deliberately never
//                 rebuilds the task list, and animating the list's width is
//                 purely a relayout cost that rebuild counts cannot see.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/shell/reveal_request.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';
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

/// Render objects laid out by one steady-state frame of the edit panel's
/// reveal animation.
///
/// Deliberately counts *layouts*, not rebuilds like everything else in this
/// file: the panel reveal never rebuilds the task list (its subtree is passed
/// to `AnimatedBuilder` as `child`, so it is built once per page build), and
/// the entire question this measures is what animating the list's width
/// instead of snapping it costs in relayout — which rebuild counts cannot
/// see at all.
///
/// `RenderParagraph` is broken out separately because it is the expensive
/// part: changing a row's maxWidth invalidates its cached paragraph and
/// forces the text to be re-shaped, whereas most other render objects just
/// re-run a trivial performLayout.
Future<({int total, int paragraphs})> _panelFrameLayouts(
  WidgetTester tester,
) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(TodoPage)),
    listen: false,
  );
  // Opens the panel the way the notification popover's "Show in To-Do" does.
  // Only the id and listId have to match a seeded row — the page looks the
  // real task up by id (see _panelTaskFor).
  container.read(revealRequestProvider.notifier).state = RevealRequest.task(
    TodoTask(
      id: 'task-00000',
      listId: todoHarnessListId,
      title: 'Task 0',
      sortOrder: 1000000,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ),
  );
  await tester.pump();
  // The whole benchmark is meaningless if the panel never opened. Asserted
  // without settling first: settling would finish the reveal, and every frame
  // sampled below would be of a stationary animation.
  expect(find.byType(TodoEditPanel), findsOneWidget);

  var total = 0;
  var paragraphs = 0;
  final samples = <({int total, int paragraphs})>[];
  final trace = <int>[];
  final byType = <String, int>{};
  final originalPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message == null || !message.startsWith('Laying out')) return;
    total++;
    if (message.contains('RenderParagraph')) paragraphs++;
    final match = RegExp(r'(Render\w+)#').firstMatch(message);
    if (match != null) {
      byType[match.group(1)!] = (byType[match.group(1)!] ?? 0) + 1;
    }
  };
  debugPrintLayouts = true;
  try {
    // Frames 0-2 still carry the open's own full rebuild; sample the steady
    // state after that, for the rest of the 270ms reveal.
    for (var i = 0; i < 16; i++) {
      total = 0;
      paragraphs = 0;
      await tester.pump(const Duration(milliseconds: 16));
      if (i >= 3) samples.add((total: total, paragraphs: paragraphs));
      trace.add(total);
    }
  } finally {
    debugPrintLayouts = false;
    debugPrint = originalPrint;
  }

  final top = byType.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  debugPrint('[perf]   per-frame layout trace: $trace');
  debugPrint(
    '[perf]   layouts by type (all frames): '
    '${top.take(6).map((e) => '${e.key}=${e.value}').join('  ')}',
  );
  // Only the frames where the reveal actually moved. The spring overshoots
  // past 1.0 partway through and _panelInset clamps there, so the inset stops
  // changing for a stretch near the end and those frames cost nothing — a
  // plain median over the whole window would report that tail, not the cost
  // of animating.
  final moving = [for (final s in samples) if (s.total > 10) s];
  if (moving.isEmpty) return (total: 0, paragraphs: 0);
  moving.sort((a, b) => a.total.compareTo(b.total));
  return moving[moving.length ~/ 2];
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
  // Isolates the edit panel's reveal animation: what one steady-state frame
  // of it costs in layout, on a list big enough that the cacheExtent is
  // holding several screens of rows mounted.
  for (final size in const [(active: 20, done: 4), (active: 200, done: 300)]) {
    testWidgets(
      'panel reveal - active=${size.active} completed=${size.done}',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await pumpTodoPage(tester, active: size.active, done: size.done);
        final frame = await _panelFrameLayouts(tester);
        debugPrint(
          '[perf] panel reveal active=${size.active} completed=${size.done} '
          'layouts/frame=${frame.total}  paragraphs/frame=${frame.paragraphs}',
        );
      },
    );
  }
}
