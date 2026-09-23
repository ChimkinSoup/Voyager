import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/features/finance/finance_asset_value_chart.dart';

AssetValuation _valuation(String assetId, DateTime asOf, int cents) {
  final stamp = DateTime.utc(2026);
  return AssetValuation(
    id: '$assetId-${asOf.toIso8601String()}',
    createdAt: stamp,
    updatedAt: stamp,
    assetId: assetId,
    valueCents: cents,
    asOf: asOf,
  );
}

Future<void> _pump(WidgetTester tester, List<AssetValuation> valuations) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        assetValuationsProvider.overrideWith((ref) async => valuations),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: AssetValueChart(assetId: 'a', color: Colors.blue),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  testWidgets('plots each valuation on its own date, carried to today', (
    tester,
  ) async {
    final first = today.subtract(const Duration(days: 30));
    final second = today.subtract(const Duration(days: 10));
    await _pump(tester, [
      _valuation('a', second, 150000),
      _valuation('a', first, 100000),
      // Another asset's history stays out of this chart.
      _valuation('b', first, 999900),
    ]);
    await tester.pumpAndSettle();

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    final spots = chart.data.lineBarsData.single.spots;
    expect(spots.map((s) => (s.x, s.y)).toList(), [
      (0.0, 1000.0),
      (20.0, 1500.0),
      (30.0, 1500.0),
    ]);
  });

  testWidgets('no carry-forward point when valued today', (tester) async {
    await _pump(tester, [
      _valuation('a', today.subtract(const Duration(days: 5)), 100),
      _valuation('a', today, 200),
    ]);
    await tester.pumpAndSettle();

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.data.lineBarsData.single.spots, hasLength(2));
  });

  testWidgets('draws nothing without two points to join', (tester) async {
    await _pump(tester, []);
    await tester.pumpAndSettle();
    expect(find.byType(LineChart), findsNothing);

    await _pump(tester, [_valuation('a', today, 100)]);
    await tester.pumpAndSettle();
    expect(find.byType(LineChart), findsNothing);
  });
}
