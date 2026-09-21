// The activity card is almost entirely chart, and the chart hit-tests its
// whole plot even with touches disabled — which made the middle of the card a
// dead zone for the tap that expands it. These pin the gesture, the two
// surfaces the expanded view stacks, and the legend that filters both.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/leetcode/leetcode_activity_bubble.dart';
import 'package:voyager/features/leetcode/leetcode_activity_calendar.dart';
import 'package:voyager/features/leetcode/leetcode_activity_card.dart';
import 'package:voyager/features/leetcode/leetcode_activity_chart.dart';
import 'package:voyager/features/leetcode/leetcode_activity_data.dart';
import 'package:voyager/domain/models/study_models.dart';

class _FixedSettings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

LeetCodeProblem _problem(
  String id,
  LeetCodeDifficulty difficulty,
  int daysAgo,
) {
  // Off the real clock: the card windows "Last 30 days" from DateTime.now(),
  // so a pinned date ages every fixture out of the legend within weeks. Local
  // noon, by calendar day, so neither DST nor the UTC round-trip moves it.
  final now = DateTime.now();
  final solved = DateTime(now.year, now.month, now.day - daysAgo, 12).toUtc();
  return LeetCodeProblem(
    id: id,
    createdAt: solved,
    updatedAt: solved,
    title: 'Problem $id',
    difficulty: difficulty,
    solvedAt: solved,
  );
}

LeetCodeReviewLog _review(String id, String problemId, int daysAgo) {
  final now = DateTime.now();
  final reviewed = DateTime(now.year, now.month, now.day - daysAgo, 12).toUtc();
  return LeetCodeReviewLog(
    id: id,
    problemId: problemId,
    grade: StudyGrade.good,
    reviewedAt: reviewed,
  );
}

