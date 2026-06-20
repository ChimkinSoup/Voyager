import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:voyager/core/sync/soft_delete_policy.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class DriftJournalRepository implements JournalRepository {
  DriftJournalRepository(this._db);

  final AppDatabase _db;
  final _policy = const SoftDeletePolicy();

  @override
  Future<List<Journal>> listJournals({bool includeDeleted = false}) async {
    final rows = await _db.select(_db.journalsTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapJournal)
        .toList();
  }

  @override
  Future<Journal?> getJournal(String id) async {
    final row = await (_db.select(_db.journalsTable)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapJournal(row);
  }

  @override
  Future<void> upsertJournal(Journal journal) async {
    await _db.into(_db.journalsTable).insertOnConflictUpdate(JournalsTableCompanion(
          id: Value(journal.id),
          name: Value(journal.name),
          guidedJournaling: Value(journal.guidedJournaling),
          promptCycleDays: Value(journal.promptCycleDays),
          createdAt: Value(journal.createdAt),
          updatedAt: Value(journal.updatedAt),
          deletedAt: Value(journal.deletedAt),
        ));
  }

  @override
  Future<void> softDeleteJournal(String id) async {
    await (_db.update(_db.journalsTable)..where((t) => t.id.equals(id))).write(
      JournalsTableCompanion(deletedAt: Value(utcNow()), updatedAt: Value(utcNow())),
    );
  }

  @override
  Future<void> deleteAllJournals() async {
    await _db.delete(_db.journalsTable).go();
  }

  @override
  Future<List<JournalEntry>> listEntries({
    String? journalId,
    DateTime? from,
    DateTime? to,
    int? limit,
    bool includeDeleted = false,
  }) async {
    var query = _db.select(_db.journalEntriesTable);
    if (journalId != null) {
      query = query..where((t) => t.journalId.equals(journalId));
    }
    if (from != null) {
      query = query..where((t) => t.entryDate.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      query = query..where((t) => t.entryDate.isSmallerOrEqualValue(to));
    }
    query = query..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
    if (limit != null) {
      query = query..limit(limit);
    }
    final rows = await query.get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapEntry)
        .toList();
  }

  @override
  Future<JournalEntry?> getEntry(String id) async {
    final row = await (_db.select(_db.journalEntriesTable)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapEntry(row);
  }

  @override
  Future<void> upsertEntry(JournalEntry entry) async {
    await _db.into(_db.journalEntriesTable).insertOnConflictUpdate(JournalEntriesTableCompanion(
          id: Value(entry.id),
          journalId: Value(entry.journalId),
          title: Value(entry.title),
          body: Value(entry.body),
          richBodyJson: Value(entry.richBodyJson),
          entryDate: Value(entry.entryDate),
          timestamp: Value(entry.timestamp),
          tagsJson: Value(jsonEncode(entry.tags)),
          mood: Value(entry.mood),
          quoteId: Value(entry.quoteId),
          customQuote: Value(entry.customQuote),
          weatherIcon: Value(entry.weatherIcon),
          guidedPrompt: Value(entry.guidedPrompt),
          createdAt: Value(entry.createdAt),
          updatedAt: Value(entry.updatedAt),
          deletedAt: Value(entry.deletedAt),
        ));
  }

  @override
  Future<void> softDeleteEntry(String id) async {
    await (_db.update(_db.journalEntriesTable)..where((t) => t.id.equals(id))).write(
      JournalEntriesTableCompanion(deletedAt: Value(utcNow()), updatedAt: Value(utcNow())),
    );
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final entries = await _db.select(_db.journalEntriesTable).get();
    for (final row in entries) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(_db.journalEntriesTable)..where((t) => t.id.equals(row.id))).go();
      }
    }
    final journals = await _db.select(_db.journalsTable).get();
    for (final row in journals) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(_db.journalsTable)..where((t) => t.id.equals(row.id))).go();
      }
    }
  }

  Journal _mapJournal(JournalsTableData row) => Journal(
        id: row.id,
        name: row.name,
        guidedJournaling: row.guidedJournaling,
        promptCycleDays: row.promptCycleDays,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
      );

  JournalEntry _mapEntry(JournalEntriesTableData row) => JournalEntry(
        id: row.id,
        journalId: row.journalId,
        title: row.title,
        body: row.body,
        richBodyJson: row.richBodyJson,
        entryDate: row.entryDate,
        timestamp: row.timestamp,
        tags: List<String>.from(jsonDecode(row.tagsJson) as List),
        mood: row.mood,
        quoteId: row.quoteId,
        customQuote: row.customQuote,
        weatherIcon: row.weatherIcon,
        guidedPrompt: row.guidedPrompt,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
      );
}

