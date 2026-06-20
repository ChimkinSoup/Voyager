import 'package:flutter/widgets.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

IconData weatherIconData(String? icon) => switch (icon) {
  'cloudy' => PhosphorIconsRegular.cloud,
  'rain' => PhosphorIconsRegular.cloudRain,
  'snow' => PhosphorIconsRegular.snowflake,
  _ => PhosphorIconsRegular.sun,
};
