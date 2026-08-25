import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/constants/hotkey_defaults.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/snippet.dart';

export 'package:voyager/domain/models/enums.dart'
    show GeometricWaveShape, AppThemeMode, WeightUnit, SnippetExpandKey;
export 'package:voyager/domain/models/snippet.dart' show Snippet;

/// Default petal tint for the light theme — a dusty watercolor rose, kept
/// separate from the accent color so the petals never fight the UI's own
/// highlight color.
const int defaultPetalColor = 0xFFE6A4B4;

class AppSettings {
  const AppSettings({
    this.accentColor = 0xFF7C9EFF,
    this.themeMode = AppThemeMode.dark,
    this.petalColor = defaultPetalColor,
    this.minorPetalColors = const [],
    this.petalMaxCount = 60,
    this.petalFallSpeed = 34.0,
    this.petalWindFrequency = 0.12,
    this.petalWindStrength = 46.0,
    this.weekStartsOnMonday = true,
    this.showQuotes = true,
    this.showDefaultTrackersInGrid = true,
    this.showDefaultTrackersInCalendar = true,
    this.journalHotkey = defaultJournalHotkey,
    this.todoHotkey = defaultTodoHotkey,
    this.calendarNavigateLeftKey = defaultCalendarNavigateLeftKey,
    this.calendarNavigateRightKey = defaultCalendarNavigateRightKey,
    this.srsFailKey = defaultStudyFailKey,
    this.srsHardKey = defaultStudyHardKey,
    this.srsGoodKey = defaultStudyGoodKey,
    this.srsEasyKey = defaultStudyEasyKey,
    this.timelineModeYearZero = true,
    this.birthYear,
    this.birthDate,
    this.alertOnPeriodicPrompts = false,
    this.alertTimeHour = 9,
    this.hideCompletedTasks = false,
    this.vimModeEnabled = false,
    this.snippetsEnabled = true,
    this.capsLockIndicatorEnabled = true,
    this.snippetExpandKey = SnippetExpandKey.tab,
    this.snippets = const [],
    this.deviceId,
    this.lastViewedJournalId,
    this.lastViewedTodoListId,
    this.defaultJournalId,
    this.defaultTodoListId,
    this.journalShowAllEntries = false,
    this.todoShowAllTasks = false,
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
    this.devShowFpsCounter = false,
    this.devDisableCache = false,
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
    this.jobsHiddenColumns = const [],
    this.jobsIncludeArchived = false,
    this.dreamSplitWidth,
    this.showDreamStatistics = false,
    this.dreamNotesPinned = false,
    this.leetcodeUsername,
    this.showNeetCode150 = true,
    this.leetCodeHideDifficulty = false,
    this.leetCodeHideTags = false,
    this.leetCodeHideQuestionName = false,
    this.leetCodeHideDescription = false,
    this.leetCodeHideExamples = false,
    this.leetCodeHideComplexity = false,
    this.leetCodeHideCode = false,
    this.weightUnit = WeightUnit.lb,
    this.workoutRestTimerEnabled = false,
    this.workoutRestSeconds = 90,
    this.showWorkoutsOnCalendar = false,
    this.showWorkoutStatistics = false,
    this.updatedAt,
    this.syncBackfillVersion = 0,
    List<int>? colorPalette,
  }) : colorPalette = colorPalette ?? defaultColorPalette;

  final int accentColor;

  /// Which hand-built theme is active. See [AppThemeMode].
  final AppThemeMode themeMode;

  /// Tint of the light theme's falling petals.
  final int petalColor;

  /// Secondary petal tints, ordered top to bottom by rank (first entry is the
  /// most common minor color). Each falling petal randomly picks one of these
  /// or [petalColor] according to a fixed weighting keyed by how many minor
  /// colors are configured. Capped at 3 entries.
  final List<int> minorPetalColors;

  /// Ceiling on simultaneously live petals. The field spawns up to this many
  /// and never allocates beyond it.
  final int petalMaxCount;

  /// Baseline downward drift speed, in logical pixels per second, before
  /// per-petal size variation.
  final double petalFallSpeed;

  /// How often the shared wind field reverses, in Hz. Lower = long, lazy
  /// swells; higher = fluttery gusts.
  final double petalWindFrequency;

