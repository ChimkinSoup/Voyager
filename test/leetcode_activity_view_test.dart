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

final _now = DateTime.utc(2026, 8, 15, 12);

class _FixedSettings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

LeetCodeProblem _problem(
  String id,
  LeetCodeDifficulty difficulty,
  int daysAgo,
) {
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
    expect(find.text('Problems solved per day'), findsNothing);

    // Dead centre, which is all chart.
    await tester.tap(find.byType(LeetCodeActivityCard));
    await _settleExpand(tester);

    // Both surfaces, one page: sparkline on top, year calendar under it.
    expect(find.text('Problems solved per day'), findsOneWidget);
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

    LeetCodeDifficulty? chartSelection() => tester
        .widget<LeetCodeActivityChart>(
          find.byWidgetPredicate(
            (w) => w is LeetCodeActivityChart && !w.compact,
          ),
        )
        .selected;
    LeetCodeDifficulty? calendarSelection() => tester
        .widget<LeetCodeActivityCalendar>(
          find.byType(LeetCodeActivityCalendar),
        )
        .difficulty;

    expect(chartSelection(), isNull);
    expect(calendarSelection(), isNull);

    await tester.tap(find.text('Medium 1'));
    await tester.pump();
    expect(chartSelection(), LeetCodeDifficulty.medium);
    expect(calendarSelection(), LeetCodeDifficulty.medium);

    // A different tier takes the selection over rather than clearing it.
    await tester.tap(find.text('Hard 1'));
    await tester.pump();
    expect(chartSelection(), LeetCodeDifficulty.hard);
    expect(calendarSelection(), LeetCodeDifficulty.hard);

    // The one that holds it clears it.
    await tester.tap(find.text('Hard 1'));
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

  // With a tier selected the grid counts only that tier, so the bubble it
  // raises has to stop reciting the other two.
  testWidgets('a filtered hover bubble lists only the selected difficulty', (
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
  });
}
