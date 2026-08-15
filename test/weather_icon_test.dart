import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/weather_icon.dart';

void main() {
  test('weatherIconData keeps regular glyphs for accent-tinted menus', () {
    expect(weatherIconData('sunny'), PhosphorIconsRegular.sun);
    expect(weatherIconData('cloudy'), PhosphorIconsRegular.cloud);
    expect(weatherIconData('rain'), PhosphorIconsRegular.cloudRain);
    expect(weatherIconData('snow'), PhosphorIconsRegular.snowflake);
    expect(weatherIconData(null), PhosphorIconsRegular.sun);
  });

  test('weatherDuotoneIconData maps each condition', () {
    expect(weatherDuotoneIconData('sunny'), PhosphorIconsDuotone.sun);
    expect(weatherDuotoneIconData('cloudy'), PhosphorIconsDuotone.cloud);
    expect(weatherDuotoneIconData('rain'), PhosphorIconsDuotone.cloudRain);
    expect(weatherDuotoneIconData('snow'), PhosphorIconsDuotone.snowflake);
  });

  testWidgets('WeatherIcon paints rain with both theme-colored layers', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.light(),
        home: const Scaffold(body: WeatherIcon('rain', size: 22)),
      ),
    );

    final colors = weatherIconColors('rain', Brightness.light);
    final icon = tester.widget<PhosphorIcon>(find.byType(PhosphorIcon));
    expect(icon.color, colors.stroke);
    expect(icon.duotoneSecondaryColor, colors.fill);
    expect(icon.duotoneSecondaryOpacity, 1);
    expect(icon.size, 22);
  });

  testWidgets('WeatherIcon uses the brighter dark-theme sun pair', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.dark(),
        home: const Scaffold(body: WeatherIcon('sunny')),
      ),
    );

    final colors = weatherIconColors('sunny', Brightness.dark);
    final icon = tester.widget<PhosphorIcon>(find.byType(PhosphorIcon));
    expect(icon.color, colors.stroke);
    expect(icon.duotoneSecondaryColor, colors.fill);
    expect(
      colors.stroke,
      isNot(weatherIconColors('sunny', Brightness.light).stroke),
    );
  });
}