  /// Peak horizontal wind velocity, in logical pixels per second.
  final double petalWindStrength;

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

  /// Grading keybinds for Study SRS/cram sessions. Space always flips the
  /// card regardless of these — see STUDY.md's "Additional Notes".
  final String srsFailKey;
  final String srsHardKey;
  final String srsGoodKey;
  final String srsEasyKey;
  final bool timelineModeYearZero;
  final int? birthYear;

  /// Full birth date (day precision), used by the Life Tracker page's
  /// week/age math. Separate from [birthYear], which predates it and is
  /// year-only — insufficient for week-precision calculations.
  final DateTime? birthDate;
  final bool alertOnPeriodicPrompts;
  final int alertTimeHour;
  final bool hideCompletedTasks;

  /// Whether Vim keybindings are active in the app's text boxes.
  final bool vimModeEnabled;

  /// Master switch for text snippets. On by default, which is free: the list
  /// ships empty, and an empty list can never expand anything.
  ///
  /// Deliberately independent of [vimModeEnabled] — snippets run in the same
  /// fields Vim would suit, whether or not Vim itself is switched on.
  final bool snippetsEnabled;

  /// Master switch for the Caps Lock caret mark. On by default: it costs
  /// nothing until Caps Lock is actually on, and the one moment it matters —
  /// typing a password in caps without noticing — is the moment nobody would
  /// have thought to switch it on for.
  ///
  /// Windows and Linux only whatever this says; macOS draws its own glyph and a
  /// soft keyboard has no lock key. See `CapsLockIndicatorScope`.
  final bool capsLockIndicatorEnabled;

  /// Which key expands a non-auto snippet. Global rather than per-snippet.
  final SnippetExpandKey snippetExpandKey;

  /// The user's snippets, in the order the settings list shows them. Triggers
  /// are unique; the settings editor is what enforces that.
  final List<Snippet> snippets;
  final String? deviceId;
  final String? lastViewedJournalId;
  final String? lastViewedTodoListId;

  /// The journal the journal page always opens into. When set it wins over
  /// both [lastViewedJournalId] and [journalShowAllEntries]; null restores
  /// whatever was last open.
  final String? defaultJournalId;

  /// The todo list the todo page always opens into. When set it wins over both
  /// [lastViewedTodoListId] and [todoShowAllTasks]; null restores whatever was
  /// last open.
  final String? defaultTodoListId;

  /// Whether the page was left in its "All journals" / "All tasks" view. Held
  /// apart from the ids above so restoring the all-view doesn't lose track of
  /// which journal/list a new entry or task should be created in.
  final bool journalShowAllEntries;
  final bool todoShowAllTasks;
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

  /// Dev-only: overlay a live FPS counter and a last-minute FPS graph, top-right.
  final bool devShowFpsCounter;
  final bool devDisableCache;
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

  /// Jobs table columns switched off, by column id. The hidden set rather than
  /// the visible one, so a column added in a later build defaults to shown.
  final List<String> jobsHiddenColumns;

  /// Whether the Jobs page includes archived applications in the list, the
  /// sparkline and the Sankey.
  final bool jobsIncludeArchived;
  final List<int> colorPalette;

  /// Adjustable width of the Dream Journal's entry-list pane, mirroring
  /// [journalEntryListWidth].
  final double? dreamSplitWidth;

  /// Whether the analytics page shows the "logged a dream today" stat.
  final bool showDreamStatistics;

  /// Whether the Dream Journal's sticky-note scratchpad is currently pinned
  /// open as a bottom panel rather than collapsed to its corner peek.
  final bool dreamNotesPinned;

  /// LeetCode username used to look up the user's own submissions via the
  /// public GraphQL endpoint (e.g. prefilling the Track modal with the
  /// most recently accepted submission).
  final String? leetcodeUsername;

  /// Whether the LeetCode dashboard shows the NeetCode 150 progress ring.
  final bool showNeetCode150;

  /// What a LeetCode Study or Cram session leaves off the card. Each one
  /// blanks a part the user would rather recall than be shown; none of them
  /// touch the Review Deck's grid, which is a browsing view where a hidden
  /// title would only make a problem harder to find.
  final bool leetCodeHideDifficulty;
  final bool leetCodeHideTags;

