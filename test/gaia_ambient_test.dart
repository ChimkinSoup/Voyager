import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_glyph.dart';

void main() {
  bool ticking(WidgetTester tester) =>
      tester.binding.transientCallbackCount > 0;

  Future<void> pumpUnder(WidgetTester tester, bool running, Widget child) =>
      tester.pumpWidget(
        MaterialApp(
          home: GaiaAmbient(
            running: running,
            child: Center(child: child),
          ),
        ),
      );

  const glyph = GaiaTierGlyph(level: 2, color: Colors.white);

  testWidgets('the tier glyph ticks only while ambient motion runs', (
    tester,
  ) async {
    await pumpUnder(tester, false, glyph);
    expect(ticking(tester), isFalse);

    await pumpUnder(tester, true, glyph);
    expect(ticking(tester), isTrue);

    await pumpUnder(tester, false, glyph);
    expect(ticking(tester), isFalse);
  });

  GaiaGlowRing ring({required bool hovered, bool capsule = false}) =>
      GaiaGlowRing(
        radius: 18,
        hovered: hovered,
        capsule: capsule,
        child: const SizedBox.square(dimension: 36),
      );

  for (final capsule in [false, true]) {
    testWidgets(
      'the ${capsule ? 'capsule' : 'floating'} shell ticks only while hovered',
      (tester) async {
        await pumpUnder(tester, true, ring(hovered: false, capsule: capsule));
        await tester.pumpAndSettle();
        expect(ticking(tester), isFalse);

        await pumpUnder(tester, true, ring(hovered: true, capsule: capsule));
        await tester.pump(const Duration(milliseconds: 50));
        expect(ticking(tester), isTrue);

        await pumpUnder(tester, true, ring(hovered: false, capsule: capsule));
        await tester.pumpAndSettle();
        expect(ticking(tester), isFalse);
      },
    );
  }
}
