import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/constants/hotkey_defaults.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart' show defaultPetalColor;
import 'package:voyager/domain/services/color_palette_codec.dart';

part 'app_database.g.dart';

class JournalsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get colorValue => integer().nullable()();
  BoolColumn get guidedJournaling =>
      boolean().withDefault(const Constant(false))();
  IntColumn get promptCycleDays => integer().withDefault(const Constant(7))();
  BoolColumn get showMood => boolean().withDefault(const Constant(true))();
  BoolColumn get showWeather => boolean().withDefault(const Constant(true))();
  BoolColumn get showQuotes => boolean().withDefault(const Constant(true))();
  BoolColumn get includeInAllView =>
      boolean().withDefault(const Constant(true))();
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

class DreamEntriesTable extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get entryDate => dateTime()();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class LeetCodeProblemsTable extends Table {
  TextColumn get id => text()();
  TextColumn get questionId => text().nullable()();
  TextColumn get questionFrontendId => text().nullable()();
  TextColumn get title => text()();
  TextColumn get titleSlug => text().nullable()();
  TextColumn get difficulty => text()();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  /// Problem statement for the flashcard front. Nullable so existing rows
  /// stay null until the user edits or re-fetches from LeetCode.
  TextColumn get description => text().nullable()();
  /// JSON array of worked examples, one string each. Existing rows default to
  /// an empty array — "no examples" — until the user adds some by hand.
  TextColumn get examplesJson => text().withDefault(const Constant('[]'))();

  /// JSON array of solutions, one object each — the write-up (approach,
  /// complexity, explanation, code, notes) for every way the user has solved
  /// this problem. The source of truth for all of them.
  TextColumn get solutionsJson => text().withDefault(const Constant('[]'))();

  /// The single solution a problem could hold before this table learned about
  /// alternatives. Migration 77 folded these into [solutionsJson], which is
  /// what every read goes through now; writes keep mirroring solution 1 here
  /// so the columns stay truthful rather than frozen at their last value.
  TextColumn get algorithm => text().withDefault(const Constant(''))();
  TextColumn get timeComplexity => text().nullable()();
  TextColumn get spaceComplexity => text().nullable()();
  TextColumn get explanation => text().withDefault(const Constant(''))();
  TextColumn get codeLanguage =>
      text().withDefault(const Constant('python'))();
  TextColumn get code => text().withDefault(const Constant(''))();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get solvedAt => dateTime()();

  /// SRS review state for the Review Deck, mirroring [StudyCardsTable]'s.
  /// `dueAt` is nullable rather than backfilled: a null reads as "due now",
  /// which is exactly right both for a freshly tracked problem and for every
  /// problem tracked before the deck learned to schedule.
  RealColumn get interval => real().withDefault(const Constant(0))();
  RealColumn get ease => real().withDefault(const Constant(2.5))();
  DateTimeColumn get dueAt => dateTime().nullable()();
  IntColumn get reviewCount => integer().withDefault(const Constant(0))();
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

  /// Whether this list's tasks join the combined "All tasks" list. Excluding a
  /// list hides it from that view only; its tasks stay in search and on the
  /// calendar.
  BoolColumn get includeInAllView =>
      boolean().withDefault(const Constant(true))();
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

  /// Repeat pattern. See [RecurrenceRule.toStorage].
  TextColumn get recurrence => text().withDefault(const Constant('none'))();

  /// The due date the pattern is measured from, frozen when the repeat was set.
  ///
  /// Not just [dueDate]: rolling a "monthly on the 31st" task forward lands it
  /// on Feb 28, and re-anchoring there would drag every later occurrence to the
  /// 28th. Holding the original anchor is what lets March return to the 31st.
  DateTimeColumn get recurrenceAnchor => dateTime().nullable()();
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

  /// Inclusive last local date an occurrence may start on. Set when a series is
  /// truncated by "this and all future events".
  DateTimeColumn get recurrenceEndDate => dateTime().nullable()();

  /// Comma-separated `yyyy-MM-dd` occurrence starts this series skips, written
  /// by "this event only" deletes and edits.
  TextColumn get exceptionDates => text().withDefault(const Constant(''))();

