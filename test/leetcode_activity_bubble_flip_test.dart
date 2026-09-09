// Where the activity-calendar hover bubble lands when the grid is scrolled.
//
// The bubble is laid out in the host stack's coordinates, and that stack is
// taller than the window it is shown through. Scrolled down, the room "above"
// the pointer inside the stack is not room on screen, so the bubble kept
// choosing it and was drawn up behind the year header the scroll area ends at.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/leetcode/leetcode_activity_bubble.dart';

const _bubble = SizedBox(key: ValueKey('bubble'), width: 120, height: 60);

/// Lays the bubble out over a 400x1000 stack — a year grid taller than its
/// viewport — with the pointer at [anchor] and the given visible band.
Future<Rect> _place(
  WidgetTester tester, {
  required Offset anchor,
  double? visibleTop,
  double? visibleBottom,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 400,
          height: 1000,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              const SizedBox.expand(),
              LeetCodeActivityBubbleLayer(
                anchor: anchor,
                visibleTop: visibleTop,
                visibleBottom: visibleBottom,
                child: _bubble,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  final stack = tester.getTopLeft(find.byType(Stack));
  return tester.getRect(find.byKey(const ValueKey('bubble'))).shift(-stack);
}

void main() {
  testWidgets('sits above the pointer when there is room above it', (
    tester,
  ) async {
    final rect = await _place(tester, anchor: const Offset(200, 500));
    expect(rect.bottom, lessThan(500));
  });

  testWidgets('flips below the pointer at the top of the stack', (tester) async {
    final rect = await _place(tester, anchor: const Offset(200, 20));
    expect(rect.top, greaterThan(20));
  });

  // The bug: 500px into the stack there is plenty of room above, but none of
  // it is on screen when the visible band starts at 480.
  testWidgets('flips below the pointer at the top of the visible band', (
    tester,
  ) async {
    final rect = await _place(
      tester,
      anchor: const Offset(200, 500),
      visibleTop: 480,
      visibleBottom: 880,
    );
    expect(rect.top, greaterThan(500), reason: 'must flip below the pointer');
    expect(rect.top, greaterThanOrEqualTo(480));
  });

  testWidgets('still goes above once the pointer is clear of the band top', (
    tester,
  ) async {
    final rect = await _place(
      tester,
      anchor: const Offset(200, 700),
      visibleTop: 480,
      visibleBottom: 880,
    );
    expect(rect.bottom, lessThan(700));
    expect(rect.top, greaterThanOrEqualTo(480));
  });
}
