import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_spinner.dart';

void main() {
  Future<void> show(
    WidgetTester tester, {
    bool reduced = false,
    bool visible = true,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: TickerMode(
          enabled: visible,
          child: const Center(child: GaiaSpinner(size: 12, label: 'Uploading')),
        ),
      ),
    ),
  );

  testWidgets('motion stops and resumes with accessibility and visibility', (
    tester,
  ) async {
    await show(tester);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await show(tester, reduced: true);
    expect(tester.binding.transientCallbackCount, 0);
    await show(tester);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await show(tester, visible: false);
    expect(tester.binding.transientCallbackCount, 0);
    await show(tester);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('keeps its compact bounds and exposes the operation label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await show(tester);
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.getSize(find.byType(GaiaSpinner)), const Size.square(12));
    expect(find.bySemanticsLabel('Uploading'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
