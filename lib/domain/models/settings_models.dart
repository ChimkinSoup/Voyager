import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/constants/hotkey_defaults.dart';
import 'package:voyager/domain/models/enums.dart';

export 'package:voyager/domain/models/enums.dart' show GeometricWaveShape;
class AppSettings {
  const AppSettings({
    this.accentColor = 0xFF7C9EFF,
    this.weekStartsOnMonday = true,
    this.showQuotes = true,
    this.showDefaultTrackersInGrid = true,
    this.showDefaultTrackersInCalendar = true,
    this.journalHotkey = defaultJournalHotkey,
    this.todoHotkey = defaultTodoHotkey,
    this.calendarNavigateLeftKey = defaultCalendarNavigateLeftKey,
    this.calendarNavigateRightKey = defaultCalendarNavigateRightKey,
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
    this.devSlowCalendarAnimations = false,
    this.devTodoSortDebugLog = false,
    this.devJournalDebugLog = false,
    this.devForceConflictUi = false,
    this.devShowConflictDocumentIds = false,
    this.devShowJournalRemotePullButton = false,
    this.geometricTextureScale = 10.0,
    this.geometricTextureIntensity = 0.85,
    this.geometricTextureFocalSpread = 1.0,
    this.geometricTextureFocalPointX = 1.0,
    this.geometricTextureFocalPointY = 0.5,
    this.geometricTextureVariationFloor = 0.75,
    this.geometricWaveEnabled = false,
    this.geometricWaveShape = GeometricWaveShape.linear,
    this.geometricWaveDirectionDegrees = 135.0,
    this.geometricWaveSpeed = 0.4,
    this.geometricWaveWidth = 0.08,
    this.geometricWavePeriod = 7.0,
    this.geometricWavePopHoldSeconds = 0.6,
    this.geometricWavePopScale = 1.4,
    this.geometricWavePopBrightness = 0.32,
    this.geometricWaveMaskDensity = 0.5,
    this.geometricWaveMaskClusterScale = 5.0,
    this.geometricWaveTwinkleSparsity = 0.15,
    this.geometricWaveShadowLightDegrees = 225.0,
    this.geometricWaveShadowOffset = 0.06,
    this.geometricWaveShadowSoftness = 0.04,
    this.geometricWaveShadowStrength = 0.45,
    this.geometricWavePopBrightnessVariance = 0.4,
    this.geometricWaveTiltAmount = 0.7,
    this.geometricWaveTiltShading = 0.5,
    this.geometricWaveMassLagSeconds = 0.12,
    this.geometricWaveMassSpring = 0.3,
    this.geometricWaveScatterMode = false,
    this.geometricWaveScatterLitAmount = 0.12,
    this.weatherForecastJson,
    this.weatherChartTempColor,
    this.weatherChartRainColor,
    this.weatherChartCurveTension = 0.22,
    this.journalEntryListWidth,
    this.navPageOrder,
    this.startupPageMode = StartupPageMode.first,
    this.customStartupPage,
    this.lastSeenNavPage,
    this.todoCompletedSectionExpanded = true,
    this.showAnnualizedSubscriptionCost = false,
    List<int>? colorPalette,
  }) : colorPalette = colorPalette ?? defaultColorPalette;

  final int accentColor;
  final bool weekStartsOnMonday;
  final bool showQuotes;

  /// Whether built-in default trackers (currently the "Journal Entries"
  /// tracker) appear in the analytics page's grid view.
  final bool showDefaultTrackersInGrid;

