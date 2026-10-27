import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_orb.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_glyph.dart';

void main() {
  Future<void> pumpOrb(
    WidgetTester tester, {
    GaiaOrbState state = GaiaOrbState.thinking,
    bool reduced = false,
    bool onScreen = true,
  }) => tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: TickerMode(
          enabled: onScreen,
          child: GaiaOrb(state: state, tier: 1),
        ),
      ),
    ),
  );

  bool ticking(WidgetTester tester) =>
      tester.binding.transientCallbackCount > 0;

  testWidgets('ticks while on screen', (tester) async {
    await pumpOrb(tester);
    expect(ticking(tester), isTrue);

    await pumpOrb(tester, onScreen: false);
    expect(ticking(tester), isFalse);
  });

  testWidgets('holds still under reduced motion', (tester) async {
    await pumpOrb(tester, reduced: true);
    expect(ticking(tester), isFalse);

    await pumpOrb(tester);
    expect(ticking(tester), isTrue);

    await pumpOrb(tester, reduced: true);
    expect(ticking(tester), isFalse);
  });

  testWidgets('says what Gaia is doing', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpOrb(tester);
    expect(find.bySemanticsLabel('Thinking'), findsOneWidget);

    await pumpOrb(tester, state: GaiaOrbState.speaking);
    expect(find.bySemanticsLabel('Replying'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a finished reply compacts into its glyph, which takes over', (
    tester,
  ) async {
    final orb = find.byType(CustomPaint);
    await pumpOrb(tester, state: GaiaOrbState.speaking);
    await pumpOrb(tester, state: GaiaOrbState.glyph);
    expect(find.byType(GaiaTierGlyph), findsNothing, reason: 'still gathering');

    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(GaiaTierGlyph), findsOneWidget);
    expect(
      find.descendant(of: find.byType(GaiaOrb), matching: orb),
      findsOneWidget,
      reason: "the glyph's own paint, the orb's gone",
    );

    // A new reply brings the orb back.
    await pumpOrb(tester, state: GaiaOrbState.thinking);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(GaiaTierGlyph), findsNothing);
  });

  testWidgets('a glyph carried to a new reply flies there and opens out', (
    tester,
  ) async {
    final key = GlobalKey();
    Future<void> at(int slot, GaiaOrbState state) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            for (var i = 0; i < 2; i++)
              SizedBox.square(
                dimension: 100,
                child: i == slot
                    ? GaiaOrb(key: key, state: state, tier: 1)
                    : null,
              ),
          ],
        ),
      ),
    );
    await at(0, GaiaOrbState.glyph);
    await tester.pump();
    expect(find.byType(GaiaTierGlyph), findsOneWidget);

    await at(1, GaiaOrbState.thinking);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(GaiaTierGlyph), findsNothing, reason: 'opening out');
    expect(ticking(tester), isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('completion reverses when another message arrives mid-fold', (
    tester,
  ) async {
    await pumpOrb(tester, state: GaiaOrbState.speaking);
    await tester.pump(const Duration(milliseconds: 100));
    await pumpOrb(tester, state: GaiaOrbState.glyph);
    await tester.pump(const Duration(milliseconds: 300));
    await pumpOrb(tester, state: GaiaOrbState.thinking);
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(GaiaTierGlyph), findsNothing);
    expect(ticking(tester), isTrue);
    await pumpOrb(tester, state: GaiaOrbState.glyph);
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(GaiaTierGlyph), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabling reduced motion during a fold lands immediately', (
    tester,
  ) async {
    await pumpOrb(tester, state: GaiaOrbState.speaking);
    await pumpOrb(tester, state: GaiaOrbState.glyph);
    await tester.pump(const Duration(milliseconds: 100));
    await pumpOrb(tester, state: GaiaOrbState.glyph, reduced: true);
    await tester.pump();
    expect(find.byType(GaiaTierGlyph), findsOneWidget);
    expect(ticking(tester), isFalse);
    await pumpOrb(tester, state: GaiaOrbState.thinking, reduced: true);
    expect(find.byType(GaiaTierGlyph), findsNothing);
    expect(ticking(tester), isFalse);
  });

  testWidgets('live astral motion pauses with Gaia ambient motion', (
    tester,
  ) async {
    Future<void> show(bool running) => tester.pumpWidget(
      MaterialApp(
        home: GaiaAmbient(
          running: running,
          child: const Center(
            child: GaiaOrb(state: GaiaOrbState.thinking, tier: 2),
          ),
        ),
      ),
    );
    await show(true);
    expect(ticking(tester), isTrue);
    await show(false);
    await tester.pump();
    expect(ticking(tester), isFalse);
    await show(true);
    expect(ticking(tester), isTrue);
  });

  testWidgets('starts as the glyph when the reply was already done', (
    tester,
  ) async {
    await pumpOrb(tester, state: GaiaOrbState.glyph);
    expect(find.byType(GaiaTierGlyph), findsOneWidget);
  });
}
