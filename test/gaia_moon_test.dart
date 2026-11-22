import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_moon.dart';

void main() {
  testWidgets('names the phase and how much is lit', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: GaiaMoonIcon(phase: 0.25)),
    );
    expect(find.byTooltip('First quarter, 50% lit'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: GaiaMoonIcon(phase: 0.5)));
    expect(find.byTooltip('Full moon, 100% lit'), findsOneWidget);
  });
}