  /// Whether built-in default trackers are offered in the analytics page's
  /// calendar view (i.e. listed in its statistic dropdown).
  final bool showDefaultTrackersInCalendar;
  final String journalHotkey;
  final String todoHotkey;
  final String calendarNavigateLeftKey;
  final String calendarNavigateRightKey;
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
  final bool devSlowCalendarAnimations;
  final bool devTodoSortDebugLog;
  final bool devJournalDebugLog;
  final bool devForceConflictUi;
  final bool devShowConflictDocumentIds;
  final bool devShowJournalRemotePullButton;
  final double geometricTextureScale;
  final double geometricTextureIntensity;
  final double geometricTextureFocalSpread;
  final double geometricTextureFocalPointX;
  final double geometricTextureFocalPointY;
  final double geometricTextureVariationFloor;
  final bool geometricWaveEnabled;
  final GeometricWaveShape geometricWaveShape;
  final double geometricWaveDirectionDegrees;
  final double geometricWaveSpeed;
  final double geometricWaveWidth;
  final double geometricWavePeriod;
  final double geometricWavePopHoldSeconds;
  final double geometricWavePopScale;
  final double geometricWavePopBrightness;
  final double geometricWaveMaskDensity;
  final double geometricWaveMaskClusterScale;
  final double geometricWaveTwinkleSparsity;
  final double geometricWaveShadowLightDegrees;
  final double geometricWaveShadowOffset;
  final double geometricWaveShadowSoftness;
  final double geometricWaveShadowStrength;
  final double geometricWavePopBrightnessVariance;
  final double geometricWaveTiltAmount;
  final double geometricWaveTiltShading;
  final double geometricWaveMassLagSeconds;
  final double geometricWaveMassSpring;
  final bool geometricWaveScatterMode;
  final double geometricWaveScatterLitAmount;
  final String? weatherForecastJson;
  final int? weatherChartTempColor;
  final int? weatherChartRainColor;
  final double weatherChartCurveTension;
  final double? journalEntryListWidth;
  final List<String>? navPageOrder;
  final StartupPageMode startupPageMode;
  final String? customStartupPage;
  final String? lastSeenNavPage;

  /// Whether the "Completed" section in the to-do list is expanded. Persisted
  /// device-locally (this table isn't synced) so the collapsed state survives
  /// app restarts.
  final bool todoCompletedSectionExpanded;

  /// Whether the Bill Radar shows each subscription's annualized cost in faint
  /// text next to it (e.g. "$180/yr" beside a $15/month plan).
  final bool showAnnualizedSubscriptionCost;
  final List<int> colorPalette;

  bool get hasWeatherLocation => weatherLat != null && weatherLon != null;

