@Tags(['manual'])
library;

// Benchmark harness for the expanded LeetCode activity view.
//
//   flutter test --run-skipped test/leetcode_activity_perf_test.dart
//
// Counts widgets rebuilt per pointer move rather than wall clock, for the
// reason test/todo_page_perf_test.dart gives: timings on this desktop swing by
// more than the regressions being hunted.
//
// Both panes drive their hover off the pointer, so both pay on every mouse
// move — which is the whole interaction, since the bubble exists to be swept
// across the data. What each number caught:
//
//   * calendar - hover used to live in State, so one pointer event rebuilt the
//                whole year: twelve month tiles of forty-two day cells, ~1900
//                widgets. It now sits in a ValueNotifier and only the bubble
//                rebuilds.
//   * settle   - frames fl_chart keeps animating after the pointer has already
//                stopped. It implicitly lerps every LineChartData change over
//                150ms, the hover line's x included, so the indicator crawled
//                after the cursor and re-lerped all three series every frame
//                of the crawl.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/leetcode/leetcode_activity_card.dart';

final _now = DateTime.utc(2026, 8, 15, 12);

class _FixedSettings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

LeetCodeProblem _problem(String id, LeetCodeDifficulty difficulty, int daysAgo) {
  final solved = _now.subtract(Duration(days: daysAgo));
  return LeetCodeProblem(
    id: id,
    createdAt: solved,
    updatedAt: solved,
    title: 'Problem $id',
    difficulty: difficulty,
    solvedAt: solved,
  );
}

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

/// Opens the expanded view over a year's worth of solving.
Future<void> _openExpanded(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        leetcodeProblemsProvider.overrideWith(
          (ref) async => [
            for (var i = 0; i < 120; i++)
              _problem('p$i', LeetCodeDifficulty.values[i % 3], i * 2),
          ],
        ),
        settingsProvider.overrideWith(_FixedSettings.new),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(width: 280, child: LeetCodeActivityCard()),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.byType(LeetCodeActivityCard));
  await _settle(tester);
}

/// Runs an expand or a pane crossfade to completion a frame at a time.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('hover cost', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _openExpanded(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    // --- sparkline ---
    final plot = tester.getRect(find.text('Problems solved per day'));
    final plotY = plot.center.dy + 200;
    await mouse.moveTo(Offset(plot.left + 100, plotY));
    await tester.pump();

    final sparkline = await _countRebuilds(() async {
      await mouse.moveTo(Offset(plot.left + 140, plotY));
      await tester.pump();
    });

    var settleFrames = 0;
    while (tester.binding.hasScheduledFrame && settleFrames < 60) {
      await tester.pump(const Duration(milliseconds: 16));
      settleFrames++;
    }

    // --- calendar ---
    await tester.tap(find.text('Calendar'));
    await _settle(tester);

    final january = find
        .ancestor(of: find.text('January'), matching: find.byType(Card))
        .first;
    final day = tester.getCenter(
      find.descendant(of: january, matching: find.text('12')),
    );
    await mouse.moveTo(day);
    await tester.pump();

    final calendar = await _countRebuilds(() async {
      await mouse.moveTo(day + const Offset(1, 0));
      await tester.pump();
    });

    debugPrint('sparkline hover step:  $sparkline rebuilds');
    debugPrint('sparkline settle:      $settleFrames frames after the stop');
    debugPrint('calendar  hover step:  $calendar rebuilds');
  });
}
