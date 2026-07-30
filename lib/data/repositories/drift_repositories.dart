import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/soft_delete_policy.dart';
import 'package:voyager/core/sync/sync_activity.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/sync_conflict.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';

class DriftJournalRepository implements JournalRepository {
  DriftJournalRepository(this._db, {this._syncActivity});

  final AppDatabase _db;
  final SyncActivityController? _syncActivity;
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
    final row = await (_db.select(
      _db.journalsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapJournal(row);
  }

  @override
  Future<void> upsertJournal(
    Journal journal, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.journalsTable)
        .insertOnConflictUpdate(
          JournalsTableCompanion(
            id: Value(journal.id),
            name: Value(journal.name),
            colorValue: Value(journal.colorValue),
            guidedJournaling: Value(journal.guidedJournaling),
            promptCycleDays: Value(journal.promptCycleDays),
            createdAt: Value(journal.createdAt),
            updatedAt: Value(journal.updatedAt),
            version: Value(journal.version),
            deletedAt: Value(journal.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.journals);
    }
  }

  @override
  Future<void> softDeleteJournal(String id) async {
    await (_db.update(_db.journalsTable)..where((t) => t.id.equals(id))).write(
      JournalsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.journals);
  }

  @override
  Future<void> softDeleteEntriesInJournal(String journalId) async {
    final now = utcNow();
    await (_db.update(_db.journalEntriesTable)
          ..where((t) => t.journalId.equals(journalId)))
        .write(
      JournalEntriesTableCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.journalEntries);
  }

  @override
  Future<void> deleteAllJournals() async {
    await _db.delete(_db.journalsTable).go();
  }

  @override
  Future<void> deleteAllEntries() async {
    await _db.delete(_db.journalEntriesTable).go();
  }

  @override
  Future<void> reassignEntriesJournal(
    String fromJournalId,
    String toJournalId,
  ) async {
    await (_db.update(
      _db.journalEntriesTable,
    )..where((t) => t.journalId.equals(fromJournalId))).write(
      JournalEntriesTableCompanion(
        journalId: Value(toJournalId),
        updatedAt: Value(utcNow()),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.journalEntries);
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
    query = query
      ..orderBy([
        (t) => OrderingTerm.desc(t.entryDate),
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.desc(t.id),
      ]);
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
  Future<Map<String, int>> countEntriesByJournal({
    bool includeDeleted = false,
  }) async {
    final journalIdCol = _db.journalEntriesTable.journalId;
    final countCol = _db.journalEntriesTable.id.count();
    final query = _db.selectOnly(_db.journalEntriesTable)
      ..addColumns([journalIdCol, countCol]);
    if (!includeDeleted) {
      query.where(_db.journalEntriesTable.deletedAt.isNull());
    }
    query.groupBy([journalIdCol]);

    final rows = await query.get();
    return {
      for (final row in rows)
        row.read(journalIdCol)!: row.read(countCol)!,
    };
  }

  @override
  Future<JournalEntry?> getEntry(String id) async {
    final row = await (_db.select(
      _db.journalEntriesTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapEntry(row);
  }

  @override
  Future<void> upsertEntry(
    JournalEntry entry, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.journalEntriesTable)
        .insertOnConflictUpdate(
          JournalEntriesTableCompanion(
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
            version: Value(entry.version),
            deletedAt: Value(entry.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.journalEntries);
    }
  }

  @override
  Future<void> softDeleteEntry(String id) async {
    await (_db.update(
      _db.journalEntriesTable,
    )..where((t) => t.id.equals(id))).write(
      JournalEntriesTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.journalEntries);
  }

  @override
  Future<void> hardDeleteEntry(String id) async {
    await (_db.delete(
      _db.journalEntriesTable,
    )..where((t) => t.id.equals(id))).go();
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final entries = await _db.select(_db.journalEntriesTable).get();
    for (final row in entries) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.journalEntriesTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
    final journals = await _db.select(_db.journalsTable).get();
    for (final row in journals) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.journalsTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
  }

  @override
  Future<List<JournalEntry>> getAllEntries({bool includeDeleted = true}) async {
    final rows = await _db.select(_db.journalEntriesTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapEntry)
        .toList();
  }

  Journal _mapJournal(JournalsTableData row) => Journal(
    id: row.id,
    name: row.name,
    colorValue: row.colorValue,
    guidedJournaling: row.guidedJournaling,
    promptCycleDays: row.promptCycleDays,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
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
    version: row.version,
    deletedAt: row.deletedAt,
  );
}

class DriftDreamRepository implements DreamRepository {
  DriftDreamRepository(this._db, {this._syncActivity});

  final AppDatabase _db;
  final SyncActivityController? _syncActivity;
  final _policy = const SoftDeletePolicy();

  @override
  Future<List<DreamEntry>> listEntries({
    DateTime? from,
    DateTime? to,
    int? limit,
    bool includeDeleted = false,
  }) async {
    var query = _db.select(_db.dreamEntriesTable);
    if (from != null) {
      query = query..where((t) => t.entryDate.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      query = query..where((t) => t.entryDate.isSmallerOrEqualValue(to));
    }
    query = query
      ..orderBy([
        (t) => OrderingTerm.desc(t.entryDate),
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.desc(t.id),
      ]);
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
  Future<DreamEntry?> getEntry(String id) async {
    final row = await (_db.select(
      _db.dreamEntriesTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapEntry(row);
  }

  @override
  Future<void> upsertEntry(
    DreamEntry entry, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.dreamEntriesTable)
        .insertOnConflictUpdate(
          DreamEntriesTableCompanion(
            id: Value(entry.id),
            title: Value(entry.title),
            body: Value(entry.body),
            notes: Value(entry.notes),
            entryDate: Value(entry.entryDate),
            tagsJson: Value(jsonEncode(entry.tags)),
            createdAt: Value(entry.createdAt),
            updatedAt: Value(entry.updatedAt),
            version: Value(entry.version),
            deletedAt: Value(entry.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.dreamEntries);
    }
  }

  @override
  Future<void> softDeleteEntry(String id) async {
    await (_db.update(
      _db.dreamEntriesTable,
    )..where((t) => t.id.equals(id))).write(
      DreamEntriesTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.dreamEntries);
  }

  @override
  Future<void> hardDeleteEntry(String id) async {
    await (_db.delete(
      _db.dreamEntriesTable,
    )..where((t) => t.id.equals(id))).go();
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final entries = await _db.select(_db.dreamEntriesTable).get();
    for (final row in entries) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.dreamEntriesTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
  }

  @override
  Future<List<DreamEntry>> getAllEntries({bool includeDeleted = true}) async {
    final rows = await _db.select(_db.dreamEntriesTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapEntry)
        .toList();
  }

  DreamEntry _mapEntry(DreamEntriesTableData row) => DreamEntry(
    id: row.id,
    title: row.title,
    body: row.body,
    notes: row.notes,
    entryDate: row.entryDate,
    tags: List<String>.from(jsonDecode(row.tagsJson) as List),
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );
}

class DriftTodoRepository implements TodoRepository {
  DriftTodoRepository(this._db, {this._syncActivity});

  final AppDatabase _db;
  final SyncActivityController? _syncActivity;
  final _policy = const SoftDeletePolicy();

  @override
  Future<List<TodoListModel>> listLists({bool includeDeleted = false}) async {
    final rows = await _db.select(_db.todoListsTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(
          (r) => TodoListModel(
            id: r.id,
            name: r.name,
            colorValue: r.colorValue,
            createdAt: r.createdAt,
            updatedAt: r.updatedAt,
            version: r.version,
            deletedAt: r.deletedAt,
          ),
        )
        .toList();
  }

  @override
  Future<void> upsertList(
    TodoListModel list, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.todoListsTable)
        .insertOnConflictUpdate(
          TodoListsTableCompanion(
            id: Value(list.id),
            name: Value(list.name),
            colorValue: Value(list.colorValue),
            createdAt: Value(list.createdAt),
            updatedAt: Value(list.updatedAt),
            version: Value(list.version),
            deletedAt: Value(list.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.todoLists);
    }
  }

  @override
  Future<void> softDeleteList(String id) async {
    await (_db.update(_db.todoListsTable)..where((t) => t.id.equals(id))).write(
      TodoListsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<void> softDeleteTasksInList(String listId) async {
    final now = utcNow();
    await (_db.update(_db.todoTasksTable)..where((t) => t.listId.equals(listId)))
        .write(
      TodoTasksTableCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
      ),
    );
  }

  @override
  Future<void> reassignTasksList(String fromListId, String toListId) async {
    await (_db.update(_db.todoTasksTable)
          ..where((t) => t.listId.equals(fromListId)))
        .write(
      TodoTasksTableCompanion(
        listId: Value(toListId),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<List<TodoTask>> listTasks(
    String listId, {
    bool includeDeleted = false,
    bool topLevelOnly = true,
  }) async {
    final rows = await (_db.select(
      _db.todoTasksTable,
    )..where((t) => t.listId.equals(listId))).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .where((r) => !topLevelOnly || r.parentTaskId == null)
        .map(_mapTask)
        .toList();
  }

  @override
  Future<List<TodoTask>> listSubtasks(String parentTaskId) async {
    final rows = await (_db.select(
      _db.todoTasksTable,
    )
      ..where((t) => t.parentTaskId.equals(parentTaskId))
      ..orderBy([
        (t) => OrderingTerm(expression: t.sortOrder, mode: OrderingMode.asc)
      ])).get();
    return rows.where((r) => r.deletedAt == null).map(_mapTask).toList();
  }

  @override
  Future<int> nextSortOrder(String listId) async {
    final tasks = await listTasks(listId);
    final active = activeTopLevelTasks(tasks.where((t) => !t.completed));
    return nextNewTaskSortOrder(active);
  }

  TodoTask _mapTask(TodoTasksTableData r) => TodoTask(
    id: r.id,
    listId: r.listId,
    title: r.title,
    notes: r.notes,
    dueDate: r.dueDate,
    completed: r.completed,
    starred: r.starred,
    sortOrder: r.sortOrder,
    preStarSortOrder: r.preStarSortOrder,
    dueDateSetAt: r.dueDateSetAt,
    parentTaskId: r.parentTaskId,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    version: r.version,
    deletedAt: r.deletedAt,
  );

  @override
  Future<void> upsertTask(
    TodoTask task, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.todoTasksTable)
        .insertOnConflictUpdate(
          TodoTasksTableCompanion(
            id: Value(task.id),
            listId: Value(task.listId),
            parentTaskId: Value(task.parentTaskId),
            title: Value(task.title),
            notes: Value(task.notes),
            dueDate: Value(task.dueDate),
            completed: Value(task.completed),
            starred: Value(task.starred),
            sortOrder: Value(task.sortOrder),
            preStarSortOrder: Value(task.preStarSortOrder),
            dueDateSetAt: Value(task.dueDateSetAt),
            createdAt: Value(task.createdAt),
            updatedAt: Value(task.updatedAt),
            version: Value(task.version),
            deletedAt: Value(task.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.todoTasks);
    }
  }

  @override
  Future<void> upsertTasksBatch(
    List<TodoTask> tasks, {
    bool recordLocalActivity = true,
  }) async {
    if (tasks.isEmpty) return;
    await _db.batch((b) {
      b.insertAllOnConflictUpdate(
        _db.todoTasksTable,
        [
          for (final task in tasks)
            TodoTasksTableCompanion(
              id: Value(task.id),
              listId: Value(task.listId),
              parentTaskId: Value(task.parentTaskId),
              title: Value(task.title),
              notes: Value(task.notes),
              dueDate: Value(task.dueDate),
              completed: Value(task.completed),
              starred: Value(task.starred),
              sortOrder: Value(task.sortOrder),
              preStarSortOrder: Value(task.preStarSortOrder),
              dueDateSetAt: Value(task.dueDateSetAt),
              createdAt: Value(task.createdAt),
              updatedAt: Value(task.updatedAt),
              version: Value(task.version),
              deletedAt: Value(task.deletedAt),
            ),
        ],
      );
    });
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.todoTasks);
    }
  }

  @override
  Future<void> softDeleteTask(String id) async {
    await (_db.update(_db.todoTasksTable)..where((t) => t.id.equals(id))).write(
      TodoTasksTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final lists = await _db.select(_db.todoListsTable).get();
    for (final row in lists) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.todoListsTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
    final tasks = await _db.select(_db.todoTasksTable).get();
    for (final row in tasks) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.todoTasksTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
  }

  @override
  Future<List<TodoTask>> getAllTasks({bool includeDeleted = true}) async {
    final rows = await _db.select(_db.todoTasksTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapTask)
        .toList();
  }

  @override
  Future<TodoTask?> getTask(String id) async {
    final row = await (_db.select(
      _db.todoTasksTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapTask(row);
  }
}

class DriftCalendarRepository implements CalendarRepository {
  DriftCalendarRepository(this._db);

  final AppDatabase _db;
  final _policy = const SoftDeletePolicy();

  @override
  Future<List<Calendar>> listCalendars({bool includeDeleted = false}) async {
    final rows = await _db.select(_db.calendarsTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapCalendar)
        .toList();
  }

  @override
  Future<void> upsertCalendar(Calendar calendar) async {
    await _db
        .into(_db.calendarsTable)
        .insertOnConflictUpdate(
          CalendarsTableCompanion(
            id: Value(calendar.id),
            name: Value(calendar.name),
            colorValue: Value(calendar.colorValue),
            createdAt: Value(calendar.createdAt),
            updatedAt: Value(calendar.updatedAt),
            version: Value(calendar.version),
            deletedAt: Value(calendar.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteCalendar(String id) async {
    await (_db.update(
      _db.calendarsTable,
    )..where((t) => t.id.equals(id))).write(
      CalendarsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<void> softDeleteEventsInCalendar(String calendarId) async {
    final now = utcNow();
    await (_db.update(_db.calendarEventsTable)
          ..where((t) => t.calendarId.equals(calendarId)))
        .write(
      CalendarEventsTableCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
      ),
    );
  }

  @override
  Future<void> reassignEventsCalendar(
    String fromCalendarId,
    String toCalendarId,
  ) async {
    await (_db.update(_db.calendarEventsTable)
          ..where((t) => t.calendarId.equals(fromCalendarId)))
        .write(
      CalendarEventsTableCompanion(
        calendarId: Value(toCalendarId),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<List<CalendarEvent>> listEvents({
    String? calendarId,
    DateTime? from,
    DateTime? to,
    bool includeDeleted = false,
  }) async {
    var query = _db.select(_db.calendarEventsTable);
    if (calendarId != null) {
      query = query..where((t) => t.calendarId.equals(calendarId));
    }
    if (from != null) {
      query = query..where((t) => t.start.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      query = query..where((t) => t.end.isSmallerOrEqualValue(to));
    }
    final rows = await query.get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapEvent)
        .toList();
  }

  @override
  Future<void> upsertEvent(CalendarEvent event) async {
    await _db
        .into(_db.calendarEventsTable)
        .insertOnConflictUpdate(
          CalendarEventsTableCompanion(
            id: Value(event.id),
            calendarId: Value(event.calendarId),
            title: Value(event.title),
            start: Value(event.start),
            end: Value(event.end),
            isFullDay: Value(event.isFullDay),
            colorValue: Value(event.colorValue),
            notes: Value(event.notes),
            source: Value(event.source.name),
            externalId: Value(event.externalId),
            recurrence: Value(event.recurrence.name),
            createdAt: Value(event.createdAt),
            updatedAt: Value(event.updatedAt),
            deletedAt: Value(event.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteEvent(String id) async {
    await (_db.update(
      _db.calendarEventsTable,
    )..where((t) => t.id.equals(id))).write(
      CalendarEventsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<void> deleteAllEvents() async {
    await _db.delete(_db.calendarEventsTable).go();
  }

  @override
  Future<void> replaceGoogleEvents(List<CalendarEvent> events) async {
    await (_db.delete(
      _db.calendarEventsTable,
    )..where((t) => t.source.equals('google'))).go();
    for (final event in events) {
      // Google-imported events currently always land in the default calendar;
      // mapping Google's own calendars to Voyager calendars is future work.
      await upsertEvent(event);
    }
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final rows = await _db.select(_db.calendarEventsTable).get();
    for (final row in rows) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.calendarEventsTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
    final calendars = await _db.select(_db.calendarsTable).get();
    for (final row in calendars) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.calendarsTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
  }

  Calendar _mapCalendar(CalendarsTableData row) => Calendar(
    id: row.id,
    name: row.name,
    colorValue: row.colorValue,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  CalendarEvent _mapEvent(CalendarEventsTableData row) => CalendarEvent(
    id: row.id,
    calendarId: row.calendarId,
    title: row.title,
    start: row.start,
    end: row.end,
    isFullDay: row.isFullDay,
    colorValue: row.colorValue,
    notes: row.notes,
    source: EventSource.values.byName(row.source),
    externalId: row.externalId,
    recurrence:
        recurrenceFromStorage(row.recurrence),
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
  Future<List<StatisticTracker>> listTrackers({
    bool includeDeleted = false,
  }) async {
    final rows = await _db.select(_db.trackersTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapTracker)
        .toList();
  }

  @override
  Future<void> upsertTracker(StatisticTracker tracker) async {
    await _db
        .into(_db.trackersTable)
        .insertOnConflictUpdate(
          TrackersTableCompanion(
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
            trackingStyle: Value(tracker.trackingStyle?.name),
            starred: Value(tracker.starred),
            sortOrder: Value(tracker.sortOrder),
            createdAt: Value(tracker.createdAt),
            updatedAt: Value(tracker.updatedAt),
            deletedAt: Value(tracker.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteTracker(String id) async {
    await (_db.update(_db.trackersTable)..where((t) => t.id.equals(id))).write(
      TrackersTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<List<TrackerValue>> listValues(String trackerId) async {
    final rows = await (_db.select(
      _db.trackerValuesTable,
    )..where((t) => t.trackerId.equals(trackerId) & t.deletedAt.isNull())).get();
    return rows.map(_mapValue).toList();
  }

  @override
  Future<void> upsertValue(TrackerValue value) async {
    await _db
        .into(_db.trackerValuesTable)
        .insertOnConflictUpdate(
          TrackerValuesTableCompanion(
            id: Value(value.id),
            trackerId: Value(value.trackerId),
            periodStart: Value(value.periodStart),
            intValue: Value(value.intValue),
            boolValue: Value(value.boolValue),
            enumValue: Value(value.enumValue),
            createdAt: Value(value.createdAt),
            updatedAt: Value(value.updatedAt),
            deletedAt: Value(value.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteValue(String id) async {
    await (_db.update(_db.trackerValuesTable)..where((t) => t.id.equals(id))).write(
      TrackerValuesTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final trackers = await _db.select(_db.trackersTable).get();
    for (final row in trackers) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.trackersTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
    final values = await _db.select(_db.trackerValuesTable).get();
    for (final row in values) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.trackerValuesTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
  }

  StatisticTracker _mapTracker(TrackersTableData row) => StatisticTracker(
    id: row.id,
    name: row.name,
    type: TrackerType.values.byName(
      row.type == 'enumType' ? 'enumType' : row.type,
    ),
    cadence: TrackerCadence.values.byName(row.cadence),
    colorValue: row.colorValue,
    showOnCalendar: row.showOnCalendar,
    integerCap: row.integerCap,
    defaultInt: row.defaultInt,
    defaultBool: row.defaultBool,
    enumOptions: List<String>.from(jsonDecode(row.enumOptionsJson) as List),
    defaultEnumOption: row.defaultEnumOption,
    trackingStyle: row.trackingStyle == null
        ? null
        : TrackerStyle.values.byName(row.trackingStyle!),
    starred: row.starred,
    sortOrder: row.sortOrder,
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

class DriftNotificationRepository implements NotificationRepository {
  DriftNotificationRepository(this._db);

  final AppDatabase _db;

  @override
  Future<List<PinnedNote>> listPinnedNotes() async {
    final rows =
        await (_db.select(_db.pinnedNotesTable)
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();
    return rows
        .map((r) => PinnedNote(id: r.id, text: r.body, createdAt: r.createdAt))
        .toList();
  }

  @override
  Future<void> upsertPinnedNote(PinnedNote note) async {
    await _db
        .into(_db.pinnedNotesTable)
        .insertOnConflictUpdate(
          PinnedNotesTableCompanion(
            id: Value(note.id),
            body: Value(note.text),
            createdAt: Value(note.createdAt),
          ),
        );
  }

  @override
  Future<void> deletePinnedNote(String id) async {
    await (_db.delete(
      _db.pinnedNotesTable,
    )..where((t) => t.id.equals(id))).go();
  }

  @override
  Future<Set<String>> listDismissals() async {
    final rows = await _db.select(_db.dismissedNotificationsTable).get();
    return rows.map((r) => r.id).toSet();
  }

  @override
  Future<void> dismiss(String dismissalKey) async {
    await _db
        .into(_db.dismissedNotificationsTable)
        .insertOnConflictUpdate(
          DismissedNotificationsTableCompanion(
            id: Value(dismissalKey),
            dismissedAt: Value(utcNow()),
          ),
        );
  }

  @override
  Future<void> undismiss(String dismissalKey) async {
    await (_db.delete(
      _db.dismissedNotificationsTable,
    )..where((t) => t.id.equals(dismissalKey))).go();
  }
}

class DriftFinanceRepository implements FinanceRepository {
  DriftFinanceRepository(this._db);

  final AppDatabase _db;
  final _policy = const SoftDeletePolicy();

  @override
  Future<List<FinancialTransaction>> listTransactions({
    bool includeDeleted = false,
  }) async {
    final rows = await _db.select(_db.transactionsTable).get();
    final transactions = rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_map)
        .toList();
    // Newest first — the ledger is a reverse-chronological feed.
    transactions.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return transactions;
  }

  @override
  Future<void> upsertTransaction(FinancialTransaction transaction) async {
    await _db
        .into(_db.transactionsTable)
        .insertOnConflictUpdate(
          TransactionsTableCompanion(
            id: Value(transaction.id),
            type: Value(transaction.type.name),
            amountCents: Value(transaction.amountCents),
            note: Value(transaction.note),
            tagsJson: Value(jsonEncode(transaction.tags)),
            occurredAt: Value(transaction.occurredAt),
            createdAt: Value(transaction.createdAt),
            updatedAt: Value(transaction.updatedAt),
            version: Value(transaction.version),
            deletedAt: Value(transaction.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteTransaction(String id) async {
    await (_db.update(
      _db.transactionsTable,
    )..where((t) => t.id.equals(id))).write(
      TransactionsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<List<Subscription>> listSubscriptions({
    bool includeDeleted = false,
  }) async {
    final rows = await _db.select(_db.subscriptionsTable).get();
    final subscriptions = rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapSubscription)
        .toList();
    // Soonest due first — the radar is a countdown to the next bill.
    subscriptions.sort((a, b) => a.nextDue().compareTo(b.nextDue()));
    return subscriptions;
  }

  @override
  Future<void> upsertSubscription(Subscription subscription) async {
    await _db
        .into(_db.subscriptionsTable)
        .insertOnConflictUpdate(
          SubscriptionsTableCompanion(
            id: Value(subscription.id),
            name: Value(subscription.name),
            amountCents: Value(subscription.amountCents),
            period: Value(subscription.period.name),
            anchorDueDate: Value(subscription.anchorDueDate),
            colorValue: Value(subscription.colorValue),
            note: Value(subscription.note),
            createdAt: Value(subscription.createdAt),
            updatedAt: Value(subscription.updatedAt),
            version: Value(subscription.version),
            deletedAt: Value(subscription.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteSubscription(String id) async {
    await (_db.update(
      _db.subscriptionsTable,
    )..where((t) => t.id.equals(id))).write(
      SubscriptionsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<List<Budget>> listBudgets({bool includeDeleted = false}) async {
    final rows = await _db.select(_db.budgetsTable).get();
    final budgets = rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapBudget)
        .toList();
    budgets.sort((a, b) => a.tag.toLowerCase().compareTo(b.tag.toLowerCase()));
    return budgets;
  }

  @override
  Future<void> upsertBudget(Budget budget) async {
    await _db
        .into(_db.budgetsTable)
        .insertOnConflictUpdate(
          BudgetsTableCompanion(
            id: Value(budget.id),
            tag: Value(budget.tag),
            limitCents: Value(budget.limitCents),
            createdAt: Value(budget.createdAt),
            updatedAt: Value(budget.updatedAt),
            version: Value(budget.version),
            deletedAt: Value(budget.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteBudget(String id) async {
    await (_db.update(_db.budgetsTable)..where((t) => t.id.equals(id))).write(
      BudgetsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<List<FinanceCategory>> listCategories({
    bool includeDeleted = false,
  }) async {
    final rows = await _db.select(_db.financeCategoriesTable).get();
    final categories = rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapCategory)
        .toList();
    categories
        .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return categories;
  }

  @override
  Future<void> upsertCategory(FinanceCategory category) async {
    await _db
        .into(_db.financeCategoriesTable)
        .insertOnConflictUpdate(
          FinanceCategoriesTableCompanion(
            id: Value(category.id),
            name: Value(category.name),
            colorValue: Value(category.colorValue),
            tagsJson: Value(jsonEncode(category.tags)),
            createdAt: Value(category.createdAt),
            updatedAt: Value(category.updatedAt),
            version: Value(category.version),
            deletedAt: Value(category.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteCategory(String id) async {
    await (_db.update(
      _db.financeCategoriesTable,
    )..where((t) => t.id.equals(id))).write(
      FinanceCategoriesTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<List<Asset>> listAssets({bool includeDeleted = false}) async {
    final rows = await _db.select(_db.assetsTable).get();
    final assets = rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapAsset)
        .toList();
    assets.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return assets;
  }

  @override
  Future<void> upsertAsset(Asset asset) async {
    await _db
        .into(_db.assetsTable)
        .insertOnConflictUpdate(
          AssetsTableCompanion(
            id: Value(asset.id),
            name: Value(asset.name),
            note: Value(asset.note),
            colorValue: Value(asset.colorValue),
            createdAt: Value(asset.createdAt),
            updatedAt: Value(asset.updatedAt),
            version: Value(asset.version),
            deletedAt: Value(asset.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteAsset(String id) async {
    await (_db.update(_db.assetsTable)..where((t) => t.id.equals(id))).write(
      AssetsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
    // Tombstone the asset's valuations too, so a deleted asset stops
    // contributing to historical net-worth points.
    await (_db.update(
      _db.assetValuationsTable,
    )..where((t) => t.assetId.equals(id) & t.deletedAt.isNull())).write(
      AssetValuationsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<List<AssetValuation>> listAssetValuations({
    String? assetId,
    bool includeDeleted = false,
  }) async {
    final rows = await _db.select(_db.assetValuationsTable).get();
    final valuations = rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .where((r) => assetId == null || r.assetId == assetId)
        .map(_mapValuation)
        .toList();
    valuations.sort((a, b) => b.asOf.compareTo(a.asOf));
    return valuations;
  }

  @override
  Future<void> upsertAssetValuation(AssetValuation valuation) async {
    await _db
        .into(_db.assetValuationsTable)
        .insertOnConflictUpdate(
          AssetValuationsTableCompanion(
            id: Value(valuation.id),
            assetId: Value(valuation.assetId),
            valueCents: Value(valuation.valueCents),
            asOf: Value(valuation.asOf),
            createdAt: Value(valuation.createdAt),
            updatedAt: Value(valuation.updatedAt),
            version: Value(valuation.version),
            deletedAt: Value(valuation.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteAssetValuation(String id) async {
    await (_db.update(
      _db.assetValuationsTable,
    )..where((t) => t.id.equals(id))).write(
      AssetValuationsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<List<SavingsGoal>> listSavingsGoals({
    bool includeDeleted = false,
  }) async {
    final rows = await _db.select(_db.savingsGoalsTable).get();
    final goals = rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapGoal)
        .toList();
    goals.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return goals;
  }

  @override
  Future<void> upsertSavingsGoal(SavingsGoal goal) async {
    await _db
        .into(_db.savingsGoalsTable)
        .insertOnConflictUpdate(
          SavingsGoalsTableCompanion(
            id: Value(goal.id),
            name: Value(goal.name),
            targetCents: Value(goal.targetCents),
            colorValue: Value(goal.colorValue),
            note: Value(goal.note),
            targetDate: Value(goal.targetDate),
            createdAt: Value(goal.createdAt),
            updatedAt: Value(goal.updatedAt),
            version: Value(goal.version),
            deletedAt: Value(goal.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteSavingsGoal(String id) async {
    await (_db.update(
      _db.savingsGoalsTable,
    )..where((t) => t.id.equals(id))).write(
      SavingsGoalsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
    // Tombstone the goal's allocations so they stop counting toward progress.
    await (_db.update(
      _db.goalAllocationsTable,
    )..where((t) => t.goalId.equals(id) & t.deletedAt.isNull())).write(
      GoalAllocationsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  @override
  Future<List<GoalAllocation>> listGoalAllocations({
    String? goalId,
    bool includeDeleted = false,
  }) async {
    final rows = await _db.select(_db.goalAllocationsTable).get();
    final allocations = rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .where((r) => goalId == null || r.goalId == goalId)
        .map(_mapAllocation)
        .toList();
    allocations.sort((a, b) => b.allocatedAt.compareTo(a.allocatedAt));
    return allocations;
  }

  @override
  Future<void> upsertGoalAllocation(GoalAllocation allocation) async {
    await _db
        .into(_db.goalAllocationsTable)
        .insertOnConflictUpdate(
          GoalAllocationsTableCompanion(
            id: Value(allocation.id),
            goalId: Value(allocation.goalId),
            amountCents: Value(allocation.amountCents),
            allocatedAt: Value(allocation.allocatedAt),
            note: Value(allocation.note),
            createdAt: Value(allocation.createdAt),
            updatedAt: Value(allocation.updatedAt),
            version: Value(allocation.version),
            deletedAt: Value(allocation.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteGoalAllocation(String id) async {
    await (_db.update(
      _db.goalAllocationsTable,
    )..where((t) => t.id.equals(id))).write(
      GoalAllocationsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
  }

  SavingsGoal _mapGoal(SavingsGoalsTableData row) => SavingsGoal(
    id: row.id,
    name: row.name,
    targetCents: row.targetCents,
    colorValue: row.colorValue,
    note: row.note,
    targetDate: row.targetDate,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  GoalAllocation _mapAllocation(GoalAllocationsTableData row) => GoalAllocation(
    id: row.id,
    goalId: row.goalId,
    amountCents: row.amountCents,
    allocatedAt: row.allocatedAt,
    note: row.note,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  FinanceCategory _mapCategory(FinanceCategoriesTableData row) =>
      FinanceCategory(
        id: row.id,
        name: row.name,
        colorValue: row.colorValue,
        tags: List<String>.from(jsonDecode(row.tagsJson) as List),
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        version: row.version,
        deletedAt: row.deletedAt,
      );

  Asset _mapAsset(AssetsTableData row) => Asset(
    id: row.id,
    name: row.name,
    note: row.note,
    colorValue: row.colorValue,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  AssetValuation _mapValuation(AssetValuationsTableData row) => AssetValuation(
    id: row.id,
    assetId: row.assetId,
    valueCents: row.valueCents,
    asOf: row.asOf,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final rows = await _db.select(_db.transactionsTable).get();
    for (final row in rows) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.transactionsTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
    final subscriptions = await _db.select(_db.subscriptionsTable).get();
    for (final row in subscriptions) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.subscriptionsTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
    final budgets = await _db.select(_db.budgetsTable).get();
    for (final row in budgets) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.budgetsTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
    final categories = await _db.select(_db.financeCategoriesTable).get();
    for (final row in categories) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.financeCategoriesTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
    final valuations = await _db.select(_db.assetValuationsTable).get();
    for (final row in valuations) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.assetValuationsTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
    final assets = await _db.select(_db.assetsTable).get();
    for (final row in assets) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.assetsTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
    final allocations = await _db.select(_db.goalAllocationsTable).get();
    for (final row in allocations) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.goalAllocationsTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
    final goals = await _db.select(_db.savingsGoalsTable).get();
    for (final row in goals) {
      if (row.deletedAt != null && _policy.isExpired(row.deletedAt!, now)) {
        await (_db.delete(
          _db.savingsGoalsTable,
        )..where((t) => t.id.equals(row.id))).go();
      }
    }
  }

  Budget _mapBudget(BudgetsTableData row) => Budget(
    id: row.id,
    tag: row.tag,
    limitCents: row.limitCents,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  Subscription _mapSubscription(SubscriptionsTableData row) => Subscription(
    id: row.id,
    name: row.name,
    amountCents: row.amountCents,
    period: BillingPeriod.values.byName(row.period),
    anchorDueDate: row.anchorDueDate,
    colorValue: row.colorValue,
    note: row.note,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  FinancialTransaction _map(TransactionsTableData row) => FinancialTransaction(
    id: row.id,
    type: TransactionType.values.byName(row.type),
    amountCents: row.amountCents,
    note: row.note,
    tags: List<String>.from(jsonDecode(row.tagsJson) as List),
    occurredAt: row.occurredAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );
}

class DriftSettingsRepository implements SettingsRepository {
  DriftSettingsRepository(this._db);

  final AppDatabase _db;

  @override
  Future<AppSettings> getSettings() async {
    final row = await (_db.select(
      _db.settingsTable,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    if (row == null) {
      const defaults = AppSettings();
      await saveSettings(defaults);
      return defaults;
    }
    return AppSettings(
      accentColor: row.accentColor,
      themeMode: AppThemeMode.values.byName(row.themeMode),
      petalColor: row.petalColor,
      petalMaxCount: row.petalMaxCount,
      petalFallSpeed: row.petalFallSpeed,
      petalWindFrequency: row.petalWindFrequency,
      petalWindStrength: row.petalWindStrength,
      weekStartsOnMonday: row.weekStartsOnMonday,
      showQuotes: row.showQuotes,
      showDefaultTrackersInGrid: row.showDefaultTrackersInGrid,
      showDefaultTrackersInCalendar: row.showDefaultTrackersInCalendar,
      journalHotkey: row.journalHotkey,
      todoHotkey: row.todoHotkey,
      calendarNavigateLeftKey: row.calendarNavigateLeftKey,
      calendarNavigateRightKey: row.calendarNavigateRightKey,
      timelineModeYearZero: row.timelineModeYearZero,
      birthYear: row.birthYear,
      alertOnPeriodicPrompts: row.alertOnPeriodicPrompts,
      alertTimeHour: row.alertTimeHour,
      hideCompletedTasks: row.hideCompletedTasks,
      deviceId: row.deviceId,
      lastViewedJournalId: row.lastViewedJournalId,
      lastViewedTodoListId: row.lastViewedTodoListId,
      weatherLocationLabel: row.weatherLocationLabel,
      weatherLat: row.weatherLat,
      weatherLon: row.weatherLon,
      weatherIcon: row.weatherIcon,
      weatherFetchedAt: row.weatherFetchedAt,
      weatherConditionCode: row.weatherConditionCode,
      weatherTempC: row.weatherTempC,
      weatherLocationUpdatedAt: row.weatherLocationUpdatedAt,
      devUseDirectOpenWeather: row.devUseDirectOpenWeather,
      devOpenWeatherApiKey: row.devOpenWeatherApiKey,
      devShowSyncLocalSaves: row.devShowSyncLocalSaves,
      devShowSyncUploads: row.devShowSyncUploads,
      devShowSyncDownloads: row.devShowSyncDownloads,
      devShowCacheStatus: row.devShowCacheStatus,
      devShowCalendarZoomPrewarm: row.devShowCalendarZoomPrewarm,
      devShowCalendarInstantViewSwitch: row.devShowCalendarInstantViewSwitch,
      devSlowCalendarAnimations: row.devSlowCalendarAnimations,
      devTodoSortDebugLog: row.devTodoSortDebugLog,
      devJournalDebugLog: row.devJournalDebugLog,
      devForceConflictUi: row.devForceConflictUi,
      devShowConflictDocumentIds: row.devShowConflictDocumentIds,
      devShowJournalRemotePullButton: row.devShowJournalRemotePullButton,
      devShowFpsCounter: row.devShowFpsCounter,
      devDisableCache: row.devDisableCache,
      geometricTextureScale: row.geometricTextureScale,
      geometricTextureIntensity: row.geometricTextureIntensity,
      geometricTextureFocalSpread: row.geometricTextureFocalSpread,
      geometricTextureFocalPointX: row.geometricTextureFocalPointX,
      geometricTextureFocalPointY: row.geometricTextureFocalPointY,
      geometricTextureVariationFloor: row.geometricTextureVariationFloor,
      geometricWaveEnabled: row.geometricWaveEnabled,
      geometricWaveShape: GeometricWaveShape.values.byName(
        row.geometricWaveShape,
      ),
      geometricWaveDirectionDegrees: row.geometricWaveDirectionDegrees,
      geometricWaveSpeed: row.geometricWaveSpeed,
      geometricWaveWidth: row.geometricWaveWidth,
      geometricWavePeriod: row.geometricWavePeriod,
      geometricWavePopHoldSeconds: row.geometricWavePopHoldSeconds,
      geometricWavePopScale: row.geometricWavePopScale,
      geometricWavePopBrightness: row.geometricWavePopBrightness,
      geometricWaveMaskDensity: row.geometricWaveMaskDensity,
      geometricWaveMaskClusterScale: row.geometricWaveMaskClusterScale,
      geometricWaveTwinkleSparsity: row.geometricWaveTwinkleSparsity,
      geometricWaveShadowLightDegrees: row.geometricWaveShadowLightDegrees,
      geometricWaveShadowOffset: row.geometricWaveShadowOffset,
      geometricWaveShadowSoftness: row.geometricWaveShadowSoftness,
      geometricWaveShadowStrength: row.geometricWaveShadowStrength,
      geometricWavePopBrightnessVariance:
          row.geometricWavePopBrightnessVariance,
      geometricWaveTiltAmount: row.geometricWaveTiltAmount,
      geometricWaveTiltShading: row.geometricWaveTiltShading,
      geometricWaveMassLagSeconds: row.geometricWaveMassLagSeconds,
      geometricWaveMassSpring: row.geometricWaveMassSpring,
      geometricWaveScatterMode: row.geometricWaveScatterMode,
      geometricWaveScatterLitAmount: row.geometricWaveScatterLitAmount,
      weatherForecastJson: row.weatherForecastJson,
      weatherChartTempColor: row.weatherChartTempColor,
      weatherChartRainColor: row.weatherChartRainColor,
      weatherChartCurveTension: row.weatherChartCurveTension,
      journalEntryListWidth: row.journalEntryListWidth,
      navPageOrder: row.navPageOrderJson == null
          ? null
          : List<String>.from(jsonDecode(row.navPageOrderJson!) as List),
      minorPetalColors: row.minorPetalColorsJson == null
          ? const []
          : List<int>.from(jsonDecode(row.minorPetalColorsJson!) as List),
      startupPageMode: StartupPageMode.values.byName(row.startupPageMode),
      customStartupPage: row.customStartupPage,
      lastSeenNavPage: row.lastSeenNavPage,
      todoCompletedSectionExpanded: row.todoCompletedSectionExpanded,
      showAnnualizedSubscriptionCost: row.showAnnualizedSubscriptionCost,
      colorPalette: decodeColorPaletteJson(row.colorPaletteJson),
      dreamSplitWidth: row.dreamSplitWidth,
      showDreamStatistics: row.showDreamStatistics,
      dreamNotesPinned: row.dreamNotesPinned,
    );
  }

  @override
  Future<void> saveSettings(AppSettings settings) async {
    await _db
        .into(_db.settingsTable)
        .insertOnConflictUpdate(
          SettingsTableCompanion(
            id: const Value(1),
            accentColor: Value(settings.accentColor),
            themeMode: Value(settings.themeMode.name),
            petalColor: Value(settings.petalColor),
            minorPetalColorsJson: Value(
              settings.minorPetalColors.isEmpty
                  ? null
                  : jsonEncode(settings.minorPetalColors),
            ),
            petalMaxCount: Value(settings.petalMaxCount),
            petalFallSpeed: Value(settings.petalFallSpeed),
            petalWindFrequency: Value(settings.petalWindFrequency),
            petalWindStrength: Value(settings.petalWindStrength),
            weekStartsOnMonday: Value(settings.weekStartsOnMonday),
            showQuotes: Value(settings.showQuotes),
            showDefaultTrackersInGrid:
                Value(settings.showDefaultTrackersInGrid),
            showDefaultTrackersInCalendar:
                Value(settings.showDefaultTrackersInCalendar),
            journalHotkey: Value(settings.journalHotkey),
            todoHotkey: Value(settings.todoHotkey),
            calendarNavigateLeftKey: Value(settings.calendarNavigateLeftKey),
            calendarNavigateRightKey: Value(settings.calendarNavigateRightKey),
            timelineModeYearZero: Value(settings.timelineModeYearZero),
            birthYear: Value(settings.birthYear),
            alertOnPeriodicPrompts: Value(settings.alertOnPeriodicPrompts),
            alertTimeHour: Value(settings.alertTimeHour),
            hideCompletedTasks: Value(settings.hideCompletedTasks),
            deviceId: Value(settings.deviceId),
            lastViewedJournalId: Value(settings.lastViewedJournalId),
            lastViewedTodoListId: Value(settings.lastViewedTodoListId),
            weatherLocationLabel: Value(settings.weatherLocationLabel),
            weatherLat: Value(settings.weatherLat),
            weatherLon: Value(settings.weatherLon),
            weatherIcon: Value(settings.weatherIcon),
            weatherFetchedAt: Value(settings.weatherFetchedAt),
            weatherConditionCode: Value(settings.weatherConditionCode),
            weatherTempC: Value(settings.weatherTempC),
            weatherLocationUpdatedAt: Value(settings.weatherLocationUpdatedAt),
            devUseDirectOpenWeather: Value(settings.devUseDirectOpenWeather),
            devOpenWeatherApiKey: Value(settings.devOpenWeatherApiKey),
            devShowSyncLocalSaves: Value(settings.devShowSyncLocalSaves),
            devShowSyncUploads: Value(settings.devShowSyncUploads),
            devShowSyncDownloads: Value(settings.devShowSyncDownloads),
            devShowCacheStatus: Value(settings.devShowCacheStatus),
            devShowCalendarZoomPrewarm: Value(settings.devShowCalendarZoomPrewarm),
            devShowCalendarInstantViewSwitch:
                Value(settings.devShowCalendarInstantViewSwitch),
            devSlowCalendarAnimations: Value(settings.devSlowCalendarAnimations),
            devTodoSortDebugLog: Value(settings.devTodoSortDebugLog),
            devJournalDebugLog: Value(settings.devJournalDebugLog),
            devForceConflictUi: Value(settings.devForceConflictUi),
            devShowConflictDocumentIds:
                Value(settings.devShowConflictDocumentIds),
            devShowJournalRemotePullButton:
                Value(settings.devShowJournalRemotePullButton),
            devShowFpsCounter: Value(settings.devShowFpsCounter),
            devDisableCache: Value(settings.devDisableCache),
            geometricTextureScale: Value(settings.geometricTextureScale),
            geometricTextureIntensity: Value(settings.geometricTextureIntensity),
            geometricTextureFocalSpread:
                Value(settings.geometricTextureFocalSpread),
            geometricTextureFocalPointX:
                Value(settings.geometricTextureFocalPointX),
            geometricTextureFocalPointY:
                Value(settings.geometricTextureFocalPointY),
            geometricTextureVariationFloor:
                Value(settings.geometricTextureVariationFloor),
            geometricWaveEnabled: Value(settings.geometricWaveEnabled),
            geometricWaveShape: Value(settings.geometricWaveShape.name),
            geometricWaveDirectionDegrees:
                Value(settings.geometricWaveDirectionDegrees),
            geometricWaveSpeed: Value(settings.geometricWaveSpeed),
            geometricWaveWidth: Value(settings.geometricWaveWidth),
            geometricWavePeriod: Value(settings.geometricWavePeriod),
            geometricWavePopHoldSeconds:
                Value(settings.geometricWavePopHoldSeconds),
            geometricWavePopScale: Value(settings.geometricWavePopScale),
            geometricWavePopBrightness:
                Value(settings.geometricWavePopBrightness),
            geometricWaveMaskDensity: Value(settings.geometricWaveMaskDensity),
            geometricWaveMaskClusterScale:
                Value(settings.geometricWaveMaskClusterScale),
            geometricWaveTwinkleSparsity:
                Value(settings.geometricWaveTwinkleSparsity),
            geometricWaveShadowLightDegrees:
                Value(settings.geometricWaveShadowLightDegrees),
            geometricWaveShadowOffset:
                Value(settings.geometricWaveShadowOffset),
            geometricWaveShadowSoftness:
                Value(settings.geometricWaveShadowSoftness),
            geometricWaveShadowStrength:
                Value(settings.geometricWaveShadowStrength),
            geometricWavePopBrightnessVariance:
                Value(settings.geometricWavePopBrightnessVariance),
            geometricWaveTiltAmount: Value(settings.geometricWaveTiltAmount),
            geometricWaveTiltShading: Value(settings.geometricWaveTiltShading),
            geometricWaveMassLagSeconds:
                Value(settings.geometricWaveMassLagSeconds),
            geometricWaveMassSpring: Value(settings.geometricWaveMassSpring),
            geometricWaveScatterMode:
                Value(settings.geometricWaveScatterMode),
            geometricWaveScatterLitAmount:
                Value(settings.geometricWaveScatterLitAmount),
            weatherForecastJson: Value(settings.weatherForecastJson),
            weatherChartTempColor: Value(settings.weatherChartTempColor),
            weatherChartRainColor: Value(settings.weatherChartRainColor),
            weatherChartCurveTension: Value(settings.weatherChartCurveTension),
            journalEntryListWidth: Value(settings.journalEntryListWidth),
            navPageOrderJson: Value(
              settings.navPageOrder == null
                  ? null
                  : jsonEncode(settings.navPageOrder),
            ),
            startupPageMode: Value(settings.startupPageMode.name),
            customStartupPage: Value(settings.customStartupPage),
            lastSeenNavPage: Value(settings.lastSeenNavPage),
            todoCompletedSectionExpanded:
                Value(settings.todoCompletedSectionExpanded),
            showAnnualizedSubscriptionCost:
                Value(settings.showAnnualizedSubscriptionCost),
            colorPaletteJson: Value(
              encodeColorPaletteJson(settings.colorPalette),
            ),
            dreamSplitWidth: Value(settings.dreamSplitWidth),
            showDreamStatistics: Value(settings.showDreamStatistics),
            dreamNotesPinned: Value(settings.dreamNotesPinned),
          ),
        );
  }

  @override
  Future<Map<String, int>> getTagColors() async {
    final rows = await _db.select(_db.tagColorsTable).get();
    return {for (final r in rows) r.tag: r.colorValue};
  }

  @override
  Future<void> setTagColor(String tag, int colorValue) async {
    await _db
        .into(_db.tagColorsTable)
        .insertOnConflictUpdate(
          TagColorsTableCompanion(
            tag: Value(tag),
            colorValue: Value(colorValue),
          ),
        );
  }
}

class DriftSyncConflictRepository implements SyncConflictRepository {
  DriftSyncConflictRepository(this._db);

  final AppDatabase _db;

  @override
  Future<List<SyncConflict>> listConflicts() async {
    final rows = await (_db.select(_db.syncConflictsTable)
          ..orderBy([(t) => OrderingTerm.desc(t.detectedAt)]))
        .get();
    return rows.map(_map).toList();
  }

  @override
  Future<SyncConflict?> getConflict(String id) async {
    final row = await (_db.select(_db.syncConflictsTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _map(row);
  }

  @override
  Future<void> upsertConflict(SyncConflict conflict) async {
    await _db.into(_db.syncConflictsTable).insertOnConflictUpdate(
          SyncConflictsTableCompanion(
            id: Value(conflict.id),
            collection: Value(conflict.collection),
            documentId: Value(conflict.documentId),
            localPayloadJson: Value(conflict.localPayloadJson),
            remotePayloadJson: Value(conflict.remotePayloadJson),
            localTitle: Value(conflict.localTitle),
            remoteTitle: Value(conflict.remoteTitle),
            localText: Value(conflict.localText),
            remoteText: Value(conflict.remoteText),
            detectedAt: Value(conflict.detectedAt),
          ),
        );
  }

  @override
  Future<void> deleteConflict(String id) async {
    await (_db.delete(_db.syncConflictsTable)..where((t) => t.id.equals(id)))
        .go();
  }

  @override
  Future<void> deleteConflictsForDocument(
    String collection,
    String documentId,
  ) async {
    await (_db.delete(_db.syncConflictsTable)
          ..where(
            (t) =>
                t.collection.equals(collection) &
                t.documentId.equals(documentId),
          ))
        .go();
  }

  SyncConflict _map(SyncConflictsTableData row) => SyncConflict(
    id: row.id,
    collection: row.collection,
    documentId: row.documentId,
    localPayloadJson: row.localPayloadJson,
    remotePayloadJson: row.remotePayloadJson,
    localTitle: row.localTitle,
    remoteTitle: row.remoteTitle,
    localText: row.localText,
    remoteText: row.remoteText,
    detectedAt: row.detectedAt,
  );
}
