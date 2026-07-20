# Graph Report - Voyager  (2026-07-15)

## Corpus Check
- 310 files · ~260,393 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 6512 nodes · 9251 edges · 238 communities (217 shown, 21 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 47 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `20b13f8a`
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
- TIME_SELECTOR.md
- MessageHandler
- graphify.md
- graphify.md
- FEEDBACK.md
- _VoyagerAppState
- alertTimeHour
- cadence
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
2. `journalRepositoryProvider` - 33 edges
3. `settingsProvider` - 29 edges
4. `todoRepositoryProvider` - 27 edges
5. `FlutterEngine` - 26 edges
6. `DartProject` - 25 edges
7. `Win32Window` - 22 edges
8. `_JournalPageState` - 19 edges
9. `MethodCodec` - 19 edges
10. `trackerRepositoryProvider` - 17 edges

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

## Communities (238 total, 21 thin omitted)

### Community 0 - "Database Data"
Cohesion: 0.01
Nodes (398): BoolColumn get, _, _accentColorMeta, actualTableName, _addedAtMeta, _alertOnPeriodicPromptsMeta, _alertTimeHourMeta, _alias (+390 more)

### Community 1 - "Calendar Features"
Cohesion: 0.01
Nodes (255): AnimationStatusListener?, _, _abortMorphAnimation, accentColor, adjacentColor, _advanceWarmup, anchor, _applyYearTransform (+247 more)

### Community 2 - "Calendar Day"
Cohesion: 0.01
Nodes (218): accentColor, adjacentBorderT, adjacentTextT, alpha, _animatingEventId, available, barHeight, barStride (+210 more)

### Community 3 - "Journal Features"
Cohesion: 0.01
Nodes (146): Journal?, journalListEntriesProvider, accentColor, _appliedSavedPreferences, _applyingListShortcut, _applyJournalDeletedUiState, _applyListContinuation, _applySavedPreferencesIfReady (+138 more)

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
Cohesion: 0.03
Nodes (78): appendOperation, authStateChanges, claimCalendarLock, claimWeatherFetchLock, countEntriesByJournal, currentUserId, deleteAllEntries, deleteAllEvents (+70 more)

### Community 9 - "Calendar Grid"
Cohesion: 0.03
Nodes (69): calendar_day_entries.dart, calendar_day_grid.dart, calendar_todo_markers.dart, calendar_week_timeline.dart, CalendarViewMode, accentColor, allDay, build (+61 more)

### Community 10 - "App Dev"
Cohesion: 0.10
Nodes (20): detectJournalEntryConflict, detectTodoTaskConflict, isConflict, _isCorruptedOpChain, _isHardMetadataCollision, _isHardTodoMetadataCollision, _merger, payloadJson (+12 more)

### Community 11 - "Todo Features"
Cohesion: 0.03
Nodes (67): CurvedAnimation, _activeInList, _animController, _applyListMoveOptimistic, _applyOptimisticActiveOrder, _applyPersistedSortBatchToUi, _applySortBatchOptimistic, _checkScale (+59 more)

### Community 12 - "Models Domain"
Cohesion: 0.03
Nodes (66): accentColor, alertOnPeriodicPrompts, alertTimeHour, birthYear, calendarNavigateLeftKey, calendarNavigateRightKey, colorPalette, copyWith (+58 more)

### Community 13 - "Calendar Markers"
Cohesion: 0.03
Nodes (69): build, buildCalendarTodoMarkers, CalendarDayTodoBar, CalendarDayTodoIcons, CalendarDayTodoTile, calendarMaxTodoIconsPerDay, calendarMorphTodoIconProgress, calendarPackWeekAllDayShelf (+61 more)

### Community 14 - "Dev Remote"
Cohesion: 0.03
Nodes (63): _addInstantDiff, allMatched, _charMerger, compareAllJournalEntries, compareAllTodoLists, comparedAt, _compareJournalEntry, compareTodoList (+55 more)

### Community 15 - "Repositories Data"
Cohesion: 0.03
Nodes (66): countEntriesByJournal, _db, deleteAllEntries, deleteAllEvents, deleteAllJournals, deleteConflict, deleteConflictsForDocument, getAllEntries (+58 more)

### Community 16 - "Sync Weather"
Cohesion: 0.05
Nodes (58): _, @DriftDatabase, fakes/fake_weather_api_client.dart, SyncEngine, AppDatabase, InMemorySyncRepository, package:drift/native.dart, package:flutter_test/flutter_test.dart (+50 more)

### Community 17 - "Todo Task"
Cohesion: 0.03
Nodes (59): activeTasks, activeTopLevelTasks, applyDueDateChange, applyNewUndatedTask, applyNormalizeUnstarredIfNeeded, applyReorder, _applyStar, applyStarToggle (+51 more)

### Community 18 - "App Providers"
Cohesion: 0.02
Nodes (92): AsyncValue, AuthNotifier, CacheStatusSnapshot, DataExportService, DataImportService, DevSettingsController, GeometricTextureParams, JournalDebugLogger? (+84 more)

### Community 19 - "Analytics Features"
Cohesion: 0.01
Nodes (152): DateTime get, Key? dateKey,
  double, accent, _addOption, analytics, _AnalyticsViewMode, anchorDateRect, anchorRect (+144 more)

### Community 20 - "Merger Services"
Cohesion: 0.07
Nodes (34): authRepositoryProvider, build, createState, dispose, _emailController, _error, _formatAuthError, _googleSignIn (+26 more)

### Community 21 - "Search Features"
Cohesion: 0.06
Nodes (35): JournalEntry, JournalWriteCoordinator?, _accentColor, _bodyController, _bodyFocusNode, _coordinator, createState, dispose (+27 more)

### Community 22 - "Todo Features"
Cohesion: 0.14
Nodes (15): devGeometricTexturePanelOpenProvider, geometricTextureParamsProvider, build, DevGeometricTextureSection, display, divisions, _GeometricTextureSlider, label (+7 more)

### Community 23 - "Text Widgets"
Cohesion: 0.04
Nodes (53): accentColor, _applyHighlightText, build, contentPadding, controller, createState, cursorColor, decoration (+45 more)

### Community 24 - "Windows Runner"
Cohesion: 0.18
Nodes (13): Point, Size, wchar_t, wstring, Scale(), Create, Destroy, Win32Window::Win32Window() (+5 more)

### Community 25 - "Widgets Color"
Cohesion: 0.04
Nodes (48): boxH, boxW, cappedMaxHeight, cappedMaxWidth, cell, clipPartialNextRow, ColorPaletteGrid, _ColorSwatch (+40 more)

### Community 26 - "Widgets Rounded"
Cohesion: 0.04
Nodes (48): AddListDropdownValue, addListLabel, _addListSentinel, build, closedTrailing, createState, didChangeDependencies, displayLabel (+40 more)

### Community 27 - "Widgets Contextual"
Cohesion: 0.04
Nodes (45): CapturedThemes, Color get, _ContextMenuLayoutDelegate, accentColor, barrierColor, barrierDismissible, barrierLabel, _borderWidth (+37 more)

### Community 28 - "Windows Ephemeral"
Cohesion: 0.09
Nodes (34): EncodedType, ByteBufferStreamWriter, bytes_, ByteStreamWriter, WriteAlignment, WriteByte, WriteBytes, StandardCodecSerializer (+26 more)

### Community 29 - "Time Widgets"
Cohesion: 0.05
Nodes (44): FixedExtentScrollController, FixedExtentScrollPhysics, _amPmController, applyTo, build, _buildWheel, createBallisticSimulation, createState (+36 more)

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
Cohesion: 0.09
Nodes (15): map, string, vector, EncodableValue, EncodableValue, EncodableValue, EncodableValue, EncodableValue (+7 more)

### Community 34 - "Shell Features"
Cohesion: 0.05
Nodes (45): dart:ui, cachedCurrentWeatherProvider, syncActivityProvider, accent, branchIndex, build, child, color (+37 more)

### Community 35 - "Import Export"
Cohesion: 0.05
Nodes (46): class MockDocumentReference extends, DocumentReference, Exception, FirebaseFirestore, FirebaseFunctions?, _call, _firestore, FirestoreWeatherReader (+38 more)

### Community 36 - "Todo List"
Cohesion: 0.12
Nodes (16): ChangeNotifier, AuthNotifier, DevSettingsController, JournalDebugLogger, SyncCompareLogger, TodoSortDebugLogger, begin, complete (+8 more)

### Community 37 - "Sync Firestore"
Cohesion: 0.05
Nodes (39): body, CrdtTextFields, _dateToFirestore, _dateToFirestoreRequired, firestoreDocumentIdForLocal, fromJournalPayload, fromTodoPayload, id (+31 more)

### Community 38 - "Windows Ephemeral"
Cohesion: 0.05
Nodes (47): calendarRepositoryProvider, calendarsProvider, deviceIdProvider, allCalendars, assigner, changeCalendarListColor, choice, color (+39 more)

### Community 39 - "Sync Engine"
Cohesion: 0.04
Nodes (47): Duration, Duration get, cancel, DebouncedCallback, debounceDelay, Debouncer, delay, dispose (+39 more)

### Community 40 - "Calendar Event"
Cohesion: 0.05
Nodes (39): DateTimeRange, build, _buildPayload, CalendarEventPanel, _CalendarEventPanelState, _calendarFlagColor, _calendarId, calendars (+31 more)

### Community 41 - "Sync Conflict"
Cohesion: 0.06
Nodes (36): syncConflictsProvider, collection, detectedAt, documentId, id, localPayloadJson, localText, localTitle (+28 more)

### Community 42 - "Calendar Features"
Cohesion: 0.05
Nodes (41): _EmptyTrackersCard, _GridView, _HeatmapGroupDivider, _HeatmapMonthTile, _MacroStatsRow, _SectionLabel, _StatChip, CalendarDayCell (+33 more)

### Community 43 - "Features Dev"
Cohesion: 0.06
Nodes (48): authNotifierProvider, backgroundSyncOrchestratorProvider, databaseProvider, journalAllEntryIdsProvider, journalEntryCountsProvider, lazyLoadProvider, liveSyncProvider, quoteBankProvider (+40 more)

### Community 44 - "Models Domain"
Cohesion: 0.05
Nodes (36): buildDailyForecastSummaries, byDay, conditionCode, dailySummaries, date, day, days, description (+28 more)

### Community 45 - "Todo Features"
Cohesion: 0.10
Nodes (20): _buildEditor, createState, date, didUpdateWidget, dispose, _formatDate, initState, _intController (+12 more)

### Community 46 - "Sync Conflict"
Cohesion: 0.13
Nodes (12): CopyBufferCallback, FlutterDesktopPixelBuffer, function, TextureRegistrarImpl::UnregisterTexture(), PixelBufferTexture, copy_buffer_callback_, FlutterDesktopTextureRegistrarRef, TextureRegistrarImpl (+4 more)

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
Cohesion: 0.14
Nodes (12): AccessibilityMode, GpuPreference, UIThreadPolicy, DartProject, aot_library_path_, assets_path_, dart_entrypoint_, dart_entrypoint_arguments_ (+4 more)

### Community 51 - "Widgets Text"
Cohesion: 0.06
Nodes (33): FocusNode get, InputCounterWidgetBuilder?, accentColor, autofocus, build, buildCounter, controller, createState (+25 more)

### Community 52 - "Weather Features"
Cohesion: 0.13
Nodes (15): AppSettings, build, _controller, createState, didUpdateWidget, dispose, _error, initState (+7 more)

### Community 53 - "Widgets Field"
Cohesion: 0.06
Nodes (33): accentColor, alignLabelToTop, autofocus, borderRadius, build, contentPadding, controller, createState (+25 more)

### Community 54 - "Weather Forecast"
Cohesion: 0.06
Nodes (33): DayForecastChartSeries, _animation, _beginTransition, build, _controller, createState, _currentTimeHour, didUpdateWidget (+25 more)

### Community 55 - "Windows Ephemeral"
Cohesion: 0.10
Nodes (23): StreamHandlerCancel, StreamHandlerListen, EventSink, EndOfStreamInternal, ErrorInternal, SuccessInternal, string, T (+15 more)

### Community 56 - "Windows Ephemeral"
Cohesion: 0.07
Nodes (21): GeneratedPluginRegistrant, Keep, FlutterEngine, engine_, GetRegistrarForPlugin, next_frame_callback_, owns_engine_, ProcessExternalWindowMessage (+13 more)

### Community 57 - "Widgets Notched"
Cohesion: 0.06
Nodes (32): accentColor, alignLabelToTop, borderRadius, borderWidth, build, child, color, contentPadding (+24 more)

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
Cohesion: 0.05
Nodes (46): dataExportServiceProvider, dataImportServiceProvider, journalsProvider, searchServiceProvider, settingsProvider, todoListStatsProvider, todoTasksProvider, _defaultEventColor (+38 more)

### Community 62 - "Sync Activity"
Cohesion: 0.06
Nodes (30): applySettings, clearTimer, collection, direction, _displayDuration, dispose, event, eventFor (+22 more)

### Community 63 - "Models Domain"
Cohesion: 0.06
Nodes (30): body, byCreated, byDate, colorValue, compareJournalEntriesNewestFirst, copyWith, customQuote, entryDate (+22 more)

### Community 64 - "Platform Keyboard"
Cohesion: 0.04
Nodes (51): dart:async, dart:io, Future, _auth, dispose, _isAuthenticated, _subscription, clearLog (+43 more)

### Community 65 - "Database Users"
Cohesion: 0.14
Nodes (27): CalendarEventsTableCompanion, CalendarEventsTableData, CalendarsTableCompanion, CalendarsTableData, DataClass, JournalEntriesTableCompanion, JournalEntriesTableData, JournalsTableCompanion (+19 more)

### Community 66 - "Features Shell"
Cohesion: 0.07
Nodes (28): cacheGeneration, clear, degreeGridArgb, _entries, from, generation, gradientStartHour, hashCode (+20 more)

### Community 67 - "Windows Ephemeral"
Cohesion: 0.09
Nodes (24): FlutterDesktopMessage, TextureVariant, BinaryMessengerImpl::BinaryMessengerImpl(), BinaryMessengerImpl::Send(), BinaryMessengerImpl::SetMessageHandler(), BinaryMessageHandler, BinaryReply, FlutterDesktopMessengerRef (+16 more)

### Community 68 - "Firestore Data"
Cohesion: 0.07
Nodes (27): appendOperation, claimCalendarLock, claimWeatherFetchLock, _collection, deleteDocument, deleteOperationsForDocument, _doc, _firestore (+19 more)

### Community 69 - "Windows Ephemeral"
Cohesion: 0.10
Nodes (20): character, CharacterOperation, charOps, charOpsKey, CharOpsPayload, clientId, copyWith, deleted (+12 more)

### Community 70 - "Widgets Geometric"
Cohesion: 0.07
Nodes (27): FragmentProgram?, FragmentShader?, accentColor, baseColor, build, copyWith, createState, defaults (+19 more)

### Community 71 - "Text Sync"
Cohesion: 0.07
Nodes (25): addListener, advance, applyToLocalText, bufferWhileEditing, clearDocument, collection, documentId, documentKey (+17 more)

### Community 72 - "Calendar Features"
Cohesion: 0.12
Nodes (15): build, createState, dispose, initialColor, initState, _nameController, palette, _selectedColor (+7 more)

### Community 73 - "Domain Services"
Cohesion: 0.07
Nodes (26): allOps, CharacterOpRegistry, CharacterOpSession, clear, clientId, ensureSession, _insertOp, key (+18 more)

### Community 74 - "Widgets Keep"
Cohesion: 0.10
Nodes (25): AutomaticKeepAliveClientMixin, EdgeInsetsGeometry, IndexedWidgetBuilder, build, cacheExtent, child, children, controller (+17 more)

### Community 75 - "Domain Services"
Cohesion: 0.08
Nodes (19): EncodableValueVariant, any, decodeColorPaletteJson, encodeColorPaletteJson, formatColorHex, jsonEncode, normalizeColorValue, normalized (+11 more)

### Community 76 - "Main App"
Cohesion: 0.15
Nodes (12): double?, CalendarDayEntry, build, CalendarDayEntryBar, date, entry, fontSize, height (+4 more)

### Community 77 - "Widgets Date"
Cohesion: 0.07
Nodes (27): FocusNode, accentColor, build, _canPop, createState, didUpdateWidget, dispose, _firstSelected (+19 more)

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
Cohesion: 0.05
Nodes (37): CloudFunctionWeatherClient, DevOpenWeatherClient, refreshForecast, refreshWeather, WeatherApiClient, _deviceId, fetchForecastIfNeeded, isCacheStale (+29 more)

### Community 82 - "Shell Shortcuts"
Cohesion: 0.09
Nodes (23): _blockingShortcuts, BlockShellTabShortcuts, build, child, createState, dispose, _goToRelativeTab, _handleKeyEvent (+15 more)

### Community 83 - "Models Domain"
Cohesion: 0.08
Nodes (26): bool?, boolValue, cadence, colorValue, copyWith, defaultBool, defaultEnumOption, defaultInt (+18 more)

### Community 84 - "Cloud Data"
Cohesion: 0.08
Nodes (23): A. Journal — create and propagate, Automated tests (CI / local), B. Journal — concurrent edit (CRDT stress), C. Journal — metadata, Check import/export works, especially for todo lists, and deleting journals keeps journal count consistent, CRDT / journal body checks, D. Todo — create and propagate, E. Todo — reorder and star (+15 more)

### Community 85 - "Journal Features"
Cohesion: 0.07
Nodes (27): accentColor, build, _canPop, createState, _currentDateTime, didChangeDependencies, dispose, _focusRequested (+19 more)

### Community 86 - "Widgets Desktop"
Cohesion: 0.09
Nodes (22): build, buttonHeight, buttonRadius, buttonWidth, createState, DesktopWindowTitleBar, _DesktopWindowTitleBarState, dispose (+14 more)

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
Cohesion: 0.09
Nodes (21): double get, attempted, attemptedFraction, attemptedPercent, CacheItemState, cacheStateColor, cacheStateLabel, cacheStatusFromAsync (+13 more)

### Community 91 - "Features Shell"
Cohesion: 0.09
Nodes (21): EdgeInsets, belowCurvePath, curvedLinePath, hourAtPixelX, matchesScale, maxX, maxY, minX (+13 more)

### Community 92 - "Functions Forecast"
Cohesion: 0.13
Nodes (15): chartBucketHour(), firestore_1, forecastBucketKey(), formatDateKey(), localPartsFromUtc(), localTodayKey(), mergeForecastArchive(), parseBucketDateKey() (+7 more)

### Community 93 - "Features Page"
Cohesion: 0.09
Nodes (24): weatherForecastProvider, _advance, build, createState, dispose, _done, _frame, initState (+16 more)

### Community 94 - "Dev Features"
Cohesion: 0.14
Nodes (12): calendar, debug, journal, manage, search, VoyagerIcons, weatherIconData, package:flutter/widgets.dart (+4 more)

### Community 95 - "Theme Menu"
Cohesion: 0.06
Nodes (35): BoxConstraints? constraints,
  EdgeInsetsGeometry, dropdownMenuTheme, _GlowBorder, glowColor, _itemHighlightRadius, itemPadding, menuBorderRadius, menuColor (+27 more)

### Community 96 - "Registrar Windows"
Cohesion: 0.09
Nodes (19): MessageHandler, MethodCallHandler, BasicMessageChannel, codec_, messenger_, name_, BinaryReply, string (+11 more)

### Community 97 - "Functions Src"
Cohesion: 0.16
Nodes (17): ArchiveDoc, archiveLocationMatches(), chartBucketHour(), clearForecastArchive(), forecastBucketKey(), ForecastPeriod, formatDateKey(), localPartsFromUtc() (+9 more)

### Community 98 - "Dev Settings"
Cohesion: 0.10
Nodes (20): applySettings, devForceConflictUi, loadFromSettings, _persist, setDevForceConflictUi, setShowCacheStatus, setShowCalendarInstantViewSwitch, setShowCalendarZoomPrewarm (+12 more)

### Community 99 - "Dev Todo"
Cohesion: 0.07
Nodes (30): HotKey?, configureDesktopWindow, desktopWindowChromeActive, _desktopWindowConfigured, exception, installWindowsKeyboardWorkaround, _isKnownWindowsKeyboardDesync, message (+22 more)

### Community 100 - "Binding Utils"
Cohesion: 0.10
Nodes (20): alt, binding, control, _displayToken, formatKeyBinding, join, KeyBinding, keyBindingFromKeyEvent (+12 more)

### Community 101 - "Widgets Resizable"
Cohesion: 0.10
Nodes (20): build, clampListWidth, createState, defaultListWidth, dividerWidth, _dragging, _dragStartGlobalX, editorPadding (+12 more)

### Community 102 - "Auth Data"
Cohesion: 0.09
Nodes (22): _auth, _authErrorMessage, authStateChanges, _controller, currentUserId, dispose, fallback, FirebaseAuthRepository (+14 more)

### Community 103 - "Character Domain"
Cohesion: 0.15
Nodes (10): ClearPlugins, PluginRegistrarManager, GetInstance, OnRegistrarDestroyed, FlutterDesktopPluginRegistrarRef, FlutterDesktopPluginRegistrarRef, PluginRegistrar::PluginRegistrar(), PluginRegistrarManager::GetInstance() (+2 more)

### Community 104 - "Features Calendar"
Cohesion: 0.10
Nodes (19): CacheItemStatus get, int get, checks, _checksEqual, _checksEqualLists, detail, idle, isFullyPrewarmed (+11 more)

### Community 105 - "Features Calendar"
Cohesion: 0.18
Nodes (11): _apiKeyController, build, createState, DevWeatherApiTile, _DevWeatherApiTileState, didUpdateWidget, dispose, initState (+3 more)

### Community 106 - "Widgets Clamp"
Cohesion: 0.11
Nodes (18): GlobalKey, GlobalKey get, attach, ClampToTargetBounds, createRenderObject, detach, _handleScroll, _hasAttemptedScrollLookup (+10 more)

### Community 107 - "Hotkey Features"
Cohesion: 0.16
Nodes (13): class, geometricShaderProvider, _GeometricBackground, _advance, build, createState, _done, _frame (+5 more)

### Community 108 - "Palette Color"
Cohesion: 0.14
Nodes (12): AnalyticsService, booleanTrueCount, completedTasks, countWords, heatmapIntensity, integerSeries, interpolateConsecutive, rollingMax (+4 more)

### Community 109 - "Dev Sync"
Cohesion: 0.18
Nodes (10): applyMergedPayload, applyMergedText, _extractExplicitCharOps, _extractSnapshot, _latestSnapshot, mergeOperations, _pickBody, _textFromSnapshot (+2 more)

### Community 110 - "Domain Repositories"
Cohesion: 0.31
Nodes (7): EventChannel, codec_, messenger_, name_, string, T, unique_ptr

### Community 111 - "Calendar Features"
Cohesion: 0.11
Nodes (18): build, CalendarKeyboardShortcuts, _CalendarKeyboardShortcutsState, calendarNavShortcutsEnabled, child, context, createState, dispose (+10 more)

### Community 112 - "Windows Ephemeral"
Cohesion: 0.12
Nodes (16): best, colorFor, cursor, highlightedStyle, index, keywords, _keywordSpans, lower (+8 more)

### Community 113 - "Widgets Desktop"
Cohesion: 0.11
Nodes (17): Animation, AnimationController, _animDuration, _barVisible, build, child, _controller, createState (+9 more)

### Community 114 - "Widgets Dropdown"
Cohesion: 0.09
Nodes (21): FormField, FormFieldState, InputDecoration?, dark, VoyagerTheme, accentColor, build, createState (+13 more)

### Community 115 - "App Providers"
Cohesion: 0.13
Nodes (9): ByteBufferStreamReader, bytes_, location_, size_, ByteStreamReader, ReadAlignment, ReadByte, ReadBytes (+1 more)

### Community 116 - "Windows Ephemeral"
Cohesion: 0.06
Nodes (29): _, GoRouter, isDue, longestJournalStreak, missedPeriods, _nextPeriod, PeriodicPromptService, periodStartFor (+21 more)

### Community 117 - "Sync Debouncer"
Cohesion: 0.10
Nodes (19): Client, FirebaseAuth, _apiKey, _http, _periodFromForecastItem, refreshForecast, refreshWeather, _auth (+11 more)

### Community 118 - "Widgets Menu"
Cohesion: 0.12
Nodes (17): IconData? get, Iterable, buildCatalogMenu, defaultCatalogMenuChild, defaultEntityManageMenuEntries, entityManageMenuEntries, forWeatherIcon, from (+9 more)

### Community 119 - "Widgets Search"
Cohesion: 0.25
Nodes (7): BinaryMessengerImpl, handlers_, messenger_, Send, SetMessageHandler, BinaryMessageHandler, FlutterDesktopMessengerRef

### Community 120 - "Models Domain"
Cohesion: 0.11
Nodes (17): int?, colorValue, completed, copyWith, dueDate, dueDateSetAt, fromJson, isSubtask (+9 more)

### Community 121 - "Settings Palette"
Cohesion: 0.17
Nodes (11): WeatherForecast, WeatherSnapshot, package:voyager/domain/repositories/weather_api_client.dart, forecastCalls, forecastResult, geocodeCalls, geocodeResult, refreshCalls (+3 more)

### Community 122 - "Windows Ephemeral"
Cohesion: 0.17
Nodes (12): vector, ReplyManager::SendResponseData(), EngineMethodResult, codec_, reply_manager_, BinaryReply, string, T (+4 more)

### Community 123 - "Platform Widgets"
Cohesion: 0.08
Nodes (23): EditableText, IconData, body, build, floatingActionButton, PlatformAdaptiveScaffold, build, child (+15 more)

### Community 124 - "Shell Features"
Cohesion: 0.08
Nodes (23): build, QuickJournalPopup, QuickTodoPopup, icon, index, label, order, page (+15 more)

### Community 125 - "Windows Ephemeral"
Cohesion: 0.24
Nodes (10): string, T, unique_ptr, vector, MethodCodec, DecodeAndProcessResponseEnvelopeInternal, DecodeMethodCallInternal, EncodeErrorEnvelopeInternal (+2 more)

### Community 126 - "Database Data"
Cohesion: 0.14
Nodes (14): @DataClassName, CalendarEventsTable, CalendarsTable, JournalEntriesTable, JournalsTable, PendingUploadsTable, SettingsTable, SyncConflictsTable (+6 more)

### Community 127 - "Menu Widgets"
Cohesion: 0.15
Nodes (11): bool get, isAndroid, isWindows, VoyagerPlatform, copyWithDeleted, createdAt, deletedAt, id (+3 more)

### Community 128 - "Sync Outbox"
Cohesion: 0.09
Nodes (15): FlutterDesktopViewControllerRef, FlutterDesktopViewRef, FlutterViewController, controller_, ForceRedraw, HandleTopLevelWindowProc, view_id, shared_ptr (+7 more)

### Community 129 - "Functions Scripts"
Cohesion: 0.13
Nodes (14): dependencies, firebase-admin, firebase-functions, devDependencies, typescript, engines, node, main (+6 more)

### Community 130 - "Dev Warmup"
Cohesion: 0.05
Nodes (38): dart:convert, CrdtDocumentResolver, _merger, _mergeSyncOperations, resolvePayload, appSettingsWithGeometricTextureParams, copyWith, geometricTextureParamsFromSettings (+30 more)

### Community 131 - "Todo Task"
Cohesion: 0.20
Nodes (10): trackerRepositoryProvider, _createTracker, _delete, _HeatmapPopover, _HeatmapPopoverState, _MorphPopover, _MorphPopoverState, _persist (+2 more)

### Community 132 - "Gradient Widgets"
Cohesion: 0.06
Nodes (33): BaseSliderTrackShape, Color, currentWeatherProvider, build, color, ColorCornerFlag, colorValue, JournalBookmarkFlag (+25 more)

### Community 133 - "Models Analytics"
Cohesion: 0.25
Nodes (7): firestoreId, legacyTodoListFirestoreId, legacyTodoListId, localId, todoListDocumentIdForFirestore, todoListDocumentIdFromFirestore, return

### Community 134 - "Models Domain"
Cohesion: 0.11
Nodes (19): Calendar, CalendarEvent, calendarId, colorValue, copyWith, end, EventRecurrence, EventSource (+11 more)

### Community 135 - "Windows Ephemeral"
Cohesion: 0.29
Nodes (7): _handleTap, _HeatmapBucket, _HeatmapBucketState, _heatmapDraggingProvider, _HoverEditPopover, _HoverEditPopoverState, _show

### Community 136 - "Platform Domain"
Cohesion: 0.21
Nodes (13): OnCreate, RECT, HWND, Win32Window, child_content_, GetClientArea, GetHandle, OnCreate (+5 more)

### Community 137 - "Domain Services"
Cohesion: 0.07
Nodes (51): ConsumerState, allTodoTasksProvider, remoteSyncServiceProvider, todoListsProvider, todoRepositoryProvider, todoSortDebugLoggerProvider, build, VoyagerApp (+43 more)

### Community 138 - "Functions Tsconfig"
Cohesion: 0.15
Nodes (12): compileOnSave, compilerOptions, esModuleInterop, module, noImplicitReturns, noUnusedLocals, outDir, skipLibCheck (+4 more)

### Community 139 - "Auth Firebase"
Cohesion: 0.15
Nodes (12): contains, embedded, firebaseAuthErrorMessage, invalidCredentialHints, _isGenericInternalMessage, lower, _messageFromEmbeddedDetails, normalizedCode (+4 more)

### Community 140 - "Color Widgets"
Cohesion: 0.33
Nodes (6): @immutable, CacheItemStatus, CacheStatusSnapshot, MonthZoomPrewarmCheck, MonthZoomPrewarmStatus, WeatherChartPlotCacheKey

### Community 141 - "FlutterView"
Cohesion: 0.13
Nodes (14): package:voyager/domain/todo/todo_task_sorting.dart, required String id,
  bool, byId, dueDate, dueDateSetAt, id, main, now (+6 more)

### Community 142 - "Windows Ephemeral"
Cohesion: 0.13
Nodes (14): Delay, _authRepo, _db, _firestore, initialize, _instance, _isDraining, isInitialized (+6 more)

### Community 143 - "Windows Ephemeral"
Cohesion: 0.27
Nodes (9): ResultHandlerError, ResultHandlerNotImplemented, ResultHandlerSuccess, string, T, MethodResultFunctions, on_error_, on_not_implemented_ (+1 more)

### Community 144 - "Widgets Selector"
Cohesion: 0.40
Nodes (6): _AddListMenuItem, _AddListMenuItemState, _RoundedDropdownMenuItem, _RoundedDropdownMenuItemState, Object?, PopupMenuEntry

### Community 145 - "Constants Google"
Cohesion: 0.09
Nodes (28): cacheStatusSnapshotProvider, devSettingsProvider, journalDebugLoggerProvider, pendingStatEntriesProvider, build, StatisticsActionFab, _scaledMorphDuration, build (+20 more)

### Community 146 - "Features Analytics"
Cohesion: 0.14
Nodes (13): Files touched by this migration, How it works, Intentional exception: the inline todo-item rename field, Known limitations / non-goals, `LabeledTextField` (`lib/core/widgets/labeled_text_field.dart`), `TagHighlightedTextField` (`lib/core/widgets/tag_highlighted_text_field.dart`), Text box widget: `NotchedFieldBorder`, The notch math (+5 more)

### Community 147 - "Features Settings"
Cohesion: 0.18
Nodes (11): build, _captured, createState, current, dispose, _handleKeyEvent, initState, _KeyBindingDialog (+3 more)

### Community 148 - "Shell App"
Cohesion: 0.29
Nodes (7): StatisticTracker, TrackerValue, Journal, JournalEntry, SoftDeletable, TodoListModel, TodoTask

### Community 149 - "Widgets Features"
Cohesion: 0.18
Nodes (11): CustomPainter, _ClockDialPainter, GeometricTexturePainter, _CornerFlagPainter, _NotchedBorderPainter, _TagHighlightPainter, CalendarWeekDayColumnBorderPainter, CalendarWeekTimeGridPainter (+3 more)

### Community 150 - "Constants Journal"
Cohesion: 0.18
Nodes (10): firestoreId, firestoreJournalId, journalDocumentIdForFirestore, journalDocumentIdFromFirestore, journalReferenceIdForFirestore, journalReferenceIdFromFirestore, legacyJournalFirestoreId, legacyJournalId (+2 more)

### Community 151 - "Widgets Confirm"
Cohesion: 0.18
Nodes (10): cancelLabel, confirmed, confirmLabel, deleteAllLabel, DeleteContainerChoice, moveLabel, result, showConfirmDialog (+2 more)

### Community 152 - "Weather Fakes"
Cohesion: 0.40
Nodes (4): isExpired, purgeEligibleAfter, SoftDeletePolicy, package:voyager/core/constants/app_constants.dart

### Community 153 - "Features Settings"
Cohesion: 0.14
Nodes (13): int? current,
  Set, assign, nextColor, palette, PaletteAssigner, paletteFromItems, pickColorFromPalette, pickPaletteColorWithRef (+5 more)

### Community 154 - "Shell App"
Cohesion: 0.25
Nodes (7): _callbacks, flushAll, instance, PendingFlushRegistry, register, unregister, static final

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
Nodes (44): buildScrollbar, createState, didChangeAppLifecycleState, dispose, _flushAllPendingEdits, initState, _NoScrollbarScrollBehavior, onWindowClose (+36 more)

### Community 162 - "Sync Text"
Cohesion: 0.22
Nodes (8): _, adjustedSelection, _commonPrefixLength, _commonSuffixLength, _fallbackMerge, injectRemoteDelta, _insertAt, TextDeltaInjector

### Community 163 - "Sync Pending"
Cohesion: 0.40
Nodes (4): package:voyager/core/constants/google_auth_config.dart, package:voyager/data/remote/desktop_google_oauth.dart, StateError, main

### Community 164 - "App Providers"
Cohesion: 0.17
Nodes (11): googleOAuthClientId, _googleOAuthClientIdRaw, googleOAuthClientSecret, _googleOAuthClientSecretRaw, googleOAuthRedirectPort, id, isGoogleOAuthClientSecretConfigured, isGoogleOAuthConfigured (+3 more)

### Community 165 - "trackerRepositoryProvider"
Cohesion: 0.19
Nodes (11): T, unique_ptr, vector, MessageCodec, DecodeMessageInternal, EncodeMessageInternal, EncodableValue, StandardMessageCodec (+3 more)

### Community 166 - "Theme Spacing"
Cohesion: 0.22
Nodes (8): compactListVerticalDensity, lg, md, sm, VoyagerSpacing, xl, xs, xxs

### Community 167 - "settingsRepositoryProvider"
Cohesion: 0.29
Nodes (7): @visibleForTesting, calendarNavDeltaForEvent, calendarNavShortcutsEnabledForState, isTextInputFocused, isShellTabShortcutEvent, shellTabDeltaForEvent, shellTabShortcutsEnabledForState

### Community 168 - "Windows Ephemeral"
Cohesion: 0.07
Nodes (37): colorPaletteProvider, journalEntryCacheInvalidatorProvider, journalRepositoryProvider, journalWriteCoordinatorProvider, build, createJournalList, build, created (+29 more)

### Community 169 - ".CallTopLevelWindowProcDelegates"
Cohesion: 0.25
Nodes (7): build, children, currentIndex, ShellBranchContainer, shellBranchContainerBuilder, package:go_router/go_router.dart, ShellNavigationContainerBuilder

### Community 170 - "ByteBufferStreamReader"
Cohesion: 0.17
Nodes (10): FlutterViewId, HWND, LPARAM, LRESULT, optional, UINT, WPARAM, FlutterViewController::FlutterViewController() (+2 more)

### Community 171 - "Widgets Enter"
Cohesion: 0.50
Nodes (4): BorderedRoundedDropdown, RoundedDropdown, _RoundedDropdownState, T

### Community 172 - "Gpusurfacetexture Windows"
Cohesion: 0.39
Nodes (5): FlutterDesktopGpuSurfaceDescriptor, FlutterDesktopGpuSurfaceType, ObtainDescriptorCallback, GpuSurfaceTexture, obtain_descriptor_callback_

### Community 173 - "@immutable"
Cohesion: 0.08
Nodes (25): WindowProcDelegate, GetRegistrar(), FlutterDesktopPluginRegistrarRef, set, T, unique_ptr, PluginRegistrar, AddPlugin (+17 more)

### Community 174 - "Constants Todo"
Cohesion: 0.33
Nodes (5): dart:math, indices, main, r, sorted

### Community 175 - "Shell Features"
Cohesion: 0.20
Nodes (9): 1. Database Schema (SQLite / CRDT Ready), 2. State Management & Logic (Riverpod), 3. UI / Widget Architecture, A. The 1-Year Rolling Maximum (Independent Integers), A. The Journal Page Entry Flow, B. Analytics Page: Default View (The 4 Dashboards), B. Enum Dynamic Color Generation, C. Analytics Page: Calendar View (+1 more)

### Community 176 - "Messenger Windows"
Cohesion: 0.12
Nodes (16): _addColor, build, createState, dispose, _hexController, _hexError, _hexFocusNode, palette (+8 more)

### Community 177 - "dart:math"
Cohesion: 0.08
Nodes (22): allLists, assigner, choice, color, controller, deleted, deleteTodoList, list (+14 more)

### Community 178 - "Constants Hotkey"
Cohesion: 0.29
Nodes (6): defaultCalendarNavigateLeftKey, defaultCalendarNavigateRightKey, defaultJournalHotkey, defaultTodoHotkey, legacyJournalHotkey, legacyTodoHotkey

### Community 179 - "Sync Firestore"
Cohesion: 0.15
Nodes (11): FirestoreCollections, journalEntries, journals, syncOperations, todoLists, todoTasks, AppFonts, applyTo (+3 more)

### Community 180 - "@visibleForTesting"
Cohesion: 0.13
Nodes (12): decoration, restingColor, selectedColor, VoyagerListItemSurface, formatTime12Hour, formatTimeOfDay12Hour, jm, local (+4 more)

### Community 181 - "MethodCall"
Cohesion: 0.48
Nodes (5): string, T, unique_ptr, MethodCall, method_name_

### Community 182 - "Anagram List1"
Cohesion: 0.33
Nodes (5): list1, list2, main, s1, s2

### Community 183 - "dart:math"
Cohesion: 0.38
Nodes (10): HWND, LPARAM, LRESULT, UINT, WPARAM, EnableFullDpiSupportIfAvailable(), GetThisFromHandle, MessageHandler (+2 more)

### Community 184 - "Calendar Features"
Cohesion: 0.33
Nodes (6): InheritedWidget, _ContextualPopoverAccentScope, CalendarEventTapScope, CalendarMorphYearDotsOpacity, _MorphProgress, _WeekMorphProgress

### Community 185 - "debouncer.dart"
Cohesion: 0.50
Nodes (3): package:voyager/core/utils/key_binding.dart, package:voyager/features/calendar/calendar_keyboard_shortcuts.dart, main

### Community 186 - "Widgets Rounded"
Cohesion: 0.40
Nodes (5): Intent, _SubmitIntent, _BlockShellTabIntent, NextShellTabIntent, PreviousShellTabIntent

### Community 187 - "Chart Weather"
Cohesion: 0.33
Nodes (5): package:fl_chart/fl_chart.dart, package:voyager/features/shell/weather_chart_curve.dart, curveFor, main, spots

### Community 188 - "Android Gradlew"
Cohesion: 0.60
Nodes (3): gradlew script, die(), warn()

### Community 189 - "Deinterleave Evens"
Cohesion: 0.40
Nodes (4): evens, main, odds, s

### Community 190 - "WeatherApiClient"
Cohesion: 0.11
Nodes (30): ConsumerWidget, allJournalEntriesProvider, analyticsServiceProvider, periodicPromptServiceProvider, trackersProvider, trackerValuesProvider, AnalyticsPage, _AnalyticsToolbar (+22 more)

### Community 191 - "Dev Flags"
Cohesion: 0.33
Nodes (5): DevFlags, showTimeSelectorHitboxes, slowHeatmapPopoverAnimation, verboseSync, static bool

### Community 192 - "Utils Ids"
Cohesion: 0.40
Nodes (4): newId, utcNow, _uuid, package:uuid/uuid.dart

### Community 193 - "Utils Journal"
Cohesion: 0.40
Nodes (4): colorForTag, extractTags, journalTagPattern, matches

### Community 194 - "Google Desktop"
Cohesion: 0.29
Nodes (6): string, T, MethodResult, ErrorInternal, NotImplementedInternal, SuccessInternal

### Community 195 - "Constants Todo"
Cohesion: 0.50
Nodes (3): normalizeUnstarredSortOrder, starredSortOrderMax, unstarredSortOrderBase

### Community 196 - "PLAN.md"
Cohesion: 0.22
Nodes (8): AGENTS, Features, Frontend UI, Future Additions, High Level Overview, Low Level Design, Miscellaneous, Theme

### Community 198 - "Calendar Customclipper"
Cohesion: 0.40
Nodes (5): CustomClipper, _RevealClipper, _WeekTimedViewportClipper, Path, Rect

### Community 199 - "High-Level Design: Voyager Weekly Calendar View"
Cohesion: 0.22
Nodes (8): High-Level Design: Voyager Weekly Calendar View, I. System Overview, II. Visual Layout & Z-Index Stack, III. The Overlap Engine (Column Splitting), IV. Data Entity Specifications, The Zero-Duration Task Layout Logic, Todo Task Logic, V. User Interaction Flow

### Community 200 - "IMPORT_EXPORT.md"
Cohesion: 0.25
Nodes (7): 1. The Database Layer (Drift), 2. The Export Pipeline (`DataExportService`), 3. The Import Pipeline (`DataImportService`), 4. The Trickle Sync Engine (`OutboxSyncWorker`), 5. Testing Strategy, Integration Tests (Slow, End-to-End), Unit Tests (Fast, Isolated)

### Community 201 - "Constants App"
Cohesion: 0.50
Nodes (3): popupGlowAlpha, softDeleteRetentionDays, syncDebounceSeconds

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
Cohesion: 0.10
Nodes (17): DateTime?, nextQuote, QuoteBank, _quotes, _random, _used, build, HeatmapCalendar (+9 more)

### Community 217 - "Voyager"
Cohesion: 0.33
Nodes (5): Architecture, Features, Setup, Testing, Voyager

### Community 220 - "TIME_SELECTOR.md"
Cohesion: 0.40
Nodes (4): 1. The Container (The Anchored Popover), 2. The Internal Layout (Start Time Popup), 3. The Internal Layout (End Time / Duration Popup), The Execution Summary

### Community 221 - "MessageHandler"
Cohesion: 0.15
Nodes (13): HWND, LPARAM, LRESULT, UINT, WPARAM, FlutterWindow, flutter_controller_, FlutterWindow::FlutterWindow() (+5 more)

### Community 228 - "_VoyagerAppState"
Cohesion: 0.10
Nodes (20): ConsumerStatefulWidget, _CalendarCell, _CalendarCellState, _HeatmapDayCell, _HeatmapDayCellState, _HeatmapSquare, _HeatmapSquareState, _HeatmapWeekBlock (+12 more)

### Community 237 - "cadence"
Cohesion: 0.09
Nodes (35): _ContextMenuOverlay, _ContextMenuOverlayState, _CreateNameColorDialog, _CreateNameColorDialogState, DateSelectorPopover, _DateSelectorPopoverState, DateTimeSelectorPopover, _DateTimeSelectorPopoverState (+27 more)

### Community 362 - "dart:ui"
Cohesion: 0.09
Nodes (20): CharacterSequenceCrdtMerger, applyMergedPayload, _delegate, merge, SequenceCrdtMerger, byId, main, merger (+12 more)

## Knowledge Gaps
- **4616 isolated node(s):** `_fallbackDeviceId`, `_useCloudFunctions`, `_openWeatherApiKey`, `db`, `syncConflictRepositoryProvider` (+4611 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **21 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `any` connect `Domain Services` to `Windows Cpp`?**
  _High betweenness centrality (0.154) - this node is a cross-community bridge._
- **Why does `FlutterEngine` connect `Windows Ephemeral` to `Registrar Windows`, `Windows Cpp`, `Windows Ephemeral`, `Sync Outbox`?**
  _High betweenness centrality (0.023) - this node is a cross-community bridge._
- **Why does `PluginRegistrarWindows` connect `@immutable` to `Sync Outbox`, `Windows Runner`, `Character Domain`?**
  _High betweenness centrality (0.013) - this node is a cross-community bridge._
- **What connects `_fallbackDeviceId`, `_useCloudFunctions`, `_openWeatherApiKey` to the rest of the system?**
  _4616 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Database Data` be split into smaller, more focused modules?**
  _Cohesion score 0.005012531328320802 - nodes in this community are weakly interconnected._
- **Should `Calendar Features` be split into smaller, more focused modules?**
  _Cohesion score 0.0078125 - nodes in this community are weakly interconnected._
- **Should `Calendar Day` be split into smaller, more focused modules?**
  _Cohesion score 0.0091324200913242 - nodes in this community are weakly interconnected._