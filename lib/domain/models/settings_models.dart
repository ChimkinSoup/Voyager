import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/constants/hotkey_defaults.dart';
class AppSettings {
  const AppSettings({
    this.accentColor = 0xFF7C9EFF,
    this.weekStartsOnMonday = true,
    this.showQuotes = true,
    this.journalHotkey = defaultJournalHotkey,
    this.todoHotkey = defaultTodoHotkey,
    this.calendarNavigateLeftKey = defaultCalendarNavigateLeftKey,
    this.calendarNavigateRightKey = defaultCalendarNavigateRightKey,
    this.rankingColorStart = 0xFF4CAF50,
    this.rankingColorEnd = 0xFFF44336,
    this.timelineModeYearZero = true,
    this.birthYear,
    this.alertOnPeriodicPrompts = false,
    this.alertTimeHour = 9,
    this.hideCompletedTasks = false,
    this.deviceId,
    this.lastViewedJournalId,
    this.lastViewedTodoListId,
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
    this.devShowSyncLocalSaves = false,
    this.devShowSyncUploads = false,
    this.devShowSyncDownloads = false,
    this.devShowCacheStatus = false,
    this.devShowCalendarZoomPrewarm = false,
    this.devShowCalendarInstantViewSwitch = false,
    this.devTodoSortDebugLog = false,
    this.devJournalDebugLog = false,
    this.devForceConflictUi = false,
    this.devShowConflictDocumentIds = false,
    this.geometricTextureScale = 10.0,
    this.geometricTextureIntensity = 0.85,
    this.geometricTextureFocalSpread = 1.0,
    this.geometricTextureFocalPointX = 1.0,
    this.geometricTextureFocalPointY = 0.5,
    this.geometricTextureVariationFloor = 0.75,
    this.weatherForecastJson,
    this.weatherChartTempColor,
    this.weatherChartRainColor,
    this.weatherChartCurveTension = 0.22,
    this.journalEntryListWidth,
    List<int>? colorPalette,
  }) : colorPalette = colorPalette ?? defaultColorPalette;

  final int accentColor;
  final bool weekStartsOnMonday;
  final bool showQuotes;
  final String journalHotkey;
  final String todoHotkey;
  final String calendarNavigateLeftKey;
  final String calendarNavigateRightKey;
  final int rankingColorStart;
  final int rankingColorEnd;
  final bool timelineModeYearZero;
  final int? birthYear;
  final bool alertOnPeriodicPrompts;
  final int alertTimeHour;
  final bool hideCompletedTasks;
  final String? deviceId;
  final String? lastViewedJournalId;
  final String? lastViewedTodoListId;
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
  final bool devShowSyncLocalSaves;
  final bool devShowSyncUploads;
  final bool devShowSyncDownloads;
  final bool devShowCacheStatus;
  final bool devShowCalendarZoomPrewarm;
  final bool devShowCalendarInstantViewSwitch;
  final bool devTodoSortDebugLog;
  final bool devJournalDebugLog;
  final bool devForceConflictUi;
  final bool devShowConflictDocumentIds;
  final double geometricTextureScale;
  final double geometricTextureIntensity;
  final double geometricTextureFocalSpread;
  final double geometricTextureFocalPointX;
  final double geometricTextureFocalPointY;
  final double geometricTextureVariationFloor;
  final String? weatherForecastJson;
  final int? weatherChartTempColor;
  final int? weatherChartRainColor;
  final double weatherChartCurveTension;
  final double? journalEntryListWidth;
  final List<int> colorPalette;

  bool get hasWeatherLocation => weatherLat != null && weatherLon != null;

