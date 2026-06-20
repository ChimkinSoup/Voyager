/// Maps OpenWeather condition ids to Voyager weather icons.
String iconForOpenWeatherCondition(int conditionId) {
  if (conditionId == 800 || conditionId == 801) return 'sunny';
  if (conditionId >= 802 && conditionId <= 804) return 'cloudy';
  if (conditionId >= 200 && conditionId <= 531) return 'rain';
  if (conditionId >= 600 && conditionId <= 622) return 'snow';
  if (conditionId >= 701 && conditionId <= 781) return 'cloudy';
  return 'cloudy';
}
