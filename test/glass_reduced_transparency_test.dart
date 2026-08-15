// Every translucent surface has to answer the same accessibility signal the
// same way, or the app ends up with a near-solid dialog carrying blurred
// buttons on it. Flutter exposes no cross-platform
// "prefers-reduced-transparency", so `MediaQuery.highContrast` is the proxy —
// these pin that all three glass surfaces read it, and that
// MaterializeTransition's blur ramp exists at all and costs nothing at rest.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';

/// Sigma of the blur the single [BackdropFilter] under [of] is applying.
double _blurSigma(WidgetTester tester, Finder of) {
  final filter = tester
      .widget<BackdropFilter>(
        find.descendant(of: of, matching: find.byType(BackdropFilter)),
      )
      .filter;
  // dart:ui's blur filters compare by their sigmas, so equality against a
  // zero-sigma blur is the only public way to tell "no blur" apart.
  return filter == ImageFilter.blur(sigmaX: 0, sigmaY: 0) ? 0.0 : 1.0;
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required bool highContrast,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(highContrast: highContrast),
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

void main() {
  testWidgets('GlassButton drops its blur under high contrast', (tester) async {
    final button = GlassButton(onPressed: () {}, label: 'Save');

    await _pump(tester, button, highContrast: false);
    expect(
      _blurSigma(tester, find.byType(GlassButton)),
      greaterThan(0),
      reason: 'normally the button frosts what is behind it',
    );

    await _pump(tester, button, highContrast: true);
    expect(
      _blurSigma(tester, find.byType(GlassButton)),
      0,
      reason: 'high contrast asks for a solid surface, not a translucent one',
    );
  });

  testWidgets('GlassSurface answers high contrast the same way a button does', (
    tester,
  ) async {
    const surface = GlassSurface(child: SizedBox(width: 100, height: 100));

    await _pump(tester, surface, highContrast: false);
    expect(_blurSigma(tester, find.byType(GlassSurface)), greaterThan(0));

    await _pump(tester, surface, highContrast: true);
    expect(
      _blurSigma(tester, find.byType(GlassSurface)),
      0,
      reason: 'a surface and the buttons on it must not disagree',
    );
  });

  testWidgets('MaterializeTransition blurs on arrival and clears once settled', (
    tester,
  ) async {
    Future<void> pumpAt(double t) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MaterializeTransition(
            t: AlwaysStoppedAnimation<double>(t),
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );

    await pumpAt(0.0);
    expect(
      find.byType(BackdropFilter),
      findsOneWidget,
      reason: 'the surface should arrive as a material, frosting its backdrop',
    );

    await pumpAt(1.0);
    expect(
      find.byType(BackdropFilter),
      findsNothing,
      reason: 'a settled surface must cost no filter at all',
    );
  });

  testWidgets('MaterializeTransition skips the blur under reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: MaterializeTransition(
              t: const AlwaysStoppedAnimation<double>(0.0),
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byType(BackdropFilter),
      findsNothing,
      reason: 'materializing is exactly the effect reduced motion opts out of',
    );
  });
}