class DriftTodoRepository implements TodoRepository {
  DriftTodoRepository(this._db);

  final AppDatabase _db;
  final _policy = const SoftDeletePolicy();

  @override
  Future<List<TodoListModel>> listLists({bool includeDeleted = false}) async {
    final rows = await _db.select(_db.todoListsTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map((r) => TodoListModel(
              id: r.id,
              name: r.name,
              createdAt: r.createdAt,
              updatedAt: r.updatedAt,
              deletedAt: r.deletedAt,
            ))
        .toList();
  }

  @override
  Future<void> upsertList(TodoListModel list) async {
    await _db.into(_db.todoListsTable).insertOnConflictUpdate(TodoListsTableCompanion(
          id: Value(list.id),
          name: Value(list.name),
          createdAt: Value(list.createdAt),
          updatedAt: Value(list.updatedAt),
          deletedAt: Value(list.deletedAt),
        ));
  }

  @override
  Future<void> softDeleteList(String id) async {
    await (_db.update(_db.todoListsTable)..where((t) => t.id.equals(id))).write(
      TodoListsTableCompanion(deletedAt: Value(utcNow()), updatedAt: Value(utcNow())),
    );
  }

  @override
  Future<List<TodoTask>> listTasks(String listId, {bool includeDeleted = false}) async {
    final rows = await (_db.select(_db.todoTasksTable)..where((t) => t.listId.equals(listId))).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map((r) => TodoTask(
              id: r.id,
              listId: r.listId,
              title: r.title,
              notes: r.notes,
              dueDate: r.dueDate,
              completed: r.completed,
              createdAt: r.createdAt,
              updatedAt: r.updatedAt,
              deletedAt: r.deletedAt,
            ))
        .toList();
  }

  @override
  Future<void> upsertTask(TodoTask task) async {
    await _db.into(_db.todoTasksTable).insertOnConflictUpdate(TodoTasksTableCompanion(
          id: Value(task.id),
          listId: Value(task.listId),
          title: Value(task.title),
          notes: Value(task.notes),
          dueDate: Value(task.dueDate),
          completed: Value(task.completed),
          createdAt: Value(task.createdAt),
          updatedAt: Value(task.updatedAt),
          deletedAt: Value(task.deletedAt),
        ));
  }

  @override
  Future<void> softDeleteTask(String id) async {
    await (_db.update(_db.todoTasksTable)..where((t) => t.id.equals(id))).write(
      TodoTasksTableCompanion(deletedAt: Value(utcNow()), updatedAt: Value(utcNow())),
    );
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final lists = await _db.select(_db.todoListsTable).get();
    for (final row in lists) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(_db.todoListsTable)..where((t) => t.id.equals(row.id))).go();
      }
    }
    final tasks = await _db.select(_db.todoTasksTable).get();
    for (final row in tasks) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(_db.todoTasksTable)..where((t) => t.id.equals(row.id))).go();
      }
    }
  }
}

class DriftCalendarRepository implements CalendarRepository {
  DriftCalendarRepository(this._db);

  final AppDatabase _db;
  final _policy = const SoftDeletePolicy();

  @override
  Future<List<CalendarEvent>> listEvents({
    DateTime? from,
    DateTime? to,
    bool includeDeleted = false,
  }) async {
    var query = _db.select(_db.calendarEventsTable);
    if (from != null) query = query..where((t) => t.start.isBiggerOrEqualValue(from));
    if (to != null) query = query..where((t) => t.end.isSmallerOrEqualValue(to));
    final rows = await query.get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapEvent)
        .toList();
  }

  @override
  Future<void> upsertEvent(CalendarEvent event) async {
    await _db.into(_db.calendarEventsTable).insertOnConflictUpdate(CalendarEventsTableCompanion(
          id: Value(event.id),
          title: Value(event.title),
          start: Value(event.start),
          end: Value(event.end),
          isFullDay: Value(event.isFullDay),
          colorValue: Value(event.colorValue),
          notes: Value(event.notes),
          source: Value(event.source.name),
          externalId: Value(event.externalId),
          createdAt: Value(event.createdAt),
          updatedAt: Value(event.updatedAt),
          deletedAt: Value(event.deletedAt),
        ));
  }

  @override
  Future<void> softDeleteEvent(String id) async {
    await (_db.update(_db.calendarEventsTable)..where((t) => t.id.equals(id))).write(
      CalendarEventsTableCompanion(deletedAt: Value(utcNow()), updatedAt: Value(utcNow())),
    );
  }

  @override
  Future<void> replaceGoogleEvents(List<CalendarEvent> events) async {
    await (_db.delete(_db.calendarEventsTable)..where((t) => t.source.equals('google'))).go();
    for (final event in events) {
      await upsertEvent(event);
    }
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final rows = await _db.select(_db.calendarEventsTable).get();
    for (final row in rows) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(_db.calendarEventsTable)..where((t) => t.id.equals(row.id))).go();
      }
    }
  }

  CalendarEvent _mapEvent(CalendarEventsTableData row) => CalendarEvent(
        id: row.id,
        title: row.title,
        start: row.start,
        end: row.end,
        isFullDay: row.isFullDay,
        colorValue: row.colorValue,
        notes: row.notes,
        source: EventSource.values.byName(row.source),
        externalId: row.externalId,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
      );
}

