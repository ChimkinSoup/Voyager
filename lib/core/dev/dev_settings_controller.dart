import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Persists debug-menu toggles in local [AppSettings].
///
/// When adding a new Dev page switch:
/// 1. Add a `dev*` bool to [AppSettings] and the settings table (with migration).
/// 2. Add a field + getter/setter here and include it in [applySettings] / [_persist].
/// 3. Wire the Dev page toggle through this controller instead of a [StateProvider].
class DevSettingsController extends ChangeNotifier {
  DevSettingsController({SettingsRepository? settingsRepository})
    : _settingsRepository = settingsRepository;

  final SettingsRepository? _settingsRepository;

  bool showCacheStatus = false;
  bool showCalendarZoomPrewarm = false;
  bool showCalendarInstantViewSwitch = false;

  Future<void> loadFromSettings() async {
    final repo = _settingsRepository;
    if (repo == null) return;
    final settings = await repo.getSettings();
    applySettings(settings);
  }

  void applySettings(AppSettings settings) {
    var changed = false;

    if (showCacheStatus != settings.devShowCacheStatus) {
      showCacheStatus = settings.devShowCacheStatus;
      changed = true;
    }
    if (showCalendarZoomPrewarm != settings.devShowCalendarZoomPrewarm) {
      showCalendarZoomPrewarm = settings.devShowCalendarZoomPrewarm;
      changed = true;
    }
    if (showCalendarInstantViewSwitch !=
        settings.devShowCalendarInstantViewSwitch) {
      showCalendarInstantViewSwitch = settings.devShowCalendarInstantViewSwitch;
      changed = true;
    }

    if (changed) notifyListeners();
  }

  Future<void> setShowCacheStatus(bool value) async {
    if (showCacheStatus == value) return;
    showCacheStatus = value;
    notifyListeners();
    await _persist();
  }

  Future<void> setShowCalendarZoomPrewarm(bool value) async {
    if (showCalendarZoomPrewarm == value) return;
    showCalendarZoomPrewarm = value;
    notifyListeners();
    await _persist();
  }

  Future<void> setShowCalendarInstantViewSwitch(bool value) async {
    if (showCalendarInstantViewSwitch == value) return;
    showCalendarInstantViewSwitch = value;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final repo = _settingsRepository;
    if (repo == null) return;
    final settings = await repo.getSettings();
    await repo.saveSettings(
      settings.copyWith(
        devShowCacheStatus: showCacheStatus,
        devShowCalendarZoomPrewarm: showCalendarZoomPrewarm,
        devShowCalendarInstantViewSwitch: showCalendarInstantViewSwitch,
      ),
    );
  }
}
