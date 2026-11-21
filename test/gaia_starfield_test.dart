import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_starfield.dart';

void main() {
  late ValueNotifier<bool> active;

  Future<void> pumpField(WidgetTester tester, {bool reduced = false}) async {
    active = ValueNotifier(false);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: GaiaStarfield(active: active, child: const SizedBox.expand()),
        ),
      ),
    );
  }

  bool ticking(WidgetTester tester) =>
      tester.binding.transientCallbackCount > 0;

  /// A mouse over the field's middle, which takes it off again on teardown.
  Future<TestGesture> hover(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(
      location: tester.getCenter(find.byType(GaiaStarfield)),
    );
    await mouse.moveBy(const Offset(1, 0));
    await tester.pump();
    return mouse;
  }

  testWidgets('ticks only while active', (tester) async {
    await pumpField(tester);
    await hover(tester);
    expect(ticking(tester), isFalse);

    active.value = true;
    await tester.pump();
    expect(ticking(tester), isTrue);

    active.value = false;
    await tester.pump();
    expect(ticking(tester), isFalse);

    active.value = true;
    await tester.pump();
    expect(ticking(tester), isTrue);
  });

  testWidgets('ticks only while the cursor is over it', (tester) async {
    await pumpField(tester);
    active.value = true;
    await tester.pump();
    expect(ticking(tester), isFalse);

    final mouse = await hover(tester);
    expect(ticking(tester), isTrue);

    await mouse.moveTo(const Offset(-10, -10));
    await tester.pump();
    expect(ticking(tester), isFalse);
  });

  testWidgets('turning, steps every so often while active without the cursor', (
    tester,
  ) async {
    active = ValueNotifier(false);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: GaiaStarfield(
          active: active,
          rotation: 2,
          child: const SizedBox.expand(),
        ),
      ),
    );
    expect(ticking(tester), isFalse);

    active.value = true;
    expect(ticking(tester), isTrue);
    // A step, and then no frames until the next.
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(milliseconds: 490));
    expect(tester.binding.hasScheduledFrame, isFalse);
    final stars = tester.renderObject(find.byType(CustomPaint).first);
    await tester.pump(const Duration(milliseconds: 20), EnginePhase.build);
    expect(stars.debugNeedsPaint, isTrue);
    await tester.pump();

    // Leaves no step waiting: the test fails on a pending timer.
    active.value = false;
    await tester.pump();
    expect(ticking(tester), isFalse);
  });

  testWidgets('stepping, turns at its rate', (tester) async {
    active = ValueNotifier(false);
    addTearDown(active.dispose);
    // 2°/min over 800x600 steps every 500 ms.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: GaiaStarfield(
          active: active,
          rotation: 2,
          child: const SizedBox.expand(),
        ),
      ),
    );
    final box = tester.renderObject<RenderBox>(find.byType(CustomPaint).first);
    List<Offset> stars() {
      final canvas = TestRecordingCanvas();
      box.paint(TestRecordingPaintingContext(canvas), Offset.zero);
      return [
        for (final call in canvas.invocations)
          if (call.invocation.memberName == #drawCircle)
            call.invocation.positionalArguments[0] as Offset,
      ];
    }

    active.value = true;
    await tester.pump();
    final size = box.size;
    final middle = size.center(Offset.zero);
    final before = stars().reduce(
      (a, b) => (a - middle).distance < (b - middle).distance ? a : b,
    );
    for (var i = 0; i < 500; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    final after = stars().reduce(
      (a, b) => (a - before).distance < (b - before).distance ? a : b,
    );

    // About the pole half the height above the middle. The last step may
    // be up to one short of the 5 s.
    final pole = Offset(size.width / 2, -size.height / 2);
    final turned = ((after - pole).direction - (before - pole).direction).abs();
    const rate = 2 * pi / 180 / 60;
    expect(turned, greaterThan(rate * 4.4));
    expect(turned, lessThanOrEqualTo(rate * 5.01));

    active.value = false;
    await tester.pump();
  });

  testWidgets('turning fast, steps more often, still not every frame', (
    tester,
  ) async {
    active = ValueNotifier(false);
    addTearDown(active.dispose);
    // 45°/min over 800x600: the farthest stars move about 13 px/s, so a
    // step every 40 ms or so keeps each under half a pixel.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: GaiaStarfield(
          active: active,
          rotation: 45,
          child: const SizedBox.expand(),
        ),
      ),
    );
    active.value = true;
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(milliseconds: 30));
    expect(tester.binding.hasScheduledFrame, isFalse);
    final stars = tester.renderObject(find.byType(CustomPaint).first);
    await tester.pump(const Duration(milliseconds: 15), EnginePhase.build);
    expect(stars.debugNeedsPaint, isTrue);
    await tester.pump();

    active.value = false;
    await tester.pump();
    expect(ticking(tester), isFalse);
  });

  testWidgets('a larger step, steps half as often', (tester) async {
    active = ValueNotifier(false);
    addTearDown(active.dispose);
    // As above, with a pixel a step: one every 78 ms or so, not 39.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: GaiaStarfield(
          active: active,
          rotation: 45,
          maxStepMove: 1,
          child: const SizedBox.expand(),
        ),
      ),
    );
    active.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(tester.binding.hasScheduledFrame, isFalse);
    final stars = tester.renderObject(find.byType(CustomPaint).first);
    await tester.pump(const Duration(milliseconds: 15), EnginePhase.build);
    expect(stars.debugNeedsPaint, isTrue);
    await tester.pump();

    active.value = false;
    await tester.pump();
    expect(ticking(tester), isFalse);
  });

  testWidgets('ticks every frame only while leaning to catch the cursor', (
    tester,
  ) async {
    active = ValueNotifier(true);
    addTearDown(active.dispose);
    late Offset Function() lean;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: GaiaStarfield(
          active: active,
          rotation: 2,
          child: Builder(
            builder: (context) {
              lean = GaiaStarfield.leanOf(context)!;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);

    // At once, not at the next step.
    final mouse = await hover(tester);
    await mouse.moveBy(const Offset(200, 0));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(ticking(tester), isTrue);
    }
    expect(lean().dx, greaterThan(0));

    // Caught up, it steps only every so often, the cursor still over it.
    for (var i = 0; i < 300 && ticking(tester); i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(ticking(tester), isFalse);
    expect(lean().dx, closeTo(201 * 0.03, 0.02));

    // A move leans it again at once.
    await mouse.moveBy(const Offset(-100, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(ticking(tester), isTrue);

    active.value = false;
    await tester.pump();
  });

  testWidgets('a glow repaints the stars', (tester) async {
    await pumpField(tester);
    late void Function(double) glow;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: GaiaStarfield(
          active: active,
          child: Builder(
            builder: (context) {
              glow = GaiaStarfield.glowOf(context)!;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    final stars = tester.renderObject(find.byType(CustomPaint).first);
    expect(stars.debugNeedsPaint, isFalse);
    glow(0.5);
    expect(stars.debugNeedsPaint, isTrue);
  });

  testWidgets('never ticks under reduced motion', (tester) async {
    await pumpField(tester, reduced: true);
    await hover(tester);
    active.value = true;
    await tester.pump();
    expect(ticking(tester), isFalse);
  });

  testWidgets('stops when reduced motion turns on', (tester) async {
    await pumpField(tester);
    await hover(tester);
    active.value = true;
    await tester.pump();
    expect(ticking(tester), isTrue);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: GaiaStarfield(active: active, child: const SizedBox.expand()),
        ),
      ),
    );
    expect(ticking(tester), isFalse);
  });

  testWidgets('a tick repaints the stars, not the chat in front', (
    tester,
  ) async {
    final chat = _CountingPainter();
    active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: GaiaStarfield(
          active: active,
          child: CustomPaint(painter: chat, size: const Size(400, 400)),
        ),
      ),
    );
    await hover(tester);
    final first = chat.paints;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(ticking(tester), isTrue);
    expect(chat.paints, first);
  });

  testWidgets('stops when disposed', (tester) async {
    await pumpField(tester);
    await hover(tester);
    active.value = true;
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(ticking(tester), isFalse);
    // No listener left behind on the notifier.
    active.value = false;
  });
}

class _CountingPainter extends CustomPainter {
  var paints = 0;

  @override
  void paint(Canvas canvas, Size size) => paints++;

  @override
  bool shouldRepaint(_CountingPainter oldDelegate) => false;
}
