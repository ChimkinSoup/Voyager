import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_sky.dart';

void main() {
  late ValueNotifier<bool> active;

  Widget sky({
    bool shown = true,
    bool warp = false,
    int warpTest = 0,
    GaiaSkyExit exit = GaiaSkyExit.warp,
    GaiaAuroraExit auroraExit = GaiaAuroraExit.rise,
    bool reduced = false,
    Widget child = const SizedBox.expand(),
  }) => MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: GaiaSky(
      active: active,
      shown: shown,
      sent: warp,
      rotation: 6,
      stars: 320,
      twinkle: 0.5,
      sparkles: 2,
      traceSpeed: 80,
      figures: true,
      eventInterval: 15,
      aurora: 0.35,
      auroraExit: auroraExit,
      exit: exit,
      exitTime: 1,
      exitTest: warpTest,
      child: child,
    ),
  );

  Future<void> pumpSky(
    WidgetTester tester, {
    bool shown = true,
    bool reduced = false,
    bool isActive = false,
  }) async {
    active = ValueNotifier(isActive);
    addTearDown(active.dispose);
    await tester.pumpWidget(sky(shown: shown, reduced: reduced));
  }

  bool ticking(WidgetTester tester) =>
      tester.binding.transientCallbackCount > 0;

  testWidgets('ticks while active', (tester) async {
    await pumpSky(tester);
    expect(ticking(tester), isFalse);

    active.value = true;
    await tester.pump();
    expect(ticking(tester), isTrue);

    active.value = false;
    await tester.pump();
    expect(ticking(tester), isFalse);
  });

  testWidgets('never ticks in a chat with messages', (tester) async {
    await pumpSky(tester, shown: false);
    active.value = true;
    await tester.pump();
    expect(ticking(tester), isFalse);
  });

  testWidgets('never ticks under reduced motion', (tester) async {
    await pumpSky(tester, reduced: true);
    active.value = true;
    await tester.pump();
    expect(ticking(tester), isFalse);

    // Nor to leave.
    await tester.pumpWidget(sky(shown: false, warp: true, reduced: true));
    expect(ticking(tester), isFalse);
  });

  // Frames of 50 ms: the sky caps each frame's step, so one long pump
  // isn't that long to it.
  Future<void> frames(WidgetTester tester, double seconds) async {
    for (var i = 0; i < (seconds / 0.05).round(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('warps away on a prompt, then stops', (tester) async {
    await pumpSky(tester, isActive: true);
    await frames(tester, 1);

    await tester.pumpWidget(sky(shown: false, warp: true));
    // Still going once the window's left, until the warp's done.
    active.value = false;
    await frames(tester, 0.9);
    expect(ticking(tester), isTrue);
    await frames(tester, 0.2);
    expect(ticking(tester), isFalse);
  });

  testWidgets('fades quickly when another chat opens, whatever its exit', (
    tester,
  ) async {
    await pumpSky(tester, isActive: true);
    await frames(tester, 3);

    // Not sent, so no exit: a quick fade, well within the exit's time.
    await tester.pumpWidget(sky(shown: false));
    active.value = false;
    await frames(tester, 0.2);
    expect(ticking(tester), isTrue);
    await frames(tester, 0.3);
    expect(ticking(tester), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('turns back mid-exit when the chat empties again', (
    tester,
  ) async {
    await pumpSky(tester, isActive: true);
    await frames(tester, 1);

    await tester.pumpWidget(sky(shown: false, warp: true));
    active.value = false;
    await frames(tester, 0.3);

    // Back the way it went, done well before the exit would have been.
    await tester.pumpWidget(sky());
    await frames(tester, 0.4);
    expect(ticking(tester), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blinks back in when the chat empties again', (tester) async {
    await pumpSky(tester, shown: false);
    await tester.pumpWidget(sky(exit: GaiaSkyExit.blinkOut));
    // Lighting up, then still once it has, the window not being active.
    await frames(tester, 0.9);
    expect(ticking(tester), isTrue);
    await frames(tester, 0.2);
    expect(ticking(tester), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back before it has faded, fades in rather than blinks', (
    tester,
  ) async {
    active = ValueNotifier(false);
    addTearDown(active.dispose);
    await tester.pumpWidget(sky(exit: GaiaSkyExit.blinkOut));
    await frames(tester, 1.1);
    expect(ticking(tester), isFalse);

    // Another chat opened, and left again partway through the fade.
    await tester.pumpWidget(sky(shown: false, exit: GaiaSkyExit.blinkOut));
    await frames(tester, 0.1);
    await tester.pumpWidget(sky(exit: GaiaSkyExit.blinkOut));
    // Fading back up the little it lost, not blinking in over a second
    // from nothing.
    await frames(tester, 0.4);
    expect(ticking(tester), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blinks in on first showing', (tester) async {
    active = ValueNotifier(false);
    addTearDown(active.dispose);
    await tester.pumpWidget(sky(exit: GaiaSkyExit.blinkOut));
    expect(ticking(tester), isTrue);
    await frames(tester, 1.1);
    expect(ticking(tester), isFalse);
  });

  testWidgets('a test warp comes back', (tester) async {
    await pumpSky(tester, isActive: true);
    await frames(tester, 1);

    await tester.pumpWidget(sky(warpTest: 1));
    await frames(tester, 1.5);
    // Shown and active still, so it ticks on.
    expect(ticking(tester), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tick repaints the sky, not the chat in front', (tester) async {
    final chat = _CountingPainter();
    active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      sky(
        child: CustomPaint(painter: chat, size: const Size(400, 400)),
      ),
    );
    final first = chat.paints;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(ticking(tester), isTrue);
    expect(chat.paints, first);
  });

  testWidgets('paints every part without throwing', (tester) async {
    await pumpSky(tester, isActive: true);
    // Long enough for a constellation's tracing and a meteor or two.
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpWidget(sky(shown: false, warp: true));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps clear behind a greeting, coming and going', (
    tester,
  ) async {
    active = ValueNotifier(true);
    addTearDown(active.dispose);
    const greeting = Center(
      child: GaiaSkyClear(child: SizedBox(width: 200, height: 40)),
    );
    await tester.pumpWidget(sky(child: greeting));
    await frames(tester, 1);
    await tester.pumpWidget(sky());
    await frames(tester, 0.2);
    await tester.pumpWidget(sky(child: greeting));
    await frames(tester, 0.2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a greeting moved while the sky is still repaints it', (
    tester,
  ) async {
    await pumpSky(tester, isActive: false);
    Widget at(Alignment alignment) => sky(
      child: Align(
        alignment: alignment,
        child: const GaiaSkyClear(child: SizedBox(width: 200, height: 40)),
      ),
    );
    await tester.pumpWidget(at(Alignment.topCenter));
    await tester.pump();
    expect(ticking(tester), isFalse);
    final canvas = tester.renderObject(
      find
          .descendant(
            of: find.byType(GaiaSky),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    expect(canvas.debugNeedsPaint, isFalse);

    await tester.pumpWidget(at(Alignment.bottomCenter));
    expect(canvas.debugNeedsPaint, isTrue);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final exit in GaiaSkyExit.values) {
    testWidgets('leaves by ${exit.name}, then stops', (tester) async {
      await pumpSky(tester, isActive: true);
      await frames(tester, 1);

      await tester.pumpWidget(sky(shown: false, warp: true, exit: exit));
      await frames(tester, 0.9);
      expect(ticking(tester), isTrue);
      await frames(tester, 0.2);
      expect(ticking(tester), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final auroraExit in GaiaAuroraExit.values) {
    testWidgets('its aurora goes by ${auroraExit.name}', (tester) async {
      await pumpSky(tester, isActive: true);
      await frames(tester, 1);

      await tester.pumpWidget(
        sky(shown: false, warp: true, auroraExit: auroraExit),
      );
      await frames(tester, 1.1);
      expect(ticking(tester), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('stops when disposed', (tester) async {
    await pumpSky(tester);
    active.value = true;
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(ticking(tester), isFalse);
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