  AppSettings copyWith({
    int? accentColor,
    bool? weekStartsOnMonday,
    bool? showQuotes,
    bool? showDefaultTrackersInGrid,
    bool? showDefaultTrackersInCalendar,
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
    bool? devSlowCalendarAnimations,
    bool? devTodoSortDebugLog,
    bool? devJournalDebugLog,
    bool? devForceConflictUi,
    bool? devShowConflictDocumentIds,
    bool? devShowJournalRemotePullButton,
    double? geometricTextureScale,
    double? geometricTextureIntensity,
    double? geometricTextureFocalSpread,
    double? geometricTextureFocalPointX,
    double? geometricTextureFocalPointY,
    double? geometricTextureVariationFloor,
    bool? geometricWaveEnabled,
    GeometricWaveShape? geometricWaveShape,
    double? geometricWaveDirectionDegrees,
    double? geometricWaveSpeed,
    double? geometricWaveWidth,
    double? geometricWavePeriod,
    double? geometricWavePopHoldSeconds,
    double? geometricWavePopScale,
    double? geometricWavePopBrightness,
    double? geometricWaveMaskDensity,
    double? geometricWaveMaskClusterScale,
    double? geometricWaveTwinkleSparsity,
    double? geometricWaveShadowLightDegrees,
    double? geometricWaveShadowOffset,
    double? geometricWaveShadowSoftness,
    double? geometricWaveShadowStrength,
    double? geometricWavePopBrightnessVariance,
    double? geometricWaveTiltAmount,
    double? geometricWaveTiltShading,
    double? geometricWaveMassLagSeconds,
    double? geometricWaveMassSpring,
    bool? geometricWaveScatterMode,
    double? geometricWaveScatterLitAmount,
    String? weatherForecastJson,
    int? weatherChartTempColor,
    int? weatherChartRainColor,
    double? weatherChartCurveTension,
    double? journalEntryListWidth,
    List<String>? navPageOrder,
    StartupPageMode? startupPageMode,
    String? customStartupPage,
    String? lastSeenNavPage,
    bool? todoCompletedSectionExpanded,
    bool? showAnnualizedSubscriptionCost,
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
    bool clearCustomStartupPage = false,
    bool clearLastSeenNavPage = false,
  }) {
    return AppSettings(
      accentColor: accentColor ?? this.accentColor,
      weekStartsOnMonday: weekStartsOnMonday ?? this.weekStartsOnMonday,
      showQuotes: showQuotes ?? this.showQuotes,
      showDefaultTrackersInGrid:
          showDefaultTrackersInGrid ?? this.showDefaultTrackersInGrid,
      showDefaultTrackersInCalendar:
          showDefaultTrackersInCalendar ?? this.showDefaultTrackersInCalendar,
      journalHotkey: journalHotkey ?? this.journalHotkey,
      todoHotkey: todoHotkey ?? this.todoHotkey,
      calendarNavigateLeftKey:
          calendarNavigateLeftKey ?? this.calendarNavigateLeftKey,
      calendarNavigateRightKey:
          calendarNavigateRightKey ?? this.calendarNavigateRightKey,
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
      devSlowCalendarAnimations:
          devSlowCalendarAnimations ?? this.devSlowCalendarAnimations,
      devTodoSortDebugLog: devTodoSortDebugLog ?? this.devTodoSortDebugLog,
      devJournalDebugLog: devJournalDebugLog ?? this.devJournalDebugLog,
      devForceConflictUi: devForceConflictUi ?? this.devForceConflictUi,
      devShowConflictDocumentIds:
          devShowConflictDocumentIds ?? this.devShowConflictDocumentIds,
      devShowJournalRemotePullButton: devShowJournalRemotePullButton ??
          this.devShowJournalRemotePullButton,
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
      geometricWaveEnabled: geometricWaveEnabled ?? this.geometricWaveEnabled,
      geometricWaveShape: geometricWaveShape ?? this.geometricWaveShape,
      geometricWaveDirectionDegrees:
          geometricWaveDirectionDegrees ?? this.geometricWaveDirectionDegrees,
      geometricWaveSpeed: geometricWaveSpeed ?? this.geometricWaveSpeed,
      geometricWaveWidth: geometricWaveWidth ?? this.geometricWaveWidth,
      geometricWavePeriod: geometricWavePeriod ?? this.geometricWavePeriod,
      geometricWavePopHoldSeconds:
          geometricWavePopHoldSeconds ?? this.geometricWavePopHoldSeconds,
      geometricWavePopScale: geometricWavePopScale ?? this.geometricWavePopScale,
      geometricWavePopBrightness:
          geometricWavePopBrightness ?? this.geometricWavePopBrightness,
      geometricWaveMaskDensity:
          geometricWaveMaskDensity ?? this.geometricWaveMaskDensity,
      geometricWaveMaskClusterScale:
          geometricWaveMaskClusterScale ?? this.geometricWaveMaskClusterScale,
      geometricWaveTwinkleSparsity:
          geometricWaveTwinkleSparsity ?? this.geometricWaveTwinkleSparsity,
      geometricWaveShadowLightDegrees:
          geometricWaveShadowLightDegrees ??
          this.geometricWaveShadowLightDegrees,
      geometricWaveShadowOffset:
          geometricWaveShadowOffset ?? this.geometricWaveShadowOffset,
      geometricWaveShadowSoftness:
          geometricWaveShadowSoftness ?? this.geometricWaveShadowSoftness,
      geometricWaveShadowStrength:
          geometricWaveShadowStrength ?? this.geometricWaveShadowStrength,
      geometricWavePopBrightnessVariance:
          geometricWavePopBrightnessVariance ??
          this.geometricWavePopBrightnessVariance,
      geometricWaveTiltAmount:
          geometricWaveTiltAmount ?? this.geometricWaveTiltAmount,
      geometricWaveTiltShading:
          geometricWaveTiltShading ?? this.geometricWaveTiltShading,
      geometricWaveMassLagSeconds:
          geometricWaveMassLagSeconds ?? this.geometricWaveMassLagSeconds,
      geometricWaveMassSpring:
          geometricWaveMassSpring ?? this.geometricWaveMassSpring,
      geometricWaveScatterMode:
          geometricWaveScatterMode ?? this.geometricWaveScatterMode,
      geometricWaveScatterLitAmount:
          geometricWaveScatterLitAmount ?? this.geometricWaveScatterLitAmount,
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
      navPageOrder: navPageOrder ?? this.navPageOrder,
      startupPageMode: startupPageMode ?? this.startupPageMode,
      customStartupPage: clearCustomStartupPage
          ? null
          : (customStartupPage ?? this.customStartupPage),
      lastSeenNavPage: clearLastSeenNavPage
          ? null
          : (lastSeenNavPage ?? this.lastSeenNavPage),
      todoCompletedSectionExpanded:
          todoCompletedSectionExpanded ?? this.todoCompletedSectionExpanded,
      showAnnualizedSubscriptionCost: showAnnualizedSubscriptionCost ??
          this.showAnnualizedSubscriptionCost,
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