  /// Hides the number and the title together — they read as one line on the
  /// card, and a number alone still names the problem.
  final bool leetCodeHideQuestionName;
  final bool leetCodeHideDescription;
  final bool leetCodeHideExamples;

  /// Back-of-card hides: the Time/Space line, and the solution code.
  final bool leetCodeHideComplexity;
  final bool leetCodeHideCode;

  /// Display unit for every weight in the workout tracker. Storage stays in
  /// kilograms, so flipping this converts what's shown without rewriting a
  /// single logged set.
  final WeightUnit weightUnit;

  /// Whether a rest countdown starts when a set is marked complete. Off by
  /// default — the spec asks for the timer to be opt-in.
  final bool workoutRestTimerEnabled;
  final int workoutRestSeconds;

  /// Whether days with a completed workout get a small icon on the month and
  /// week calendars (never the year view, whose cells have no room).
  final bool showWorkoutsOnCalendar;

  /// Whether the analytics page shows the "worked out today" daily boolean.
  final bool showWorkoutStatistics;

  /// When a setting that syncs last changed, on whichever device changed it —
  /// the last-write-wins clock for the whole settings document. Null on a row
  /// written before this existed.
  ///
  /// Only [settingsSyncPayload] fields move it: a weather refresh, a dev-flag
  /// toggle, or remembering which page you were on are device-local writes,
  /// and letting them bump this clock would let simply opening the app
  /// overwrite a preference another device changed more recently.
  final DateTime? updatedAt;

  /// Which one-time upload of the newly synced collections this device has
  /// already run. Device-local: it describes this installation's upload
  /// history, not a preference, so it never joins [settingsSyncPayload].
  final int syncBackfillVersion;

  bool get hasWeatherLocation => weatherLat != null && weatherLon != null;