class DriftTrackerRepository implements TrackerRepository {
  DriftTrackerRepository(this._db);

  final AppDatabase _db;
  final _policy = const SoftDeletePolicy();

  @override
  Future<List<StatisticTracker>> listTrackers({bool includeDeleted = false}) async {
    final rows = await _db.select(_db.trackersTable).get();
    return rows.where((r) => includeDeleted || r.deletedAt == null).map(_mapTracker).toList();
  }

  @override
  Future<void> upsertTracker(StatisticTracker tracker) async {
    await _db.into(_db.trackersTable).insertOnConflictUpdate(TrackersTableCompanion(
          id: Value(tracker.id),
          name: Value(tracker.name),
          type: Value(tracker.type.name),
          cadence: Value(tracker.cadence.name),
          colorValue: Value(tracker.colorValue),
          showOnCalendar: Value(tracker.showOnCalendar),
          integerCap: Value(tracker.integerCap),
          defaultInt: Value(tracker.defaultInt),
          defaultBool: Value(tracker.defaultBool),
          enumOptionsJson: Value(jsonEncode(tracker.enumOptions)),
          defaultEnumOption: Value(tracker.defaultEnumOption),
          createdAt: Value(tracker.createdAt),
          updatedAt: Value(tracker.updatedAt),
          deletedAt: Value(tracker.deletedAt),
        ));
  }

  @override
  Future<void> softDeleteTracker(String id) async {
    await (_db.update(_db.trackersTable)..where((t) => t.id.equals(id))).write(
      TrackersTableCompanion(deletedAt: Value(utcNow()), updatedAt: Value(utcNow())),
    );
  }

  @override
  Future<List<TrackerValue>> listValues(String trackerId) async {
    final rows = await (_db.select(_db.trackerValuesTable)..where((t) => t.trackerId.equals(trackerId))).get();
    return rows.map(_mapValue).toList();
  }

  @override
  Future<void> upsertValue(TrackerValue value) async {
    await _db.into(_db.trackerValuesTable).insertOnConflictUpdate(TrackerValuesTableCompanion(
          id: Value(value.id),
          trackerId: Value(value.trackerId),
          periodStart: Value(value.periodStart),
          intValue: Value(value.intValue),
          boolValue: Value(value.boolValue),
          enumValue: Value(value.enumValue),
          createdAt: Value(value.createdAt),
          updatedAt: Value(value.updatedAt),
          deletedAt: Value(value.deletedAt),
        ));
  }

  @override
  Future<List<RankingConfig>> listRankingConfigs() async {
    final rows = await _db.select(_db.rankingConfigsTable).get();
    return rows
        .where((r) => r.deletedAt == null)
        .map((r) => RankingConfig(
              id: r.id,
              name: r.name,
              cadence: TrackerCadence.values.byName(r.cadence),
              maxValue: r.maxValue,
              colorStart: r.colorStart,
              colorEnd: r.colorEnd,
              createdAt: r.createdAt,
              updatedAt: r.updatedAt,
              deletedAt: r.deletedAt,
            ))
        .toList();
  }

  @override
  Future<void> upsertRankingConfig(RankingConfig config) async {
    await _db.into(_db.rankingConfigsTable).insertOnConflictUpdate(RankingConfigsTableCompanion(
          id: Value(config.id),
          name: Value(config.name),
          cadence: Value(config.cadence.name),
          maxValue: Value(config.maxValue),
          colorStart: Value(config.colorStart),
          colorEnd: Value(config.colorEnd),
          createdAt: Value(config.createdAt),
          updatedAt: Value(config.updatedAt),
          deletedAt: Value(config.deletedAt),
        ));
  }

  @override
  Future<List<RankingValue>> listRankingValues(String configId) async {
    final rows = await (_db.select(_db.rankingValuesTable)..where((t) => t.configId.equals(configId))).get();
    return rows
        .map((r) => RankingValue(
              id: r.id,
              configId: r.configId,
              periodStart: r.periodStart,
              value: r.value,
              createdAt: r.createdAt,
              updatedAt: r.updatedAt,
              deletedAt: r.deletedAt,
            ))
        .toList();
  }

