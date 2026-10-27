import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';
import 'package:voyager/features/gaia/companion/gaia_toast_icon_studio.dart';

void main() {
  testWidgets('all marks fit a narrow toast and arrival settles and replays', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: GaiaToastIconStudio(),
          ),
        ),
      ),
    );
    expect(find.byType(GaiaToastOrbIcon), findsNWidgets(4));
    for (final mark in GaiaToastMark.values) {
      expect(find.bySemanticsLabel(mark.label), findsOneWidget);
    }
    await tester.pump(const Duration(milliseconds: 1100));
    final icon = tester.state(find.byType(GaiaToastOrbIcon).first);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Replay arrival'));
    await tester.pump();
    expect(
      tester.state(find.byType(GaiaToastOrbIcon).first),
      isNot(same(icon)),
    );
    await tester.pump(const Duration(milliseconds: 1100));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'reduced motion shows a finished mark without scheduling frames',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Center(child: GaiaToastOrbIcon(mark: GaiaToastMark.error)),
          ),
        ),
      );
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(child: GaiaToastOrbIcon(mark: GaiaToastMark.done)),
        ),
      );
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
