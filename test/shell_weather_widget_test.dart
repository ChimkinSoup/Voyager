import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/domain/models/weather_models.dart';

class _WeatherRailProbe extends ConsumerWidget {
  const _WeatherRailProbe({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final weather = ref.watch(currentWeatherProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(weatherIconData(weather.value?.icon), color: accent),
        if (weather.value?.tempC != null)
          Text('${weather.value!.tempC!.round()}°'),
      ],
    );
  }
}

void main() {
  testWidgets('shell weather rail shows rain icon and temperature', (
    tester,
  ) async {
    final snapshot = WeatherSnapshot(
      icon: 'rain',
      conditionCode: 501,
      tempC: 12.4,
      fetchedAt: DateTime.now().toUtc(),
      lat: 41.88,
      lon: -87.63,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentWeatherProvider.overrideWith((ref) async => snapshot),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: _WeatherRailProbe(accent: Colors.blue),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(weatherIconData('rain')), findsOneWidget);
    expect(find.text('12°'), findsOneWidget);
  });
}
