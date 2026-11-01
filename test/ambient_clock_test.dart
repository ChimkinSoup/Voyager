import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
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

    // About 60 ticks a second, each a step of two vsyncs; a subscriber's
    // first step is zero, and after that B ticks in A's frames.
    expect(a.length, inInclusiveRange(29, 32));
    expect(a.first, Duration.zero);
    expect(a.skip(1), everyElement(vsync * 2));
    expect(b.first, Duration.zero);
    expect(b.skip(1), a.sublist(a.length - b.length + 1));

    // Nothing left running once the last subscriber goes.
    await tester.pump(const Duration(milliseconds: 50));
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
  });

  testWidgets('a stalled frame steps by maxStep at most', (tester) async {
    final steps = <Duration>[];
    void onTick(Duration step) => steps.add(step);
    AmbientClock.instance.subscribe(onTick);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    // A 2 s stall: the timer fires late and so does the frame.
    await tester.pump(const Duration(seconds: 2));
    AmbientClock.instance.unsubscribe(onTick);
    expect(steps.last, AmbientClock.maxStep);
  });

  testWidgets('stops after idling, and input starts it again', (tester) async {
    final steps = <Duration>[];
    void onTick(Duration step) => steps.add(step);
    AmbientClock.instance.subscribe(onTick);

    Future<void> run(Duration span) async {
      for (
        var t = Duration.zero;
        t < span;
        t += const Duration(milliseconds: 100)
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // Still ticking just short of the idle limit...
    await run(AmbientClock.idleAfter - const Duration(seconds: 2));
    final nearLimit = steps.length;
    await run(const Duration(seconds: 1));
    expect(steps.length, greaterThan(nearLimit + 5));
    // ...and stopped, with nothing scheduled, a little after it.
    await run(const Duration(seconds: 2));
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
    final frozenAt = steps.length;
    await run(const Duration(seconds: 1));
    expect(steps.length, frozenAt);

    // Moving the mouse over the window resumes it, for another full spell.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    await mouse.moveTo(const Offset(20, 20));
    await run(const Duration(seconds: 1));
    expect(steps.length, greaterThan(frozenAt + 5));
    // The first step after the stop is zero: the wait isn't walked through.
    expect(steps[frozenAt], Duration.zero);

    // So does a key press after the next idle stop.
    await run(AmbientClock.idleAfter + const Duration(seconds: 1));
    final frozenAgain = steps.length;
    await run(const Duration(seconds: 1));
    expect(steps.length, frozenAgain);
    await tester.sendKeyEvent(LogicalKeyboardKey.shift);
    await run(const Duration(seconds: 1));
    expect(steps.length, greaterThan(frozenAgain + 5));

    // And wake(), for an animation that starts without input.
    await run(AmbientClock.idleAfter + const Duration(seconds: 1));
    final frozenThird = steps.length;
    await run(const Duration(seconds: 1));
    expect(steps.length, frozenThird);
    AmbientClock.instance.wake();
    await run(const Duration(seconds: 1));
    expect(steps.length, greaterThan(frozenThird + 5));
    AmbientClock.instance.unsubscribe(onTick);
    await mouse.removePointer();
  });
}
