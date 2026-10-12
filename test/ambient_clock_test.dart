import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/motion/ambient_clock.dart';

void main() {
  testWidgets('subscribers tick together, every other 120Hz frame', (
    tester,
  ) async {
    final a = <Duration>[];
    final b = <Duration>[];
    void onA(Duration t) => a.add(t);
    void onB(Duration t) => b.add(t);

    AmbientClock.instance.subscribe(onA);
    await tester.pump();
    // Joins mid-run, so it should fall into the same frames rather than
    // asking for its own.
    AmbientClock.instance.subscribe(onB);

    // A 120Hz display: a frame every 8.33ms for half a second.
    const vsync = Duration(microseconds: 8333);
    for (var i = 0; i < 60; i++) {
      await tester.pump(vsync);
    }
    AmbientClock.instance.unsubscribe(onA);
    AmbientClock.instance.unsubscribe(onB);

    // About 60 ticks a second, and B's are A's from the moment it joined.
    expect(a.length, inInclusiveRange(29, 32));
    expect(b, a.sublist(a.length - b.length));
    for (var i = 1; i < a.length; i++) {
      expect(a[i] - a[i - 1], vsync * 2);
    }

    // Nothing left running once the last subscriber goes.
    await tester.pump(const Duration(milliseconds: 50));
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
  });
}
