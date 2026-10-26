import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_orb.dart';

void main() {
  Future<void> pumpOrb(
    WidgetTester tester, {
    bool speaking = false,
    bool reduced = false,
    bool onScreen = true,
  }) => tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: TickerMode(
          enabled: onScreen,
          child: GaiaOrb(speaking: speaking),
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

    await pumpOrb(tester, speaking: true);
    expect(find.bySemanticsLabel('Replying'), findsOneWidget);
    semantics.dispose();
  });
}
