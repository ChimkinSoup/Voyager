import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_glyph.dart';

void main() {
  bool ticking(WidgetTester tester) =>
      tester.binding.transientCallbackCount > 0;

  Future<void> pumpUnder(
    WidgetTester tester,
    bool running,
    Widget child,
  ) => tester.pumpWidget(
    MaterialApp(
      home: GaiaAmbient(running: running, child: Center(child: child)),
    ),
  );

  final ring = GaiaGlowRing(
    radius: 18,
    hovered: false,
    child: const SizedBox.square(dimension: 36),
  );
  const glyph = GaiaTierGlyph(level: 2, color: Colors.white);

  for (final (name, widget) in [('glow ring', ring), ('tier glyph', glyph)]) {
    testWidgets('the $name ticks only while ambient motion runs', (
      tester,
    ) async {
      await pumpUnder(tester, false, widget);
      expect(ticking(tester), isFalse);

      await pumpUnder(tester, true, widget);
      expect(ticking(tester), isTrue);

      await pumpUnder(tester, false, widget);
      expect(ticking(tester), isFalse);
    });
  }
}
