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
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: GaiaStarfield(active: active, child: const SizedBox.expand()),
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
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: GaiaStarfield(active: active, child: const SizedBox.expand()),
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
      GaiaStarfield(
        active: active,
        child: CustomPaint(painter: chat, size: const Size(400, 400)),
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