  /// Set on a row that is one occurrence detached from a series: the id of the
  /// series it came from, and the occurrence start it stands in for.
  TextColumn get recurrenceParentId => text().nullable()();
  DateTimeColumn get recurrenceDate => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
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
  IntColumn get version => integer().withDefault(const Constant(0))();
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
  IntColumn get version => integer().withDefault(const Constant(0))();
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

class PinnedNotesTable extends Table {
  TextColumn get id => text()();
  TextColumn get body => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class DismissedNotificationsTable extends Table {
  /// `'$itemId|$urgencyTierName'` — see [NotificationFeedItem.dismissalKey].
  TextColumn get id => text()();
  DateTimeColumn get dismissedAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn get version => integer().withDefault(const Constant(0))();

  /// Set when the row is un-dismissed. A dismissal has to be able to travel to
  /// another device as "no longer dismissed", and a pull only ever sees the
  /// documents that exist — a hard delete would simply never arrive.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The Life Tracker bubble's bucket list.
class BucketListItemsTable extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get note => text().nullable()();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  DateTimeColumn get completedAt => dateTime().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
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
  TextColumn get themeMode => text().withDefault(const Constant('dark'))();
  IntColumn get petalColor =>
      integer().withDefault(const Constant(defaultPetalColor))();
  TextColumn get minorPetalColorsJson => text().nullable()();
  IntColumn get petalMaxCount => integer().withDefault(const Constant(60))();
  RealColumn get petalFallSpeed => real().withDefault(const Constant(34.0))();
  RealColumn get petalWindFrequency =>
      real().withDefault(const Constant(0.12))();
  RealColumn get petalWindStrength =>
      real().withDefault(const Constant(46.0))();
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
  DateTimeColumn get birthDate => dateTime().nullable()();
  BoolColumn get alertOnPeriodicPrompts =>
      boolean().withDefault(const Constant(false))();
  IntColumn get alertTimeHour => integer().withDefault(const Constant(9))();
  BoolColumn get hideCompletedTasks =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get vimModeEnabled =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get snippetsEnabled =>
      boolean().withDefault(const Constant(true))();

  /// [SnippetExpandKey] name — 'tab' or 'space'.
  TextColumn get snippetExpandKey =>
      text().withDefault(const Constant('tab'))();

  /// The snippet list as a JSON array of [Snippet.toJson] maps. One column
  /// rather than a table of its own: the list is small, always read whole, and
  /// syncs as a single settings field.
  TextColumn get snippetsJson => text().nullable()();
  TextColumn get deviceId => text().nullable()();
  TextColumn get lastViewedJournalId => text().nullable()();
  TextColumn get lastViewedTodoListId => text().nullable()();

  /// The journal the journal page always opens into, overriding
  /// [lastViewedJournalId] and [journalShowAllEntries]. Null means "restore
  /// whatever was last open", which is the behaviour this column replaced.
  TextColumn get defaultJournalId => text().nullable()();

  /// The todo list the todo page always opens into, overriding
  /// [lastViewedTodoListId] and [todoShowAllTasks]. The [defaultJournalId]
  /// twin, kept as its own column for the same reason.
  TextColumn get defaultTodoListId => text().nullable()();
  // Kept separate from the lastViewed* ids above rather than folded into them
  // as a sentinel: the all-view and "which one was I actually in" are two
  // independent facts, and storing them in one column loses the second, which
  // is what decides where a new entry/task created from the all-view lands.
  BoolColumn get journalShowAllEntries =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get todoShowAllTasks =>
      boolean().withDefault(const Constant(false))();
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
  BoolColumn get devShowFpsCounter =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get devDisableCache =>
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

  /// Jobs table columns the user has switched off, as a JSON list of column
  /// ids. Stores the hidden set rather than the visible one so a column added
  /// to a later build shows up by default instead of silently staying off.
  TextColumn get jobsHiddenColumnsJson => text().nullable()();

  /// Whether the Jobs page starts with archived applications shown (§3.1).
  BoolColumn get jobsIncludeArchived =>
      boolean().withDefault(const Constant(false))();
  RealColumn get dreamSplitWidth => real().nullable()();
  BoolColumn get showDreamStatistics =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get dreamNotesPinned =>
      boolean().withDefault(const Constant(false))();
  TextColumn get leetcodeUsername => text().nullable()();
  BoolColumn get showNeetCode150 =>
      boolean().withDefault(const Constant(true))();

  /// What a LeetCode Study or Cram session leaves off the card — see
  /// [AppSettings.leetCodeHideDifficulty] and friends.
  BoolColumn get leetCodeHideDifficulty =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get leetCodeHideTags =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get leetCodeHideQuestionName =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get leetCodeHideDescription =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get leetCodeHideExamples =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get leetCodeHideComplexity =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get leetCodeHideCode =>
      boolean().withDefault(const Constant(false))();
  TextColumn get srsFailKey =>
      text().withDefault(const Constant(defaultStudyFailKey))();
  TextColumn get srsHardKey =>
      text().withDefault(const Constant(defaultStudyHardKey))();
  TextColumn get srsGoodKey =>
      text().withDefault(const Constant(defaultStudyGoodKey))();
  TextColumn get srsEasyKey =>
      text().withDefault(const Constant(defaultStudyEasyKey))();

  /// [WeightUnit] name — 'kg' or 'lb'. Display only; storage is kilograms.
  TextColumn get weightUnit => text().withDefault(const Constant('lb'))();
  BoolColumn get workoutRestTimerEnabled =>
      boolean().withDefault(const Constant(false))();
  IntColumn get workoutRestSeconds =>
      integer().withDefault(const Constant(90))();
  BoolColumn get showWorkoutsOnCalendar =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get showWorkoutStatistics =>
      boolean().withDefault(const Constant(false))();

  /// When a *synced* setting last changed on some device — the whole-document
  /// last-write-wins clock for [settingsSyncPayload]. Device-local writes
  /// (weather cache, dev flags, window state) deliberately leave it alone, so
  /// merely opening the app can't overwrite a preference another device
  /// changed more recently.
  ///
  /// Null until a synced setting is actually changed. That matters on a fresh
  /// install: stamping the default row with "now" would make untouched
  /// defaults the newest settings in the account and overwrite the real ones
  /// before the first pull ever ran.
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// Which one-time upload of the newly synced collections this device has
  /// run — see `RemoteSyncService.syncBackfillVersion`. Device-local, so it
  /// stays out of [settingsSyncPayload].
  IntColumn get syncBackfillVersion => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class TagColorsTable extends Table {
  TextColumn get tag => text()();
  IntColumn get colorValue => integer()();

  /// Carries no `deletedAt`: a tag's color can be re-picked but never removed,
  /// so there is no deletion for another device to hear about.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {tag};
}

class CustomWordsTable extends Table {
  TextColumn get word => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn get version => integer().withDefault(const Constant(0))();

  /// Set when the word is removed from the dictionary, so the removal reaches
  /// other devices instead of the word reappearing on their next pull.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {word};
}

/// Quotes the user wrote, added to the pool a new journal entry draws from.
///
/// Unlike [CustomWordsTable] this is a synced collection, so it carries the
/// id/timestamps/version/deletedAt shape every synced table has rather than
/// keying on its own content — the text is editable, and a device that renamed
/// a quote has to be able to say *which* quote it renamed.
class CustomQuotesTable extends Table {
  TextColumn get id => text()();
  TextColumn get quote => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
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

  /// [SyncConflictReason.storageValue]; null for rows written before the
  /// detector recorded which of its checks fired.
  TextColumn get reason => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('PendingUploadData')
class PendingUploadsTable extends Table {
  TextColumn get documentId => text()();
  TextColumn get collectionName => text()();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();

  /// Null while the upload is still queued for retry.
  ///
  /// Set once the failure is known to be unfixable by retrying — the row then
  /// stays as a durable record that this document never reached the server,
  /// and the drain skips it so one rejected document can't stall the queue
  /// behind it.
  TextColumn get failureReason => text().nullable()();

  @override
  Set<Column> get primaryKey => {documentId, collectionName};
}

class StudyFoldersTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get parentFolderId => text().nullable()();
  IntColumn get colorValue => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class StudyDecksTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get parentFolderId => text().nullable()();
  IntColumn get colorValue => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class StudyCardsTable extends Table {
  TextColumn get id => text()();
  TextColumn get deckId => text()();
  TextColumn get frontText => text()();
  TextColumn get backText => text()();
  RealColumn get interval => real().withDefault(const Constant(0))();
  RealColumn get ease => real().withDefault(const Constant(2.5))();
  DateTimeColumn get dueAt => dateTime()();
  IntColumn get reviewCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The exercise library. Every set ever logged points back at one of these
/// rows, which is what makes a movement's whole history queryable from the
/// detail view regardless of which plan or day it was performed under.
class ExercisesTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get formCues => text().withDefault(const Constant(''))();
  IntColumn get colorValue => integer().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// The movement's target, shared by every day it is planned on. Held here
  /// rather than on the placement so editing it once changes it everywhere.
  IntColumn get targetSets => integer().withDefault(const Constant(3))();
  IntColumn get targetReps => integer().withDefault(const Constant(8))();
  RealColumn get targetWeightKg => real().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class WorkoutPlansTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// [WorkoutPlanMode] name — 'weekly' or 'cycle'.
  TextColumn get mode => text().withDefault(const Constant('weekly'))();
  IntColumn get cycleLength => integer().withDefault(const Constant(4))();
  DateTimeColumn get cycleAnchor => dateTime()();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Lifts the pre-v68 per-placement targets up onto the movement they belong
/// to, so an existing split doesn't reset to 3 × 8 the moment targets go
/// global.
///
/// Most recently edited placement wins: several days planning the same lift at
/// different weights cannot all survive the collapse to one global number, and
/// the newest is the likeliest intent. Named rather than inlined so
/// `workout_test.dart` can run the real statement against a legacy-shaped
/// table — a typo'd column here throws on app start, after the point where the
/// user could do anything about it.
const String kWorkoutTargetBackfillSql = '''
UPDATE exercises_table SET
  target_sets = COALESCE((
    SELECT e.sets FROM workout_plan_entries_table e
    WHERE e.exercise_id = exercises_table.id AND e.deleted_at IS NULL
    ORDER BY e.updated_at DESC LIMIT 1
  ), target_sets),
  target_reps = COALESCE((
    SELECT e.reps FROM workout_plan_entries_table e
    WHERE e.exercise_id = exercises_table.id AND e.deleted_at IS NULL
    ORDER BY e.updated_at DESC LIMIT 1
  ), target_reps),
  target_weight_kg = COALESCE((
    SELECT e.weight_kg FROM workout_plan_entries_table e
    WHERE e.exercise_id = exercises_table.id AND e.deleted_at IS NULL
    ORDER BY e.updated_at DESC LIMIT 1
  ), target_weight_kg)
''';

/// A placement only — which movement sits on which day, in what order. The
/// sets/reps/weight it used to carry moved to [ExercisesTable] so they are
/// global to the movement; see the v68 migration.
class WorkoutPlanEntriesTable extends Table {
  TextColumn get id => text()();
  TextColumn get planId => text()();
  IntColumn get dayIndex => integer()();
  TextColumn get exerciseId => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class WorkoutSessionsTable extends Table {
  TextColumn get id => text()();
  TextColumn get planId => text().nullable()();
  IntColumn get dayIndex => integer().nullable()();
  DateTimeColumn get date => dateTime()();
  DateTimeColumn get startedAt => dateTime()();

  /// Null while the workout is live. The active session lives in the database
  /// rather than in memory so the floating island survives an app restart.
  DateTimeColumn get endedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class WorkoutSetLogsTable extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get exerciseId => text()();
  IntColumn get exerciseOrder => integer().withDefault(const Constant(0))();
  IntColumn get setIndex => integer().withDefault(const Constant(0))();
  RealColumn get weightKg => real().withDefault(const Constant(0))();
  IntColumn get reps => integer().withDefault(const Constant(0))();
  RealColumn get plannedWeightKg => real().withDefault(const Constant(0))();
  IntColumn get plannedReps => integer().withDefault(const Constant(0))();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class StudyReviewLogTable extends Table {
  TextColumn get id => text()();
  TextColumn get cardId => text()();
  TextColumn get grade => text()();
  DateTimeColumn get reviewedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Job applications. `company` and `status` are free strings rather than
/// foreign keys: deleting a stage or a company suggestion must leave the
/// applications that referenced it readable, not dangling.
class JobApplicationsTable extends Table {
  TextColumn get id => text()();
  TextColumn get company => text()();
  TextColumn get title => text()();
  TextColumn get status => text()();
  DateTimeColumn get dateApplied => dateTime()();
  TextColumn get applicationUrl => text().nullable()();
  TextColumn get notes => text().nullable()();

  /// Null while active; the season this application was archived into once set.
  TextColumn get seasonId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Append-only status timeline. Stores the display strings as they read when
/// the move happened, so renaming a stage never rewrites history.
class JobStatusEventsTable extends Table {
  TextColumn get id => text()();
  TextColumn get applicationId => text()();
  TextColumn get fromStatus => text().nullable()();
  TextColumn get toStatus => text()();
  DateTimeColumn get changedAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Pipeline stages. [sortOrder] is display order only — transitions are
/// unconstrained in both directions.
class JobStagesTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The company typeahead list. [categoryId] carries the at-most-one-category
/// assignment directly rather than through a join table.
class JobCompaniesTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get categoryId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class JobCategoriesTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get colorValue => integer()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class JobSeasonsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    JournalsTable,
    JournalEntriesTable,
    DreamEntriesTable,
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
    PinnedNotesTable,
    DismissedNotificationsTable,
    CustomWordsTable,
    CustomQuotesTable,
    BucketListItemsTable,
    LeetCodeProblemsTable,
    StudyFoldersTable,
    StudyDecksTable,
    StudyCardsTable,
    StudyReviewLogTable,
    ExercisesTable,
    WorkoutPlansTable,
    WorkoutPlanEntriesTable,
    WorkoutSessionsTable,
    WorkoutSetLogsTable,
    JobApplicationsTable,
    JobStatusEventsTable,
    JobStagesTable,
    JobCompaniesTable,
    JobCategoriesTable,
    JobSeasonsTable,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 84;

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
      if (from < 52) {
        await _addSettingsColumnIfNotExists(migrator, settingsTable.themeMode);
        await _addSettingsColumnIfNotExists(migrator, settingsTable.petalColor);
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.petalMaxCount,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.petalFallSpeed,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.petalWindFrequency,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.petalWindStrength,
        );
      }
      if (from < 53) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.devShowFpsCounter,
        );
      }
      if (from < 54) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.minorPetalColorsJson,
        );
      }
      if (from < 55) {
        await migrator.createTable(dreamEntriesTable);
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.dreamSplitWidth,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.showDreamStatistics,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.dreamNotesPinned,
        );
      }
      if (from < 56) {
        await migrator.createTable(pinnedNotesTable);
        await migrator.createTable(dismissedNotificationsTable);
      }
      if (from < 57) {
        // Drift has always serialised DateTime as unix seconds (integer) by
        // default.  Switch to ISO-8601 text storage so that sub-second
        // precision is preserved end-to-end.  This migration rewrites every
        // existing integer timestamp in place; new writes go through the text
        // path once build_runner regenerates app_database.g.dart with the
        // store_date_time_values_as_text: true option from build.yaml.
        //
        // The WHERE typeof(col) = 'integer' guard makes the update idempotent:
        // if the column already holds a text value (e.g. the migration was
        // partially applied on a dev build), the row is skipped rather than
        // double-converted.
        await _migrateUnixSecondsToIsoText();
      }
      if (from < 58) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.devDisableCache,
        );
      }
      if (from < 59) {
        await migrator.createTable(customWordsTable);
      }
      if (from < 60) {
        await _addSettingsColumnIfNotExists(migrator, settingsTable.birthDate);
        await migrator.createTable(bucketListItemsTable);
      }
      if (from < 61) {
        await migrator.createTable(leetCodeProblemsTable);
      }
      if (from < 62) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.leetcodeUsername,
        );
      }
      if (from < 63) {
        await migrator.createTable(studyFoldersTable);
        await migrator.createTable(studyDecksTable);
        await migrator.createTable(studyCardsTable);
        await migrator.createTable(studyReviewLogTable);
        await _addSettingsColumnIfNotExists(migrator, settingsTable.srsFailKey);
        await _addSettingsColumnIfNotExists(migrator, settingsTable.srsHardKey);
        await _addSettingsColumnIfNotExists(migrator, settingsTable.srsGoodKey);
        await _addSettingsColumnIfNotExists(migrator, settingsTable.srsEasyKey);
      }
      if (from < 64) {
        // Guard against duplicate-column error: anyone upgrading from below
        // 63 already gets colorValue from the from-<63 createTable step
        // above, since that step builds the table from its current (not
        // historical) column set.
        await _addColumnIfNotExists(
          migrator,
          'study_folders_table',
          studyFoldersTable,
          studyFoldersTable.colorValue,
        );
        await _addColumnIfNotExists(
          migrator,
          'study_decks_table',
          studyDecksTable,
          studyDecksTable.colorValue,
        );
      }
      if (from < 65) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.journalShowAllEntries,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.todoShowAllTasks,
        );
        // The journal page used to record the all-journals view by writing the
        // sentinel 'ALL_JOURNALS' into last_viewed_journal_id, which overwrote
        // the id of the journal actually last open. Split the two facts apart;
        // the concrete id is unrecoverable for these rows, so it goes null and
        // the page falls back to the default journal exactly once.
        await customStatement(
          "UPDATE settings_table SET journal_show_all_entries = 1, "
          "last_viewed_journal_id = NULL "
          "WHERE last_viewed_journal_id = 'ALL_JOURNALS'",
        );
      }
      // No step 66: it added a `global_sort_order` column to todo_tasks_table
      // to remember drags in the "All tasks" view. That view derives its order
      // instead (see `resolveGlobalTaskOrder`) and is not reorderable, so the
      // column is gone. Databases that already took step 66 keep the unused
      // column — Drift names columns explicitly, so a stray nullable one is
      // inert, and dropping it would cost a table rebuild for nothing.
      if (from < 67) {
        await migrator.createTable(exercisesTable);
        await migrator.createTable(workoutPlansTable);
        await migrator.createTable(workoutPlanEntriesTable);
        await migrator.createTable(workoutSessionsTable);
        await migrator.createTable(workoutSetLogsTable);
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.weightUnit,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.workoutRestTimerEnabled,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.workoutRestSeconds,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.showWorkoutsOnCalendar,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.showWorkoutStatistics,
        );
      }
      if (from < 68) {
        // Targets moved off the placement and onto the movement, so editing
        // a lift's weight changes it on every day of every plan at once.
        await _addColumnIfNotExists(
          migrator,
          'exercises_table',
          exercisesTable,
          exercisesTable.targetSets,
        );
        await _addColumnIfNotExists(
          migrator,
          'exercises_table',
          exercisesTable,
          exercisesTable.targetReps,
        );
        await _addColumnIfNotExists(
          migrator,
          'exercises_table',
          exercisesTable,
          exercisesTable.targetWeightKg,
        );
        // Only a database that actually reached v67 has the old per-entry
        // columns to carry over; one upgrading from further back had its
        // plan-entry table created above from the current (column-less)
        // schema, and reading them would be a SQL error.
        if (from >= 67) {
          await customStatement(kWorkoutTargetBackfillSql);
          // Rebuilds the table from its current schema, dropping the three
          // columns that no longer exist in Dart.
          await migrator.alterTable(
            TableMigration(workoutPlanEntriesTable),
          );
        }
      }
      if (from < 69) {
        await _addColumnIfNotExists(
          migrator,
          'settings_table',
          settingsTable,
          settingsTable.vimModeEnabled,
        );
      }
      if (from < 70) {
        await migrator.createTable(customQuotesTable);
      }
      if (from < 71) {
        await _addColumnIfNotExists(
          migrator,
          'pending_uploads_table',
          pendingUploadsTable,
          pendingUploadsTable.failureReason,
        );
      }
      if (from < 72) {
        for (final column in [
          leetCodeProblemsTable.interval,
          leetCodeProblemsTable.ease,
          leetCodeProblemsTable.dueAt,
          leetCodeProblemsTable.reviewCount,
        ]) {
          await _addColumnIfNotExists(
            migrator,
            'leet_code_problems_table',
            leetCodeProblemsTable,
            column,
          );
        }
      }
      if (from < 73) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.showNeetCode150,
        );
      }
      if (from < 74) {
        await _addColumnIfNotExists(
          migrator,
          'leet_code_problems_table',
          leetCodeProblemsTable,
          leetCodeProblemsTable.description,
        );
      }
      if (from < 75) {
        await _addColumnIfNotExists(
          migrator,
          'leet_code_problems_table',
          leetCodeProblemsTable,
          leetCodeProblemsTable.examplesJson,
        );
      }
      // Everything the sync layer needs from the collections that used to be
      // local-only: a version/updatedAt pair to order two devices' edits, and
      // a deletedAt so a removal can travel instead of the row reappearing on
      // the next pull.
      if (from < 76) {
        await _addColumnIfNotExists(
          migrator,
          'calendar_events_table',
          calendarEventsTable,
          calendarEventsTable.version,
        );
        await _addColumnIfNotExists(
          migrator,
          'trackers_table',
          trackersTable,
          trackersTable.version,
        );
        await _addColumnIfNotExists(
          migrator,
          'tracker_values_table',
          trackerValuesTable,
          trackerValuesTable.version,
        );
        // The non-null `updatedAt` columns can't go through addColumn: their
        // schema default is CURRENT_TIMESTAMP, and SQLite rejects ADD COLUMN
        // with a non-constant default outright. They're added with a constant
        // instead and then seeded from the timestamp each table already has,
        // so a migrated row's "last changed" is its real age rather than the
        // moment of the upgrade.
        await _addTimestampColumnIfNotExists(
          'pinned_notes_table',
          'updated_at',
          seedFrom: 'created_at',
        );
        for (final column in [
          pinnedNotesTable.version,
          pinnedNotesTable.deletedAt,
        ]) {
          await _addColumnIfNotExists(
            migrator,
            'pinned_notes_table',
            pinnedNotesTable,
            column,
          );
        }
        await _addTimestampColumnIfNotExists(
          'dismissed_notifications_table',
          'updated_at',
          seedFrom: 'dismissed_at',
        );
        for (final column in [
          dismissedNotificationsTable.version,
          dismissedNotificationsTable.deletedAt,
        ]) {
          await _addColumnIfNotExists(
            migrator,
            'dismissed_notifications_table',
            dismissedNotificationsTable,
            column,
          );
        }
        for (final column in [
          bucketListItemsTable.version,
          bucketListItemsTable.deletedAt,
        ]) {
          await _addColumnIfNotExists(
            migrator,
            'bucket_list_items_table',
            bucketListItemsTable,
            column,
          );
        }
        // Tag colors and custom words have no timestamp of their own to seed
        // from, so migrated rows start at the epoch: the oldest possible
        // edit, which any real change on any device then wins against.
        await _addTimestampColumnIfNotExists('tag_colors_table', 'updated_at');
        await _addColumnIfNotExists(
          migrator,
          'tag_colors_table',
          tagColorsTable,
          tagColorsTable.version,
        );
        await _addTimestampColumnIfNotExists(
          'custom_words_table',
          'created_at',
        );
        await _addTimestampColumnIfNotExists(
          'custom_words_table',
          'updated_at',
        );
        for (final column in [
          customWordsTable.version,
          customWordsTable.deletedAt,
        ]) {
          await _addColumnIfNotExists(
            migrator,
            'custom_words_table',
            customWordsTable,
            column,
          );
        }
        await _addSettingsColumnIfNotExists(migrator, settingsTable.updatedAt);
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.syncBackfillVersion,
        );
      }
      if (from < 77) {
        await _addColumnIfNotExists(
          migrator,
          'leet_code_problems_table',
          leetCodeProblemsTable,
          leetCodeProblemsTable.solutionsJson,
        );
        await _foldLeetCodeSolutionColumns();
      }
      if (from < 78) {
        await _addColumnIfNotExists(
          migrator,
          'sync_conflicts_table',
          syncConflictsTable,
          syncConflictsTable.reason,
        );
      }
      if (from < 79) {
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.snippetsEnabled,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.snippetExpandKey,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.snippetsJson,
        );
      }
      if (from < 80) {
        for (final column in [
          settingsTable.leetCodeHideDifficulty,
          settingsTable.leetCodeHideTags,
          settingsTable.leetCodeHideQuestionName,
          settingsTable.leetCodeHideDescription,
          settingsTable.leetCodeHideExamples,
          settingsTable.leetCodeHideComplexity,
          settingsTable.leetCodeHideCode,
        ]) {
          await _addSettingsColumnIfNotExists(migrator, column);
        }
      }
      if (from < 81) {
        for (final column in [
          journalsTable.showMood,
          journalsTable.showWeather,
          journalsTable.showQuotes,
          journalsTable.includeInAllView,
        ]) {
          await _addColumnIfNotExists(
            migrator,
            'journals_table',
            journalsTable,
            column,
          );
        }
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.defaultJournalId,
        );
      }
      if (from < 82) {
        await _addColumnIfNotExists(
          migrator,
          'todo_lists_table',
          todoListsTable,
          todoListsTable.includeInAllView,
        );
        await _addSettingsColumnIfNotExists(
          migrator,
          settingsTable.defaultTodoListId,
        );
      }
      if (from < 83) {
        for (final column in [
          calendarEventsTable.recurrenceEndDate,
          calendarEventsTable.exceptionDates,
          calendarEventsTable.recurrenceParentId,
          calendarEventsTable.recurrenceDate,
        ]) {
          await _addColumnIfNotExists(
            migrator,
            'calendar_events_table',
            calendarEventsTable,
            column,
          );
        }
        for (final column in [
          todoTasksTable.recurrence,
          todoTasksTable.recurrenceAnchor,
        ]) {
          await _addColumnIfNotExists(
            migrator,
            'todo_tasks_table',
            todoTasksTable,
            column,
          );
        }
      }
      if (from < 84) {
        await migrator.createTable(jobApplicationsTable);
        await migrator.createTable(jobStatusEventsTable);
        await migrator.createTable(jobStagesTable);
        await migrator.createTable(jobCompaniesTable);
        await migrator.createTable(jobCategoriesTable);
        await migrator.createTable(jobSeasonsTable);
        for (final column in [
          settingsTable.jobsHiddenColumnsJson,
          settingsTable.jobsIncludeArchived,
        ]) {
          await _addSettingsColumnIfNotExists(migrator, column);
        }
      }
    },
  );

  /// Rewrites every problem's one-and-only solution — the flat columns it was
  /// stored in before problems could hold alternatives — into the
  /// `solutions_json` list that reads go through now.
  ///
  /// Done in Dart rather than in SQL: the shape has to match exactly what
  /// [LeetCodeSolution.fromJson] expects, and building it from the same
  /// helper the importer and the sync merge use is what guarantees that.
  /// A problem with every field blank gets an empty list — it had no solution
  /// to carry over.
  Future<void> _foldLeetCodeSolutionColumns() async {
    final rows = await customSelect(
      'SELECT id, algorithm, time_complexity, space_complexity, explanation, '
      'code_language, code, notes FROM leet_code_problems_table',
    ).get();
    for (final row in rows) {
      final solutions = leetCodeSolutionsFromLegacyFields(
        algorithm: row.read<String?>('algorithm'),
        timeComplexity: row.read<String?>('time_complexity'),
        spaceComplexity: row.read<String?>('space_complexity'),
        explanation: row.read<String?>('explanation'),
        codeLanguage: row.read<String?>('code_language'),
        code: row.read<String?>('code'),
        notes: row.read<String?>('notes'),
      );
      await customUpdate(
        'UPDATE leet_code_problems_table SET solutions_json = ? WHERE id = ?',
        variables: [
          Variable.withString(
            jsonEncode([for (final s in solutions) s.toJson()]),
          ),
          Variable.withString(row.read<String>('id')),
        ],
        updates: {leetCodeProblemsTable},
      );
    }
  }

  /// Skips ADD COLUMN when the local DB already has it (e.g. after branch churn,
  /// or because an earlier createTable step in the same upgrade run already
  /// built the table with this column from its current schema).
  Future<void> _addColumnIfNotExists(
    Migrator migrator,
    String tableName,
    TableInfo table,
    GeneratedColumn<Object> column,
  ) async {
    final exists = await customSelect(
      "SELECT 1 FROM pragma_table_info('$tableName') WHERE name = ?",
      variables: [Variable.withString(column.name)],
    ).get();
    if (exists.isEmpty) {
      await migrator.addColumn(table, column);
    }
  }

  /// Adds a non-nullable `DateTime` column to an existing table.
  ///
  /// [Migrator.addColumn] can't: these columns declare `CURRENT_TIMESTAMP` as
  /// their schema default so that freshly created rows get a real timestamp,
  /// and SQLite rejects `ALTER TABLE … ADD COLUMN` with a non-constant
  /// default. The column is added with the epoch as a constant default and
  /// then seeded from [seedFrom] — another timestamp column on the same
  /// table — where the table has one to seed from.
  ///
  /// The literal matches how drift stores date times in this database
  /// (`storeDateTimeAsText`): an ISO-8601 string in UTC.
  Future<void> _addTimestampColumnIfNotExists(
    String tableName,
    String columnName, {
    String? seedFrom,
  }) async {
    final exists = await customSelect(
      "SELECT 1 FROM pragma_table_info('$tableName') WHERE name = ?",
      variables: [Variable.withString(columnName)],
    ).get();
    if (exists.isNotEmpty) return;

    await customStatement(
      "ALTER TABLE $tableName ADD COLUMN $columnName TEXT NOT NULL "
      "DEFAULT '1970-01-01T00:00:00.000Z'",
    );
    if (seedFrom != null) {
      await customStatement(
        'UPDATE $tableName SET $columnName = $seedFrom '
        'WHERE $seedFrom IS NOT NULL',
      );
    }
  }

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
      'UPDATE settings_table SET journal_show_all_entries = 0 WHERE journal_show_all_entries IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET todo_show_all_tasks = 0 WHERE todo_show_all_tasks IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET dev_show_fps_counter = 0 WHERE dev_show_fps_counter IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET snippets_enabled = 1 WHERE snippets_enabled IS NULL',
    );
    await customStatement(
      "UPDATE settings_table SET snippet_expand_key = 'tab' WHERE snippet_expand_key IS NULL",
    );
    for (final column in [
      'leet_code_hide_difficulty',
      'leet_code_hide_tags',
      'leet_code_hide_question_name',
      'leet_code_hide_description',
      'leet_code_hide_examples',
      'leet_code_hide_complexity',
      'leet_code_hide_code',
    ]) {
      await customStatement(
        'UPDATE settings_table SET $column = 0 WHERE $column IS NULL',
      );
    }
    for (final column in [
      'show_mood',
      'show_weather',
      'show_quotes',
      'include_in_all_view',
    ]) {
      await customStatement(
        'UPDATE journals_table SET $column = 1 WHERE $column IS NULL',
      );
    }
    await customStatement(
      'UPDATE todo_lists_table SET include_in_all_view = 1 '
      'WHERE include_in_all_view IS NULL',
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
    await customStatement(
      "UPDATE settings_table SET weight_unit = 'lb' WHERE weight_unit IS NULL",
    );
    await customStatement(
      'UPDATE settings_table SET workout_rest_timer_enabled = 0 WHERE workout_rest_timer_enabled IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET workout_rest_seconds = 90 WHERE workout_rest_seconds IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET show_workouts_on_calendar = 0 WHERE show_workouts_on_calendar IS NULL',
    );
    await customStatement(
      'UPDATE settings_table SET show_workout_statistics = 0 WHERE show_workout_statistics IS NULL',
    );
  }

  /// Converts every unix-second INTEGER timestamp in all tables to ISO-8601
  /// text. Called once during the schema-v57 migration.  The format string
  /// produces e.g. "2026-07-28T02:36:57Z" which [DateTime.parse] accepts.
  Future<void> _migrateUnixSecondsToIsoText() async {
    // Helper: all non-nullable datetime columns across all tables.
    const nonNullable = <(String, String)>[
      ('journals_table', 'created_at'),
      ('journals_table', 'updated_at'),
      ('journal_entries_table', 'entry_date'),
      ('journal_entries_table', 'created_at'),
      ('journal_entries_table', 'updated_at'),
      ('dream_entries_table', 'entry_date'),
      ('dream_entries_table', 'created_at'),
      ('dream_entries_table', 'updated_at'),
      ('todo_lists_table', 'created_at'),
      ('todo_lists_table', 'updated_at'),
      ('todo_tasks_table', 'created_at'),
      ('todo_tasks_table', 'updated_at'),
      ('calendars_table', 'created_at'),
      ('calendars_table', 'updated_at'),
      ('calendar_events_table', 'start'),
      ('calendar_events_table', 'end'),
      ('calendar_events_table', 'created_at'),
      ('calendar_events_table', 'updated_at'),
      ('trackers_table', 'created_at'),
      ('trackers_table', 'updated_at'),
      ('tracker_values_table', 'period_start'),
      ('tracker_values_table', 'created_at'),
      ('tracker_values_table', 'updated_at'),
      ('transactions_table', 'occurred_at'),
      ('transactions_table', 'created_at'),
      ('transactions_table', 'updated_at'),
      ('subscriptions_table', 'anchor_due_date'),
      ('subscriptions_table', 'created_at'),
      ('subscriptions_table', 'updated_at'),
      ('budgets_table', 'created_at'),
      ('budgets_table', 'updated_at'),
      ('finance_categories_table', 'created_at'),
      ('finance_categories_table', 'updated_at'),
      ('assets_table', 'created_at'),
      ('assets_table', 'updated_at'),
      ('asset_valuations_table', 'as_of'),
      ('asset_valuations_table', 'created_at'),
      ('asset_valuations_table', 'updated_at'),
      ('savings_goals_table', 'created_at'),
      ('savings_goals_table', 'updated_at'),
      ('goal_allocations_table', 'allocated_at'),
      ('goal_allocations_table', 'created_at'),
      ('goal_allocations_table', 'updated_at'),
      ('pinned_notes_table', 'created_at'),
      ('dismissed_notifications_table', 'dismissed_at'),
      ('sync_conflicts_table', 'detected_at'),
      ('pending_uploads_table', 'added_at'),
    ];

    // Nullable datetime columns — same conversion, NULL rows are
    // implicitly skipped by the WHERE typeof(...) = 'integer' guard.
    const nullable = <(String, String)>[
      ('journals_table', 'deleted_at'),
      ('journal_entries_table', 'timestamp'),
      ('journal_entries_table', 'deleted_at'),
      ('dream_entries_table', 'deleted_at'),
      ('todo_lists_table', 'deleted_at'),
      ('todo_tasks_table', 'due_date'),
      ('todo_tasks_table', 'due_date_set_at'),
      ('todo_tasks_table', 'deleted_at'),
      ('calendars_table', 'deleted_at'),
      ('calendar_events_table', 'deleted_at'),
      ('trackers_table', 'deleted_at'),
      ('tracker_values_table', 'deleted_at'),
      ('transactions_table', 'deleted_at'),
      ('subscriptions_table', 'deleted_at'),
      ('budgets_table', 'deleted_at'),
      ('finance_categories_table', 'deleted_at'),
      ('assets_table', 'deleted_at'),
      ('asset_valuations_table', 'deleted_at'),
      ('savings_goals_table', 'target_date'),
      ('savings_goals_table', 'deleted_at'),
      ('goal_allocations_table', 'deleted_at'),
      ('settings_table', 'weather_fetched_at'),
      ('settings_table', 'weather_location_updated_at'),
    ];

    for (final (table, col) in [...nonNullable, ...nullable]) {
      await customStatement(
        "UPDATE $table "
        "SET $col = strftime('%Y-%m-%dT%H:%M:%SZ', CAST($col AS INTEGER), 'unixepoch') "
        "WHERE typeof($col) = 'integer'",
      );
    }
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
    // Resolve the path on this isolate — path_provider needs the platform
    // channel, which only exists here.
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'voyager.sqlite'));
    // Run sqlite on its own isolate. NativeDatabase's FFI calls are
    // synchronous under their Futures, so on the UI isolate every read and
    // write blocks whatever frame it lands in — a task completion, for
    // instance, fires several writes plus a re-read of every list right while
    // the row is animating. In the background the UI isolate only pays for the
    // message hop.
    return NativeDatabase.createInBackground(file);
  });
}