  AppSettings copyWith({
    int? accentColor,
    AppThemeMode? themeMode,
    int? petalColor,
    List<int>? minorPetalColors,
    int? petalMaxCount,
    double? petalFallSpeed,
    double? petalWindFrequency,
    double? petalWindStrength,
    bool? weekStartsOnMonday,
    bool? showQuotes,
    bool? showDefaultTrackersInGrid,
    bool? showDefaultTrackersInCalendar,
    String? journalHotkey,
    String? todoHotkey,
    String? calendarNavigateLeftKey,
    String? calendarNavigateRightKey,
    String? srsFailKey,
    String? srsHardKey,
    String? srsGoodKey,
    String? srsEasyKey,
    bool? hideCompletedTasks,
    bool? vimModeEnabled,
    bool? snippetsEnabled,
    bool? capsLockIndicatorEnabled,
    SnippetExpandKey? snippetExpandKey,
    List<Snippet>? snippets,
    bool? timelineModeYearZero,
    int? birthYear,
    bool clearBirthYear = false,
    DateTime? birthDate,
    bool? alertOnPeriodicPrompts,
    int? alertTimeHour,
    String? deviceId,
    String? lastViewedJournalId,
    String? lastViewedTodoListId,
    String? defaultJournalId,
    String? defaultTodoListId,
    bool? journalShowAllEntries,
    bool? todoShowAllTasks,
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
    bool? devShowFpsCounter,
    bool? devDisableCache,
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
    List<String>? jobsHiddenColumns,
    bool? jobsIncludeArchived,
    double? dreamSplitWidth,
    bool? showDreamStatistics,
    bool? dreamNotesPinned,
    String? leetcodeUsername,
    bool? showNeetCode150,
    bool? leetCodeHideDifficulty,
    bool? leetCodeHideTags,
    bool? leetCodeHideQuestionName,
    bool? leetCodeHideDescription,
    bool? leetCodeHideExamples,
    bool? leetCodeHideComplexity,
    bool? leetCodeHideCode,
    WeightUnit? weightUnit,
    bool? workoutRestTimerEnabled,
    int? workoutRestSeconds,
    bool? showWorkoutsOnCalendar,
    bool? showWorkoutStatistics,
    DateTime? updatedAt,
    int? syncBackfillVersion,
    List<int>? colorPalette,
    bool clearLeetcodeUsername = false,
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
    bool clearDefaultJournalId = false,
    bool clearDefaultTodoListId = false,
    bool clearJournalEntryListWidth = false,
    bool clearCustomStartupPage = false,
    bool clearLastSeenNavPage = false,
    bool clearDreamSplitWidth = false,
    // Needed by the settings merge: a field the user cleared on another device
    // has to arrive as "cleared" rather than being read as "unspecified" by
    // the `??` fallbacks below and silently keeping the old local value.
    bool clearBirthDate = false,
    bool clearNavPageOrder = false,
    bool clearWeatherChartTempColor = false,
    bool clearWeatherChartRainColor = false,
  }) {
    return AppSettings(
      accentColor: accentColor ?? this.accentColor,
      themeMode: themeMode ?? this.themeMode,
      petalColor: petalColor ?? this.petalColor,
      minorPetalColors: minorPetalColors ?? this.minorPetalColors,
      petalMaxCount: petalMaxCount ?? this.petalMaxCount,
      petalFallSpeed: petalFallSpeed ?? this.petalFallSpeed,
      petalWindFrequency: petalWindFrequency ?? this.petalWindFrequency,
      petalWindStrength: petalWindStrength ?? this.petalWindStrength,
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
      srsFailKey: srsFailKey ?? this.srsFailKey,
      srsHardKey: srsHardKey ?? this.srsHardKey,
      srsGoodKey: srsGoodKey ?? this.srsGoodKey,
      srsEasyKey: srsEasyKey ?? this.srsEasyKey,
      timelineModeYearZero: timelineModeYearZero ?? this.timelineModeYearZero,
      birthYear: clearBirthYear ? null : (birthYear ?? this.birthYear),
      birthDate: clearBirthDate ? null : (birthDate ?? this.birthDate),
      alertOnPeriodicPrompts:
          alertOnPeriodicPrompts ?? this.alertOnPeriodicPrompts,
      alertTimeHour: alertTimeHour ?? this.alertTimeHour,
      hideCompletedTasks: hideCompletedTasks ?? this.hideCompletedTasks,
      vimModeEnabled: vimModeEnabled ?? this.vimModeEnabled,
      snippetsEnabled: snippetsEnabled ?? this.snippetsEnabled,
      capsLockIndicatorEnabled:
          capsLockIndicatorEnabled ?? this.capsLockIndicatorEnabled,
      snippetExpandKey: snippetExpandKey ?? this.snippetExpandKey,
      snippets: snippets ?? this.snippets,
      deviceId: deviceId ?? this.deviceId,
      lastViewedJournalId: clearLastViewedJournalId
          ? null
          : (lastViewedJournalId ?? this.lastViewedJournalId),
      lastViewedTodoListId: clearLastViewedTodoListId
          ? null
          : (lastViewedTodoListId ?? this.lastViewedTodoListId),
      defaultJournalId: clearDefaultJournalId
          ? null
          : (defaultJournalId ?? this.defaultJournalId),
      defaultTodoListId: clearDefaultTodoListId
          ? null
          : (defaultTodoListId ?? this.defaultTodoListId),
      journalShowAllEntries:
          journalShowAllEntries ?? this.journalShowAllEntries,
      todoShowAllTasks: todoShowAllTasks ?? this.todoShowAllTasks,
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
      devShowFpsCounter: devShowFpsCounter ?? this.devShowFpsCounter,
      devDisableCache: devDisableCache ?? this.devDisableCache,
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
      weatherChartTempColor: clearWeatherChartTempColor
          ? null
          : (weatherChartTempColor ?? this.weatherChartTempColor),
      weatherChartRainColor: clearWeatherChartRainColor
          ? null
          : (weatherChartRainColor ?? this.weatherChartRainColor),
      weatherChartCurveTension:
          weatherChartCurveTension ?? this.weatherChartCurveTension,
      journalEntryListWidth: clearJournalEntryListWidth
          ? null
          : (journalEntryListWidth ?? this.journalEntryListWidth),
      navPageOrder: clearNavPageOrder ? null : (navPageOrder ?? this.navPageOrder),
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
      jobsHiddenColumns: jobsHiddenColumns ?? this.jobsHiddenColumns,
      jobsIncludeArchived: jobsIncludeArchived ?? this.jobsIncludeArchived,
      colorPalette: colorPalette ?? this.colorPalette,
      dreamSplitWidth: clearDreamSplitWidth
          ? null
          : (dreamSplitWidth ?? this.dreamSplitWidth),
      showDreamStatistics: showDreamStatistics ?? this.showDreamStatistics,
      dreamNotesPinned: dreamNotesPinned ?? this.dreamNotesPinned,
      leetcodeUsername: clearLeetcodeUsername
          ? null
          : (leetcodeUsername ?? this.leetcodeUsername),
      showNeetCode150: showNeetCode150 ?? this.showNeetCode150,
      leetCodeHideDifficulty:
          leetCodeHideDifficulty ?? this.leetCodeHideDifficulty,
      leetCodeHideTags: leetCodeHideTags ?? this.leetCodeHideTags,
      leetCodeHideQuestionName:
          leetCodeHideQuestionName ?? this.leetCodeHideQuestionName,
      leetCodeHideDescription:
          leetCodeHideDescription ?? this.leetCodeHideDescription,
      leetCodeHideExamples:
          leetCodeHideExamples ?? this.leetCodeHideExamples,
      leetCodeHideComplexity:
          leetCodeHideComplexity ?? this.leetCodeHideComplexity,
      leetCodeHideCode: leetCodeHideCode ?? this.leetCodeHideCode,
      weightUnit: weightUnit ?? this.weightUnit,
      workoutRestTimerEnabled:
          workoutRestTimerEnabled ?? this.workoutRestTimerEnabled,
      workoutRestSeconds: workoutRestSeconds ?? this.workoutRestSeconds,
      showWorkoutsOnCalendar:
          showWorkoutsOnCalendar ?? this.showWorkoutsOnCalendar,
      showWorkoutStatistics:
          showWorkoutStatistics ?? this.showWorkoutStatistics,
      updatedAt: updatedAt ?? this.updatedAt,
      syncBackfillVersion: syncBackfillVersion ?? this.syncBackfillVersion,
    );
  }
}

