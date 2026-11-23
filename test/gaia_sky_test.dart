import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    GaiaSatellite satellite = GaiaSatellite.dot,
    double eventInterval = 15,
    bool reduced = false,
    int restRate = 0,
    Widget child = const SizedBox.expand(),
  }) => MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: GaiaSky(
      active: active,
      shown: shown,
      sent: warp,
      rotation: 6,
      restRate: restRate,
      stars: 320,
      twinkle: 0.5,
      sparkles: 2,
      traceSpeed: 80,
      figures: true,
      eventInterval: eventInterval,
      aurora: 0.35,
      auroraExit: auroraExit,
      exit: exit,
      exitTime: 1,
      exitTest: warpTest,
      satellite: satellite,
      rareSatellites: false,
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

  // The sky's repaints, at its own boundary: one a step.
  int skyPaints(WidgetTester tester) {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find
          .descendant(
            of: find.byType(GaiaSky),
            matching: find.byType(RepaintBoundary),
          )
          .first,
    );
    return boundary.debugSymmetricPaintCount +
        boundary.debugAsymmetricPaintCount;
  }

  // Frames of 1 ms over [seconds], like a fast display's, for the sky to
  // step on as few or as many of as it likes.
  Future<int> stepsOver(WidgetTester tester, double seconds) async {
    final before = skyPaints(tester);
    for (var i = 0; i < (seconds * 1000).round(); i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    return skyPaints(tester) - before;
  }

  testWidgets('at rest, steps at its rest rate', (tester) async {
    active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(sky(restRate: 30));
    // Faded in, every frame. Nothing quick follows until the first
    // constellation, two seconds in.
    expect(await stepsOver(tester, 0.2), greaterThan(150));
    await frames(tester, 0.8);
    expect(await stepsOver(tester, 0.5), inInclusiveRange(14, 18));

    active.value = false;
    await tester.pump();
    expect(await stepsOver(tester, 0.1), 0);
  });

  testWidgets('leaving, steps every frame again at once', (tester) async {
    active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(sky(restRate: 30));
    await frames(tester, 1);

    await tester.pumpWidget(sky(shown: false, warp: true, restRate: 30));
    expect(await stepsOver(tester, 0.1), greaterThan(95));
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

  testWidgets('no star sparkles behind a greeting', (tester) async {
    active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      sky(
        eventInterval: 1e6,
        child: const Center(
          child: GaiaSkyClear(child: SizedBox(width: 300, height: 200)),
        ),
      ),
    );
    final box = tester.renderObject<RenderBox>(find.byType(GaiaSky));
    final greeting = Rect.fromCenter(
      center: box.size.center(Offset.zero),
      width: 300,
      height: 200,
    );
    // Sparkles are the sky's only white, softened shapes.
    final behind = <Offset>[], beside = <Offset>[];
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final canvas = TestRecordingCanvas();
      box.paint(TestRecordingPaintingContext(canvas), Offset.zero);
      for (final call in canvas.invocations) {
        if (call.invocation.memberName != #drawPath) continue;
        final [path, paint] = call.invocation.positionalArguments;
        final color = (paint as Paint).color;
        if (paint.maskFilter == null ||
            color.r != 1 ||
            color.g != 1 ||
            color.b != 1) {
          continue;
        }
        final at = (path as Path).getBounds().center;
        (greeting.inflate(30).contains(at) ? behind : beside).add(at);
      }
    }
    expect(beside, isNotEmpty);
    expect(behind, isEmpty);
    active.value = false;
  });

  testWidgets('a clear fades as its greeting does', (tester) async {
    await pumpSky(tester);
    await tester.pumpWidget(
      sky(
        child: const Center(
          child: GaiaSkyClear(
            opacity: 0.25,
            child: SizedBox(width: 200, height: 40),
          ),
        ),
      ),
    );
    await tester.pump();
    final canvas = TestRecordingCanvas();
    tester
        .renderObject<RenderBox>(find.byType(GaiaSky))
        .paint(TestRecordingPaintingContext(canvas), Offset.zero);
    final clears = [
      for (final call in canvas.invocations)
        if (call.invocation.memberName == #drawRRect)
          (call.invocation.positionalArguments[1] as Paint).color.a,
    ];
    expect(clears, [closeTo(0.25, 0.01)]);
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

  testWidgets('keeps its edge fade as it starts to leave', (tester) async {
    await pumpSky(tester, isActive: true);
    await frames(tester, 1);

    await tester.pumpWidget(
      sky(shown: false, warp: true, exit: GaiaSkyExit.fade),
    );
    await tester.pump(const Duration(milliseconds: 16));

    final box = tester.renderObject<RenderBox>(find.byType(GaiaSky));
    final canvas = TestRecordingCanvas();
    box.paint(TestRecordingPaintingContext(canvas), Offset.zero);
    final size = box.size;
    var near = 0;
    for (final call in canvas.invocations) {
      if (call.invocation.memberName != #drawRawPoints) continue;
      final [mode, points, paint] = call.invocation.positionalArguments;
      if (mode != PointMode.points) continue;
      final alpha = (paint as Paint).color.a;
      final xy = points as Float32List;
      for (var i = 0; i < xy.length; i += 2) {
        final x = xy[i], y = xy[i + 1];
        final edge = [x, size.width - x, y, size.height - y].reduce(min);
        if (edge >= 24) continue;
        near++;
        // No brighter than the fade allows, give or take a level.
        expect(alpha, lessThanOrEqualTo(edge / 24 + 0.1));
      }
    }
    expect(near, greaterThan(0));
  });

  testWidgets("satellites leaving over the top don't fly on unseen", (
    tester,
  ) async {
    active = ValueNotifier(true);
    addTearDown(active.dispose);
    // Many skies, three satellites each (as many as one sky has up): enough
    // that some head over the top.
    Widget skies(GaiaSatellite satellite) => Stack(
      textDirection: TextDirection.ltr,
      children: [
        for (var i = 0; i < 67; i++)
          // Nothing but satellites, to keep this quick.
          GaiaSky(
            key: ValueKey(i),
            active: active,
            shown: true,
            sent: false,
            rotation: 0,
            stars: 0,
            twinkle: 0,
            sparkles: 0,
            traceSpeed: 80,
            figures: false,
            eventInterval: 1e6,
            aurora: 0,
            exit: GaiaSkyExit.fade,
            exitTime: 1,
            satellite: satellite,
            rareSatellites: false,
            child: const SizedBox.expand(),
          ),
      ],
    );
    await tester.pumpWidget(skies(GaiaSatellite.trail));
    await frames(tester, 2);
    for (final satellite in [
      GaiaSatellite.dot,
      GaiaSatellite.trail,
      GaiaSatellite.dot,
    ]) {
      await tester.pumpWidget(skies(satellite));
    }
    // About one in seventeen heads over the top. Looked at every second
    // until all have had time to cross.
    final boxes = tester.renderObjectList<RenderBox>(find.byType(GaiaSky));
    final above = <double>[];
    for (var second = 0; second < 50; second++) {
      // Steps as long as the sky takes whole, to keep this quick.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      for (final box in boxes) {
        final canvas = TestRecordingCanvas();
        box.paint(TestRecordingPaintingContext(canvas), Offset.zero);
        for (final call in canvas.invocations) {
          if (call.invocation.memberName != #drawCircle) continue;
          final y = (call.invocation.positionalArguments[0] as Offset).dy;
          if (y < -10.5) above.add(y);
        }
      }
    }
    expect(above, isEmpty);
    active.value = false;
  });

  /// Satellites drawn as panels: one body each.
  int panels(WidgetTester tester) {
    final canvas = TestRecordingCanvas();
    tester
        .renderObject<RenderBox>(find.byType(GaiaSky))
        .paint(TestRecordingPaintingContext(canvas), Offset.zero);
    return canvas.invocations
        .where(
          (call) =>
              call.invocation.memberName == #drawRect &&
              (call.invocation.positionalArguments[0] as Rect).width == 2.6,
        )
        .length;
  }

  testWidgets('a satellite keeps its look when the style changes', (
    tester,
  ) async {
    await pumpSky(tester, isActive: true);
    await frames(tester, 1);
    await tester.pumpWidget(sky(satellite: GaiaSatellite.panels));
    await tester.pumpWidget(sky(satellite: GaiaSatellite.train));
    await frames(tester, 1);
    expect(panels(tester), 1);
    active.value = false;
  });

  testWidgets('a change of style sends one only while there is room', (
    tester,
  ) async {
    await pumpSky(tester, isActive: true);
    await frames(tester, 1);
    // Five panels and five dots asked for; three in all go up.
    for (var i = 0; i < 10; i++) {
      await tester.pumpWidget(
        sky(satellite: i.isEven ? GaiaSatellite.panels : GaiaSatellite.dot),
      );
    }
    await frames(tester, 1);
    expect(panels(tester), 2);
    active.value = false;
  });

  testWidgets('a quicker interval brings the next satellite sooner', (
    tester,
  ) async {
    active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(sky(satellite: GaiaSatellite.panels));
    // The first goes up at 10 s; the next is due 37.5 to 62.5 s on.
    await frames(tester, 11);
    expect(panels(tester), 1);
    await tester.pumpWidget(
      sky(satellite: GaiaSatellite.panels, eventInterval: 3),
    );
    // On the new clock, within 12.5 s. Counted as each goes up: the first,
    // flying at a random speed, may have left by then.
    var up = 0, last = 1;
    for (var i = 0; i < 13 / 0.05; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final now = panels(tester);
      if (now > last) up += now - last;
      last = now;
    }
    expect(up, 1);
    active.value = false;
  });

  testWidgets('its aurora softens at the sidebar as at the window edge', (
    tester,
  ) async {
    active = ValueNotifier(true);
    addTearDown(active.dispose);
    final left = ValueNotifier(0.0);
    addTearDown(left.dispose);
    final key = GlobalKey();
    // Nothing but the aurora.
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: GaiaSky(
          active: active,
          shown: true,
          sent: false,
          rotation: 0,
          stars: 0,
          twinkle: 0,
          sparkles: 0,
          traceSpeed: 80,
          figures: false,
          eventInterval: 1e6,
          aurora: 1,
          exit: GaiaSkyExit.fade,
          exitTime: 1,
          left: left,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await frames(tester, 2);
    active.value = false;
    await tester.pump();

    // How much shows in the 4 px just right of x = 300.
    Future<double> strip() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = (await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData();
        image.dispose();
        return data!;
      }))!;
      final width = boundary.size.width.round();
      var sum = 0;
      for (var y = 0; y < boundary.size.height; y++) {
        for (var x = 300; x < 304; x++) {
          sum += bytes.getUint8((y * width + x) * 4 + 3);
        }
      }
      return sum.toDouble();
    }

    final open = await strip();
    expect(open, greaterThan(0));
    left.value = 300;
    await tester.pump();
    // Fading in from the sidebar's edge, not cut off at full strength.
    expect(await strip() / open, lessThan(0.9));
  });

  testWidgets('stops when disposed', (tester) async {
    await pumpSky(tester);
    active.value = true;
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(ticking(tester), isFalse);
    active.value = false;
  });

  group('sightings (GAIA_STATS_HLD.md §3)', () {
    late List<GaiaSighting> sightings;

    setUp(() {
      sightings = [];
      active = ValueNotifier(true);
      addTearDown(active.dispose);
    });

    // At 1.5 s between events, the first meteor comes at 0.4 s and the
    // first satellite at 1 s.
    Widget counted({
      bool rolls = true,
      double eventInterval = 1.5,
      double aurora = 0,
      bool rareAurora = false,
      GaiaRareAurora? rareColours,
      GaiaSatellite satellite = GaiaSatellite.dot,
      int satelliteTest = 0,
      int burstTest = 0,
    }) => GaiaSky(
      active: active,
      shown: true,
      sent: false,
      rotation: 0,
      stars: 0,
      twinkle: 0,
      sparkles: 0,
      traceSpeed: 80,
      figures: false,
      eventInterval: eventInterval,
      aurora: aurora,
      rareAurora: rareAurora,
      rareColours: rareColours,
      exit: GaiaSkyExit.fade,
      exitTime: 1,
      satellite: satellite,
      satelliteTest: satelliteTest,
      burstTest: burstTest,
      onSighting: sightings.add,
      random: _Rigged(rare: rolls),
      child: const SizedBox.expand(),
    );

    Iterable<GaiaSatellite> satellites() =>
        sightings.map((s) => s.satellite).nonNulls;
    Iterable<GaiaRareAurora> auroras() =>
        sightings.map((s) => s.aurora).nonNulls;
    int meteors() =>
        sightings.where((s) => s.satellite == null && s.aurora == null).length;

    testWidgets('a rolled rare satellite counts once, after 3 s in view', (
      tester,
    ) async {
      await tester.pumpWidget(counted());
      // Sent at 1 s from just off the left edge, in view half a second on.
      await frames(tester, 4.2);
      expect(satellites(), isEmpty);
      await frames(tester, 0.6);
      expect(satellites(), [GaiaSatellite.iss]);
      // The next comes at about 4.8 s, so not counted till 8.3 s or so.
      await frames(tester, 3);
      expect(satellites(), [GaiaSatellite.iss]);
      active.value = false;
    });

    testWidgets("a rare look chosen in the debug menu doesn't count", (
      tester,
    ) async {
      await tester.pumpWidget(counted(satellite: GaiaSatellite.iss));
      await frames(tester, 6);
      expect(satellites(), isEmpty);
      active.value = false;
    });

    testWidgets("a test satellite doesn't count, rare or not", (tester) async {
      await tester.pumpWidget(counted(eventInterval: 1e6));
      await frames(tester, 0.1);
      await tester.pumpWidget(counted(eventInterval: 1e6, satelliteTest: 1));
      await frames(tester, 6);
      expect(satellites(), isEmpty);
      active.value = false;
    });

    testWidgets('a rolled rare aurora counts once a sky', (tester) async {
      await tester.pumpWidget(counted(aurora: 0.35));
      await frames(tester, 2);
      expect(auroras(), [GaiaRareAurora.crimson]);
      active.value = false;
    });

    testWidgets("the debug menu's rare aurora doesn't count", (tester) async {
      await tester.pumpWidget(
        counted(aurora: 0.35, rareAurora: true, rolls: false),
      );
      await frames(tester, 1);
      expect(auroras(), isEmpty);
      // Rolled, but in the colours the debug menu set.
      await tester.pumpWidget(Container());
      await tester.pumpWidget(
        counted(aurora: 0.35, rareColours: GaiaRareAurora.gold),
      );
      await frames(tester, 1);
      expect(auroras(), isEmpty);
      active.value = false;
    });

    testWidgets("each meteor counts, a test burst's don't", (tester) async {
      await tester.pumpWidget(counted(eventInterval: 1.5));
      await frames(tester, 0.1);
      await tester.pumpWidget(counted(eventInterval: 1.5, burstTest: 1));
      await frames(tester, 0.2);
      expect(meteors(), 0);
      // The first of the sky's own, at 0.4 s.
      await frames(tester, 0.2);
      expect(meteors(), 1);
      active.value = false;
    });
  });

  test("the rare aurora's colours share all its skies", () {
    final shares = GaiaRareAurora.values.map((c) => c.share);
    expect(shares.reduce((a, b) => a + b), closeTo(1, 1e-9));
    expect(GaiaRareAurora.gold.share, lessThan(GaiaRareAurora.crimson.share));
  });

  test('the rare satellites share all the rare ones, the ISS least', () {
    final shares = GaiaSatellite.values.map((s) => s.share);
    expect(shares.reduce((a, b) => a + b), closeTo(1, 1e-9));
    for (final look in GaiaSatellite.values) {
      if (look.share > 0 && look != GaiaSatellite.iss) {
        expect(GaiaSatellite.iss.share, lessThan(look.share));
      }
    }
  });

  group('meteor showers', () {
    test('are strongest at their peak', () {
      final shower = gaiaMeteorShower(DateTime(2026, 12, 14))!;
      expect(shower.name, 'Geminids');
      expect(shower.strength, closeTo(1, 1e-6));
    });

    test('fall away to a trace at the end of their days', () {
      final last = gaiaMeteorShower(DateTime(2026, 8, 24))!;
      expect(last.name, 'Perseids');
      expect(last.strength, closeTo(0.05, 0.01));
      expect(gaiaMeteorShower(DateTime(2026, 8, 25)), isNull);
    });

    test('carry on over the new year', () {
      expect(gaiaMeteorShower(DateTime(2026, 12, 30))?.name, 'Quadrantids');
      expect(gaiaMeteorShower(DateTime(2027, 1, 10))?.name, 'Quadrantids');
    });

    test('of two at once, take the stronger', () {
      expect(gaiaMeteorShower(DateTime(2026, 4, 25))?.name, 'Lyrids');
      expect(gaiaMeteorShower(DateTime(2026, 4, 30))?.name, 'Eta Aquariids');
    });

    test('leave most of the year without one', () {
      expect(gaiaMeteorShower(DateTime(2026, 3, 1)), isNull);
      expect(gaiaMeteorShower(DateTime(2026, 6, 15)), isNull);
    });
  });
}

/// Rolls the same every time: every rare roll comes up if [rare], none if
/// not, and every share's roll picks the first, the ISS and crimson.
class _Rigged implements Random {
  _Rigged({required this.rare});

  final bool rare;

  @override
  int nextInt(int max) => rare || max == 1 ? 0 : 1;

  @override
  double nextDouble() => 0.01;

  @override
  bool nextBool() => true;
}

class _CountingPainter extends CustomPainter {
  var paints = 0;

  @override
  void paint(Canvas canvas, Size size) => paints++;

  @override
  bool shouldRepaint(_CountingPainter oldDelegate) => false;
}
