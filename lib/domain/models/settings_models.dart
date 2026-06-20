import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/constants/hotkey_defaults.dart';
class AppSettings {
  const AppSettings({
    this.accentColor = 0xFF7C9EFF,
    this.weekStartsOnMonday = true,
    this.showQuotes = true,
    this.journalHotkey = defaultJournalHotkey,
    this.todoHotkey = defaultTodoHotkey,
    this.rankingColorStart = 0xFF4CAF50,
    this.rankingColorEnd = 0xFFF44336,
    this.timelineModeYearZero = true,
    this.birthYear,
    this.alertOnPeriodicPrompts = false,
    this.alertTimeHour = 9,
    this.hideCompletedTasks = false,
    this.deviceId,
    this.weatherLocationLabel,
    this.weatherLat,
    this.weatherLon,
    this.weatherIcon,
    this.weatherFetchedAt,
    this.weatherConditionCode,
    this.weatherTempC,
    this.weatherLocationUpdatedAt,
    this.devUseDirectOpenWeather = false,
    this.devOpenWeatherApiKey,
    this.weatherForecastJson,
    this.weatherChartTempColor,
    this.weatherChartRainColor,
    List<int>? colorPalette,
  }) : colorPalette = colorPalette ?? defaultColorPalette;

  final int accentColor;
  final bool weekStartsOnMonday;
  final bool showQuotes;
  final String journalHotkey;
  final String todoHotkey;
  final int rankingColorStart;
  final int rankingColorEnd;
  final bool timelineModeYearZero;
  final int? birthYear;
  final bool alertOnPeriodicPrompts;
  final int alertTimeHour;
  final bool hideCompletedTasks;
  final String? deviceId;
  final String? weatherLocationLabel;
  final double? weatherLat;
  final double? weatherLon;
  final String? weatherIcon;
  final DateTime? weatherFetchedAt;
  final int? weatherConditionCode;
  final double? weatherTempC;
  final DateTime? weatherLocationUpdatedAt;
  final bool devUseDirectOpenWeather;
  final String? devOpenWeatherApiKey;
  final String? weatherForecastJson;
  final int? weatherChartTempColor;
  final int? weatherChartRainColor;
  final List<int> colorPalette;

  bool get hasWeatherLocation => weatherLat != null && weatherLon != null;

  AppSettings copyWith({
    int? accentColor,
    bool? weekStartsOnMonday,
    bool? showQuotes,
    String? journalHotkey,
    String? todoHotkey,
    bool? hideCompletedTasks,
    String? deviceId,
    String? weatherLocationLabel,
    double? weatherLat,
    double? weatherLon,
    String? weatherIcon,
    DateTime? weatherFetchedAt,
    int? weatherConditionCode,
    double? weatherTempC,
    DateTime? weatherLocationUpdatedAt,
    bool? devUseDirectOpenWeather,
    String? devOpenWeatherApiKey,
    String? weatherForecastJson,
    int? weatherChartTempColor,
    int? weatherChartRainColor,
    List<int>? colorPalette,
    bool clearWeatherLocationLabel = false,
    bool clearWeatherLat = false,
    bool clearWeatherLon = false,
    bool clearWeatherIcon = false,
    bool clearWeatherFetchedAt = false,
    bool clearWeatherConditionCode = false,
    bool clearWeatherTempC = false,
    bool clearWeatherLocationUpdatedAt = false,
    bool clearDevOpenWeatherApiKey = false,
    bool clearWeatherForecastJson = false,
  }) {
    return AppSettings(
      accentColor: accentColor ?? this.accentColor,
      weekStartsOnMonday: weekStartsOnMonday ?? this.weekStartsOnMonday,
      showQuotes: showQuotes ?? this.showQuotes,
      journalHotkey: journalHotkey ?? this.journalHotkey,
      todoHotkey: todoHotkey ?? this.todoHotkey,
      rankingColorStart: rankingColorStart,
      rankingColorEnd: rankingColorEnd,
      timelineModeYearZero: timelineModeYearZero,
      birthYear: birthYear,
      alertOnPeriodicPrompts: alertOnPeriodicPrompts,
      alertTimeHour: alertTimeHour,
      hideCompletedTasks: hideCompletedTasks ?? this.hideCompletedTasks,
      deviceId: deviceId ?? this.deviceId,
      weatherLocationLabel: clearWeatherLocationLabel
          ? null
          : (weatherLocationLabel ?? this.weatherLocationLabel),
      weatherLat: clearWeatherLat ? null : (weatherLat ?? this.weatherLat),
      weatherLon: clearWeatherLon ? null : (weatherLon ?? this.weatherLon),
      weatherIcon: clearWeatherIcon ? null : (weatherIcon ?? this.weatherIcon),
      weatherFetchedAt: clearWeatherFetchedAt
          ? null
          : (weatherFetchedAt ?? this.weatherFetchedAt),
      weatherConditionCode: clearWeatherConditionCode
          ? null
          : (weatherConditionCode ?? this.weatherConditionCode),
      weatherTempC: clearWeatherTempC
          ? null
          : (weatherTempC ?? this.weatherTempC),
      weatherLocationUpdatedAt: clearWeatherLocationUpdatedAt
          ? null
          : (weatherLocationUpdatedAt ?? this.weatherLocationUpdatedAt),
      devUseDirectOpenWeather:
          devUseDirectOpenWeather ?? this.devUseDirectOpenWeather,
      devOpenWeatherApiKey: clearDevOpenWeatherApiKey
          ? null
          : (devOpenWeatherApiKey ?? this.devOpenWeatherApiKey),
      weatherForecastJson: clearWeatherForecastJson
          ? null
          : (weatherForecastJson ?? this.weatherForecastJson),
      weatherChartTempColor: weatherChartTempColor ?? this.weatherChartTempColor,
      weatherChartRainColor: weatherChartRainColor ?? this.weatherChartRainColor,
      colorPalette: colorPalette ?? this.colorPalette,
    );
  }
}

class Quote {
  const Quote({required this.id, required this.text});

  final String id;
  final String text;
}

class SyncOperation {
  const SyncOperation({
    required this.id,
    required this.documentId,
    required this.sequence,
    required this.payload,
    required this.deviceId,
    required this.timestamp,
  });

  final String id;
  final String documentId;
  final int sequence;
  final String payload;
  final String deviceId;
  final DateTime timestamp;
}

class GoogleCalendarSyncLock {
  const GoogleCalendarSyncLock({
    required this.deviceId,
    required this.lockedAt,
    required this.expiresAt,
  });

  final String deviceId;
  final DateTime lockedAt;
  final DateTime expiresAt;

  bool isValid(String requestingDeviceId, DateTime now) {
    if (now.isAfter(expiresAt)) return true;
    return deviceId == requestingDeviceId;
  }
}