class Quote {
  const Quote({required this.id, required this.text});

  final String id;
  final String text;
}

/// A quote the user wrote, pooled with the bundled ones a journal entry draws
/// from.
///
/// Synced, so it carries the same id/timestamps/version/deletedAt shape as the
/// other synced entities. [toQuote] is how it joins the bundled asset quotes in
/// the pool.
/// The color the user picked for one journal tag.
///
/// Carries no `deletedAt`: a tag's color can be re-picked but never removed,
/// so there is nothing for a tombstone to describe.
class TagColorRecord {
  const TagColorRecord({
    required this.tag,
    required this.colorValue,
    required this.updatedAt,
    this.version = 0,
  });

  final String tag;
  final int colorValue;
  final DateTime updatedAt;
  final int version;
}

/// A word the user added to the spell checker's dictionary.
///
/// Removing one tombstones it rather than dropping the row, so the removal
/// reaches the user's other devices instead of the word coming back on their
/// next pull.
class CustomWord {
  const CustomWord({
    required this.word,
    required this.createdAt,
    required this.updatedAt,
    this.version = 0,
    this.deletedAt,
  });

  final String word;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;
  final DateTime? deletedAt;
}

class CustomQuote {
  const CustomQuote({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    this.version = 0,
    this.deletedAt,
  });

  final String id;
  final String text;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;
  final DateTime? deletedAt;

  Quote toQuote() => Quote(id: id, text: text);

  CustomQuote copyWith({
    String? text,
    DateTime? updatedAt,
    int? version,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return CustomQuote(
      id: id,
      text: text ?? this.text,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }
}

/// Whether [a] and [b] are the same quote for duplicate-detection purposes:
/// case- and whitespace-insensitive, so "Carpe diem" can't be added twice as
/// "carpe  diem ".
///
/// Shared by the settings editor and any other entry point, so one cannot
/// admit a duplicate the other would have rejected.
bool sameQuoteText(String a, String b) =>
    normalizeQuoteText(a) == normalizeQuoteText(b);

String normalizeQuoteText(String text) =>
    text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

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
