import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';

enum VoyagerMenuCatalogEntry {
  rename,
  changeColor,
  delete,
  weatherSunny,
  weatherCloudy,
  weatherRain,
  weatherSnow,
}

/// Default entries for built-in default journal/list (rename + color only).
const defaultEntityManageMenuEntries = [
  VoyagerMenuCatalogEntry.rename,
  VoyagerMenuCatalogEntry.changeColor,
];

/// Default entries and order for journal/list manage menus (⋮ popup).
const entityManageMenuEntries = [
  VoyagerMenuCatalogEntry.rename,
  VoyagerMenuCatalogEntry.changeColor,
  VoyagerMenuCatalogEntry.delete,
];

/// Default entries and order for journal entry weather picker.
const weatherMenuEntries = [
  VoyagerMenuCatalogEntry.weatherSunny,
  VoyagerMenuCatalogEntry.weatherCloudy,
  VoyagerMenuCatalogEntry.weatherRain,
  VoyagerMenuCatalogEntry.weatherSnow,
];

typedef VoyagerMenuChildBuilder =
    Widget Function(BuildContext context, VoyagerMenuCatalogEntry entry);

extension VoyagerMenuCatalogEntryLabels on VoyagerMenuCatalogEntry {
  String get label => switch (this) {
    VoyagerMenuCatalogEntry.rename => 'Rename',
    VoyagerMenuCatalogEntry.changeColor => 'Change color',
    VoyagerMenuCatalogEntry.delete => 'Delete',
    VoyagerMenuCatalogEntry.weatherSunny => 'Sunny',
    VoyagerMenuCatalogEntry.weatherCloudy => 'Cloudy',
    VoyagerMenuCatalogEntry.weatherRain => 'Rain',
    VoyagerMenuCatalogEntry.weatherSnow => 'Snow',
  };

  IconData? get icon => switch (this) {
    VoyagerMenuCatalogEntry.rename => PhosphorIconsRegular.pencilSimple,
    VoyagerMenuCatalogEntry.changeColor => PhosphorIconsRegular.palette,
    VoyagerMenuCatalogEntry.delete => PhosphorIconsRegular.trash,
    VoyagerMenuCatalogEntry.weatherSunny => weatherIconData('sunny'),
    VoyagerMenuCatalogEntry.weatherCloudy => weatherIconData('cloudy'),
    VoyagerMenuCatalogEntry.weatherRain => weatherIconData('rain'),
    VoyagerMenuCatalogEntry.weatherSnow => weatherIconData('snow'),
  };

  String? get weatherIconValue => switch (this) {
    VoyagerMenuCatalogEntry.weatherSunny => 'sunny',
    VoyagerMenuCatalogEntry.weatherCloudy => 'cloudy',
    VoyagerMenuCatalogEntry.weatherRain => 'rain',
    VoyagerMenuCatalogEntry.weatherSnow => 'snow',
    _ => null,
  };

  static VoyagerMenuCatalogEntry? forWeatherIcon(String? icon) => switch (icon) {
    'sunny' => VoyagerMenuCatalogEntry.weatherSunny,
    'cloudy' => VoyagerMenuCatalogEntry.weatherCloudy,
    'rain' => VoyagerMenuCatalogEntry.weatherRain,
    'snow' => VoyagerMenuCatalogEntry.weatherSnow,
    _ => null,
  };
}

/// Default row: optional leading icon + label.
Widget defaultCatalogMenuChild(VoyagerMenuCatalogEntry entry) {
  final icon = entry.icon;
  if (icon == null) return Text(entry.label);
  return Row(
    children: [
      Icon(icon, size: 18),
      const SizedBox(width: 8),
      Text(entry.label),
    ],
  );
}

/// Builds Voyager-styled popup entries from the catalog.
///
/// [from] sets canonical ordering (defaults to all catalog entries).
/// [visible] filters which entries appear; order follows [from].
/// [childOverrides] replaces the default child for specific entries (e.g. a red
/// delete row or extra widgets).
List<PopupMenuEntry<VoyagerMenuCatalogEntry>> buildCatalogMenu(
  BuildContext context, {
  Iterable<VoyagerMenuCatalogEntry> from = VoyagerMenuCatalogEntry.values,
  Set<VoyagerMenuCatalogEntry>? visible,
  Map<VoyagerMenuCatalogEntry, VoyagerMenuChildBuilder>? childOverrides,
}) {
  final shown = visible == null
      ? from.toList()
      : from.where(visible.contains).toList();

  return voyagerPopupMenuEntries<VoyagerMenuCatalogEntry>([
    for (final entry in shown)
      (
        value: entry,
        child: childOverrides?[entry]?.call(context, entry) ??
            defaultCatalogMenuChild(entry),
      ),
  ]);
}
