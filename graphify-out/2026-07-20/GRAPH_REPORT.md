# Graph Report - Voyager  (2026-07-19)

## Corpus Check
- 340 files · ~317,310 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 7298 nodes · 10441 edges · 268 communities (237 shown, 31 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 47 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `d398db16`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Database Data
- Calendar Features
- Calendar Day
- Journal Features
- Features Shell
- Calendar Features
- Sync Remote
- Todo Features
- Repositories Domain
- Calendar Grid
- App Dev
- Todo Features
- Models Domain
- Calendar Markers
- Dev Remote
- Repositories Data
- Sync Weather
- Todo Task
- App Providers
- Analytics Features
- Merger Services
- Search Features
- Todo Features
- Text Widgets
- Windows Runner
- Widgets Color
- Widgets Rounded
- Widgets Contextual
- Windows Ephemeral
- Time Widgets
- Calendar Features
- Widgets Datetime
- Domain Services
- Windows Cpp
- Shell Features
- Import Export
- Todo List
- Sync Firestore
- Windows Ephemeral
- Sync Engine
- Calendar Event
- Sync Conflict
- Calendar Features
- Features Dev
- Models Domain
- Todo Features
- Sync Conflict
- Time Widgets
- Domain Services
- Dev Journal
- Windows Ephemeral
- Widgets Text
- Weather Features
- Widgets Field
- Weather Forecast
- Windows Ephemeral
- Windows Ephemeral
- Widgets Notched
- Data Remote
- Crdt Frac
- Weather Features
- Journal Features
- Sync Activity
- Models Domain
- Platform Keyboard
- Database Users
- Features Shell
- Windows Ephemeral
- Firestore Data
- Windows Ephemeral
- Widgets Geometric
- Text Sync
- Calendar Features
- Domain Services
- Widgets Keep
- Domain Services
- Main App
- Widgets Date
- Features Shell
- Calendar Features
- Sync Journal
- Domain Services
- Shell Shortcuts
- Models Domain
- Cloud Data
- Journal Features
- Widgets Desktop
- Domain Calendar
- Windows Ephemeral
- Client Data
- Dev Cache
- Features Shell
- Functions Forecast
- Features Page
- Dev Features
- Theme Menu
- Registrar Windows
- Functions Src
- Dev Settings
- Dev Todo
- Binding Utils
- Widgets Resizable
- Auth Data
- Character Domain
- Features Calendar
- Features Calendar
- Widgets Clamp
- Hotkey Features
- Palette Color
- Dev Sync
- Domain Repositories
- Calendar Features
- Windows Ephemeral
- Widgets Desktop
- Widgets Dropdown
- App Providers
- Windows Ephemeral
- Sync Debouncer
- Widgets Menu
- Widgets Search
- Models Domain
- Settings Palette
- Windows Ephemeral
- Platform Widgets
- Shell Features
- Windows Ephemeral
- Database Data
- Menu Widgets
- Sync Outbox
- Functions Scripts
- Dev Warmup
- Todo Task
- Gradient Widgets
- Models Analytics
- Models Domain
- Windows Ephemeral
- Platform Domain
- Domain Services
- Functions Tsconfig
- Auth Firebase
- Color Widgets
- FlutterView
- Windows Ephemeral
- Windows Ephemeral
- Widgets Selector
- Constants Google
- Features Analytics
- Features Settings
- Shell App
- Widgets Features
- Constants Journal
- Widgets Confirm
- Weather Fakes
- Features Settings
- Shell App
- Data Remote
- Delta Scramble
- Dev Sync
- Windows Runner
- Domain Services
- Shell Features
- Windows Ephemeral
- Sync Text
- Sync Pending
- App Providers
- trackerRepositoryProvider
- Theme Spacing
- settingsRepositoryProvider
- Windows Ephemeral
- .CallTopLevelWindowProcDelegates
- ByteBufferStreamReader
- Widgets Enter
- Gpusurfacetexture Windows
- @immutable
- Constants Todo
- Shell Features
- Messenger Windows
- dart:math
- Constants Hotkey
- Sync Firestore
- @visibleForTesting
- MethodCall
- Anagram List1
- dart:math
- Calendar Features
- debouncer.dart
- Widgets Rounded
- Chart Weather
- Android Gradlew
- Deinterleave Evens
- WeatherApiClient
- Dev Flags
- Utils Ids
- Utils Journal
- Google Desktop
- Constants Todo
- PLAN.md
- Mainactivity Android
- Calendar Customclipper
- High-Level Design: Voyager Weekly Calendar View
- IMPORT_EXPORT.md
- Constants App
- todoSortDebugLoggerProvider
- Color
- Constants Default
- desktop_google_oauth_test.dart
- Domain Services
- Calendar Features
- enums.dart
- ADR 001: Local-First Data Model
- ADR 002: Sync Protocol Boundaries
- ADR 003: Module Structure
- List
- _VoyagerAppState
- Voyager
- _AddListMenuItem
- weatherForecastProvider
- TIME_SELECTOR.md
- MessageHandler
- package:voyager/domain/services/weather_forecast_chart.dart
- _ContextMenuLayoutDelegate
- graphify.md
- graphify.md
- FEEDBACK.md
- MorphDayEventStack
- _VoyagerAppState
- _CalendarMorphWarmupState
- _MonthWeekMorphLayer
- _MorphAnimationLayer
- _CalendarWeekTimelineState
- alertTimeHour
- accentColor
- addedAt
- alertOnPeriodicPrompts
- cadence
- alertTimeHour
- birthYear
- body
- boolValue
- cadence
- calendarId
- calendarNavigateLeftKey
- calendarNavigateRightKey
- collection
- collectionName
- colorPaletteJson
- colorValue
- completed
- createdAt
- customQuote
- customStartupPage
- defaultBool
- None Map
- None Rect
- None Set
- None Size
- None String
- None
- package:voyager/domain/services/weather_forecast_chart.dart
- dart:ui

## God Nodes (most connected - your core abstractions)
1. `remoteSyncServiceProvider` - 60 edges
2. `settingsProvider` - 35 edges
3. `journalRepositoryProvider` - 33 edges
4. `todoRepositoryProvider` - 27 edges
5. `FlutterEngine` - 26 edges
6. `DartProject` - 25 edges
7. `settingsRepositoryProvider` - 22 edges
8. `Win32Window` - 22 edges
9. `DataClass` - 21 edges
10. `_JournalPageState` - 19 edges

## Surprising Connections (you probably didn't know these)
- `build` --references--> `currentWeatherProvider`  [EXTRACTED]
  test/shell_weather_widget_test.dart → lib/app/providers.dart
- `ThrowingJournalRepository` --inherits--> `DriftJournalRepository`  [EXTRACTED]
  test/import_export_test.dart → lib/data/repositories/drift_repositories.dart
- `FakeAuthRepository` --implements--> `AuthRepository`  [EXTRACTED]
  test/import_export_test.dart → lib/domain/repositories/repositories.dart
- `_FlakySyncRepository` --inherits--> `InMemorySyncRepository`  [EXTRACTED]
  test/sync_integration_test.dart → lib/data/remote/in_memory_sync.dart
- `_confirmDeleteAllEntries` --references--> `journalRepositoryProvider`  [EXTRACTED]
  lib/features/dev/dev_page.dart → lib/app/providers.dart

## Import Cycles
- None detected.

## Communities (268 total, 31 thin omitted)

### Community 0 - "Database Data"
Cohesion: 0.00
Nodes (525): BoolColumn get, _, _accentColorMeta, actualTableName, _addedAtMeta, _alertOnPeriodicPromptsMeta, _alertTimeHourMeta, _alias (+517 more)

### Community 1 - "Calendar Features"
Cohesion: 0.01
Nodes (255): AnimationStatusListener?, _, _abortMorphAnimation, accentColor, adjacentColor, _advanceWarmup, anchor, _applyYearTransform (+247 more)

### Community 2 - "Calendar Day"
Cohesion: 0.01
Nodes (218): accentColor, adjacentBorderT, adjacentTextT, alpha, _animatingEventId, available, barHeight, barStride (+210 more)

### Community 3 - "Journal Features"
Cohesion: 0.01
Nodes (141): accentColor, _appliedSavedPreferences, _applyingListShortcut, _applyJournalDeletedUiState, _applyListContinuation, _applySavedPreferencesIfReady, _bodyFocusNode, bodyPreview (+133 more)

### Community 4 - "Features Shell"
Cohesion: 0.02
Nodes (121): allowOverflow, allowVerticalOverflow, axisMaxY, axisMinY, belowPath, bottom, bottomAxisHeight, bucket (+113 more)

### Community 5 - "Calendar Features"
Cohesion: 0.02
Nodes (93): accentColor, allDayAreaTop, allDayShelfHeight, borderedClipRects, borderedDayColumnRect, borderedRects, borderRadius, build (+85 more)

### Community 6 - "Sync Remote"
Cohesion: 0.02
Nodes (87): CharacterOpRegistry get, _activeDebouncers, _activelyEditedDocuments, addPendingTextMergeListener, applyPendingJournalEntryTextMerge, applyPendingTodoTaskNotesMerge, cancelDocument, cancelPending (+79 more)

### Community 7 - "Todo Features"
Cohesion: 0.02
Nodes (88): _applyPendingNotesMerge, build, _buildHeader, _clearDueDate, _close, color, _compactIconButtonStyle, _controller (+80 more)

### Community 8 - "Repositories Domain"
Cohesion: 0.02
Nodes (102): appendOperation, authStateChanges, claimCalendarLock, claimWeatherFetchLock, countEntriesByJournal, currentUserId, deleteAllEntries, deleteAllEvents (+94 more)

### Community 9 - "Calendar Grid"
Cohesion: 0.03
Nodes (71): calendar_day_entries.dart, calendar_day_grid.dart, calendar_todo_markers.dart, calendar_week_timeline.dart, accentColor, allDay, build, _buildMonthTile (+63 more)

### Community 10 - "App Dev"
Cohesion: 0.11
Nodes (17): detectJournalEntryConflict, detectTodoTaskConflict, isConflict, _isCorruptedOpChain, _isHardMetadataCollision, _isHardTodoMetadataCollision, _merger, payloadJson (+9 more)

### Community 11 - "Todo Features"
Cohesion: 0.03
Nodes (67): CurvedAnimation, _activeInList, _animController, _applyListMoveOptimistic, _applyOptimisticActiveOrder, _applyPersistedSortBatchToUi, _applySortBatchOptimistic, _checkScale (+59 more)

### Community 12 - "Models Domain"
Cohesion: 0.02
Nodes (93): accentColor, alertOnPeriodicPrompts, alertTimeHour, birthYear, calendarNavigateLeftKey, calendarNavigateRightKey, colorPalette, copyWith (+85 more)

### Community 13 - "Calendar Markers"
Cohesion: 0.03
Nodes (69): build, buildCalendarTodoMarkers, CalendarDayTodoBar, CalendarDayTodoIcons, CalendarDayTodoTile, calendarMaxTodoIconsPerDay, calendarMorphTodoIconProgress, calendarPackWeekAllDayShelf (+61 more)

### Community 14 - "Dev Remote"
Cohesion: 0.03
Nodes (63): _addInstantDiff, allMatched, _charMerger, compareAllJournalEntries, compareAllTodoLists, comparedAt, _compareJournalEntry, compareTodoList (+55 more)

### Community 15 - "Repositories Data"
Cohesion: 0.02
Nodes (96): countEntriesByJournal, _db, deleteAllEntries, deleteAllEvents, deleteAllJournals, deleteConflict, deleteConflictsForDocument, getAllEntries (+88 more)

### Community 16 - "Sync Weather"
Cohesion: 0.04
Nodes (61): _, @DriftDatabase, fakes/fake_weather_api_client.dart, SyncEngine, AppDatabase, InMemorySyncRepository, package:drift/native.dart, package:flutter_test/flutter_test.dart (+53 more)

### Community 17 - "Todo Task"
Cohesion: 0.03
Nodes (59): activeTasks, activeTopLevelTasks, applyDueDateChange, applyNewUndatedTask, applyNormalizeUnstarredIfNeeded, applyReorder, _applyStar, applyStarToggle (+51 more)

### Community 18 - "App Providers"
Cohesion: 0.02
Nodes (81): AsyncValue, AuthNotifier, CacheStatusSnapshot, DataExportService, DataImportService, DevSettingsController, JournalDebugLogger, JournalWriteCoordinator (+73 more)

### Community 19 - "Analytics Features"
Cohesion: 0.01
Nodes (168): await, DateTime get, Key? dateKey,
  double, accent, _addOption, analytics, anchorDateRect, anchorRect (+160 more)

### Community 20 - "Merger Services"
Cohesion: 0.09
Nodes (23): authRepositoryProvider, build, createState, dispose, _emailController, _error, _formatAuthError, _googleSignIn (+15 more)

### Community 21 - "Search Features"
Cohesion: 0.04
Nodes (60): journalWriteCoordinatorProvider, searchServiceProvider, FirestorePullService, _findTask, _journalRepository, JournalWriteCoordinator, _remoteSync, saveEntry (+52 more)

### Community 22 - "Todo Features"
Cohesion: 0.14
Nodes (15): devGeometricTexturePanelOpenProvider, geometricTextureParamsProvider, build, DevGeometricTextureSection, display, divisions, _GeometricTextureSlider, label (+7 more)

### Community 23 - "Text Widgets"
Cohesion: 0.04
Nodes (53): accentColor, _applyHighlightText, build, contentPadding, controller, createState, cursorColor, decoration (+45 more)

### Community 24 - "Windows Runner"
Cohesion: 0.15
Nodes (16): Point, Size, wchar_t, wstring, Scale(), Create, Destroy, SetQuitOnClose (+8 more)

### Community 25 - "Widgets Color"
Cohesion: 0.04
Nodes (47): boxH, boxW, cappedMaxHeight, cappedMaxWidth, cell, clipPartialNextRow, ColorPaletteGrid, _ColorSwatch (+39 more)

### Community 26 - "Widgets Rounded"
Cohesion: 0.04
Nodes (49): AddListDropdownValue, addListLabel, _addListSentinel, BorderedRoundedDropdown, build, closedTrailing, createState, didChangeDependencies (+41 more)

### Community 27 - "Widgets Contextual"
Cohesion: 0.05
Nodes (42): CapturedThemes, Color get, accentColor, barrierColor, barrierDismissible, barrierLabel, _borderWidth, build (+34 more)

### Community 28 - "Windows Ephemeral"
Cohesion: 0.07
Nodes (39): EncodedType, ByteBufferStreamWriter, bytes_, ByteStreamReader, ReadAlignment, ReadByte, ReadBytes, ByteStreamWriter (+31 more)

### Community 29 - "Time Widgets"
Cohesion: 0.05
Nodes (42): FixedExtentScrollController, _amPmController, applyTo, build, _buildWheel, createBallisticSimulation, createState, _currentAmPmIndex (+34 more)

### Community 30 - "Calendar Features"
Cohesion: 0.06
Nodes (31): assigned, _buildClusters, CalendarOverlapSlot, clusterColumns, clusters, column, columnEnds, dayEnd (+23 more)

### Community 31 - "Widgets Datetime"
Cohesion: 0.05
Nodes (42): ColorScheme, build, _ClockDial, _ClockTimeMode, _ClockTimePicker, _ClockTimePickerState, colorScheme, createState (+34 more)

### Community 32 - "Domain Services"
Cohesion: 0.05
Nodes (42): ForecastPeriod?, 0, bucketHours, buckets, buildDayForecastChartSeries, chartBucketHour, chartBucketRangeCenteredOn, currentTimeChartHour (+34 more)

### Community 33 - "Windows Cpp"
Cohesion: 0.06
Nodes (23): FlutterDesktopMessage, TextureVariant, map, string, vector, BinaryMessengerImpl::BinaryMessengerImpl(), FlutterDesktopMessengerRef, FlutterDesktopTextureRegistrarRef (+15 more)

### Community 34 - "Shell Features"
Cohesion: 0.05
Nodes (46): dart:ui, Error, cachedCurrentWeatherProvider, accent, branchIndex, build, child, color (+38 more)

### Community 35 - "Import Export"
Cohesion: 0.05
Nodes (46): class MockDocumentReference extends, DocumentReference, Exception, FirebaseFirestore, DriftJournalRepository, JournalRepository, archive, DataImportService (+38 more)

### Community 36 - "Todo List"
Cohesion: 0.13
Nodes (13): begin, complete, fail, stateFor, _states, WarmupTracker, android, DefaultFirebaseOptions (+5 more)

### Community 37 - "Sync Firestore"
Cohesion: 0.05
Nodes (39): body, CrdtTextFields, _dateToFirestore, _dateToFirestoreRequired, firestoreDocumentIdForLocal, fromJournalPayload, fromTodoPayload, id (+31 more)

### Community 38 - "Windows Ephemeral"
Cohesion: 0.10
Nodes (20): allCalendars, assigner, choice, color, controller, created, defaultColor, deleteCalendarList (+12 more)

### Community 39 - "Sync Engine"
Cohesion: 0.04
Nodes (44): CrdtDocumentResolver, Debouncer, BackgroundSyncOrchestrator, backoffMultiplier, _calendarRepository, cancelScheduledDocumentSync, _crdtResolver, _debouncer (+36 more)

### Community 40 - "Calendar Event"
Cohesion: 0.05
Nodes (38): build, _buildPayload, CalendarEventPanel, _CalendarEventPanelState, _calendarFlagColor, _calendarId, calendars, _closingAfterSave (+30 more)

### Community 41 - "Sync Conflict"
Cohesion: 0.06
Nodes (36): syncConflictsProvider, collection, detectedAt, documentId, id, localPayloadJson, localText, localTitle (+28 more)

### Community 42 - "Calendar Features"
Cohesion: 0.04
Nodes (46): _AnalyticsToolbar, _EmptyTrackersCard, _GridView, _HeatmapGroupDivider, _HeatmapMonthTile, _MacroStatsRow, _SectionLabel, _StatChip (+38 more)

### Community 43 - "Features Dev"
Cohesion: 0.08
Nodes (36): authNotifierProvider, backgroundSyncOrchestratorProvider, databaseProvider, lazyLoadProvider, liveSyncProvider, quotesLoadedProvider, shellDataWarmupProvider, syncEngineProvider (+28 more)

### Community 44 - "Models Domain"
Cohesion: 0.05
Nodes (36): buildDailyForecastSummaries, byDay, conditionCode, dailySummaries, date, day, days, description (+28 more)

### Community 45 - "Todo Features"
Cohesion: 0.10
Nodes (20): _buildEditor, createState, date, didUpdateWidget, dispose, _formatDate, initState, _intController (+12 more)

### Community 46 - "Sync Conflict"
Cohesion: 0.47
Nodes (4): CopyBufferCallback, FlutterDesktopPixelBuffer, PixelBufferTexture, copy_buffer_callback_

### Community 47 - "Time Widgets"
Cohesion: 0.05
Nodes (45): _activeIsStart, _applyDuration, _applyEndDt, _applyStartDt, _applyTimeDt, build, _canPop, createState (+37 more)

### Community 48 - "Domain Services"
Cohesion: 0.06
Nodes (35): archiveLat, archiveLon, bucketHour, bucketMap, d, day, forecastArchiveLocationMatches, forecastBucketKey (+27 more)

### Community 49 - "Dev Journal"
Cohesion: 0.06
Nodes (34): _append, applySettings, _appStartMarker, bodyDraftEntryIds, bodyFocused, bodyText, clearLog, enabled (+26 more)

### Community 50 - "Windows Ephemeral"
Cohesion: 0.13
Nodes (13): AccessibilityMode, GpuPreference, UIThreadPolicy, DartProject, aot_library_path_, assets_path_, dart_entrypoint_, dart_entrypoint_arguments_ (+5 more)

### Community 51 - "Widgets Text"
Cohesion: 0.06
Nodes (33): FocusNode get, InputCounterWidgetBuilder?, accentColor, autofocus, build, buildCounter, controller, createState (+25 more)

### Community 52 - "Weather Features"
Cohesion: 0.06
Nodes (34): AppSettings, createState, DevRemotePurgeSection, _DevRemotePurgeSectionState, dispose, _entryIdController, _purgeEntry, _purging (+26 more)

### Community 53 - "Widgets Field"
Cohesion: 0.06
Nodes (34): bool?, accentColor, alignLabelToTop, autofocus, borderRadius, build, contentPadding, controller (+26 more)

### Community 54 - "Weather Forecast"
Cohesion: 0.06
Nodes (33): DayForecastChartSeries, _animation, _beginTransition, build, _controller, createState, _currentTimeHour, didUpdateWidget (+25 more)

### Community 55 - "Windows Ephemeral"
Cohesion: 0.10
Nodes (23): StreamHandlerCancel, StreamHandlerListen, EventSink, EndOfStreamInternal, ErrorInternal, SuccessInternal, string, T (+15 more)

### Community 56 - "Windows Ephemeral"
Cohesion: 0.06
Nodes (29): GeneratedPluginRegistrant, FlutterDesktopViewControllerRef, Keep, FlutterEngine, engine_, GetRegistrarForPlugin, next_frame_callback_, owns_engine_ (+21 more)

### Community 57 - "Widgets Notched"
Cohesion: 0.05
Nodes (36): isExpired, purgeEligibleAfter, SoftDeletePolicy, accentColor, alignLabelToTop, borderRadius, borderWidth, build (+28 more)

### Community 58 - "Data Remote"
Cohesion: 0.06
Nodes (32): appendOperation, _calendarLock, claimCalendarLock, claimWeatherFetchLock, _collectionWatchers, _currentWeather, deleteDocument, deleteOperationsForDocument (+24 more)

### Community 59 - "Crdt Frac"
Cohesion: 0.07
Nodes (27): main, ops, pos, s, allOps, main, merger, opsA (+19 more)

### Community 60 - "Weather Features"
Cohesion: 0.07
Nodes (30): DateFormat, weatherForecastLastDayProvider, DailyForecastSummary, createState, _DailyCard, day, dayFormat, forecast (+22 more)

### Community 61 - "Journal Features"
Cohesion: 0.06
Nodes (31): createState, DevOutOfSyncPurgeSection, _DevOutOfSyncPurgeSectionState, _lastResults, _purgeAll, _purging, allJournals, assigner (+23 more)

### Community 62 - "Sync Activity"
Cohesion: 0.06
Nodes (30): applySettings, clearTimer, collection, direction, _displayDuration, dispose, event, eventFor (+22 more)

### Community 63 - "Models Domain"
Cohesion: 0.06
Nodes (30): body, byCreated, byDate, colorValue, compareJournalEntriesNewestFirst, copyWith, customQuote, entryDate (+22 more)

### Community 64 - "Platform Keyboard"
Cohesion: 0.10
Nodes (20): _append, applySettings, clearLog, enabled, _enqueue, _formatAllListsSnapshot, _formatTaskHeader, _formatTaskLine (+12 more)

### Community 65 - "Database Users"
Cohesion: 0.09
Nodes (43): AssetsTableCompanion, AssetsTableData, AssetValuationsTableCompanion, AssetValuationsTableData, BudgetsTableCompanion, BudgetsTableData, CalendarEventsTableCompanion, CalendarEventsTableData (+35 more)

### Community 66 - "Features Shell"
Cohesion: 0.07
Nodes (28): cacheGeneration, clear, degreeGridArgb, _entries, from, generation, gradientStartHour, hashCode (+20 more)

### Community 67 - "Windows Ephemeral"
Cohesion: 0.12
Nodes (16): BinaryMessengerImpl::Send(), BinaryMessengerImpl::SetMessageHandler(), BinaryMessageHandler, BinaryReply, string, ReplyManager::ReplyManager(), ResizeChannel(), SetChannelWarnsOnOverflow() (+8 more)

### Community 68 - "Firestore Data"
Cohesion: 0.07
Nodes (27): appendOperation, claimCalendarLock, claimWeatherFetchLock, _collection, deleteDocument, deleteOperationsForDocument, _doc, _firestore (+19 more)

### Community 69 - "Windows Ephemeral"
Cohesion: 0.08
Nodes (29): journalAllEntryIdsProvider, journalDebugLoggerProvider, journalEntryCacheInvalidatorProvider, journalEntryCountsProvider, journalListEntriesProvider, quoteBankProvider, settingsRepositoryProvider, build (+21 more)

### Community 70 - "Widgets Geometric"
Cohesion: 0.04
Nodes (56): FragmentProgram?, FragmentShader?, accentColor, animates, baseColor, build, _clock, copyWith (+48 more)

### Community 71 - "Text Sync"
Cohesion: 0.08
Nodes (23): addListener, advance, applyToLocalText, bufferWhileEditing, clearDocument, collection, documentId, documentKey (+15 more)

### Community 72 - "Calendar Features"
Cohesion: 0.05
Nodes (39): build, _CreateNameColorDialog, _CreateNameColorDialogState, createState, dispose, initialColor, initState, _nameController (+31 more)

### Community 73 - "Domain Services"
Cohesion: 0.07
Nodes (26): allOps, CharacterOpRegistry, CharacterOpSession, clear, clientId, ensureSession, _insertOp, key (+18 more)

### Community 74 - "Widgets Keep"
Cohesion: 0.08
Nodes (35): AutomaticKeepAliveClientMixin, EdgeInsetsGeometry, IndexedWidgetBuilder, _PalettePickDialog, _PalettePickDialogState, build, cacheExtent, child (+27 more)

### Community 75 - "Domain Services"
Cohesion: 0.08
Nodes (19): EncodableValueVariant, any, decodeColorPaletteJson, encodeColorPaletteJson, formatColorHex, jsonEncode, normalizeColorValue, normalized (+11 more)

### Community 76 - "Main App"
Cohesion: 0.17
Nodes (11): CalendarDayEntry, build, CalendarDayEntryBar, date, entry, fontSize, height, onTap (+3 more)

### Community 77 - "Widgets Date"
Cohesion: 0.07
Nodes (28): accentColor, build, _canPop, createState, DateSelectorPopover, _DateSelectorPopoverState, didUpdateWidget, dispose (+20 more)

### Community 78 - "Features Shell"
Cohesion: 0.06
Nodes (34): CalendarTodoPanel, _CalendarTodoPanelState, _closingAfterSave, _completed, createState, didUpdateWidget, _discard, dispose (+26 more)

### Community 79 - "Calendar Features"
Cohesion: 0.08
Nodes (24): _, allDay, allDayEvent, available, calendarDayEntriesForDay, CalendarDayEntryKind, calendarVisibleEntryCount, clamp (+16 more)

### Community 80 - "Sync Journal"
Cohesion: 0.12
Nodes (18): remoteSyncCompareServiceProvider, syncCompareLoggerProvider, build, _compareAllTodoLists, _compareJournalEntries, _compareTodoList, _comparing, createState (+10 more)

### Community 81 - "Domain Services"
Cohesion: 0.06
Nodes (34): CloudFunctionWeatherClient, DevOpenWeatherClient, refreshForecast, refreshWeather, WeatherApiClient, _deviceId, fetchForecastIfNeeded, isCacheStale (+26 more)

### Community 82 - "Shell Shortcuts"
Cohesion: 0.09
Nodes (23): _blockingShortcuts, BlockShellTabShortcuts, build, child, createState, dispose, _goToRelativeTab, _handleKeyEvent (+15 more)

### Community 83 - "Models Domain"
Cohesion: 0.05
Nodes (42): boolValue, buildJournalEntriesTracker, buildStreakTracker, buildWordCountTracker, cadence, colorValue, copyWith, _dailySpan (+34 more)

### Community 84 - "Cloud Data"
Cohesion: 0.08
Nodes (23): A. Journal — create and propagate, Automated tests (CI / local), B. Journal — concurrent edit (CRDT stress), C. Journal — metadata, Check import/export works, especially for todo lists, and deleting journals keeps journal count consistent, CRDT / journal body checks, D. Todo — create and propagate, E. Todo — reorder and star (+15 more)

### Community 85 - "Journal Features"
Cohesion: 0.07
Nodes (29): FocusNode, accentColor, build, _canPop, createState, _currentDateTime, DateTimeSelectorPopover, _DateTimeSelectorPopoverState (+21 more)

### Community 86 - "Widgets Desktop"
Cohesion: 0.09
Nodes (23): build, buttonHeight, buttonRadius, buttonWidth, createState, DesktopWindowTitleBar, _DesktopWindowTitleBarState, dispose (+15 more)

### Community 87 - "Domain Calendar"
Cohesion: 0.08
Nodes (25): a, _areConsecutiveCalendarDays, b, calendarEventBarEndsOnDay, calendarEventBarsBridge, calendarEventBarStartsOnDay, calendarEventOccursOnDay, calendarEventOccursOnDayNormalized (+17 more)

### Community 88 - "Windows Ephemeral"
Cohesion: 0.09
Nodes (20): nanoseconds, FlutterDesktopEngineRef, FlutterDesktopPluginRegistrarRef, function, HWND, LPARAM, LRESULT, optional (+12 more)

### Community 89 - "Client Data"
Cohesion: 0.04
Nodes (45): BorderRadius, anchor, _anim, borderRadius, build, _buildMenu, capturedThemes, child (+37 more)

### Community 90 - "Dev Cache"
Cohesion: 0.10
Nodes (20): attempted, attemptedFraction, attemptedPercent, CacheItemState, cacheStateColor, cacheStateLabel, cacheStatusFromAsync, cacheStatusFromWarmup (+12 more)

### Community 91 - "Features Shell"
Cohesion: 0.09
Nodes (22): double get, EdgeInsets, belowCurvePath, curvedLinePath, hourAtPixelX, matchesScale, maxX, maxY (+14 more)

### Community 92 - "Functions Forecast"
Cohesion: 0.13
Nodes (15): chartBucketHour(), firestore_1, forecastBucketKey(), formatDateKey(), localPartsFromUtc(), localTodayKey(), mergeForecastArchive(), parseBucketDateKey() (+7 more)

### Community 93 - "Features Page"
Cohesion: 0.09
Nodes (24): weatherForecastProvider, _advance, build, createState, dispose, _done, _frame, initState (+16 more)

### Community 94 - "Dev Features"
Cohesion: 0.12
Nodes (22): deviceIdProvider, syncActivityProvider, build, _confirmDeleteAllEntries, _confirmResetJournals, DevPage, devShowTimeSelectorHitboxesProvider, devSlowHeatmapPopoverAnimationProvider (+14 more)

### Community 95 - "Theme Menu"
Cohesion: 0.09
Nodes (21): dropdownMenuTheme, _GlowBorder, glowColor, _itemHighlightRadius, itemPadding, menuBorderRadius, menuColor, menuStyle (+13 more)

### Community 96 - "Registrar Windows"
Cohesion: 0.04
Nodes (50): _addMonths, allocatedAt, amountCents, anchorDueDate, annualCents, annualCentsFor, asOf, assetId (+42 more)

### Community 97 - "Functions Src"
Cohesion: 0.16
Nodes (17): ArchiveDoc, archiveLocationMatches(), chartBucketHour(), clearForecastArchive(), forecastBucketKey(), ForecastPeriod, formatDateKey(), localPartsFromUtc() (+9 more)

### Community 98 - "Dev Settings"
Cohesion: 0.10
Nodes (20): applySettings, devForceConflictUi, loadFromSettings, _persist, setDevForceConflictUi, setShowCacheStatus, setShowCalendarInstantViewSwitch, setShowCalendarZoomPrewarm (+12 more)

### Community 99 - "Dev Todo"
Cohesion: 0.06
Nodes (34): bool get, HotKey?, configureDesktopWindow, desktopWindowChromeActive, _desktopWindowConfigured, isAndroid, isWindows, VoyagerPlatform (+26 more)

### Community 100 - "Binding Utils"
Cohesion: 0.10
Nodes (20): alt, binding, control, _displayToken, formatKeyBinding, join, KeyBinding, keyBindingFromKeyEvent (+12 more)

### Community 101 - "Widgets Resizable"
Cohesion: 0.10
Nodes (21): double?, build, clampListWidth, createState, defaultListWidth, dividerWidth, _dragging, _dragStartGlobalX (+13 more)

### Community 102 - "Auth Data"
Cohesion: 0.10
Nodes (20): _auth, _authErrorMessage, authStateChanges, _controller, currentUserId, dispose, fallback, FirebaseAuthRepository (+12 more)

### Community 103 - "Character Domain"
Cohesion: 0.12
Nodes (15): FirebaseFunctions?, _call, _firestore, FirestoreWeatherReader, _functions, getCurrentWeather, _httpCallable, refreshForecast (+7 more)

### Community 104 - "Features Calendar"
Cohesion: 0.08
Nodes (25): @immutable, CacheItemStatus get, int get, CacheItemStatus, CacheStatusSnapshot, checks, _checksEqual, _checksEqualLists (+17 more)

### Community 105 - "Features Calendar"
Cohesion: 0.10
Nodes (21): build, buildScrollbar, createState, didChangeAppLifecycleState, dispose, _flushAllPendingEdits, initState, _NoScrollbarScrollBehavior (+13 more)

### Community 106 - "Widgets Clamp"
Cohesion: 0.11
Nodes (18): GlobalKey, GlobalKey get, attach, ClampToTargetBounds, createRenderObject, detach, _handleScroll, _hasAttemptedScrollLookup (+10 more)

### Community 107 - "Hotkey Features"
Cohesion: 0.10
Nodes (19): class, geometricShaderProvider, _GeometricBackground, appSettingsWithGeometricTextureParams, appSettingsWithGeometricWaveParams, copyWith, geometricTextureParamsFromSettings, geometricWaveParamsFromSettings (+11 more)

### Community 108 - "Palette Color"
Cohesion: 0.04
Nodes (55): StatisticTracker, AnalyticsService, booleanTrueCount, completedTasks, countWords, heatmapIntensity, integerSeries, interpolateConsecutive (+47 more)

### Community 109 - "Dev Sync"
Cohesion: 0.14
Nodes (13): build, color, ColorCornerFlag, colorValue, JournalBookmarkFlag, JournalTitleCornerFlag, onSelected, paint (+5 more)

### Community 110 - "Domain Repositories"
Cohesion: 0.07
Nodes (25): MethodCallHandler, BinaryMessengerImpl, handlers_, messenger_, Send, SetMessageHandler, BinaryMessageHandler, FlutterDesktopMessengerRef (+17 more)

### Community 111 - "Calendar Features"
Cohesion: 0.11
Nodes (18): build, CalendarKeyboardShortcuts, _CalendarKeyboardShortcutsState, calendarNavShortcutsEnabled, child, context, createState, dispose (+10 more)

### Community 112 - "Windows Ephemeral"
Cohesion: 0.12
Nodes (15): best, colorFor, cursor, highlightedStyle, index, keywords, _keywordSpans, lower (+7 more)

### Community 113 - "Widgets Desktop"
Cohesion: 0.09
Nodes (22): Animation, AnimationController, _ContextMenuOverlay, _ContextMenuOverlayState, _animDuration, _barVisible, build, child (+14 more)

### Community 114 - "Widgets Dropdown"
Cohesion: 0.10
Nodes (21): FormField, FormFieldState, InputDecoration, accentColor, build, createState, decoration, enabled (+13 more)

### Community 115 - "App Providers"
Cohesion: 0.25
Nodes (4): ByteBufferStreamReader, bytes_, location_, size_

### Community 116 - "Windows Ephemeral"
Cohesion: 0.07
Nodes (25): calendar, debug, journal, manage, search, VoyagerIcons, weatherIconData, _pickCalendarKey (+17 more)

### Community 117 - "Sync Debouncer"
Cohesion: 0.10
Nodes (19): Client, FirebaseAuth, _apiKey, _http, _periodFromForecastItem, refreshForecast, refreshWeather, _auth (+11 more)

### Community 118 - "Widgets Menu"
Cohesion: 0.12
Nodes (16): IconData? get, buildCatalogMenu, defaultCatalogMenuChild, defaultEntityManageMenuEntries, entityManageMenuEntries, forWeatherIcon, from, icon (+8 more)

### Community 119 - "Widgets Search"
Cohesion: 0.17
Nodes (11): _, GoRouter, auth, child, routerProvider, settingsRepo, package:voyager/core/widgets/desktop_window_frame.dart, package:voyager/features/auth/login_page.dart (+3 more)

### Community 120 - "Models Domain"
Cohesion: 0.12
Nodes (16): colorValue, completed, copyWith, dueDate, dueDateSetAt, fromJson, isSubtask, listId (+8 more)

### Community 121 - "Settings Palette"
Cohesion: 0.18
Nodes (10): WeatherForecast, WeatherSnapshot, forecastCalls, forecastResult, geocodeCalls, geocodeResult, refreshCalls, refreshForecast (+2 more)

### Community 122 - "Windows Ephemeral"
Cohesion: 0.17
Nodes (12): vector, ReplyManager::SendResponseData(), EngineMethodResult, codec_, reply_manager_, BinaryReply, string, T (+4 more)

### Community 123 - "Platform Widgets"
Cohesion: 0.17
Nodes (11): IconData, accentColor, build, child, dense, ellipsize, icon, isActive (+3 more)

### Community 124 - "Shell Features"
Cohesion: 0.11
Nodes (18): icon, index, label, order, page, path, result, ShellDestination (+10 more)

### Community 125 - "Windows Ephemeral"
Cohesion: 0.16
Nodes (15): string, T, unique_ptr, MethodCall, method_name_, string, T, unique_ptr (+7 more)

### Community 126 - "Database Data"
Cohesion: 0.09
Nodes (22): @DataClassName, AssetsTable, AssetValuationsTable, BudgetsTable, CalendarEventsTable, CalendarsTable, FinanceCategoriesTable, GoalAllocationsTable (+14 more)

### Community 127 - "Menu Widgets"
Cohesion: 0.25
Nodes (7): _auth, AuthNotifier, dispose, _isAuthenticated, _subscription, package:voyager/domain/repositories/repositories.dart, StreamSubscription

### Community 128 - "Sync Outbox"
Cohesion: 0.06
Nodes (32): FlutterDesktopViewRef, WindowProcDelegate, FlutterView, view_, HWND, IDXGIAdapter, GetRegistrar(), FlutterDesktopPluginRegistrarRef (+24 more)

### Community 129 - "Functions Scripts"
Cohesion: 0.13
Nodes (14): dependencies, firebase-admin, firebase-functions, devDependencies, typescript, engines, node, main (+6 more)

### Community 130 - "Dev Warmup"
Cohesion: 0.18
Nodes (10): archive, DataExportService, exportDataToZip, generateZipIsolate, journalData, _journalRepo, taskData, _todoRepo (+2 more)

### Community 131 - "Todo Task"
Cohesion: 0.12
Nodes (17): trackerRepositoryProvider, _createTracker, _delete, _handleTap, _HeatmapBucket, _HeatmapBucketState, _heatmapDraggingProvider, _HeatmapPopover (+9 more)

### Community 132 - "Gradient Widgets"
Cohesion: 0.13
Nodes (14): BaseSliderTrackShape, accent, build, getPreferredRect, gradient, GradientSliderTrackShape, inactiveColor, MoodGradientSlider (+6 more)

### Community 133 - "Models Analytics"
Cohesion: 0.25
Nodes (7): firestoreId, legacyTodoListFirestoreId, legacyTodoListId, localId, todoListDocumentIdForFirestore, todoListDocumentIdFromFirestore, return

### Community 134 - "Models Domain"
Cohesion: 0.12
Nodes (15): calendarId, colorValue, copyWith, end, EventRecurrence, EventSource, externalId, isFullDay (+7 more)

### Community 135 - "Windows Ephemeral"
Cohesion: 0.20
Nodes (9): Future, clearLog, _enqueue, log, _logFileName, logFilePath, _maxLogBytes, readLog (+1 more)

### Community 136 - "Platform Domain"
Cohesion: 0.18
Nodes (16): FlutterWindow, flutter_controller_, OnCreate, OnDestroy, project_, unique_ptr, RECT, HWND (+8 more)

### Community 137 - "Domain Services"
Cohesion: 0.07
Nodes (53): ConsumerState, allTodoTasksProvider, remoteSyncServiceProvider, todoListsProvider, todoRepositoryProvider, todoSortDebugLoggerProvider, todoTasksProvider, _CalendarPageState (+45 more)

### Community 138 - "Functions Tsconfig"
Cohesion: 0.15
Nodes (12): compileOnSave, compilerOptions, esModuleInterop, module, noImplicitReturns, noUnusedLocals, outDir, skipLibCheck (+4 more)

### Community 139 - "Auth Firebase"
Cohesion: 0.15
Nodes (12): contains, embedded, firebaseAuthErrorMessage, invalidCredentialHints, _isGenericInternalMessage, lower, _messageFromEmbeddedDetails, normalizedCode (+4 more)

### Community 140 - "Color Widgets"
Cohesion: 0.04
Nodes (44): DateTime? now,
  bool, amountCents, assetCents, best, BreakdownSlice, byAsset, cashCents, CashFlowGranularity (+36 more)

### Community 141 - "FlutterView"
Cohesion: 0.06
Nodes (30): DriftTodoRepository, DriftTrackerRepository, TodoRepository, TrackerRepository, package:voyager/core/constants/todo_sort_constants.dart, package:voyager/core/utils/ids.dart, package:voyager/domain/todo/todo_task_sorting.dart, required String id,
  bool (+22 more)

### Community 142 - "Windows Ephemeral"
Cohesion: 0.08
Nodes (23): Delay, Duration, id, OutOfSyncJournalEntryPurge, OutOfSyncJournalEntryTarget, purgeAll, purgeOne, searchHint (+15 more)

### Community 143 - "Windows Ephemeral"
Cohesion: 0.14
Nodes (15): ResultHandlerError, ResultHandlerNotImplemented, ResultHandlerSuccess, string, T, MethodResultFunctions, on_error_, on_not_implemented_ (+7 more)

### Community 144 - "Widgets Selector"
Cohesion: 0.14
Nodes (12): EditableText, body, build, floatingActionButton, PlatformAdaptiveScaffold, build, child, EnterToSubmitScope (+4 more)

### Community 145 - "Constants Google"
Cohesion: 0.14
Nodes (18): cacheStatusSnapshotProvider, devSettingsProvider, pendingStatEntriesProvider, build, StatisticsActionFab, _scaledMorphDuration, build, _CacheStatusItemList (+10 more)

### Community 146 - "Features Analytics"
Cohesion: 0.14
Nodes (13): Files touched by this migration, How it works, Intentional exception: the inline todo-item rename field, Known limitations / non-goals, `LabeledTextField` (`lib/core/widgets/labeled_text_field.dart`), `TagHighlightedTextField` (`lib/core/widgets/tag_highlighted_text_field.dart`), Text box widget: `NotchedFieldBorder`, The notch math (+5 more)

### Community 147 - "Features Settings"
Cohesion: 0.18
Nodes (11): build, _captured, createState, current, dispose, _handleKeyEvent, initState, _KeyBindingDialog (+3 more)

### Community 148 - "Shell App"
Cohesion: 0.29
Nodes (7): Calendar, CalendarEvent, Journal, JournalEntry, SoftDeletable, TodoListModel, TodoTask

### Community 149 - "Widgets Features"
Cohesion: 0.17
Nodes (12): CustomPainter, _ClockDialPainter, GeometricTexturePainter, _CornerFlagPainter, _NotchedBorderPainter, _TagHighlightPainter, CalendarWeekDayColumnBorderPainter, CalendarWeekTimeGridPainter (+4 more)

### Community 150 - "Constants Journal"
Cohesion: 0.18
Nodes (10): firestoreId, firestoreJournalId, journalDocumentIdForFirestore, journalDocumentIdFromFirestore, journalReferenceIdForFirestore, journalReferenceIdFromFirestore, legacyJournalFirestoreId, legacyJournalId (+2 more)

### Community 151 - "Widgets Confirm"
Cohesion: 0.18
Nodes (10): cancelLabel, confirmed, confirmLabel, deleteAllLabel, DeleteContainerChoice, moveLabel, result, showConfirmDialog (+2 more)

### Community 152 - "Weather Fakes"
Cohesion: 0.20
Nodes (9): dart:io, _authorizationEndpoint, DesktopGoogleOAuth, redirectUri, _tokenEndpoint, package:oauth2/oauth2.dart, package:url_launcher/url_launcher.dart, static final Uri (+1 more)

### Community 153 - "Features Settings"
Cohesion: 0.06
Nodes (31): int? current,
  Set, assign, nextColor, palette, PaletteAssigner, paletteFromItems, pickColorFromPalette, pickPaletteColorWithRef (+23 more)

### Community 154 - "Shell App"
Cohesion: 0.22
Nodes (8): dart:async, _callbacks, flushAll, instance, PendingFlushRegistry, register, unregister, static final

### Community 155 - "Data Remote"
Cohesion: 0.22
Nodes (9): build, child, createState, didUpdateWidget, _entry, initState, LocalOverlayWrapper, _LocalOverlayWrapperState (+1 more)

### Community 156 - "Delta Scramble"
Cohesion: 0.20
Nodes (8): local, main, newRemote, newRemote2, oldRemote, oldRemote2, main, lib/core/sync/text_delta_injector.dart

### Community 157 - "Dev Sync"
Cohesion: 0.17
Nodes (11): 1. Shader asset, 2. Loading, 3. Tunable parameters, 4. Widget → painter → GPU, 5. App-level composition, 6. UI that interacts with the background, 7. GPU warmup (avoid first-frame jank), 8. Failure modes (+3 more)

### Community 158 - "Windows Runner"
Cohesion: 0.16
Nodes (10): _In_, _In_opt_, optional, wWinMain(), string, vector, wchar_t, CreateAndAttachConsole() (+2 more)

### Community 159 - "Domain Services"
Cohesion: 0.20
Nodes (9): after, before, between, _digits, first, FractionalIndex, _keyAfter, _keyBefore (+1 more)

### Community 160 - "Shell Features"
Cohesion: 0.20
Nodes (9): analyticsList, devList, journalEntryList, journalEntryListAll, journalPreview, searchResults, settingsList, ShellPageStorageKeys (+1 more)

### Community 161 - "Windows Ephemeral"
Cohesion: 0.05
Nodes (39): DateTimeRange, _AllocateModal, _AllocateModalState, _amountController, _canSave, createState, _date, _datePopoverOpen (+31 more)

### Community 162 - "Sync Text"
Cohesion: 0.22
Nodes (8): _, adjustedSelection, _commonPrefixLength, _commonSuffixLength, _fallbackMerge, injectRemoteDelta, _insertAt, TextDeltaInjector

### Community 163 - "Sync Pending"
Cohesion: 0.07
Nodes (40): assetsProvider, assetValuationsProvider, budgetsProvider, financeCategoriesProvider, tagColorsProvider, transactionsProvider, abs, _AnalyticsCard (+32 more)

### Community 164 - "App Providers"
Cohesion: 0.17
Nodes (11): googleOAuthClientId, _googleOAuthClientIdRaw, googleOAuthClientSecret, _googleOAuthClientSecretRaw, googleOAuthRedirectPort, id, isGoogleOAuthClientSecretConfigured, isGoogleOAuthConfigured (+3 more)

### Community 165 - "trackerRepositoryProvider"
Cohesion: 0.10
Nodes (19): MessageHandler, BasicMessageChannel, codec_, messenger_, name_, BinaryReply, string, T (+11 more)

### Community 166 - "Theme Spacing"
Cohesion: 0.22
Nodes (8): compactListVerticalDensity, lg, md, sm, VoyagerSpacing, xl, xs, xxs

### Community 167 - "settingsRepositoryProvider"
Cohesion: 0.25
Nodes (8): @visibleForTesting, calendarNavDeltaForEvent, calendarNavShortcutsEnabledForState, isTextInputFocused, subtreeIsVisible, isShellTabShortcutEvent, shellTabDeltaForEvent, shellTabShortcutsEnabledForState

### Community 168 - "Windows Ephemeral"
Cohesion: 0.07
Nodes (35): colorPaletteProvider, journalRepositoryProvider, journalsProvider, build, changeJournalListColor, createJournalList, renameJournalList, build (+27 more)

### Community 169 - ".CallTopLevelWindowProcDelegates"
Cohesion: 0.25
Nodes (7): build, children, currentIndex, ShellBranchContainer, shellBranchContainerBuilder, package:go_router/go_router.dart, ShellNavigationContainerBuilder

### Community 170 - "ByteBufferStreamReader"
Cohesion: 0.17
Nodes (10): FlutterViewId, HWND, LPARAM, LRESULT, optional, UINT, WPARAM, FlutterViewController::FlutterViewController() (+2 more)

### Community 171 - "Widgets Enter"
Cohesion: 0.05
Nodes (38): buildDayGroups, color, colorValue, cumulative, day, _DayHeader, _EmptyLedger, _FinanceView (+30 more)

### Community 172 - "Gpusurfacetexture Windows"
Cohesion: 0.39
Nodes (5): FlutterDesktopGpuSurfaceDescriptor, FlutterDesktopGpuSurfaceType, ObtainDescriptorCallback, GpuSurfaceTexture, obtain_descriptor_callback_

### Community 173 - "@immutable"
Cohesion: 0.15
Nodes (10): ClearPlugins, PluginRegistrarManager, GetInstance, OnRegistrarDestroyed, FlutterDesktopPluginRegistrarRef, FlutterDesktopPluginRegistrarRef, PluginRegistrar::PluginRegistrar(), PluginRegistrarManager::GetInstance() (+2 more)

### Community 174 - "Constants Todo"
Cohesion: 0.33
Nodes (5): dart:math, indices, main, r, sorted

### Community 175 - "Shell Features"
Cohesion: 0.20
Nodes (9): 1. Database Schema (SQLite / CRDT Ready), 2. State Management & Logic (Riverpod), 3. UI / Widget Architecture, A. The 1-Year Rolling Maximum (Independent Integers), A. The Journal Page Entry Flow, B. Analytics Page: Default View (The 4 Dashboards), B. Enum Dynamic Color Generation, C. Analytics Page: Calendar View (+1 more)

### Community 176 - "Messenger Windows"
Cohesion: 0.06
Nodes (40): financeRepositoryProvider, _save, _delete, _save, _BudgetModal, _BudgetModalState, build, _canSave (+32 more)

### Community 177 - "dart:math"
Cohesion: 0.14
Nodes (12): DateTime, copyWithDeleted, createdAt, deletedAt, id, isDeleted, updatedAt, version (+4 more)

### Community 178 - "Constants Hotkey"
Cohesion: 0.29
Nodes (6): defaultCalendarNavigateLeftKey, defaultCalendarNavigateRightKey, defaultJournalHotkey, defaultTodoHotkey, legacyJournalHotkey, legacyTodoHotkey

### Community 179 - "Sync Firestore"
Cohesion: 0.15
Nodes (11): FirestoreCollections, journalEntries, journals, syncOperations, todoLists, todoTasks, AppFonts, applyTo (+3 more)

### Community 180 - "@visibleForTesting"
Cohesion: 0.08
Nodes (26): goalAllocationsProvider, savingsGoalsProvider, decoration, restingColor, selectedColor, VoyagerListItemSurface, formatTime12Hour, formatTimeOfDay12Hour (+18 more)

### Community 181 - "MethodCall"
Cohesion: 0.10
Nodes (20): character, CharacterOperation, charOps, charOpsKey, CharOpsPayload, clientId, copyWith, deleted (+12 more)

### Community 182 - "Anagram List1"
Cohesion: 0.33
Nodes (5): list1, list2, main, s1, s2

### Community 183 - "dart:math"
Cohesion: 0.36
Nodes (10): HWND, LPARAM, LRESULT, UINT, WPARAM, EnableFullDpiSupportIfAvailable(), GetHandle, GetThisFromHandle (+2 more)

### Community 184 - "Calendar Features"
Cohesion: 0.33
Nodes (6): InheritedWidget, _ContextualPopoverAccentScope, CalendarEventTapScope, CalendarMorphYearDotsOpacity, _MorphProgress, _WeekMorphProgress

### Community 185 - "debouncer.dart"
Cohesion: 0.10
Nodes (20): _amountController, build, _canSave, _colorValue, createState, _datePopoverOpen, _delete, dispose (+12 more)

### Community 186 - "Widgets Rounded"
Cohesion: 0.40
Nodes (5): Intent, _SubmitIntent, _BlockShellTabIntent, NextShellTabIntent, PreviousShellTabIntent

### Community 187 - "Chart Weather"
Cohesion: 0.40
Nodes (4): package:voyager/features/shell/weather_chart_curve.dart, curveFor, main, spots

### Community 188 - "Android Gradlew"
Cohesion: 0.60
Nodes (3): gradlew script, die(), warn()

### Community 189 - "Deinterleave Evens"
Cohesion: 0.40
Nodes (4): evens, main, odds, s

### Community 190 - "WeatherApiClient"
Cohesion: 0.09
Nodes (37): ConsumerWidget, allJournalEntriesProvider, analyticsServiceProvider, dataImportServiceProvider, periodicPromptServiceProvider, settingsProvider, todoListStatsProvider, trackersProvider (+29 more)

### Community 191 - "Dev Flags"
Cohesion: 0.33
Nodes (5): DevFlags, showTimeSelectorHitboxes, slowHeatmapPopoverAnimation, verboseSync, static bool

### Community 192 - "Utils Ids"
Cohesion: 0.25
Nodes (7): day, month, newId, trackerValueId, utcNow, _uuid, package:uuid/uuid.dart

### Community 193 - "Utils Journal"
Cohesion: 0.40
Nodes (4): colorForTag, extractTags, journalTagPattern, matches

### Community 194 - "Google Desktop"
Cohesion: 0.10
Nodes (20): _amountController, build, createState, _date, _datePopoverOpen, dispose, existing, _formatDate (+12 more)

### Community 195 - "Constants Todo"
Cohesion: 0.50
Nodes (3): normalizeUnstarredSortOrder, starredSortOrderMax, unstarredSortOrderBase

### Community 196 - "PLAN.md"
Cohesion: 0.22
Nodes (8): AGENTS, Features, Frontend UI, Future Additions, High Level Overview, Low Level Design, Miscellaneous, Theme

### Community 198 - "Calendar Customclipper"
Cohesion: 0.67
Nodes (3): CustomClipper, _WeekTimedViewportClipper, Path

### Community 199 - "High-Level Design: Voyager Weekly Calendar View"
Cohesion: 0.22
Nodes (8): High-Level Design: Voyager Weekly Calendar View, I. System Overview, II. Visual Layout & Z-Index Stack, III. The Overlap Engine (Column Splitting), IV. Data Entity Specifications, The Zero-Duration Task Layout Logic, Todo Task Logic, V. User Interaction Flow

### Community 200 - "IMPORT_EXPORT.md"
Cohesion: 0.25
Nodes (7): 1. The Database Layer (Drift), 2. The Export Pipeline (`DataExportService`), 3. The Import Pipeline (`DataImportService`), 4. The Trickle Sync Engine (`OutboxSyncWorker`), 5. Testing Strategy, Integration Tests (Slow, End-to-End), Unit Tests (Fast, Isolated)

### Community 201 - "Constants App"
Cohesion: 0.50
Nodes (3): popupGlowAlpha, softDeleteRetentionDays, syncDebounceSeconds

### Community 202 - "todoSortDebugLoggerProvider"
Cohesion: 0.11
Nodes (18): Color, currentWeatherProvider, build, child, color, GeometricProgressRing, paint, progress (+10 more)

### Community 203 - "Color"
Cohesion: 0.33
Nodes (5): dark, VoyagerTheme, OutlinedBorder, package:voyager/core/theme/app_fonts.dart, package:voyager/core/theme/voyager_menu_theme.dart

### Community 208 - "enums.dart"
Cohesion: 0.11
Nodes (18): build, _canSave, _colorValue, createState, _datePopoverOpen, _delete, dispose, existing (+10 more)

### Community 212 - "ADR 001: Local-First Data Model"
Cohesion: 0.33
Nodes (5): ADR 001: Local-First Data Model, Consequences, Context, Decision, Status

### Community 213 - "ADR 002: Sync Protocol Boundaries"
Cohesion: 0.33
Nodes (5): ADR 002: Sync Protocol Boundaries, Consequences, Context, Decision, Status

### Community 214 - "ADR 003: Module Structure"
Cohesion: 0.33
Nodes (5): ADR 003: Module Structure, Consequences, Context, Decision, Status

### Community 215 - "List"
Cohesion: 0.29
Nodes (6): nextQuote, QuoteBank, _quotes, _random, _used, List

### Community 216 - "_VoyagerAppState"
Cohesion: 0.12
Nodes (15): axisReservedSize, chars, compactNumberLabel, intervals, magnitude, magnitudeSuffixes, mantissa, mantissas (+7 more)

### Community 217 - "Voyager"
Cohesion: 0.33
Nodes (5): Architecture, Features, Setup, Testing, Voyager

### Community 219 - "weatherForecastProvider"
Cohesion: 0.13
Nodes (14): 1. Core Purpose & Overview, 2. Database Models & Schema Integration, 3. Detailed Component Breakdown & Edge Cases, 4. Popover & Morphing Editor, 5. Summary of Key Technical Edge Cases, A. Hover Tooltip Overlay, A. The Grid View & Sparkline Stack, B. Morph Route Transition (+6 more)

### Community 220 - "TIME_SELECTOR.md"
Cohesion: 0.40
Nodes (4): 1. The Container (The Anchored Popover), 2. The Internal Layout (Start Time Popup), 3. The Internal Layout (End Time / Duration Popup), The Execution Summary

### Community 221 - "MessageHandler"
Cohesion: 0.33
Nodes (6): HWND, LPARAM, LRESULT, UINT, WPARAM, MessageHandler

### Community 222 - "package:voyager/domain/services/weather_forecast_chart.dart"
Cohesion: 0.50
Nodes (3): package:voyager/domain/services/weather_forecast_chart.dart, main, _period

### Community 223 - "_ContextMenuLayoutDelegate"
Cohesion: 0.67
Nodes (3): _ContextMenuLayoutDelegate, _PopoverLayoutDelegate, SingleChildLayoutDelegate

### Community 228 - "_VoyagerAppState"
Cohesion: 0.11
Nodes (18): ConsumerStatefulWidget, _HeatmapDayCell, _HeatmapDayCellState, _HeatmapSquare, _HeatmapSquareState, _HeatmapWeekBlock, _HeatmapWeekBlockState, _MonthGridBox (+10 more)

### Community 234 - "accentColor"
Cohesion: 0.14
Nodes (14): BoxConstraints? constraints,
  EdgeInsetsGeometry, VoyagerMenuItemPosition, accent, build, checkColor, createState, menuPadding, menuStyle (+6 more)

### Community 235 - "addedAt"
Cohesion: 0.15
Nodes (14): devGeometricWavePanelOpenProvider, geometricWaveParamsProvider, GeometricWaveShape, build, DevGeometricWaveSection, display, divisions, label (+6 more)

### Community 236 - "alertOnPeriodicPrompts"
Cohesion: 0.18
Nodes (11): subscriptionsProvider, Subscription, BillRadarPanel, build, _dueColor, _dueLabel, _EmptyRadar, showAnnual (+3 more)

### Community 238 - "alertTimeHour"
Cohesion: 0.18
Nodes (10): Duration get, cancel, DebouncedCallback, debounceDelay, Debouncer, delay, dispose, schedule (+2 more)

### Community 239 - "birthYear"
Cohesion: 0.18
Nodes (10): int?, budget, color, _EmptyBudgets, pace, _PacingBar, spentCents, spentFraction (+2 more)

### Community 240 - "body"
Cohesion: 0.28
Nodes (9): calendarRepositoryProvider, calendarsProvider, changeCalendarListColor, createCalendarList, renameCalendarList, _createCalendarFromDropdown, _ensureDefaultCalendar, _saveSidebarEvent (+1 more)

### Community 241 - "boolValue"
Cohesion: 0.22
Nodes (9): TrackerValue, Asset, AssetValuation, Budget, FinanceCategory, FinancialTransaction, GoalAllocation, SavingsGoal (+1 more)

### Community 242 - "cadence"
Cohesion: 0.22
Nodes (8): BillingPeriod, CalendarViewMode, HeatmapMode, StartupPageMode, TrackerCadence, TrackerStyle, TrackerType, TransactionType

### Community 243 - "calendarId"
Cohesion: 0.22
Nodes (8): function, TextureRegistrarImpl::UnregisterTexture(), FlutterDesktopTextureRegistrarRef, TextureRegistrarImpl, MarkTextureFrameAvailable, RegisterTexture, texture_registrar_ref_, UnregisterTexture

### Community 244 - "calendarNavigateLeftKey"
Cohesion: 0.25
Nodes (8): ChangeNotifier, DevSettingsController, JournalDebugLogger, SyncCompareLogger, TodoSortDebugLogger, SyncActivityController, CalendarEventTapState, MonthZoomPrewarmTracker

### Community 245 - "calendarNavigateRightKey"
Cohesion: 0.40
Nodes (5): GeometricTextureParamsNotifier, GeometricWaveParamsNotifier, GeometricTextureParams, GeometricWaveParams, StateNotifier

### Community 246 - "collection"
Cohesion: 0.50
Nodes (3): 1. The Sparklines (Consecutive Trackers), 2. The Heatmap Grid, 3. Calendar View

### Community 362 - "dart:ui"
Cohesion: 0.05
Nodes (41): dart:convert, CrdtDocumentResolver, _merger, _mergeSyncOperations, resolvePayload, list, loadQuotesFromAssets, raw (+33 more)

## Knowledge Gaps
- **5226 isolated node(s):** `1. Core Purpose & Overview`, `Cadences & Date Anchoring`, `A. The Grid View & Sparkline Stack`, `B. The Heatmap Bucket & Reordering System`, `C. Virtual Default Trackers` (+5221 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **31 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `any` connect `Domain Services` to `Windows Cpp`?**
  _High betweenness centrality (0.139) - this node is a cross-community bridge._
- **Why does `PluginRegistrarWindows` connect `Sync Outbox` to `@immutable`, `Windows Runner`?**
  _High betweenness centrality (0.013) - this node is a cross-community bridge._
- **Why does `AppDatabase` connect `Sync Weather` to `Database Data`, `Import Export`, `FlutterView`, `Windows Ephemeral`, `Repositories Data`, `App Providers`?**
  _High betweenness centrality (0.012) - this node is a cross-community bridge._
- **What connects `1. Core Purpose & Overview`, `Cadences & Date Anchoring`, `A. The Grid View & Sparkline Stack` to the rest of the system?**
  _5226 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Database Data` be split into smaller, more focused modules?**
  _Cohesion score 0.0038022813688212928 - nodes in this community are weakly interconnected._
- **Should `Calendar Features` be split into smaller, more focused modules?**
  _Cohesion score 0.0078125 - nodes in this community are weakly interconnected._
- **Should `Calendar Day` be split into smaller, more focused modules?**
  _Cohesion score 0.0091324200913242 - nodes in this community are weakly interconnected._