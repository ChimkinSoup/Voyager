import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_debug_menu.dart';
import 'package:voyager/features/gaia/companion/gaia_orb.dart';

void main() {
  for (final width in [280.0, 480.0]) {
    testWidgets('message preview replays the live lifecycle at $width px', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: GaiaOrbMessagePreview(),
              ),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('First message'));
      await tester.tap(find.text('First message'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.widgetList<GaiaOrb>(find.byType(GaiaOrb)).last.state,
        GaiaOrbState.thinking,
      );
      await tester.ensureVisible(find.text('Start reply'));
      await tester.tap(find.text('Start reply'));
      await tester.pump();
      expect(
        tester.widgetList<GaiaOrb>(find.byType(GaiaOrb)).last.state,
        GaiaOrbState.speaking,
      );
      await tester.ensureVisible(find.text('Finish reply'));
      await tester.tap(find.text('Finish reply'));
      await tester.pump();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        tester.widgetList<GaiaOrb>(find.byType(GaiaOrb)).last.state,
        GaiaOrbState.glyph,
      );
      await tester.ensureVisible(find.text('New message'));
      await tester.tap(find.text('New message'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widgetList<GaiaOrb>(find.byType(GaiaOrb)).last.state,
        GaiaOrbState.thinking,
      );
      expect(tester.takeException(), isNull);
      // Cancel scheduled replies and their timers on close.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
