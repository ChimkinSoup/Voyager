import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_studio.dart';

void main() {
  Future<void> study(
    WidgetTester tester, {
    GaiaOrbMood mood = GaiaOrbMood.idle,
    bool reduced = false,
    bool active = true,
    bool onScreen = true,
    bool paused = false,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: GaiaAmbient(
          running: active,
          child: TickerMode(
            enabled: onScreen,
            child: GaiaOrbStudy(
              design: GaiaOrbDesign.astral,
              mood: mood,
              paused: paused,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('motion respects pause, visibility, focus and reduced motion', (
    tester,
  ) async {
    await study(tester);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    for (final blocked in ['paused', 'hidden', 'inactive', 'reduced']) {
      await study(
        tester,
        paused: blocked == 'paused',
        onScreen: blocked != 'hidden',
        active: blocked != 'inactive',
        reduced: blocked == 'reduced',
      );
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0, reason: blocked);
    }
    await study(tester);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  testWidgets('done settles and a new reply resumes motion', (tester) async {
    await study(tester, mood: GaiaOrbMood.done);
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.binding.transientCallbackCount, 0);
    await study(tester, mood: GaiaOrbMood.speaking);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('studio shows only Astral core and its preview controls', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(20),
            child: GaiaOrbStudio(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(GaiaOrbStudy), findsOneWidget);
    expect(
      tester
          .widgetList<GaiaOrbStudy>(find.byType(GaiaOrbStudy))
          .map((study) => study.design),
      [GaiaOrbDesign.astral],
    );
    await tester.tap(find.text('Replying'));
    await tester.pump();
    expect(
      tester
          .widgetList<GaiaOrbStudy>(find.byType(GaiaOrbStudy))
          .every((study) => study.mood == GaiaOrbMood.speaking),
      isTrue,
    );
    await tester.ensureVisible(find.text('Gather stars'));
    await tester.tap(find.text('Gather stars'));
    await tester.pump();
    expect(
      tester
          .widgetList<GaiaOrbStudy>(find.byType(GaiaOrbStudy))
          .every(
            (study) => study.gather == 1 && study.mood == GaiaOrbMood.thinking,
          ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Earlier studies'), findsNothing);
    expect(find.text('Flame inside a sphere'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Astral core renders arrival, pulse and reduced-motion glyphs', (
    tester,
  ) async {
    Future<void> render({
      required int arrival,
      required int burst,
      bool reduced = false,
    }) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Wrap(
            children: [
              for (final design in GaiaOrbDesign.values)
                SizedBox(
                  width: 130,
                  height: 180,
                  child: GaiaOrbStudy(
                    design: design,
                    mood: reduced ? GaiaOrbMood.done : GaiaOrbMood.speaking,
                    arrival: arrival,
                    burst: burst,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await render(arrival: 0, burst: 0);
    await render(arrival: 1, burst: 0);
    for (var frame = 0; frame < 70; frame++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    await render(arrival: 1, burst: 1);
    for (var frame = 0; frame < 70; frame++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(tester.takeException(), isNull);
    await render(arrival: 1, burst: 1, reduced: true);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('motion studies loop every style and play the pair picked', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: GaiaOrbMotionStudies()),
        ),
      ),
    );
    final studies = tester.widgetList<GaiaOrbStudy>(find.byType(GaiaOrbStudy));
    expect(
      studies
          .where((s) => s.mood == GaiaOrbMood.thinking)
          .map((s) => s.thinkingStyle),
      containsAll(GaiaOrbThinking.values),
    );
    expect(
      studies
          .where((s) => s.mood == GaiaOrbMood.speaking)
          .map((s) => s.replyingStyle),
      GaiaOrbReplying.values,
    );
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.tap(find.text('Synapse'));
    await tester.tap(find.text('Outpour'));
    await tester.ensureVisible(find.text('Play a message'));
    await tester.tap(find.text('Play a message'));
    await tester.pump();
    expect(
      find.text('Synapse thinking, then Outpour replying.'),
      findsOneWidget,
    );
    final played = tester
        .widgetList<GaiaOrbStudy>(find.byType(GaiaOrbStudy))
        .last;
    expect(played.thinkingStyle, GaiaOrbThinking.synapse);
    expect(played.replyingStyle, GaiaOrbReplying.outpour);
    // Through thinking, the reply and the fold into the mark.
    for (var frame = 0; frame < 250; frame++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(
      tester.widgetList<GaiaOrbStudy>(find.byType(GaiaOrbStudy)).last.mood,
      GaiaOrbMood.done,
    );
    expect(tester.takeException(), isNull);
  });
}