  @override
  Future<void> upsertRankingValue(RankingValue value) async {
    await _db.into(_db.rankingValuesTable).insertOnConflictUpdate(RankingValuesTableCompanion(
          id: Value(value.id),
          configId: Value(value.configId),
          periodStart: Value(value.periodStart),
          value: Value(value.value),
          createdAt: Value(value.createdAt),
          updatedAt: Value(value.updatedAt),
          deletedAt: Value(value.deletedAt),
        ));
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final trackers = await _db.select(_db.trackersTable).get();
    for (final row in trackers) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(_db.trackersTable)..where((t) => t.id.equals(row.id))).go();
      }
    }
    final values = await _db.select(_db.trackerValuesTable).get();
    for (final row in values) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(_db.trackerValuesTable)..where((t) => t.id.equals(row.id))).go();
      }
    }
    final configs = await _db.select(_db.rankingConfigsTable).get();
    for (final row in configs) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(_db.rankingConfigsTable)..where((t) => t.id.equals(row.id))).go();
      }
    }
    final rankings = await _db.select(_db.rankingValuesTable).get();
    for (final row in rankings) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(_db.rankingValuesTable)..where((t) => t.id.equals(row.id))).go();
      }
    }
  }

  StatisticTracker _mapTracker(TrackersTableData row) => StatisticTracker(
        id: row.id,
        name: row.name,
        type: TrackerType.values.byName(row.type == 'enumType' ? 'enumType' : row.type),
        cadence: TrackerCadence.values.byName(row.cadence),
        colorValue: row.colorValue,
        showOnCalendar: row.showOnCalendar,
        integerCap: row.integerCap,
        defaultInt: row.defaultInt,
        defaultBool: row.defaultBool,
        enumOptions: List<String>.from(jsonDecode(row.enumOptionsJson) as List),
        defaultEnumOption: row.defaultEnumOption,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
      );

  TrackerValue _mapValue(TrackerValuesTableData row) => TrackerValue(
        id: row.id,
        trackerId: row.trackerId,
        periodStart: row.periodStart,
        intValue: row.intValue,
        boolValue: row.boolValue,
        enumValue: row.enumValue,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
      );
}

class DriftSettingsRepository implements SettingsRepository {
  DriftSettingsRepository(this._db);

  final AppDatabase _db;

  @override
  Future<AppSettings> getSettings() async {
    final row = await (_db.select(_db.settingsTable)..where((t) => t.id.equals(1))).getSingleOrNull();
    if (row == null) {
      const defaults = AppSettings();
      await saveSettings(defaults);
      return defaults;
    }
    return AppSettings(
      accentColor: row.accentColor,
      weekStartsOnMonday: row.weekStartsOnMonday,
      showQuotes: row.showQuotes,
      journalHotkey: row.journalHotkey,
      todoHotkey: row.todoHotkey,
      rankingColorStart: row.rankingColorStart,
      rankingColorEnd: row.rankingColorEnd,
      timelineModeYearZero: row.timelineModeYearZero,
      birthYear: row.birthYear,
      alertOnPeriodicPrompts: row.alertOnPeriodicPrompts,
      alertTimeHour: row.alertTimeHour,
      hideCompletedTasks: row.hideCompletedTasks,
    );
  }

  @override
  Future<void> saveSettings(AppSettings settings) async {
    await _db.into(_db.settingsTable).insertOnConflictUpdate(SettingsTableCompanion(
          id: const Value(1),
          accentColor: Value(settings.accentColor),
          weekStartsOnMonday: Value(settings.weekStartsOnMonday),
          showQuotes: Value(settings.showQuotes),
          journalHotkey: Value(settings.journalHotkey),
          todoHotkey: Value(settings.todoHotkey),
          rankingColorStart: Value(settings.rankingColorStart),
          rankingColorEnd: Value(settings.rankingColorEnd),
          timelineModeYearZero: Value(settings.timelineModeYearZero),
          birthYear: Value(settings.birthYear),
          alertOnPeriodicPrompts: Value(settings.alertOnPeriodicPrompts),
          alertTimeHour: Value(settings.alertTimeHour),
          hideCompletedTasks: Value(settings.hideCompletedTasks),
        ));
  }

  @override
  Future<Map<String, int>> getTagColors() async {
    final rows = await _db.select(_db.tagColorsTable).get();
    return {for (final r in rows) r.tag: r.colorValue};
  }

  @override
  Future<void> setTagColor(String tag, int colorValue) async {
    await _db.into(_db.tagColorsTable).insertOnConflictUpdate(TagColorsTableCompanion(
          tag: Value(tag),
          colorValue: Value(colorValue),
        ));
  }
}
