import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/services/openweather_mapper.dart';

void main() {
  test('maps clear sky to sunny', () {
    expect(iconForOpenWeatherCondition(800), 'sunny');
    expect(iconForOpenWeatherCondition(801), 'sunny');
  });

  test('maps clouds to cloudy', () {
    expect(iconForOpenWeatherCondition(803), 'cloudy');
    expect(iconForOpenWeatherCondition(741), 'cloudy');
  });

  test('maps rain to rain', () {
    expect(iconForOpenWeatherCondition(200), 'rain');
    expect(iconForOpenWeatherCondition(501), 'rain');
  });

  test('maps snow to snow', () {
    expect(iconForOpenWeatherCondition(600), 'snow');
    expect(iconForOpenWeatherCondition(622), 'snow');
  });
}