Future<void> _pumpCard(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        leetcodeProblemsProvider.overrideWith(
          (ref) async => [
            _problem('a', LeetCodeDifficulty.easy, 1),
            _problem('b', LeetCodeDifficulty.medium, 3),
            _problem('c', LeetCodeDifficulty.hard, 3),
          ],
        ),
        // Two on one day and one on another, so the reviewed line has a shape
        // and its legend total (3) can't be confused with any tier's (1).
        leetcodeReviewLogProvider.overrideWith(
          (ref) async => [
            _review('r1', 'a', 2),
            _review('r2', 'b', 2),
            _review('r3', 'c', 5),
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
  // The provider resolves a frame after the first build; no pumpAndSettle,
  // which the expand animation's spring would keep busy.
  await tester.pump(const Duration(milliseconds: 50));
}

/// Runs the 300ms expand to completion a frame at a time.
Future<void> _settleExpand(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('tapping the middle of the card expands it', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpCard(tester);
    expect(find.text('Last 30 days'), findsOneWidget);
    expect(find.text('Problems solved and reviewed per day'), findsNothing);

    // Dead centre, which is all chart.
    await tester.tap(find.byType(LeetCodeActivityCard));
    await _settleExpand(tester);

    // Both surfaces, one page: sparkline on top, year calendar under it.
    expect(find.text('Problems solved and reviewed per day'), findsOneWidget);
    expect(find.byType(LeetCodeActivityCalendar), findsOneWidget);
    expect(find.text('${DateTime.now().year}'), findsOneWidget);
    expect(find.text('January'), findsOneWidget);
    expect(find.text('December'), findsOneWidget);
  });

  // The X axis asked for a label a week, but fl_chart labels the axis maximum
  // on top of that — which put the final day's label right beside the last
  // week's.
  testWidgets('the X axis is labelled on a clean weekly interval', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpCard(tester);
    await tester.tap(find.byType(LeetCodeActivityCard));
    await _settleExpand(tester);

    // The window ends on today; a label every seven days back from its start
    // lands on yesterday, and today itself gets none.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    String label(int daysAgo) =>
        DateFormat('MMM d').format(addCalendarDays(today, -daysAgo));

    for (final daysAgo in [29, 22, 15, 8, 1]) {
      expect(find.text(label(daysAgo)), findsOneWidget);
    }
    expect(find.text(label(0)), findsNothing);
  });

  // Clicking a difficulty fills its capsule and narrows both the curve and the
  // heatmap to that tier; clicking it again puts all three back.
  testWidgets('the legend filters the sparkline and the calendar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpCard(tester);
    await tester.tap(find.byType(LeetCodeActivityCard));
    await _settleExpand(tester);

    LeetCodeActivitySeries? chartSelection() => tester
        .widget<LeetCodeActivityChart>(
          find.byWidgetPredicate(
            (w) => w is LeetCodeActivityChart && !w.compact,
          ),
        )
        .selected;
    LeetCodeActivitySeries? calendarSelection() => tester
        .widget<LeetCodeActivityCalendar>(
          find.byType(LeetCodeActivityCalendar),
        )
        .series;

    expect(chartSelection(), isNull);
    expect(calendarSelection(), isNull);

    await tester.tap(find.text('Medium 1'));
    await tester.pump();
    expect(chartSelection(), LeetCodeActivitySeries.medium);
    expect(calendarSelection(), LeetCodeActivitySeries.medium);

    // A different tier takes the selection over rather than clearing it.
    await tester.tap(find.text('Hard 1'));
    await tester.pump();
    expect(chartSelection(), LeetCodeActivitySeries.hard);
    expect(calendarSelection(), LeetCodeActivitySeries.hard);

    // Reviewed is a series like the rest — it takes the selection over and
    // filters both surfaces the same way a tier does.
    await tester.tap(find.text('Reviewed 3'));
    await tester.pump();
    expect(chartSelection(), LeetCodeActivitySeries.reviewed);
    expect(calendarSelection(), LeetCodeActivitySeries.reviewed);

    // The one that holds it clears it.
    await tester.tap(find.text('Reviewed 3'));
    await tester.pump();
    expect(chartSelection(), isNull);
    expect(calendarSelection(), isNull);
  });

  // The calendar's hover lives in a ValueNotifier rather than in State, so
  // that sweeping the pointer doesn't rebuild the whole year. That is easy to
  // rewire in a way which is fast and shows nothing.
  testWidgets('hovering a calendar day raises and drops its bubble', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpCard(tester);
    await tester.tap(find.byType(LeetCodeActivityCard));
    await _settleExpand(tester);

    expect(find.byType(LeetCodeActivityBubble), findsNothing);

    // Inside January's own tile — the cell hovered has to belong to the month
    // rather than be a neighbour's day spilling into the grid, and January is
    // the one tile guaranteed to be above the fold without scrolling.
    final januaryTile = find
        .ancestor(of: find.text('January'), matching: find.byType(Card))
        .first;
    final day = find.descendant(of: januaryTile, matching: find.text('12'));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(day));
    await tester.pump();

    final year = DateTime.now().year;
    expect(find.byType(LeetCodeActivityBubble), findsOneWidget);
    expect(find.text('Jan 12, $year'), findsOneWidget);

    // Off the grid entirely: the cell that owns the bubble exits, so it clears.
    await mouse.moveTo(const Offset(5, 5));
    await tester.pump();

    expect(find.byType(LeetCodeActivityBubble), findsNothing);
  });

  // With a series selected the grid counts only that series, so the bubble it
  // raises has to stop reciting the others.
  testWidgets('a filtered hover bubble lists only the selected series', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpCard(tester);
    await tester.tap(find.byType(LeetCodeActivityCard));
    await _settleExpand(tester);
    await tester.tap(find.text('Medium 1'));
    await tester.pump();

    final januaryTile = find
        .ancestor(of: find.text('January'), matching: find.byType(Card))
        .first;
    final day = find.descendant(of: januaryTile, matching: find.text('12'));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(day));
    await tester.pump();

    // Bare labels are the bubble's rows; the legend's capsules carry a count.
    expect(find.text('Medium'), findsOneWidget);
    expect(find.text('Easy'), findsNothing);
    expect(find.text('Hard'), findsNothing);
    expect(find.text('Reviewed'), findsNothing);
  });

  // The calendar's hover bubble is where a day's reviews are read off, beside
  // the three difficulties.
  testWidgets('an unfiltered hover bubble counts reviews beside the tiers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              LeetCodeActivityBubble(
                date: DateTime(2026, 8, 10),
                counts: const LeetCodeDayCounts(medium: 1, reviews: 4),
              ),
            ],
          ),
        ),
      ),
    );

    final row = (String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(Row),
    );

    expect(find.text('Reviewed'), findsOneWidget);
    expect(
      find.descendant(of: row('Reviewed').first, matching: find.text('4')),
      findsOneWidget,
    );
    // Every series keeps a row, zeros included, so the bubble holds its size
    // as the pointer sweeps across days.
    expect(
      find.descendant(of: row('Easy').first, matching: find.text('0')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row('Medium').first, matching: find.text('1')),
      findsOneWidget,
    );
  });

  // Reviews are kept out of the tint on purpose, which left a day of nothing
  // but review work looking identical to a day off. The corner ring is what
  // tells those two apart.
  testWidgets('a review-only day is ringed on the unfiltered heatmap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final year = DateTime.now().year;
    final byDay = {
      // Reviewed, nothing solved: no tint to go on, so this is the day the
      // ring exists for.
      DateTime(year, 6, 10): const LeetCodeDayCounts(reviews: 2),
      // Solved and reviewed: lit *and* ringed.
      DateTime(year, 6, 11): const LeetCodeDayCounts(medium: 1, reviews: 1),
      // Solved only: lit, no ring.
      DateTime(year, 6, 12): const LeetCodeDayCounts(hard: 1),
    };

    Future<void> pump(LeetCodeActivitySeries? series) => tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(_FixedSettings.new)],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1000,
              height: 800,
              child: LeetCodeActivityCalendar(byDay: byDay, series: series),
            ),
          ),
        ),
      ),
    );

    // Scoped to the month tiles so the year row's chevrons can't count.
    final rings = find.descendant(
      of: find.byType(Card),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).shape == BoxShape.circle,
      ),
    );

    await pump(null);
    await tester.pump();
    expect(rings, findsNWidgets(2));

    // Filtered, the tint is already counting one series — a second signal on
    // top of it would be reading the grid two ways at once.
    await pump(LeetCodeActivitySeries.reviewed);
    await tester.pump();
    expect(rings, findsNothing);

    await pump(LeetCodeActivitySeries.medium);
    await tester.pump();
    expect(rings, findsNothing);
  });
}