  AppSettings copyWith({
    int? accentColor,
    bool? weekStartsOnMonday,
    bool? showQuotes,
    String? journalHotkey,
    String? todoHotkey,
    String? calendarNavigateLeftKey,
    String? calendarNavigateRightKey,
    bool? hideCompletedTasks,
    String? deviceId,
    String? lastViewedJournalId,
    String? lastViewedTodoListId,
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
    bool? devShowSyncLocalSaves,
    bool? devShowSyncUploads,
    bool? devShowSyncDownloads,
    bool? devShowCacheStatus,
    bool? devShowCalendarZoomPrewarm,
    bool? devShowCalendarInstantViewSwitch,
    bool? devTodoSortDebugLog,
    bool? devJournalDebugLog,
    bool? devForceConflictUi,
    bool? devShowConflictDocumentIds,
    double? geometricTextureScale,
    double? geometricTextureIntensity,
    double? geometricTextureFocalSpread,
    double? geometricTextureFocalPointX,
    double? geometricTextureFocalPointY,
    double? geometricTextureVariationFloor,
    String? weatherForecastJson,
    int? weatherChartTempColor,
    int? weatherChartRainColor,
    double? weatherChartCurveTension,
    double? journalEntryListWidth,
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
    bool clearLastViewedJournalId = false,
    bool clearLastViewedTodoListId = false,
    bool clearJournalEntryListWidth = false,
  }) {
    return AppSettings(
      accentColor: accentColor ?? this.accentColor,
      weekStartsOnMonday: weekStartsOnMonday ?? this.weekStartsOnMonday,
      showQuotes: showQuotes ?? this.showQuotes,
      journalHotkey: journalHotkey ?? this.journalHotkey,
      todoHotkey: todoHotkey ?? this.todoHotkey,
      calendarNavigateLeftKey:
          calendarNavigateLeftKey ?? this.calendarNavigateLeftKey,
      calendarNavigateRightKey:
          calendarNavigateRightKey ?? this.calendarNavigateRightKey,
      rankingColorStart: rankingColorStart,
      rankingColorEnd: rankingColorEnd,
      timelineModeYearZero: timelineModeYearZero,
      birthYear: birthYear,
      alertOnPeriodicPrompts: alertOnPeriodicPrompts,
      alertTimeHour: alertTimeHour,
      hideCompletedTasks: hideCompletedTasks ?? this.hideCompletedTasks,
      deviceId: deviceId ?? this.deviceId,
      lastViewedJournalId: clearLastViewedJournalId
          ? null
          : (lastViewedJournalId ?? this.lastViewedJournalId),
      lastViewedTodoListId: clearLastViewedTodoListId
          ? null
          : (lastViewedTodoListId ?? this.lastViewedTodoListId),
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
      devShowSyncLocalSaves:
          devShowSyncLocalSaves ?? this.devShowSyncLocalSaves,
      devShowSyncUploads: devShowSyncUploads ?? this.devShowSyncUploads,
      devShowSyncDownloads: devShowSyncDownloads ?? this.devShowSyncDownloads,
      devShowCacheStatus: devShowCacheStatus ?? this.devShowCacheStatus,
      devShowCalendarZoomPrewarm:
          devShowCalendarZoomPrewarm ?? this.devShowCalendarZoomPrewarm,
      devShowCalendarInstantViewSwitch: devShowCalendarInstantViewSwitch ??
          this.devShowCalendarInstantViewSwitch,
      devTodoSortDebugLog: devTodoSortDebugLog ?? this.devTodoSortDebugLog,
      devJournalDebugLog: devJournalDebugLog ?? this.devJournalDebugLog,
      devForceConflictUi: devForceConflictUi ?? this.devForceConflictUi,
      devShowConflictDocumentIds:
          devShowConflictDocumentIds ?? this.devShowConflictDocumentIds,
      geometricTextureScale:
          geometricTextureScale ?? this.geometricTextureScale,
      geometricTextureIntensity:
          geometricTextureIntensity ?? this.geometricTextureIntensity,
      geometricTextureFocalSpread:
          geometricTextureFocalSpread ?? this.geometricTextureFocalSpread,
      geometricTextureFocalPointX:
          geometricTextureFocalPointX ?? this.geometricTextureFocalPointX,
      geometricTextureFocalPointY:
          geometricTextureFocalPointY ?? this.geometricTextureFocalPointY,
      geometricTextureVariationFloor: geometricTextureVariationFloor ??
          this.geometricTextureVariationFloor,
      weatherForecastJson: clearWeatherForecastJson
          ? null
          : (weatherForecastJson ?? this.weatherForecastJson),
      weatherChartTempColor: weatherChartTempColor ?? this.weatherChartTempColor,
      weatherChartRainColor: weatherChartRainColor ?? this.weatherChartRainColor,
      weatherChartCurveTension:
          weatherChartCurveTension ?? this.weatherChartCurveTension,
      journalEntryListWidth: clearJournalEntryListWidth
          ? null
          : (journalEntryListWidth ?? this.journalEntryListWidth),
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
