import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/constants/hotkey_defaults.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';

part 'app_database.g.dart';

class JournalsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get colorValue => integer().nullable()();
  BoolColumn get guidedJournaling =>
      boolean().withDefault(const Constant(false))();
  IntColumn get promptCycleDays => integer().withDefault(const Constant(7))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class JournalEntriesTable extends Table {
  TextColumn get id => text()();
  TextColumn get journalId => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();
  TextColumn get richBodyJson => text().nullable()();
  DateTimeColumn get entryDate => dateTime()();
  DateTimeColumn get timestamp => dateTime().nullable()();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  IntColumn get mood => integer().nullable()();
  TextColumn get quoteId => text().nullable()();
  TextColumn get customQuote => text().nullable()();
  TextColumn get weatherIcon => text().nullable()();
  TextColumn get guidedPrompt => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class TodoListsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get colorValue => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class TodoTasksTable extends Table {
  TextColumn get id => text()();
  TextColumn get listId => text()();
  TextColumn get parentTaskId => text().nullable()();
  TextColumn get title => text()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get dueDate => dateTime().nullable()();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  BoolColumn get starred => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get preStarSortOrder => integer().nullable()();
  DateTimeColumn get dueDateSetAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class CalendarsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get colorValue => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class CalendarEventsTable extends Table {
  TextColumn get id => text()();
  TextColumn get calendarId =>
      text().withDefault(const Constant(legacyCalendarId))();
  TextColumn get title => text()();
  DateTimeColumn get start => dateTime()();
  DateTimeColumn get end => dateTime()();
  BoolColumn get isFullDay => boolean().withDefault(const Constant(true))();
  IntColumn get colorValue =>
      integer().withDefault(const Constant(0xFF7C9EFF))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get source => text().withDefault(const Constant('local'))();
  TextColumn get externalId => text().nullable()();
  TextColumn get recurrence =>
      text().withDefault(const Constant('none'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class TrackersTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get type => text()();
  TextColumn get cadence => text()();
  IntColumn get colorValue =>
      integer().withDefault(const Constant(0xFF7C9EFF))();
  BoolColumn get showOnCalendar =>
      boolean().withDefault(const Constant(false))();
  IntColumn get integerCap => integer().nullable()();
  IntColumn get defaultInt => integer().withDefault(const Constant(0))();
  BoolColumn get defaultBool => boolean().withDefault(const Constant(false))();
  TextColumn get enumOptionsJson => text().withDefault(const Constant('[]'))();
  TextColumn get defaultEnumOption => text().nullable()();
  TextColumn get trackingStyle => text().nullable()();
  BoolColumn get starred => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class TrackerValuesTable extends Table {
  TextColumn get id => text()();
  TextColumn get trackerId => text()();
  DateTimeColumn get periodStart => dateTime()();
  IntColumn get intValue => integer().nullable()();
  BoolColumn get boolValue => boolean().nullable()();
  TextColumn get enumValue => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class TransactionsTable extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()();
  IntColumn get amountCents => integer()();
  TextColumn get note => text().nullable()();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  DateTimeColumn get occurredAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class SubscriptionsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get amountCents => integer()();
  TextColumn get period => text()();
  DateTimeColumn get anchorDueDate => dateTime()();
  IntColumn get colorValue =>
      integer().withDefault(const Constant(0xFF7C9EFF))();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class BudgetsTable extends Table {
  TextColumn get id => text()();
  TextColumn get tag => text()();
  IntColumn get limitCents => integer()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class FinanceCategoriesTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get colorValue =>
      integer().withDefault(const Constant(0xFF7C9EFF))();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class AssetsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get note => text().nullable()();
  IntColumn get colorValue =>
      integer().withDefault(const Constant(0xFF7C9EFF))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class AssetValuationsTable extends Table {
  TextColumn get id => text()();
  TextColumn get assetId => text()();
  IntColumn get valueCents => integer()();
  DateTimeColumn get asOf => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class SavingsGoalsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get targetCents => integer()();
  IntColumn get colorValue =>
      integer().withDefault(const Constant(0xFF7C9EFF))();
  TextColumn get note => text().nullable()();
  DateTimeColumn get targetDate => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class GoalAllocationsTable extends Table {
  TextColumn get id => text()();
  TextColumn get goalId => text()();
  IntColumn get amountCents => integer()();
  DateTimeColumn get allocatedAt => dateTime()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class SettingsTable extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  IntColumn get accentColor =>
      integer().withDefault(const Constant(0xFF7C9EFF))();
  BoolColumn get weekStartsOnMonday =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get showQuotes => boolean().withDefault(const Constant(true))();
  BoolColumn get showDefaultTrackersInGrid =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get showDefaultTrackersInCalendar =>
      boolean().withDefault(const Constant(true))();
  TextColumn get journalHotkey =>
      text().withDefault(const Constant(defaultJournalHotkey))();
  TextColumn get todoHotkey =>
      text().withDefault(const Constant(defaultTodoHotkey))();
  TextColumn get calendarNavigateLeftKey =>
      text().withDefault(const Constant(defaultCalendarNavigateLeftKey))();
  TextColumn get calendarNavigateRightKey =>
      text().withDefault(const Constant(defaultCalendarNavigateRightKey))();
  BoolColumn get timelineModeYearZero =>
      boolean().withDefault(const Constant(true))();
  IntColumn get birthYear => integer().nullable()();
  BoolColumn get alertOnPeriodicPrompts =>
      boolean().withDefault(const Constant(false))();
  IntColumn get alertTimeHour => integer().withDefault(const Constant(9))();
  BoolColumn get hideCompletedTasks =>
      boolean().withDefault(const Constant(false))();
  TextColumn get deviceId => text().nullable()();
  TextColumn get lastViewedJournalId => text().nullable()();
  TextColumn get lastViewedTodoListId => text().nullable()();
  TextColumn get weatherLocationLabel => text().nullable()();
  RealColumn get weatherLat => real().nullable()();
  RealColumn get weatherLon => real().nullable()();
  TextColumn get weatherIcon => text().nullable()();
  DateTimeColumn get weatherFetchedAt => dateTime().nullable()();
  IntColumn get weatherConditionCode => integer().nullable()();
  RealColumn get weatherTempC => real().nullable()();
  DateTimeColumn get weatherLocationUpdatedAt => dateTime().nullable()();
  BoolColumn get devUseDirectOpenWeather =>
      boolean().withDefault(const Constant(false))();
  TextColumn get devOpenWeatherApiKey => text().nullable()();
  BoolColumn get devShowSyncLocalSaves =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get devShowSyncUploads =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get devShowSyncDownloads =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get devShowCacheStatus =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get devShowCalendarZoomPrewarm =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get devShowCalendarInstantViewSwitch =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get devSlowCalendarAnimations =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get devTodoSortDebugLog =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get devJournalDebugLog =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get devForceConflictUi =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get devShowConflictDocumentIds =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get devShowJournalRemotePullButton =>
      boolean().withDefault(const Constant(false))();
  TextColumn get weatherForecastJson => text().nullable()();
  IntColumn get weatherChartTempColor => integer().nullable()();
  IntColumn get weatherChartRainColor => integer().nullable()();
  RealColumn get weatherChartCurveTension =>
      real().withDefault(const Constant(0.22))();
  TextColumn get colorPaletteJson => text().nullable()();
  RealColumn get journalEntryListWidth => real().nullable()();
  RealColumn get geometricTextureScale =>
      real().withDefault(const Constant(10.0))();
  RealColumn get geometricTextureIntensity =>
      real().withDefault(const Constant(0.85))();
  RealColumn get geometricTextureFocalSpread =>
      real().withDefault(const Constant(1.0))();
  RealColumn get geometricTextureFocalPointX =>
      real().withDefault(const Constant(1.0))();
  RealColumn get geometricTextureFocalPointY =>
      real().withDefault(const Constant(0.5))();
  RealColumn get geometricTextureVariationFloor =>
      real().withDefault(const Constant(0.75))();
  BoolColumn get geometricWaveEnabled =>
      boolean().withDefault(const Constant(false))();
  TextColumn get geometricWaveShape =>
      text().withDefault(const Constant('linear'))();
  RealColumn get geometricWaveDirectionDegrees =>
      real().withDefault(const Constant(135.0))();
  RealColumn get geometricWaveSpeed =>
      real().withDefault(const Constant(0.4))();
  RealColumn get geometricWaveWidth =>
      real().withDefault(const Constant(0.08))();
  RealColumn get geometricWavePeriod =>
      real().withDefault(const Constant(7.0))();
  RealColumn get geometricWavePopHoldSeconds =>
      real().withDefault(const Constant(0.6))();
  RealColumn get geometricWavePopScale =>
      real().withDefault(const Constant(1.4))();
  RealColumn get geometricWavePopBrightness =>
      real().withDefault(const Constant(0.32))();
  RealColumn get geometricWaveMaskDensity =>
      real().withDefault(const Constant(0.5))();
  RealColumn get geometricWaveMaskClusterScale =>
      real().withDefault(const Constant(5.0))();
  RealColumn get geometricWaveTwinkleSparsity =>
      real().withDefault(const Constant(0.15))();
  RealColumn get geometricWaveShadowLightDegrees =>
      real().withDefault(const Constant(225.0))();
  RealColumn get geometricWaveShadowOffset =>
      real().withDefault(const Constant(0.06))();
  RealColumn get geometricWaveShadowSoftness =>
      real().withDefault(const Constant(0.04))();
  RealColumn get geometricWaveShadowStrength =>
      real().withDefault(const Constant(0.45))();
  RealColumn get geometricWavePopBrightnessVariance =>
      real().withDefault(const Constant(0.4))();
  RealColumn get geometricWaveTiltAmount =>
      real().withDefault(const Constant(0.7))();
  RealColumn get geometricWaveTiltShading =>
      real().withDefault(const Constant(0.5))();
  RealColumn get geometricWaveMassLagSeconds =>
      real().withDefault(const Constant(0.12))();
  RealColumn get geometricWaveMassSpring =>
      real().withDefault(const Constant(0.3))();
  BoolColumn get geometricWaveScatterMode =>
      boolean().withDefault(const Constant(false))();
  RealColumn get geometricWaveScatterLitAmount =>
      real().withDefault(const Constant(0.12))();
  TextColumn get navPageOrderJson => text().nullable()();
  TextColumn get startupPageMode => text().withDefault(const Constant('first'))();
  TextColumn get customStartupPage => text().nullable()();
  TextColumn get lastSeenNavPage => text().nullable()();
  BoolColumn get todoCompletedSectionExpanded =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get showAnnualizedSubscriptionCost =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class TagColorsTable extends Table {
  TextColumn get tag => text()();
  IntColumn get colorValue => integer()();

  @override
  Set<Column> get primaryKey => {tag};
}

class SyncConflictsTable extends Table {
  TextColumn get id => text()();
  TextColumn get collection => text()();
  TextColumn get documentId => text()();
  TextColumn get localPayloadJson => text()();
  TextColumn get remotePayloadJson => text()();
  TextColumn get localTitle => text().nullable()();
  TextColumn get remoteTitle => text().nullable()();
  TextColumn get localText => text().nullable()();
  TextColumn get remoteText => text().nullable()();
  DateTimeColumn get detectedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('PendingUploadData')
class PendingUploadsTable extends Table {
  TextColumn get documentId => text()();
  TextColumn get collectionName => text()();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {documentId, collectionName};
}

@DriftDatabase(
  tables: [
    JournalsTable,
    JournalEntriesTable,
    TodoListsTable,
    TodoTasksTable,
    CalendarsTable,
    CalendarEventsTable,
    TrackersTable,
    TrackerValuesTable,
    SettingsTable,
    TagColorsTable,
    SyncConflictsTable,
    PendingUploadsTable,
    TransactionsTable,
    SubscriptionsTable,
    BudgetsTable,
    FinanceCategoriesTable,
    AssetsTable,
    AssetValuationsTable,
    SavingsGoalsTable,
    GoalAllocationsTable,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 51;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (details) async {
      if (details.wasCreated) return;
      await _backfillNullBools();
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.hideCompletedTasks,
        );
      }
      if (from < 3) {
        await _backfillNullBools();
      }
      if (from < 4) {
        await migrator.addColumn(
          journalEntriesTable,
          journalEntriesTable.richBodyJson,
        );
      }
      if (from < 5) {
        await migrator.addColumn(journalsTable, journalsTable.colorValue);
        await migrator.addColumn(todoListsTable, todoListsTable.colorValue);
        await migrator.addColumn(todoTasksTable, todoTasksTable.parentTaskId);
        await migrator.addColumn(todoTasksTable, todoTasksTable.starred);
        await migrator.addColumn(todoTasksTable, todoTasksTable.sortOrder);
        await migrator.addColumn(
          todoTasksTable,
          todoTasksTable.preStarSortOrder,
        );
        await _backfillNullBools();
      }
      if (from < 6) {
        await migrator.addColumn(settingsTable, settingsTable.deviceId);
        await migrator.addColumn(
          settingsTable,
          settingsTable.weatherLocationLabel,
        );
        await migrator.addColumn(settingsTable, settingsTable.weatherLat);
        await migrator.addColumn(settingsTable, settingsTable.weatherLon);
        await migrator.addColumn(settingsTable, settingsTable.weatherIcon);
        await migrator.addColumn(settingsTable, settingsTable.weatherFetchedAt);
        await migrator.addColumn(
          settingsTable,
          settingsTable.weatherConditionCode,
        );
        await migrator.addColumn(settingsTable, settingsTable.weatherTempC);
      }
      if (from < 7) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.weatherLocationUpdatedAt,
        );
      }
      if (from < 8) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.devUseDirectOpenWeather,
        );
        await migrator.addColumn(
          settingsTable,
          settingsTable.devOpenWeatherApiKey,
        );
      }
      if (from < 9) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.weatherForecastJson,
        );
      }
      if (from < 10) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.weatherChartTempColor,
        );
        await migrator.addColumn(
          settingsTable,
          settingsTable.weatherChartRainColor,
        );
      }
      if (from < 11) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.colorPaletteJson,
        );
        await customStatement(
          'UPDATE settings_table SET color_palette_json = ? WHERE color_palette_json IS NULL',
          [encodeColorPaletteJson(defaultColorPalette)],
        );
      }
      if (from < 12) {
        await customStatement(
          'UPDATE settings_table SET todo_hotkey = ? WHERE todo_hotkey = ?',
          [defaultTodoHotkey, legacyTodoHotkey],
        );
        await customStatement(
          'UPDATE settings_table SET journal_hotkey = ? WHERE journal_hotkey = ?',
          [defaultJournalHotkey, legacyJournalHotkey],
        );
      }
      if (from < 13) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.lastViewedJournalId,
        );
      }
      if (from < 14) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.devShowSyncUploads,
        );
        await migrator.addColumn(
          settingsTable,
          settingsTable.devShowSyncDownloads,
        );
      }
      if (from < 15) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.devShowSyncLocalSaves,
        );
      }
      if (from < 16) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.journalEntryListWidth,
        );
      }
      if (from < 17) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.devShowCacheStatus,
        );
      }
      if (from < 18) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.devShowCalendarZoomPrewarm,
        );
      }
      if (from < 19) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.devShowCalendarInstantViewSwitch,
        );
      }
      if (from < 20) {
        // Guard against duplicate-column error if the column was already added
        // by a previous partial migration (e.g. after a hot restart mid-run).
        try {
          await migrator.addColumn(
            settingsTable,
            settingsTable.weatherChartCurveTension,
          );
        } on Exception catch (_) {
          // Column already exists — safe to proceed.
        }
      }
      if (from < 21) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.calendarNavigateLeftKey,
        );
        await migrator.addColumn(
          settingsTable,
          settingsTable.calendarNavigateRightKey,
        );
      }
      if (from < 22) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.lastViewedTodoListId,
        );
        await migrator.addColumn(
          calendarEventsTable,
          calendarEventsTable.recurrence,
        );
      }
      if (from < 23) {
        await migrator.addColumn(
          todoTasksTable,
          todoTasksTable.dueDateSetAt,
        );
      }
      if (from < 24) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.devTodoSortDebugLog,
        );
      }
      if (from < 25) {
        await migrator.addColumn(journalsTable, journalsTable.version);
        await migrator.addColumn(journalEntriesTable, journalEntriesTable.version);
        await migrator.addColumn(todoListsTable, todoListsTable.version);
        await migrator.addColumn(todoTasksTable, todoTasksTable.version);
      }
      if (from < 26) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.devJournalDebugLog,
        );
      }
      if (from < 27) {
        await migrator.createTable(syncConflictsTable);
        await migrator.addColumn(
          settingsTable,
          settingsTable.devForceConflictUi,
        );
      }
      if (from < 28) {
        await migrator.addColumn(
          settingsTable,
          settingsTable.devShowConflictDocumentIds,
        );
      }
      if (from < 29) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricTextureScale,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricTextureIntensity,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricTextureFocalSpread,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricTextureFocalPointX,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricTextureFocalPointY,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricTextureVariationFloor,
        );
      }
      if (from < 30) {
        await migrator.createTable(pendingUploadsTable);
      }
      if (from < 31) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.devShowJournalRemotePullButton,
        );
      }
      if (from < 32) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.devSlowCalendarAnimations,
        );
      }
      if (from < 33) {
        await _addSettingsColumnIfNotExists(migrator, settingsTable.navPageOrderJson);
        await _addSettingsColumnIfNotExists(migrator, settingsTable.startupPageMode);
        await _addSettingsColumnIfNotExists(migrator, settingsTable.customStartupPage);
        await _addSettingsColumnIfNotExists(migrator, settingsTable.lastSeenNavPage);
      }
      if (from < 34) {
        await migrator.addColumn(trackersTable, trackersTable.trackingStyle);
      }
      if (from < 35) {
        await migrator.deleteTable('ranking_configs_table');
        await migrator.deleteTable('ranking_values_table');
        await _dropSettingsColumnIfExists(migrator, 'ranking_color_start');
        await _dropSettingsColumnIfExists(migrator, 'ranking_color_end');
      }
      if (from < 36) {
        await migrator.addColumn(trackersTable, trackersTable.starred);
        await migrator.addColumn(trackersTable, trackersTable.sortOrder);
      }
      if (from < 37) {
        await migrator.createTable(calendarsTable);
        await migrator.addColumn(
          calendarEventsTable,
          calendarEventsTable.calendarId,
        );
        final now = DateTime.now().toUtc();
        await into(calendarsTable).insertOnConflictUpdate(
          CalendarsTableCompanion(
            id: const Value(legacyCalendarId),
            name: const Value('Calendar'),
            colorValue: const Value(0xFF7C9EFF),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
        // Defensive backfill in case the ADD COLUMN default isn't retroactively
        // applied to pre-existing rows on this platform/SQLite version.
        await customStatement(
          'UPDATE calendar_events_table SET calendar_id = ? WHERE calendar_id IS NULL',
          [legacyCalendarId],
        );
      }
      if (from < 38) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveEnabled,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveShape,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveDirectionDegrees,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveSpeed,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveWidth,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWavePeriod,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWavePopHoldSeconds,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWavePopScale,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWavePopBrightness,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveMaskDensity,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveMaskClusterScale,
        );
      }
      if (from < 39) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveTwinkleSparsity,
        );
      }
      if (from < 40) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveShadowLightDegrees,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveShadowOffset,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveShadowSoftness,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveShadowStrength,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWavePopBrightnessVariance,
        );
      }
      if (from < 41) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveTiltAmount,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveTiltShading,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveMassLagSeconds,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveMassSpring,
        );
      }
      if (from < 42) {
        // The radiance/light-bleed effect was removed. Schema 41 shipped its
        // two columns, so local DBs that already ran it still carry them.
        await _dropSettingsColumnIfExists(
          migrator,
          'geometric_wave_radiance_strength',
        );
        await _dropSettingsColumnIfExists(
          migrator,
          'geometric_wave_radiance_radius',
        );
      }
      if (from < 43) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveScatterMode,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.geometricWaveScatterLitAmount,
        );
      }
      if (from < 44) {
        // v44 briefly shipped a single combined `show_default_trackers_in_
        // analytics` toggle. It was split into separate grid/calendar toggles
        // in v45, handled below (which also drops the old column).
      }
      if (from < 45) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.showDefaultTrackersInGrid,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.showDefaultTrackersInCalendar,
        );
        // Carry over the old combined preference where it exists, otherwise
        // default both to on. Guarded so it's a no-op when the legacy column
        // was never created.
        final hadLegacy = await customSelect(
          "SELECT 1 FROM pragma_table_info('settings_table') "
          "WHERE name = 'show_default_trackers_in_analytics'",
        ).get();
        if (hadLegacy.isNotEmpty) {
          await customStatement(
            'UPDATE settings_table SET '
            'show_default_trackers_in_grid = '
            'COALESCE(show_default_trackers_in_analytics, 1), '
            'show_default_trackers_in_calendar = '
            'COALESCE(show_default_trackers_in_analytics, 1)',
          );
          await _dropSettingsColumnIfExists(
            migrator,
            'show_default_trackers_in_analytics',
          );
        }
        // Ensure non-null values even if the columns pre-existed from branch
        // churn (which skips the ADD COLUMN that applies the Dart default).
        await customStatement(
          'UPDATE settings_table SET show_default_trackers_in_grid = 1 '
          'WHERE show_default_trackers_in_grid IS NULL',
        );
        await customStatement(
          'UPDATE settings_table SET show_default_trackers_in_calendar = 1 '
          'WHERE show_default_trackers_in_calendar IS NULL',
        );
      }
      if (from < 46) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.todoCompletedSectionExpanded,
        );
      }
      if (from < 47) {
        await migrator.createTable(transactionsTable);
      }
      if (from < 48) {
        await migrator.createTable(subscriptionsTable);
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.showAnnualizedSubscriptionCost,
        );
      }
      if (from < 49) {
        await migrator.createTable(budgetsTable);
      }
      if (from < 50) {
        await migrator.createTable(financeCategoriesTable);
        await migrator.createTable(assetsTable);
        await migrator.createTable(assetValuationsTable);
      }
      if (from < 51) {
        await migrator.createTable(savingsGoalsTable);
        await migrator.createTable(goalAllocationsTable);
      }
    },
  );

  /// Skips ADD COLUMN when the local DB already has it (e.g. after branch churn).
  Future<void> _addSettingsColumnIfNotExists(
    Migrator migrator,
    GeneratedColumn<Object> column,
  ) async {
    final exists = await customSelect(
      "SELECT 1 FROM pragma_table_info('settings_table') WHERE name = ?",
      variables: [Variable.withString(column.name)],
    ).get();
    if (exists.isEmpty) {
      await migrator.addColumn(settingsTable, column);
    }
  }

  /// Skips DROP COLUMN when the local DB doesn't have it (e.g. after branch churn).
  Future<void> _dropSettingsColumnIfExists(
    Migrator migrator,
    String columnName,
  ) async {
    final exists = await customSelect(
      "SELECT 1 FROM pragma_table_info('settings_table') WHERE name = ?",
      variables: [Variable.withString(columnName)],
    ).get();
    if (exists.isNotEmpty) {
      await migrator.dropColumn(settingsTable, columnName);
    }
  }

  Future<void> _backfillNullBools() async {
    await customStatement(
      'UPDATE settings_table SET hide_completed_tasks = 0 WHERE hide_completed_tasks IS NULL',
    );
    await customStatement(
      'UPDATE todo_tasks_table SET completed = 0 WHERE completed IS NULL',
    );
    await customStatement(
      'UPDATE todo_tasks_table SET starred = 0 WHERE starred IS NULL',
    );
    // Columns added via _addSettingsColumnIfNotExists (or the weatherChartCurveTension
    // try/catch) can be left NULL forever if the column already existed on disk from
    // branch churn, since the guard then skips the ADD COLUMN that would apply the
    // Dart-side default. Backfill them unconditionally so a non-nullable read never
    // hits a null-check crash regardless of migration history.
    await customStatement(
      'UPDATE settings_table SET weather_chart_curve_tension = 0.22 WHERE weather_chart_curve_tension IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET dev_show_journal_remote_pull_button = 0 WHERE dev_show_journal_remote_pull_button IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET dev_slow_calendar_animations = 0 WHERE dev_slow_calendar_animations IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_texture_scale = 10.0 WHERE geometric_texture_scale IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_texture_intensity = 0.85 WHERE geometric_texture_intensity IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_texture_focal_spread = 1.0 WHERE geometric_texture_focal_spread IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_texture_focal_point_x = 1.0 WHERE geometric_texture_focal_point_x IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_texture_focal_point_y = 0.5 WHERE geometric_texture_focal_point_y IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_texture_variation_floor = 0.75 WHERE geometric_texture_variation_floor IS NULL',
    );
    await customStatement(
      "UPDATE settings_table SET startup_page_mode = 'first' WHERE startup_page_mode IS NULL",
    );
    await customStatement(
      'UPDATE settings_table SET geometric_wave_enabled = 0 WHERE geometric_wave_enabled IS NULL',
    );
    await customStatement(
      "UPDATE settings_table SET geometric_wave_shape = 'linear' WHERE geometric_wave_shape IS NULL",
    );
    await customStatement(
      'UPDATE settings_table SET geometric_wave_direction_degrees = 135.0 WHERE geometric_wave_direction_degrees IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_wave_speed = 0.4 WHERE geometric_wave_speed IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_wave_width = 0.08 WHERE geometric_wave_width IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_wave_period = 7.0 WHERE geometric_wave_period IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_wave_pop_hold_seconds = 0.6 WHERE geometric_wave_pop_hold_seconds IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_wave_pop_scale = 1.4 WHERE geometric_wave_pop_scale IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_wave_pop_brightness = 0.32 WHERE geometric_wave_pop_brightness IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_wave_mask_density = 0.5 WHERE geometric_wave_mask_density IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_wave_mask_cluster_scale = 5.0 WHERE geometric_wave_mask_cluster_scale IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET geometric_wave_twinkle_sparsity = 0.15 WHERE geometric_wave_twinkle_sparsity IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET show_annualized_subscription_cost = 0 WHERE show_annualized_subscription_cost IS NULL',
    );
  }

  static AppDatabase create() {
    return AppDatabase(_openConnection());
  }

  static AppDatabase inMemory() {
    return AppDatabase(NativeDatabase.memory());
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'voyager.sqlite'));
    return NativeDatabase(file);
  });
}
