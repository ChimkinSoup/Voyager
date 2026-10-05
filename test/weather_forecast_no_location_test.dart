import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/features/shell/reveal_request.dart';
import 'package:voyager/features/shell/weather_forecast_sheet.dart';

void main() {
  testWidgets('no location: a compact prompt that opens Settings at the tile', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [weatherForecastProvider.overrideWith((ref) async => null)],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () => showWeatherForecastSheet(context),
              child: const Text('weather'),
            ),
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const Scaffold(body: Text('settings page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.tap(find.text('weather'));
    await tester.pumpAndSettle();

    expect(find.text('Weather isn\'t set up'), findsOne);
    expect(find.byTooltip('Close'), findsOne);
    // Sized to its text, not the forecast's 680×620 panel.
    final panel = find
        .descendant(of: find.byType(Dialog), matching: find.byType(Material))
        .first;
    expect(tester.getSize(panel).height, lessThan(300));
    expect(tester.getSize(panel).width, lessThanOrEqualTo(420));

    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('settings page'), findsOne);
    expect(container.read(revealWeatherLocationRequestProvider), isTrue);
  });
}
