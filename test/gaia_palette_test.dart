import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';

void main() {
  // `/stas` to `/stash`: the row under the highlight moves down as the
  // other comes up, and the light stays put rather than going with it, even
  // with the pointer resting on the top row.
  testWidgets('the highlight stays on the top row as the rows reorder', (
    tester,
  ) async {
    Widget palette(List<String> labels) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: GaiaPalette(
            width: 300,
            animate: false,
            highlight: 0,
            items: [
              for (final label in labels)
                GaiaMenuItem(label: label, onPressed: () {}),
            ],
          ),
        ),
      ),
    );
    Color? light(String label) {
      // As painted, mid-fade, not the AnimatedContainer's target.
      final box = tester.widget<DecoratedBox>(
        find
            .ancestor(
              of: find.text(label, findRichText: true),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      return (box.decoration as BoxDecoration).color;
    }

    // The glow ring never settles.
    await tester.pumpWidget(palette(['/stash-pop', '/stash']));
    await tester.pump(const Duration(seconds: 2));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.text('/stash-pop', findRichText: true)),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(palette(['/stash', '/stash-pop']));
    await tester.pump(const Duration(milliseconds: 16));
    final lit = light('/stash');
    expect(lit!.a, greaterThan(0));
    expect(light('/stash-pop')!.a, 0);
    await tester.pump(const Duration(milliseconds: 16));
    expect(light('/stash-pop')!.a, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
