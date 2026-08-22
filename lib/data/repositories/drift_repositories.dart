import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:voyager/core/constants/job_constants.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/spellcheck/word_token.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/soft_delete_policy.dart';
import 'package:voyager/core/sync/sync_activity.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/models/sync_conflict.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/models/workout_models.dart';
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
            showMood: Value(journal.showMood),
            showWeather: Value(journal.showWeather),
            showQuotes: Value(journal.showQuotes),
            includeInAllView: Value(journal.includeInAllView),
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

  /// One statement, and [version] is bumped with it — same reasoning as
  /// [softDeleteEntry], which these rows are pushed the same way as. Written
  /// as raw SQL because a drift companion can only carry literal values, and
  /// `version + 1` is an expression over the existing row.
  @override
  Future<void> softDeleteEntriesInJournal(String journalId) async {
    final now = utcNow();
    await _db.customUpdate(
      'UPDATE journal_entries_table '
      'SET deleted_at = ?, updated_at = ?, version = version + 1 '
      'WHERE journal_id = ?',
      variables: [
        Variable.withDateTime(now),
        Variable.withDateTime(now),
        Variable.withString(journalId),
      ],
      updates: {_db.journalEntriesTable},
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

  /// Bumps [version] for the same reason [softDeleteEntriesInJournal] does:
  /// these rows are pushed straight after this runs, and a payload that does
  /// not outrank the remote copy is dropped by the next device to pull.
  @override
  Future<void> reassignEntriesJournal(
    String fromJournalId,
    String toJournalId,
  ) async {
    await _db.customUpdate(
      'UPDATE journal_entries_table '
      'SET journal_id = ?, updated_at = ?, version = version + 1 '
      'WHERE journal_id = ?',
      variables: [
        Variable.withString(toJournalId),
        Variable.withDateTime(utcNow()),
        Variable.withString(fromJournalId),
      ],
      updates: {_db.journalEntriesTable},
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

  /// Bumps [version] along with [deletedAt], so the tombstone the row holds is
  /// newer than whatever the remote copy already has.
  ///
  /// Leaving the version alone made the delete losable: the pushed tombstone
  /// carries version N+1 (`copyWith` bumps it), the local row stayed at N, and
  /// the next device to pull compared its own higher version against the
  /// tombstone's, decided the remote had lost, and pushed a live row back —
  /// resurrecting the entry everywhere.
  @override
  Future<void> softDeleteEntry(String id) async {
    final current = await getEntry(id);
    if (current == null) return;
    await upsertEntry(current.copyWith(deletedAt: utcNow()));
  }

  @override
  Future<void> hardDeleteEntry(String id) async {
    await (_db.delete(
      _db.journalEntriesTable,
    )..where((t) => t.id.equals(id))).go();
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    // One statement per table rather than reading every row into Dart to
    // decide. `deletedAt <= cutoff` is the same rule [SoftDeletePolicy.isExpired]
    // applies, and SQLite can evaluate it without materialising — and JSON
    // decoding — the whole table on the UI isolate during the app's first
    // seconds. A NULL `deletedAt` never satisfies the comparison, so live rows
    // are excluded for free.
    final cutoff = _policy.purgeCutoff(now);
    await (_db.delete(_db.journalEntriesTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.journalsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
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
    showMood: row.showMood,
    showWeather: row.showWeather,
    showQuotes: row.showQuotes,
    includeInAllView: row.includeInAllView,
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
    await (_db.delete(_db.dreamEntriesTable)
          ..where(
            (t) => t.deletedAt.isSmallerOrEqualValue(_policy.purgeCutoff(now)),
          ))
        .go();
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

class DriftLeetCodeRepository implements LeetCodeRepository {
  DriftLeetCodeRepository(this._db, {this._syncActivity});

  final AppDatabase _db;
  final SyncActivityController? _syncActivity;
  final _policy = const SoftDeletePolicy();

  @override
  Future<List<LeetCodeProblem>> listProblems({
    bool includeDeleted = false,
  }) async {
    final query = _db.select(_db.leetCodeProblemsTable)
      ..orderBy([
        (t) => OrderingTerm.desc(t.solvedAt),
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.desc(t.id),
      ]);
    final rows = await query.get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapProblem)
        .toList();
  }

  @override
  Future<LeetCodeProblem?> getProblem(String id) async {
    final row = await (_db.select(
      _db.leetCodeProblemsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapProblem(row);
  }

  @override
  Future<void> upsertProblem(
    LeetCodeProblem problem, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.leetCodeProblemsTable)
        .insertOnConflictUpdate(
          LeetCodeProblemsTableCompanion(
            id: Value(problem.id),
            questionId: Value(problem.questionId),
            questionFrontendId: Value(problem.questionFrontendId),
            title: Value(problem.title),
            titleSlug: Value(problem.titleSlug),
            difficulty: Value(problem.difficulty.name),
            tagsJson: Value(jsonEncode(problem.tags)),
            description: Value(problem.description),
            examplesJson: Value(jsonEncode(problem.examples)),
            solutionsJson: Value(
              jsonEncode([for (final s in problem.solutions) s.toJson()]),
            ),
            // The legacy single-solution columns, kept in step with solution 1
            // rather than left at whatever they held before this problem grew
            // alternatives. Nothing reads them; see the table definition.
            algorithm: Value(problem.primarySolution?.algorithm ?? ''),
            timeComplexity: Value(problem.primarySolution?.timeComplexity),
            spaceComplexity: Value(problem.primarySolution?.spaceComplexity),
            explanation: Value(problem.primarySolution?.explanation ?? ''),
            codeLanguage: Value(problem.codeLanguage),
            code: Value(problem.primarySolution?.code ?? ''),
            notes: Value(problem.primarySolution?.notes),
            solvedAt: Value(problem.solvedAt),
            interval: Value(problem.interval),
            ease: Value(problem.ease),
            dueAt: Value(problem.dueAt),
            reviewCount: Value(problem.reviewCount),
            createdAt: Value(problem.createdAt),
            updatedAt: Value(problem.updatedAt),
            version: Value(problem.version),
            deletedAt: Value(problem.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.leetcodeProblems);
    }
  }

  @override
  Future<void> softDeleteProblem(String id) async {
    await (_db.update(
      _db.leetCodeProblemsTable,
    )..where((t) => t.id.equals(id))).write(
      LeetCodeProblemsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.leetcodeProblems);
  }

  @override
  Future<void> hardDeleteProblem(String id) async {
    await (_db.delete(
      _db.leetCodeProblemsTable,
    )..where((t) => t.id.equals(id))).go();
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    await (_db.delete(_db.leetCodeProblemsTable)
          ..where(
            (t) => t.deletedAt.isSmallerOrEqualValue(_policy.purgeCutoff(now)),
          ))
        .go();
  }

  @override
  Future<List<LeetCodeProblem>> getAllProblems({
    bool includeDeleted = true,
  }) async {
    final rows = await _db.select(_db.leetCodeProblemsTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapProblem)
        .toList();
  }

  LeetCodeProblem _mapProblem(LeetCodeProblemsTableData row) => LeetCodeProblem(
    id: row.id,
    questionId: row.questionId,
    questionFrontendId: row.questionFrontendId,
    title: row.title,
    titleSlug: row.titleSlug,
    difficulty: LeetCodeDifficulty.values.byName(row.difficulty),
    tags: List<String>.from(jsonDecode(row.tagsJson) as List),
    description: row.description,
    examples: List<String>.from(jsonDecode(row.examplesJson) as List),
    solutions: LeetCodeSolution.listFromJson(
      jsonDecode(row.solutionsJson) as List,
    ),
    solvedAt: row.solvedAt,
    interval: row.interval,
    ease: row.ease,
    dueAt: row.dueAt,
    reviewCount: row.reviewCount,
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
            includeInAllView: r.includeInAllView,
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
            includeInAllView: Value(list.includeInAllView),
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
    recurrence: RecurrenceRule.parse(r.recurrence),
    recurrenceAnchor: r.recurrenceAnchor,
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
            recurrence: Value(task.recurrence.toStorage()),
            recurrenceAnchor: Value(task.recurrenceAnchor),
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
              recurrence: Value(task.recurrence.toStorage()),
              recurrenceAnchor: Value(task.recurrenceAnchor),
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
    final cutoff = _policy.purgeCutoff(now);
    await (_db.delete(_db.todoListsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.todoTasksTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
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
  DriftCalendarRepository(this._db, {SyncedWriteNotifier? syncedWrites})
    : _syncedWrites = syncedWrites;

  final AppDatabase _db;
  final SyncedWriteNotifier? _syncedWrites;
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
  Future<Calendar?> getCalendar(String id) async {
    final row = await (_db.select(
      _db.calendarsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapCalendar(row);
  }

  @override
  Future<void> upsertCalendar(
    Calendar calendar, {
    bool recordLocalActivity = true,
  }) async {
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
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.calendars, calendar);
    }
  }

  // Soft deletes read-modify-write through the model rather than issuing a
  // bare UPDATE, so the row's version advances with the tombstone. A delete
  // that left version behind would lose to any concurrent edit from another
  // device under version-first conflict resolution.
  @override
  Future<void> softDeleteCalendar(String id) async {
    final calendar = await getCalendar(id);
    if (calendar == null) return;
    await upsertCalendar(calendar.copyWith(deletedAt: utcNow()));
  }

  @override
  Future<void> softDeleteEventsInCalendar(String calendarId) async {
    final events = await listEvents(calendarId: calendarId);
    final now = utcNow();
    for (final event in events) {
      await upsertEvent(event.copyWith(deletedAt: now));
    }
  }

  @override
  Future<void> reassignEventsCalendar(
    String fromCalendarId,
    String toCalendarId,
  ) async {
    final events = await listEvents(
      calendarId: fromCalendarId,
      includeDeleted: true,
    );
    for (final event in events) {
      await upsertEvent(event.copyWith(calendarId: toCalendarId));
    }
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
  Future<CalendarEvent?> getEvent(String id) async {
    final row = await (_db.select(
      _db.calendarEventsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapEvent(row);
  }

  @override
  Future<void> upsertEvent(
    CalendarEvent event, {
    bool recordLocalActivity = true,
  }) async {
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
            recurrence: Value(event.recurrence.toStorage()),
            recurrenceEndDate: Value(event.recurrenceEndDate),
            exceptionDates: Value(encodeExceptionDates(event.exceptionDates)),
            recurrenceParentId: Value(event.recurrenceParentId),
            recurrenceDate: Value(event.recurrenceDate),
            createdAt: Value(event.createdAt),
            updatedAt: Value(event.updatedAt),
            version: Value(event.version),
            deletedAt: Value(event.deletedAt),
          ),
        );
    // Google-imported events are re-derived from Google on each device by
    // [replaceGoogleEvents], which wipes and rebuilds them wholesale. Syncing
    // them would put that wipe in a fight with the pull that restores them.
    if (recordLocalActivity && event.source != EventSource.google) {
      _syncedWrites?.notifyOne(FirestoreCollections.calendarEvents, event);
    }
  }

  @override
  Future<void> softDeleteEvent(String id) async {
    final event = await getEvent(id);
    if (event == null) return;
    await upsertEvent(event.copyWith(deletedAt: utcNow()));
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
    final cutoff = _policy.purgeCutoff(now);
    await (_db.delete(_db.calendarEventsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.calendarsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
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
    recurrence: recurrenceFromStorage(row.recurrence),
    recurrenceEndDate: row.recurrenceEndDate,
    exceptionDates: decodeExceptionDates(row.exceptionDates),
    recurrenceParentId: row.recurrenceParentId,
    recurrenceDate: row.recurrenceDate,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );
}

class DriftTrackerRepository implements TrackerRepository {
  DriftTrackerRepository(this._db, {SyncedWriteNotifier? syncedWrites})
    : _syncedWrites = syncedWrites;

  final AppDatabase _db;
  final SyncedWriteNotifier? _syncedWrites;
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
  Future<StatisticTracker?> getTracker(String id) async {
    final row = await (_db.select(
      _db.trackersTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapTracker(row);
  }

  @override
  Future<void> upsertTracker(
    StatisticTracker tracker, {
    bool recordLocalActivity = true,
  }) async {
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
            version: Value(tracker.version),
            deletedAt: Value(tracker.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.trackers, tracker);
    }
  }

  @override
  Future<void> softDeleteTracker(String id) async {
    final tracker = await getTracker(id);
    if (tracker == null) return;
    await upsertTracker(tracker.copyWith(deletedAt: utcNow()));
  }

  @override
  Future<List<TrackerValue>> listValues(
    String trackerId, {
    bool includeDeleted = false,
  }) async {
    final rows = await (_db.select(_db.trackerValuesTable)..where(
          (t) => includeDeleted
              ? t.trackerId.equals(trackerId)
              : t.trackerId.equals(trackerId) & t.deletedAt.isNull(),
        ))
        .get();
    return rows.map(_mapValue).toList();
  }

  @override
  Future<TrackerValue?> getValue(String id) async {
    final row = await (_db.select(
      _db.trackerValuesTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapValue(row);
  }

  @override
  Future<void> upsertValue(
    TrackerValue value, {
    bool recordLocalActivity = true,
  }) async {
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
            version: Value(value.version),
            deletedAt: Value(value.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.trackerValues, value);
    }
  }

  @override
  Future<void> softDeleteValue(String id) async {
    final value = await getValue(id);
    if (value == null) return;
    await upsertValue(value.copyWith(deletedAt: utcNow()));
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final cutoff = _policy.purgeCutoff(now);
    await (_db.delete(_db.trackersTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.trackerValuesTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
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
    version: row.version,
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
    version: row.version,
    deletedAt: row.deletedAt,
  );
}

class DriftNotificationRepository implements NotificationRepository {
  DriftNotificationRepository(this._db, {SyncedWriteNotifier? syncedWrites})
    : _syncedWrites = syncedWrites;

  final AppDatabase _db;
  final SyncedWriteNotifier? _syncedWrites;
  final _policy = const SoftDeletePolicy();

  @override
  Future<List<PinnedNote>> listPinnedNotes({bool includeDeleted = false}) async {
    final rows =
        await (_db.select(_db.pinnedNotesTable)
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapNote)
        .toList();
  }

  @override
  Future<PinnedNote?> getPinnedNote(String id) async {
    final row = await (_db.select(
      _db.pinnedNotesTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapNote(row);
  }

  @override
  Future<void> upsertPinnedNote(
    PinnedNote note, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.pinnedNotesTable)
        .insertOnConflictUpdate(
          PinnedNotesTableCompanion(
            id: Value(note.id),
            body: Value(note.text),
            createdAt: Value(note.createdAt),
            updatedAt: Value(note.updatedAt),
            version: Value(note.version),
            deletedAt: Value(note.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.pinnedNotes, note);
    }
  }

  @override
  Future<void> deletePinnedNote(String id) async {
    final note = await getPinnedNote(id);
    if (note == null) return;
    await upsertPinnedNote(
      note.copyWith(
        updatedAt: utcNow(),
        version: note.version + 1,
        deletedAt: utcNow(),
      ),
    );
  }

  @override
  Future<Set<String>> listDismissals() async {
    final rows = await _db.select(_db.dismissedNotificationsTable).get();
    return rows.where((r) => r.deletedAt == null).map((r) => r.id).toSet();
  }

  @override
  Future<List<DismissedNotification>> listDismissalRecords() async {
    final rows = await _db.select(_db.dismissedNotificationsTable).get();
    return rows.map(_mapDismissal).toList();
  }

  @override
  Future<DismissedNotification?> getDismissal(String dismissalKey) async {
    final row = await (_db.select(
      _db.dismissedNotificationsTable,
    )..where((t) => t.id.equals(dismissalKey))).getSingleOrNull();
    return row == null ? null : _mapDismissal(row);
  }

  @override
  Future<void> dismiss(String dismissalKey) async {
    final existing = await getDismissal(dismissalKey);
    await upsertDismissal(
      DismissedNotification(
        key: dismissalKey,
        dismissedAt: utcNow(),
        updatedAt: utcNow(),
        version: (existing?.version ?? -1) + 1,
      ),
    );
  }

  /// Un-dismissing tombstones the row rather than deleting it, so the other
  /// devices hear "no longer dismissed" instead of never hearing anything.
  @override
  Future<void> undismiss(String dismissalKey) async {
    final existing = await getDismissal(dismissalKey);
    if (existing == null) return;
    await upsertDismissal(
      DismissedNotification(
        key: dismissalKey,
        dismissedAt: existing.dismissedAt,
        updatedAt: utcNow(),
        version: existing.version + 1,
        deletedAt: utcNow(),
      ),
    );
  }

  @override
  Future<void> upsertDismissal(
    DismissedNotification dismissal, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.dismissedNotificationsTable)
        .insertOnConflictUpdate(
          DismissedNotificationsTableCompanion(
            id: Value(dismissal.key),
            dismissedAt: Value(dismissal.dismissedAt),
            updatedAt: Value(dismissal.updatedAt),
            version: Value(dismissal.version),
            deletedAt: Value(dismissal.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(
        FirestoreCollections.dismissedNotifications,
        dismissal,
      );
    }
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final cutoff = _policy.purgeCutoff(now);
    await (_db.delete(_db.pinnedNotesTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.dismissedNotificationsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
  }

  PinnedNote _mapNote(PinnedNotesTableData row) => PinnedNote(
    id: row.id,
    text: row.body,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  DismissedNotification _mapDismissal(DismissedNotificationsTableData row) =>
      DismissedNotification(
        key: row.id,
        dismissedAt: row.dismissedAt,
        updatedAt: row.updatedAt,
        version: row.version,
        deletedAt: row.deletedAt,
      );
}

class DriftBucketListRepository implements BucketListRepository {
  DriftBucketListRepository(this._db, {SyncedWriteNotifier? syncedWrites})
    : _syncedWrites = syncedWrites;

  final AppDatabase _db;
  final SyncedWriteNotifier? _syncedWrites;
  final _policy = const SoftDeletePolicy();

  @override
  Future<List<BucketListItem>> listItems({bool includeDeleted = false}) async {
    final rows =
        await (_db.select(_db.bucketListItemsTable)
              ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
            .get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_map)
        .toList();
  }

  @override
  Future<BucketListItem?> getItem(String id) async {
    final row = await (_db.select(
      _db.bucketListItemsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _map(row);
  }

  @override
  Future<void> upsertItem(
    BucketListItem item, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.bucketListItemsTable)
        .insertOnConflictUpdate(
          BucketListItemsTableCompanion(
            id: Value(item.id),
            title: Value(item.title),
            note: Value(item.note),
            completed: Value(item.completed),
            completedAt: Value(item.completedAt),
            sortOrder: Value(item.sortOrder),
            createdAt: Value(item.createdAt),
            updatedAt: Value(item.updatedAt),
            version: Value(item.version),
            deletedAt: Value(item.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.bucketListItems, item);
    }
  }

  @override
  Future<void> deleteItem(String id) async {
    final item = await getItem(id);
    if (item == null) return;
    await upsertItem(
      item.copyWith(
        updatedAt: utcNow(),
        version: item.version + 1,
        deletedAt: utcNow(),
      ),
    );
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    await (_db.delete(_db.bucketListItemsTable)
          ..where(
            (t) => t.deletedAt.isSmallerOrEqualValue(_policy.purgeCutoff(now)),
          ))
        .go();
  }

  BucketListItem _map(BucketListItemsTableData row) => BucketListItem(
    id: row.id,
    title: row.title,
    note: row.note,
    completed: row.completed,
    completedAt: row.completedAt,
    sortOrder: row.sortOrder,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );
}

class DriftFinanceRepository implements FinanceRepository {
  DriftFinanceRepository(this._db, {SyncedWriteNotifier? syncedWrites})
    : _syncedWrites = syncedWrites;

  final AppDatabase _db;
  final SyncedWriteNotifier? _syncedWrites;
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
  Future<void> upsertTransaction(
    FinancialTransaction transaction, {
    bool recordLocalActivity = true,
  }) async {
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
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.transactions, transaction);
    }
  }

  @override
  Future<void> softDeleteTransaction(String id) async {
    final row = await (_db.select(
      _db.transactionsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;
    final transaction = _map(row);
    await upsertTransaction(
      transaction.copyWith(
        updatedAt: utcNow(),
        version: transaction.version + 1,
        deletedAt: utcNow(),
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
  Future<void> upsertSubscription(
    Subscription subscription, {
    bool recordLocalActivity = true,
  }) async {
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
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.subscriptions, subscription);
    }
  }

  @override
  Future<void> softDeleteSubscription(String id) async {
    final row = await (_db.select(
      _db.subscriptionsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;
    final subscription = _mapSubscription(row);
    await upsertSubscription(
      subscription.copyWith(
        updatedAt: utcNow(),
        version: subscription.version + 1,
        deletedAt: utcNow(),
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
  Future<void> upsertBudget(
    Budget budget, {
    bool recordLocalActivity = true,
  }) async {
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
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.budgets, budget);
    }
  }

  @override
  Future<void> softDeleteBudget(String id) async {
    final row = await (_db.select(
      _db.budgetsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;
    final budget = _mapBudget(row);
    await upsertBudget(
      budget.copyWith(
        updatedAt: utcNow(),
        version: budget.version + 1,
        deletedAt: utcNow(),
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
  Future<void> upsertCategory(
    FinanceCategory category, {
    bool recordLocalActivity = true,
  }) async {
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
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.financeCategories, category);
    }
  }

  @override
  Future<void> softDeleteCategory(String id) async {
    final row = await (_db.select(
      _db.financeCategoriesTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;
    final category = _mapCategory(row);
    await upsertCategory(
      category.copyWith(
        updatedAt: utcNow(),
        version: category.version + 1,
        deletedAt: utcNow(),
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
  Future<void> upsertAsset(
    Asset asset, {
    bool recordLocalActivity = true,
  }) async {
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
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.assets, asset);
    }
  }

  @override
  Future<void> softDeleteAsset(String id) async {
    final row = await (_db.select(
      _db.assetsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;
    final asset = _mapAsset(row);
    await upsertAsset(
      asset.copyWith(
        updatedAt: utcNow(),
        version: asset.version + 1,
        deletedAt: utcNow(),
      ),
    );
    // Tombstone the asset's valuations too, so a deleted asset stops
    // contributing to historical net-worth points. One row at a time rather
    // than a bulk UPDATE, so each tombstone carries its own version bump and
    // reaches the user's other devices.
    for (final valuation in await listAssetValuations(assetId: id)) {
      await upsertAssetValuation(
        valuation.copyWith(
          updatedAt: utcNow(),
          version: valuation.version + 1,
          deletedAt: utcNow(),
        ),
      );
    }
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
  Future<void> upsertAssetValuation(
    AssetValuation valuation, {
    bool recordLocalActivity = true,
  }) async {
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
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.assetValuations, valuation);
    }
  }

  @override
  Future<void> softDeleteAssetValuation(String id) async {
    final row = await (_db.select(
      _db.assetValuationsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;
    final assetValuation = _mapValuation(row);
    await upsertAssetValuation(
      assetValuation.copyWith(
        updatedAt: utcNow(),
        version: assetValuation.version + 1,
        deletedAt: utcNow(),
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
  Future<void> upsertSavingsGoal(
    SavingsGoal goal, {
    bool recordLocalActivity = true,
  }) async {
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
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.savingsGoals, goal);
    }
  }

  @override
  Future<void> softDeleteSavingsGoal(String id) async {
    final row = await (_db.select(
      _db.savingsGoalsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;
    final savingsGoal = _mapGoal(row);
    await upsertSavingsGoal(
      savingsGoal.copyWith(
        updatedAt: utcNow(),
        version: savingsGoal.version + 1,
        deletedAt: utcNow(),
      ),
    );
    // Tombstone the goal's allocations so they stop counting toward progress.
    // Row at a time, for the same reason as the asset's valuations above.
    for (final allocation in await listGoalAllocations(goalId: id)) {
      await upsertGoalAllocation(
        allocation.copyWith(
          updatedAt: utcNow(),
          version: allocation.version + 1,
          deletedAt: utcNow(),
        ),
      );
    }
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
  Future<void> upsertGoalAllocation(
    GoalAllocation allocation, {
    bool recordLocalActivity = true,
  }) async {
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
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.goalAllocations, allocation);
    }
  }

  @override
  Future<void> softDeleteGoalAllocation(String id) async {
    final row = await (_db.select(
      _db.goalAllocationsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;
    final goalAllocation = _mapAllocation(row);
    await upsertGoalAllocation(
      goalAllocation.copyWith(
        updatedAt: utcNow(),
        version: goalAllocation.version + 1,
        deletedAt: utcNow(),
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
    final cutoff = _policy.purgeCutoff(now);
    // Valuations before assets and allocations before goals, as the row-by-row
    // version did: the child rows reference the parent.
    await (_db.delete(_db.transactionsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.subscriptionsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.budgetsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.financeCategoriesTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.assetValuationsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.assetsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.goalAllocationsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.savingsGoalsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
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
  DriftSettingsRepository(this._db, {SyncedWriteNotifier? syncedWrites})
    : _syncedWrites = syncedWrites;

  final AppDatabase _db;
  final SyncedWriteNotifier? _syncedWrites;
  final _policy = const SoftDeletePolicy();

  @override
  Future<AppSettings> getSettings() async {
    final row = await (_db.select(
      _db.settingsTable,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    if (row == null) {
      const defaults = AppSettings();
      // Not a local activity: writing the default row is not the user
      // choosing anything, and treating it as one would upload untouched
      // defaults over the settings their other devices already agreed on.
      await saveSettings(defaults, recordLocalActivity: false);
      return defaults;
    }
    return _mapSettings(row);
  }

  AppSettings _mapSettings(SettingsTableData row) {
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
      birthDate: row.birthDate,
      alertOnPeriodicPrompts: row.alertOnPeriodicPrompts,
      alertTimeHour: row.alertTimeHour,
      hideCompletedTasks: row.hideCompletedTasks,
      vimModeEnabled: row.vimModeEnabled,
      snippetsEnabled: row.snippetsEnabled,
      snippetExpandKey: SnippetExpandKey.values.byName(row.snippetExpandKey),
      snippets: row.snippetsJson == null
          ? const []
          : Snippet.listFromJson(jsonDecode(row.snippetsJson!)),
      deviceId: row.deviceId,
      lastViewedJournalId: row.lastViewedJournalId,
      lastViewedTodoListId: row.lastViewedTodoListId,
      defaultJournalId: row.defaultJournalId,
      defaultTodoListId: row.defaultTodoListId,
      journalShowAllEntries: row.journalShowAllEntries,
      todoShowAllTasks: row.todoShowAllTasks,
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
      jobsHiddenColumns: row.jobsHiddenColumnsJson == null
          ? const []
          : List<String>.from(jsonDecode(row.jobsHiddenColumnsJson!) as List),
      jobsIncludeArchived: row.jobsIncludeArchived,
      startupPageMode: StartupPageMode.values.byName(row.startupPageMode),
      customStartupPage: row.customStartupPage,
      lastSeenNavPage: row.lastSeenNavPage,
      todoCompletedSectionExpanded: row.todoCompletedSectionExpanded,
      showAnnualizedSubscriptionCost: row.showAnnualizedSubscriptionCost,
      colorPalette: decodeColorPaletteJson(row.colorPaletteJson),
      dreamSplitWidth: row.dreamSplitWidth,
      showDreamStatistics: row.showDreamStatistics,
      dreamNotesPinned: row.dreamNotesPinned,
      leetcodeUsername: row.leetcodeUsername,
      showNeetCode150: row.showNeetCode150,
      leetCodeHideDifficulty: row.leetCodeHideDifficulty,
      leetCodeHideTags: row.leetCodeHideTags,
      leetCodeHideQuestionName: row.leetCodeHideQuestionName,
      leetCodeHideDescription: row.leetCodeHideDescription,
      leetCodeHideExamples: row.leetCodeHideExamples,
      leetCodeHideComplexity: row.leetCodeHideComplexity,
      leetCodeHideCode: row.leetCodeHideCode,
      srsFailKey: row.srsFailKey,
      srsHardKey: row.srsHardKey,
      srsGoodKey: row.srsGoodKey,
      srsEasyKey: row.srsEasyKey,
      weightUnit: WeightUnit.values.byName(row.weightUnit),
      workoutRestTimerEnabled: row.workoutRestTimerEnabled,
      workoutRestSeconds: row.workoutRestSeconds,
      showWorkoutsOnCalendar: row.showWorkoutsOnCalendar,
      showWorkoutStatistics: row.showWorkoutStatistics,
      updatedAt: row.updatedAt,
      syncBackfillVersion: row.syncBackfillVersion,
    );
  }

  @override
  Future<void> saveSettings(
    AppSettings settings, {
    bool recordLocalActivity = true,
  }) async {
    // Only a change to a *synced* setting moves the last-write-wins clock and
    // reaches the sync layer. Most saves are device-local — a weather refresh,
    // a dev-flag toggle, remembering which page you were on — and letting
    // those bump the clock would mean simply opening the app could overwrite a
    // preference another device changed more recently.
    final previous = await _readSettings();
    final syncedFieldsChanged =
        previous == null ||
        !_sameSyncedSettings(previous, settings);
    final effective = recordLocalActivity && syncedFieldsChanged
        ? settings.copyWith(updatedAt: utcNow())
        : settings;

    await _saveSettingsRow(effective);

    if (recordLocalActivity && syncedFieldsChanged) {
      _syncedWrites?.notifyOne(FirestoreCollections.settings, effective);
    }
  }

  bool _sameSyncedSettings(AppSettings a, AppSettings b) {
    // Compared as encoded JSON rather than field by field: the payload builder
    // is the single list of what syncs, so a field added there is covered here
    // without a second list to keep in step.
    return jsonEncode(settingsSyncPayload(a)) ==
        jsonEncode(settingsSyncPayload(b));
  }

  /// [getSettings] without the default-row insert, so [saveSettings] can ask
  /// what changed without recursing back into itself.
  ///
  /// Maps the row it just fetched instead of throwing it away and calling
  /// [getSettings], which would run the same select and the same hundred-column
  /// mapping — with its `jsonDecode`s — a second time. Settings are written far
  /// more often than the name suggests: every weather refresh, the midnight
  /// forecast prune, page-position bookkeeping, the minute timer.
  Future<AppSettings?> _readSettings() async {
    final row = await (_db.select(
      _db.settingsTable,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    if (row == null) return null;
    return _mapSettings(row);
  }

  Future<void> _saveSettingsRow(AppSettings settings) async {
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
            birthDate: Value(settings.birthDate),
            alertOnPeriodicPrompts: Value(settings.alertOnPeriodicPrompts),
            alertTimeHour: Value(settings.alertTimeHour),
            hideCompletedTasks: Value(settings.hideCompletedTasks),
            vimModeEnabled: Value(settings.vimModeEnabled),
            snippetsEnabled: Value(settings.snippetsEnabled),
            snippetExpandKey: Value(settings.snippetExpandKey.name),
            snippetsJson: Value(
              jsonEncode([for (final s in settings.snippets) s.toJson()]),
            ),
            deviceId: Value(settings.deviceId),
            lastViewedJournalId: Value(settings.lastViewedJournalId),
            lastViewedTodoListId: Value(settings.lastViewedTodoListId),
            defaultJournalId: Value(settings.defaultJournalId),
            defaultTodoListId: Value(settings.defaultTodoListId),
            journalShowAllEntries: Value(settings.journalShowAllEntries),
            todoShowAllTasks: Value(settings.todoShowAllTasks),
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
            jobsHiddenColumnsJson: Value(
              settings.jobsHiddenColumns.isEmpty
                  ? null
                  : jsonEncode(settings.jobsHiddenColumns),
            ),
            jobsIncludeArchived: Value(settings.jobsIncludeArchived),
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
            leetcodeUsername: Value(settings.leetcodeUsername),
            showNeetCode150: Value(settings.showNeetCode150),
            leetCodeHideDifficulty: Value(settings.leetCodeHideDifficulty),
            leetCodeHideTags: Value(settings.leetCodeHideTags),
            leetCodeHideQuestionName: Value(settings.leetCodeHideQuestionName),
            leetCodeHideDescription: Value(settings.leetCodeHideDescription),
            leetCodeHideExamples: Value(settings.leetCodeHideExamples),
            leetCodeHideComplexity: Value(settings.leetCodeHideComplexity),
            leetCodeHideCode: Value(settings.leetCodeHideCode),
            srsFailKey: Value(settings.srsFailKey),
            srsHardKey: Value(settings.srsHardKey),
            srsGoodKey: Value(settings.srsGoodKey),
            srsEasyKey: Value(settings.srsEasyKey),
            weightUnit: Value(settings.weightUnit.name),
            workoutRestTimerEnabled: Value(settings.workoutRestTimerEnabled),
            workoutRestSeconds: Value(settings.workoutRestSeconds),
            showWorkoutsOnCalendar: Value(settings.showWorkoutsOnCalendar),
            showWorkoutStatistics: Value(settings.showWorkoutStatistics),
            updatedAt: Value(settings.updatedAt),
            syncBackfillVersion: Value(settings.syncBackfillVersion),
          ),
        );
  }

  @override
  Future<Map<String, int>> getTagColors() async {
    final rows = await _db.select(_db.tagColorsTable).get();
    return {for (final r in rows) r.tag: r.colorValue};
  }

  @override
  Future<List<TagColorRecord>> getTagColorRecords() async {
    final rows = await _db.select(_db.tagColorsTable).get();
    return rows.map(_mapTagColor).toList();
  }

  @override
  Future<TagColorRecord?> getTagColorRecord(String tag) async {
    final row = await (_db.select(
      _db.tagColorsTable,
    )..where((t) => t.tag.equals(tag))).getSingleOrNull();
    return row == null ? null : _mapTagColor(row);
  }

  @override
  Future<void> setTagColor(String tag, int colorValue) async {
    final existing = await getTagColorRecord(tag);
    await upsertTagColor(
      TagColorRecord(
        tag: tag,
        colorValue: colorValue,
        updatedAt: utcNow(),
        version: (existing?.version ?? -1) + 1,
      ),
    );
  }

  @override
  Future<void> upsertTagColor(
    TagColorRecord tagColor, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.tagColorsTable)
        .insertOnConflictUpdate(
          TagColorsTableCompanion(
            tag: Value(tagColor.tag),
            colorValue: Value(tagColor.colorValue),
            updatedAt: Value(tagColor.updatedAt),
            version: Value(tagColor.version),
          ),
        );
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.tagColors, tagColor);
    }
  }

  @override
  Future<Set<String>> getCustomWords() async {
    final rows = await _db.select(_db.customWordsTable).get();
    return {
      for (final r in rows)
        if (r.deletedAt == null) r.word,
    };
  }

  @override
  Future<List<CustomWord>> getCustomWordRecords() async {
    final rows = await _db.select(_db.customWordsTable).get();
    return rows.map(_mapCustomWord).toList();
  }

  @override
  Future<CustomWord?> getCustomWordRecord(String word) async {
    final row = await (_db.select(
      _db.customWordsTable,
    )..where((t) => t.word.equals(word))).getSingleOrNull();
    return row == null ? null : _mapCustomWord(row);
  }

  @override
  Future<void> addCustomWord(String word) async {
    final normalized = normalizeCustomWord(word);
    if (normalized.isEmpty) return;
    final existing = await getCustomWordRecord(normalized);
    await upsertCustomWord(
      CustomWord(
        word: normalized,
        createdAt: existing?.createdAt ?? utcNow(),
        updatedAt: utcNow(),
        version: (existing?.version ?? -1) + 1,
        // Re-adding a word that was removed clears its tombstone rather than
        // leaving the row invisible.
      ),
    );
  }

  /// Removing a word tombstones it rather than dropping the row, so the
  /// removal reaches the user's other devices instead of the word coming back
  /// on their next pull.
  @override
  Future<void> removeCustomWord(String word) async {
    final normalized = normalizeCustomWord(word);
    final existing = await getCustomWordRecord(normalized);
    if (existing == null) return;
    await upsertCustomWord(
      CustomWord(
        word: normalized,
        createdAt: existing.createdAt,
        updatedAt: utcNow(),
        version: existing.version + 1,
        deletedAt: utcNow(),
      ),
    );
  }

  /// See [SettingsRepository.renameCustomWord]. Both writes go in one
  /// transaction so a crash between them can't leave the old spelling deleted
  /// with the new one never written; the two sync notifications fire after the
  /// commit, so a rolled-back rename is never uploaded.
  @override
  Future<void> renameCustomWord(String from, String to) async {
    final oldWord = normalizeCustomWord(from);
    final newWord = normalizeCustomWord(to);
    // Only the new spelling is checked: the old one is whatever is in the
    // table, and a row that predates this rule should be fixable, not stuck.
    if (oldWord == newWord || !isCustomWordToken(newWord)) return;

    CustomWord? removed;
    CustomWord? added;
    await _db.transaction(() async {
      final existing = await getCustomWordRecord(oldWord);
      if (existing == null || existing.deletedAt != null) return;
      final target = await getCustomWordRecord(newWord);
      if (target != null && target.deletedAt == null) return;

      final now = utcNow();
      final tombstone = CustomWord(
        word: oldWord,
        createdAt: existing.createdAt,
        updatedAt: now,
        version: existing.version + 1,
        deletedAt: now,
      );
      // Renaming onto a word that was removed earlier clears its tombstone,
      // exactly as re-adding it would.
      final replacement = CustomWord(
        word: newWord,
        createdAt: target?.createdAt ?? now,
        updatedAt: now,
        version: (target?.version ?? -1) + 1,
      );
      await upsertCustomWord(tombstone, recordLocalActivity: false);
      await upsertCustomWord(replacement, recordLocalActivity: false);
      removed = tombstone;
      added = replacement;
    });

    final tombstone = removed;
    final replacement = added;
    if (tombstone == null || replacement == null) return;
    // One notification carrying both: the other devices pull a deleted old doc
    // and a live new one, which is what "this spelling is gone, this spelling
    // is present" looks like on the wire.
    _syncedWrites?.notify(FirestoreCollections.customWords, [
      tombstone,
      replacement,
    ]);
  }

  @override
  Future<void> upsertCustomWord(
    CustomWord word, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.customWordsTable)
        .insertOnConflictUpdate(
          CustomWordsTableCompanion(
            word: Value(word.word),
            createdAt: Value(word.createdAt),
            updatedAt: Value(word.updatedAt),
            version: Value(word.version),
            deletedAt: Value(word.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncedWrites?.notifyOne(FirestoreCollections.customWords, word);
    }
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    await (_db.delete(_db.customWordsTable)
          ..where(
            (t) => t.deletedAt.isSmallerOrEqualValue(_policy.purgeCutoff(now)),
          ))
        .go();
  }

  TagColorRecord _mapTagColor(TagColorsTableData row) => TagColorRecord(
    tag: row.tag,
    colorValue: row.colorValue,
    updatedAt: row.updatedAt,
    version: row.version,
  );

  CustomWord _mapCustomWord(CustomWordsTableData row) => CustomWord(
    word: row.word,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  CustomQuote _mapCustomQuote(CustomQuotesTableData row) => CustomQuote(
    id: row.id,
    text: row.quote,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  @override
  Future<List<CustomQuote>> getCustomQuotes({bool includeDeleted = false}) async {
    final rows = await (_db.select(
      _db.customQuotesTable,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();
    return [
      for (final row in rows)
        if (includeDeleted || row.deletedAt == null) _mapCustomQuote(row),
    ];
  }

  @override
  Future<CustomQuote?> getCustomQuote(String id) async {
    final row = await (_db.select(
      _db.customQuotesTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapCustomQuote(row);
  }

  /// [recordLocalActivity] is accepted for symmetry with the other synced
  /// repositories (the pull path passes false) but goes unused: wiring a
  /// [SyncActivityController] in here would make settingsRepositoryProvider
  /// and syncActivityProvider depend on each other, and the controller only
  /// drives the activity indicator.
  @override
  Future<void> upsertCustomQuote(
    CustomQuote quote, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.customQuotesTable)
        .insertOnConflictUpdate(
          CustomQuotesTableCompanion(
            id: Value(quote.id),
            quote: Value(quote.text),
            createdAt: Value(quote.createdAt),
            updatedAt: Value(quote.updatedAt),
            version: Value(quote.version),
            deletedAt: Value(quote.deletedAt),
          ),
        );
  }

  @override
  Future<void> softDeleteCustomQuote(String id) async {
    final now = utcNow();
    await (_db.update(
      _db.customQuotesTable,
    )..where((t) => t.id.equals(id))).write(
      CustomQuotesTableCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
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
            reason: Value(conflict.reason?.storageValue),
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
    reason: SyncConflictReason.fromStorage(row.reason),
  );
}

class DriftStudyRepository implements StudyRepository {
  DriftStudyRepository(this._db, {SyncActivityController? syncActivity})
    : _syncActivity = syncActivity;

  final AppDatabase _db;
  final SyncActivityController? _syncActivity;
  final _policy = const SoftDeletePolicy();

  @override
  Future<List<StudyFolder>> listFolders({
    String? parentFolderId,
    bool includeDeleted = false,
  }) async {
    final rows = await _db.select(_db.studyFoldersTable).get();
    final all = rows.where((r) => includeDeleted || r.deletedAt == null).toList();
    if (parentFolderId != null) {
      return all
          .where((r) => r.parentFolderId == parentFolderId)
          .map(_mapFolder)
          .toList();
    }
    // Root level: a folder's stored parent may point at a folder that was
    // deleted (possibly on another device via CRDT sync) — render it at
    // root rather than losing it. See STUDY.md's "Ghost Parent" case.
    final validIds = all.map((r) => r.id).toSet();
    return all
        .where((r) => r.parentFolderId == null || !validIds.contains(r.parentFolderId))
        .map(_mapFolder)
        .toList();
  }

  @override
  Future<StudyFolder?> getFolder(String id) async {
    final row = await (_db.select(
      _db.studyFoldersTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapFolder(row);
  }

  @override
  Future<void> upsertFolder(
    StudyFolder folder, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.studyFoldersTable)
        .insertOnConflictUpdate(
          StudyFoldersTableCompanion(
            id: Value(folder.id),
            name: Value(folder.name),
            parentFolderId: Value(folder.parentFolderId),
            colorValue: Value(folder.colorValue),
            createdAt: Value(folder.createdAt),
            updatedAt: Value(folder.updatedAt),
            version: Value(folder.version),
            deletedAt: Value(folder.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.studyFolders);
    }
  }

  @override
  Future<void> softDeleteFolder(String id) async {
    await (_db.update(
      _db.studyFoldersTable,
    )..where((t) => t.id.equals(id))).write(
      StudyFoldersTableCompanion(deletedAt: Value(utcNow()), updatedAt: Value(utcNow())),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.studyFolders);
  }

  @override
  Future<bool> wouldCreateCycle(
    String folderId,
    String? targetParentFolderId,
  ) async {
    if (targetParentFolderId == null) return false;
    if (targetParentFolderId == folderId) return true;
    final rows = await _db.select(_db.studyFoldersTable).get();
    final byId = {for (final r in rows) r.id: r};
    String? cursor = targetParentFolderId;
    final visited = <String>{};
    while (cursor != null) {
      if (cursor == folderId) return true;
      if (!visited.add(cursor)) break;
      cursor = byId[cursor]?.parentFolderId;
    }
    return false;
  }

  @override
  Future<void> moveFolder(String folderId, String? newParentFolderId) async {
    if (await wouldCreateCycle(folderId, newParentFolderId)) {
      throw StateError('Cannot move a folder into its own descendant.');
    }
    await (_db.update(
      _db.studyFoldersTable,
    )..where((t) => t.id.equals(folderId))).write(
      StudyFoldersTableCompanion(
        parentFolderId: Value(newParentFolderId),
        updatedAt: Value(utcNow()),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.studyFolders);
  }

  @override
  Future<List<StudyDeck>> listDecks({
    String? parentFolderId,
    bool includeDeleted = false,
  }) async {
    final deckRows = await _db.select(_db.studyDecksTable).get();
    final decks = deckRows.where((r) => includeDeleted || r.deletedAt == null).toList();
    if (parentFolderId != null) {
      return decks
          .where((r) => r.parentFolderId == parentFolderId)
          .map(_mapDeck)
          .toList();
    }
    final folderRows = await _db.select(_db.studyFoldersTable).get();
    final validFolderIds = folderRows
        .where((r) => r.deletedAt == null)
        .map((r) => r.id)
        .toSet();
    return decks
        .where(
          (r) => r.parentFolderId == null || !validFolderIds.contains(r.parentFolderId),
        )
        .map(_mapDeck)
        .toList();
  }

  @override
  Future<StudyDeck?> getDeck(String id) async {
    final row = await (_db.select(
      _db.studyDecksTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapDeck(row);
  }

  @override
  Future<void> upsertDeck(StudyDeck deck, {bool recordLocalActivity = true}) async {
    await _db
        .into(_db.studyDecksTable)
        .insertOnConflictUpdate(
          StudyDecksTableCompanion(
            id: Value(deck.id),
            name: Value(deck.name),
            parentFolderId: Value(deck.parentFolderId),
            colorValue: Value(deck.colorValue),
            createdAt: Value(deck.createdAt),
            updatedAt: Value(deck.updatedAt),
            version: Value(deck.version),
            deletedAt: Value(deck.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.studyDecks);
    }
  }

  @override
  Future<void> softDeleteDeck(String id) async {
    await (_db.update(
      _db.studyDecksTable,
    )..where((t) => t.id.equals(id))).write(
      StudyDecksTableCompanion(deletedAt: Value(utcNow()), updatedAt: Value(utcNow())),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.studyDecks);
  }

  @override
  Future<void> moveDeck(String deckId, String? newParentFolderId) async {
    await (_db.update(
      _db.studyDecksTable,
    )..where((t) => t.id.equals(deckId))).write(
      StudyDecksTableCompanion(
        parentFolderId: Value(newParentFolderId),
        updatedAt: Value(utcNow()),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.studyDecks);
  }

  @override
  Future<List<StudyCard>> listCards(
    String deckId, {
    bool includeDeleted = false,
  }) async {
    final rows = await (_db.select(
      _db.studyCardsTable,
    )..where((t) => t.deckId.equals(deckId))).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapCard)
        .toList();
  }

  @override
  Future<StudyCard?> getCard(String id) async {
    final row = await (_db.select(
      _db.studyCardsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapCard(row);
  }

  @override
  Future<void> upsertCard(StudyCard card, {bool recordLocalActivity = true}) async {
    await _db
        .into(_db.studyCardsTable)
        .insertOnConflictUpdate(
          StudyCardsTableCompanion(
            id: Value(card.id),
            deckId: Value(card.deckId),
            frontText: Value(card.frontText),
            backText: Value(card.backText),
            interval: Value(card.interval),
            ease: Value(card.ease),
            dueAt: Value(card.dueAt),
            reviewCount: Value(card.reviewCount),
            createdAt: Value(card.createdAt),
            updatedAt: Value(card.updatedAt),
            version: Value(card.version),
            deletedAt: Value(card.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.studyCards);
    }
  }

  @override
  Future<void> softDeleteCard(String id) async {
    await (_db.update(
      _db.studyCardsTable,
    )..where((t) => t.id.equals(id))).write(
      StudyCardsTableCompanion(deletedAt: Value(utcNow()), updatedAt: Value(utcNow())),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.studyCards);
  }

  @override
  Future<void> moveCards(List<String> cardIds, String targetDeckId) async {
    final now = utcNow();
    for (final id in cardIds) {
      await (_db.update(
        _db.studyCardsTable,
      )..where((t) => t.id.equals(id))).write(
        StudyCardsTableCompanion(deckId: Value(targetDeckId), updatedAt: Value(now)),
      );
    }
    _syncActivity?.recordLocalSave(FirestoreCollections.studyCards);
  }

  @override
  Future<void> duplicateCards(List<String> cardIds) async {
    final now = utcNow();
    for (final id in cardIds) {
      final row = await (_db.select(
        _db.studyCardsTable,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (row == null) continue;
      await _db
          .into(_db.studyCardsTable)
          .insert(
            StudyCardsTableCompanion.insert(
              id: newId(),
              deckId: row.deckId,
              frontText: row.frontText,
              backText: row.backText,
              dueAt: now,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    _syncActivity?.recordLocalSave(FirestoreCollections.studyCards);
  }

  @override
  Future<void> logReview(StudyReviewLog log) async {
    await _db
        .into(_db.studyReviewLogTable)
        .insertOnConflictUpdate(
          StudyReviewLogTableCompanion(
            id: Value(log.id),
            cardId: Value(log.cardId),
            grade: Value(log.grade.name),
            reviewedAt: Value(log.reviewedAt),
          ),
        );
    _syncActivity?.recordLocalSave(FirestoreCollections.studyReviewLog);
  }

  @override
  Future<int> countCardsReviewedToday({DateTime? now}) async {
    final n = now ?? DateTime.now();
    final startOfDayUtc = DateTime(n.year, n.month, n.day).toUtc();
    final rows = await (_db.select(
      _db.studyReviewLogTable,
    )..where((t) => t.reviewedAt.isBiggerOrEqualValue(startOfDayUtc))).get();
    return rows.length;
  }

  @override
  Future<int> countCardsReviewedTotal() async {
    final rows = await _db.select(_db.studyReviewLogTable).get();
    return rows.length;
  }

  @override
  Future<int> countDueCards({DateTime? now}) async {
    final n = now ?? utcNow();
    final rows = await (_db.select(_db.studyCardsTable)
          ..where((t) => t.deletedAt.isNull() & t.dueAt.isSmallerOrEqualValue(n)))
        .get();
    return rows.length;
  }

  @override
  Future<int> countDueCardsInDeck(String deckId, {DateTime? now}) async {
    final n = now ?? utcNow();
    final rows = await (_db.select(_db.studyCardsTable)
          ..where(
            (t) =>
                t.deckId.equals(deckId) &
                t.deletedAt.isNull() &
                t.dueAt.isSmallerOrEqualValue(n),
          ))
        .get();
    return rows.length;
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    // Cards, then decks, then folders — children before their parents, as the
    // row-by-row version did.
    final cutoff = _policy.purgeCutoff(now);
    await (_db.delete(_db.studyCardsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.studyDecksTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.studyFoldersTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
  }

  @override
  Future<List<StudyFolder>> getAllFolders({bool includeDeleted = true}) async {
    final rows = await _db.select(_db.studyFoldersTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapFolder)
        .toList();
  }

  @override
  Future<List<StudyDeck>> getAllDecks({bool includeDeleted = true}) async {
    final rows = await _db.select(_db.studyDecksTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapDeck)
        .toList();
  }

  @override
  Future<List<StudyCard>> getAllCards({bool includeDeleted = true}) async {
    final rows = await _db.select(_db.studyCardsTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapCard)
        .toList();
  }

  @override
  Future<List<StudyReviewLog>> getAllReviewLogs() async {
    final rows = await _db.select(_db.studyReviewLogTable).get();
    return rows.map(_mapReviewLog).toList();
  }

  StudyReviewLog _mapReviewLog(StudyReviewLogTableData row) => StudyReviewLog(
    id: row.id,
    cardId: row.cardId,
    grade: StudyGrade.values.byName(row.grade),
    reviewedAt: row.reviewedAt,
  );

  StudyFolder _mapFolder(StudyFoldersTableData row) => StudyFolder(
    id: row.id,
    name: row.name,
    parentFolderId: row.parentFolderId,
    colorValue: row.colorValue,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  StudyDeck _mapDeck(StudyDecksTableData row) => StudyDeck(
    id: row.id,
    name: row.name,
    parentFolderId: row.parentFolderId,
    colorValue: row.colorValue,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  StudyCard _mapCard(StudyCardsTableData row) => StudyCard(
    id: row.id,
    deckId: row.deckId,
    frontText: row.frontText,
    backText: row.backText,
    interval: row.interval,
    ease: row.ease,
    dueAt: row.dueAt,
    reviewCount: row.reviewCount,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );
}

class DriftWorkoutRepository implements WorkoutRepository {
  DriftWorkoutRepository(this._db, {SyncActivityController? syncActivity})
    : _syncActivity = syncActivity;

  final AppDatabase _db;
  final SyncActivityController? _syncActivity;
  final _policy = const SoftDeletePolicy();

  @override
  Future<void> ensureSeeded() async {
    final planRows = await _db.select(_db.workoutPlansTable).get();
    final existingPlanIds = {for (final r in planRows) r.id};
    final now = utcNow();
    // The anchor only matters for the cycle plan, but both rows carry one so
    // the column can stay non-nullable. Today is the sensible Day 1.
    final localNow = DateTime.now();
    final today = DateTime(localNow.year, localNow.month, localNow.day);

    if (!existingPlanIds.contains(kWeeklyWorkoutPlanId)) {
      await upsertPlan(
        WorkoutPlan(
          id: kWeeklyWorkoutPlanId,
          name: 'Weekly',
          mode: WorkoutPlanMode.weekly,
          cycleAnchor: today,
          // Active out of the box: weekly is the mode the planner opens on,
          // and anything else would show an inactive plan on first launch
          // with nothing explaining why.
          isActive: true,
          createdAt: now,
          updatedAt: now,
        ),
        recordLocalActivity: false,
      );
    }
    if (!existingPlanIds.contains(kCycleWorkoutPlanId)) {
      await upsertPlan(
        WorkoutPlan(
          id: kCycleWorkoutPlanId,
          name: 'Split',
          mode: WorkoutPlanMode.cycle,
          cycleLength: 4,
          cycleAnchor: today,
          createdAt: now,
          updatedAt: now,
        ),
        recordLocalActivity: false,
      );
    }

    // Deleted rows count toward this check on purpose â€” a library the user
    // cleared out should stay cleared rather than re-seeding next launch.
    final exerciseCount = (await _db.select(_db.exercisesTable).get()).length;
    if (exerciseCount == 0) {
      for (var i = 0; i < kStarterExercises.length; i++) {
        await upsertExercise(
          Exercise(
            id: newId(),
            name: kStarterExercises[i],
            sortOrder: i,
            createdAt: now,
            updatedAt: now,
          ),
          recordLocalActivity: false,
        );
      }
    }
  }

  @override
  Future<List<Exercise>> listExercises({bool includeDeleted = false}) async {
    final rows = await _db.select(_db.exercisesTable).get();
    final exercises = rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapExercise)
        .toList();
    exercises.sort((a, b) {
      final byOrder = a.sortOrder.compareTo(b.sortOrder);
      return byOrder != 0
          ? byOrder
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return exercises;
  }

  @override
  Future<Exercise?> getExercise(String id) async {
    final row = await (_db.select(
      _db.exercisesTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapExercise(row);
  }

  @override
  Future<void> upsertExercise(
    Exercise exercise, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.exercisesTable)
        .insertOnConflictUpdate(
          ExercisesTableCompanion(
            id: Value(exercise.id),
            name: Value(exercise.name),
            formCues: Value(exercise.formCues),
            colorValue: Value(exercise.colorValue),
            sortOrder: Value(exercise.sortOrder),
            targetSets: Value(exercise.targetSets),
            targetReps: Value(exercise.targetReps),
            targetWeightKg: Value(exercise.targetWeightKg),
            createdAt: Value(exercise.createdAt),
            updatedAt: Value(exercise.updatedAt),
            version: Value(exercise.version),
            deletedAt: Value(exercise.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.exercises);
    }
  }

  @override
  Future<void> softDeleteExercise(String id) async {
    await (_db.update(
      _db.exercisesTable,
    )..where((t) => t.id.equals(id))).write(
      ExercisesTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
    // Plan entries pointing at a deleted exercise would render as blank cards,
    // so they go with it. Logged sets deliberately do not: they are history,
    // and the detail view still needs them to explain past volume.
    final entries = await (_db.select(
      _db.workoutPlanEntriesTable,
    )..where((t) => t.exerciseId.equals(id))).get();
    for (final entry in entries) {
      if (entry.deletedAt != null) continue;
      await softDeletePlanEntry(entry.id);
    }
    _syncActivity?.recordLocalSave(FirestoreCollections.exercises);
  }

  @override
  Future<List<WorkoutPlan>> listPlans({bool includeDeleted = false}) async {
    final rows = await _db.select(_db.workoutPlansTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapPlan)
        .toList();
  }

  @override
  Future<WorkoutPlan?> getPlan(String id) async {
    final row = await (_db.select(
      _db.workoutPlansTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapPlan(row);
  }

  @override
  Future<void> upsertPlan(
    WorkoutPlan plan, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.workoutPlansTable)
        .insertOnConflictUpdate(
          WorkoutPlansTableCompanion(
            id: Value(plan.id),
            name: Value(plan.name),
            mode: Value(plan.mode.name),
            cycleLength: Value(plan.cycleLength),
            cycleAnchor: Value(plan.cycleAnchor),
            isActive: Value(plan.isActive),
            createdAt: Value(plan.createdAt),
            updatedAt: Value(plan.updatedAt),
            version: Value(plan.version),
            deletedAt: Value(plan.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.workoutPlans);
    }
  }

  @override
  Future<void> setActivePlan(String planId) async {
    for (final plan in await listPlans()) {
      final shouldBeActive = plan.id == planId;
      if (plan.isActive == shouldBeActive) continue;
      await upsertPlan(
        plan.copyWith(isActive: shouldBeActive),
        recordLocalActivity: false,
      );
    }
    _syncActivity?.recordLocalSave(FirestoreCollections.workoutPlans);
  }

  @override
  Future<List<WorkoutPlanEntry>> listPlanEntries(
    String planId, {
    bool includeDeleted = false,
  }) async {
    final rows = await (_db.select(
      _db.workoutPlanEntriesTable,
    )..where((t) => t.planId.equals(planId))).get();
    final entries = rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapPlanEntry)
        .toList();
    entries.sort((a, b) {
      final byDay = a.dayIndex.compareTo(b.dayIndex);
      return byDay != 0 ? byDay : a.sortOrder.compareTo(b.sortOrder);
    });
    return entries;
  }

  @override
  Future<WorkoutPlanEntry?> getPlanEntry(String id) async {
    final row = await (_db.select(
      _db.workoutPlanEntriesTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapPlanEntry(row);
  }

  @override
  Future<void> upsertPlanEntry(
    WorkoutPlanEntry entry, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.workoutPlanEntriesTable)
        .insertOnConflictUpdate(
          WorkoutPlanEntriesTableCompanion(
            id: Value(entry.id),
            planId: Value(entry.planId),
            dayIndex: Value(entry.dayIndex),
            exerciseId: Value(entry.exerciseId),
            sortOrder: Value(entry.sortOrder),
            createdAt: Value(entry.createdAt),
            updatedAt: Value(entry.updatedAt),
            version: Value(entry.version),
            deletedAt: Value(entry.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.workoutPlanEntries);
    }
  }

  @override
  Future<void> softDeletePlanEntry(String id) async {
    await (_db.update(
      _db.workoutPlanEntriesTable,
    )..where((t) => t.id.equals(id))).write(
      WorkoutPlanEntriesTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.workoutPlanEntries);
  }

  @override
  Future<List<WorkoutSession>> listSessions({
    bool includeDeleted = false,
  }) async {
    final rows = await _db.select(_db.workoutSessionsTable).get();
    final sessions = rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapSession)
        .toList();
    sessions.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return sessions;
  }

  @override
  Future<WorkoutSession?> getSession(String id) async {
    final row = await (_db.select(
      _db.workoutSessionsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapSession(row);
  }

  @override
  Future<WorkoutSession?> getActiveSession() async {
    // listSessions is newest-started-first, so the first live row wins if a
    // sync race ever left two open at once.
    for (final session in await listSessions()) {
      if (session.isActive) return session;
    }
    return null;
  }

  @override
  Future<void> upsertSession(
    WorkoutSession session, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.workoutSessionsTable)
        .insertOnConflictUpdate(
          WorkoutSessionsTableCompanion(
            id: Value(session.id),
            planId: Value(session.planId),
            dayIndex: Value(session.dayIndex),
            date: Value(session.date),
            startedAt: Value(session.startedAt),
            endedAt: Value(session.endedAt),
            createdAt: Value(session.createdAt),
            updatedAt: Value(session.updatedAt),
            version: Value(session.version),
            deletedAt: Value(session.deletedAt),
          ),
        );
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.workoutSessions);
    }
  }

  @override
  Future<void> softDeleteSession(String id) async {
    await (_db.update(
      _db.workoutSessionsTable,
    )..where((t) => t.id.equals(id))).write(
      WorkoutSessionsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
    final logs = await (_db.select(
      _db.workoutSetLogsTable,
    )..where((t) => t.sessionId.equals(id))).get();
    for (final log in logs) {
      if (log.deletedAt != null) continue;
      await softDeleteSetLog(log.id);
    }
    _syncActivity?.recordLocalSave(FirestoreCollections.workoutSessions);
  }

  @override
  Future<List<WorkoutSetLog>> listSetLogs({
    String? sessionId,
    String? exerciseId,
    bool includeDeleted = false,
  }) async {
    final query = _db.select(_db.workoutSetLogsTable);
    if (sessionId != null) {
      query.where((t) => t.sessionId.equals(sessionId));
    }
    if (exerciseId != null) {
      query.where((t) => t.exerciseId.equals(exerciseId));
    }
    final rows = await query.get();
    final logs = rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapSetLog)
        .toList();
    logs.sort((a, b) {
      final byExercise = a.exerciseOrder.compareTo(b.exerciseOrder);
      return byExercise != 0 ? byExercise : a.setIndex.compareTo(b.setIndex);
    });
    return logs;
  }

  @override
  Future<WorkoutSetLog?> getSetLog(String id) async {
    final row = await (_db.select(
      _db.workoutSetLogsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapSetLog(row);
  }

  @override
  Future<void> upsertSetLog(
    WorkoutSetLog log, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.workoutSetLogsTable)
        .insertOnConflictUpdate(_setLogCompanion(log));
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.workoutSetLogs);
    }
  }

  @override
  Future<void> upsertSetLogsBatch(
    List<WorkoutSetLog> logs, {
    bool recordLocalActivity = true,
  }) async {
    if (logs.isEmpty) return;
    // One batched statement rather than N awaits: materialising a session
    // writes every set of every exercise at once, which is dozens of rows on
    // a big day and would otherwise land as dozens of round-trips to the
    // database isolate mid-tap.
    await _db.batch((batch) {
      for (final log in logs) {
        final companion = _setLogCompanion(log);
        batch.insert(
          _db.workoutSetLogsTable,
          companion,
          onConflict: DoUpdate((_) => companion),
        );
      }
    });
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.workoutSetLogs);
    }
  }

  @override
  Future<void> softDeleteSetLog(String id) async {
    await (_db.update(
      _db.workoutSetLogsTable,
    )..where((t) => t.id.equals(id))).write(
      WorkoutSetLogsTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.workoutSetLogs);
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    // Set logs, then sessions, then plan entries, then exercises — children
    // before their parents, as the row-by-row version did.
    final cutoff = _policy.purgeCutoff(now);
    await (_db.delete(_db.workoutSetLogsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.workoutSessionsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.workoutPlanEntriesTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.exercisesTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
  }

  @override
  Future<List<Exercise>> getAllExercises({bool includeDeleted = true}) async {
    final rows = await _db.select(_db.exercisesTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapExercise)
        .toList();
  }

  @override
  Future<List<WorkoutPlan>> getAllPlans({bool includeDeleted = true}) async {
    final rows = await _db.select(_db.workoutPlansTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapPlan)
        .toList();
  }

  @override
  Future<List<WorkoutPlanEntry>> getAllPlanEntries({
    bool includeDeleted = true,
  }) async {
    final rows = await _db.select(_db.workoutPlanEntriesTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapPlanEntry)
        .toList();
  }

  @override
  Future<List<WorkoutSession>> getAllSessions({
    bool includeDeleted = true,
  }) async {
    final rows = await _db.select(_db.workoutSessionsTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapSession)
        .toList();
  }

  @override
  Future<List<WorkoutSetLog>> getAllSetLogs({bool includeDeleted = true}) async {
    final rows = await _db.select(_db.workoutSetLogsTable).get();
    return rows
        .where((r) => includeDeleted || r.deletedAt == null)
        .map(_mapSetLog)
        .toList();
  }

  WorkoutSetLogsTableCompanion _setLogCompanion(WorkoutSetLog log) =>
      WorkoutSetLogsTableCompanion(
        id: Value(log.id),
        sessionId: Value(log.sessionId),
        exerciseId: Value(log.exerciseId),
        exerciseOrder: Value(log.exerciseOrder),
        setIndex: Value(log.setIndex),
        weightKg: Value(log.weightKg),
        reps: Value(log.reps),
        plannedWeightKg: Value(log.plannedWeightKg),
        plannedReps: Value(log.plannedReps),
        completed: Value(log.completed),
        completedAt: Value(log.completedAt),
        createdAt: Value(log.createdAt),
        updatedAt: Value(log.updatedAt),
        version: Value(log.version),
        deletedAt: Value(log.deletedAt),
      );

  Exercise _mapExercise(ExercisesTableData row) => Exercise(
    id: row.id,
    name: row.name,
    formCues: row.formCues,
    colorValue: row.colorValue,
    sortOrder: row.sortOrder,
    targetSets: row.targetSets,
    targetReps: row.targetReps,
    targetWeightKg: row.targetWeightKg,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  WorkoutPlan _mapPlan(WorkoutPlansTableData row) => WorkoutPlan(
    id: row.id,
    name: row.name,
    mode: WorkoutPlanMode.values.byName(row.mode),
    cycleLength: row.cycleLength,
    cycleAnchor: row.cycleAnchor,
    isActive: row.isActive,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  WorkoutPlanEntry _mapPlanEntry(WorkoutPlanEntriesTableData row) =>
      WorkoutPlanEntry(
        id: row.id,
        planId: row.planId,
        dayIndex: row.dayIndex,
        exerciseId: row.exerciseId,
        sortOrder: row.sortOrder,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        version: row.version,
        deletedAt: row.deletedAt,
      );

  WorkoutSession _mapSession(WorkoutSessionsTableData row) => WorkoutSession(
    id: row.id,
    planId: row.planId,
    dayIndex: row.dayIndex,
    date: row.date,
    startedAt: row.startedAt,
    endedAt: row.endedAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  WorkoutSetLog _mapSetLog(WorkoutSetLogsTableData row) => WorkoutSetLog(
    id: row.id,
    sessionId: row.sessionId,
    exerciseId: row.exerciseId,
    exerciseOrder: row.exerciseOrder,
    setIndex: row.setIndex,
    weightKg: row.weightKg,
    reps: row.reps,
    plannedWeightKg: row.plannedWeightKg,
    plannedReps: row.plannedReps,
    completed: row.completed,
    completedAt: row.completedAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );
}

class DriftJobRepository implements JobRepository {
  DriftJobRepository(this._db, {SyncActivityController? syncActivity})
    : _syncActivity = syncActivity;

  final AppDatabase _db;
  final SyncActivityController? _syncActivity;
  final _policy = const SoftDeletePolicy();

  @override
  Future<void> ensureSeeded() async {
    final now = utcNow();

    // Tombstones count as "present": clearing the stage list out is a choice,
    // and re-seeding on next launch would silently undo it.
    final stageRows = await _db.select(_db.jobStagesTable).get();
    if (stageRows.isEmpty) {
      for (var i = 0; i < jobSeedStages.length; i++) {
        await upsertStage(
          JobStage(
            id: newId(),
            name: jobSeedStages[i],
            sortOrder: i,
            createdAt: now,
            updatedAt: now,
          ),
          recordLocalActivity: false,
        );
      }
    }

    final companyRows = await _db.select(_db.jobCompaniesTable).get();
    if (companyRows.isEmpty) {
      await _db.batch((batch) {
        batch.insertAll(_db.jobCompaniesTable, [
          for (final name in jobSeedCompanies)
            JobCompaniesTableCompanion.insert(
              id: newId(),
              name: name,
              createdAt: now,
              updatedAt: now,
            ),
        ]);
      });
    }
  }

  @override
  Future<List<JobApplication>> listApplications({
    bool includeDeleted = false,
  }) async {
    final rows = await _db.select(_db.jobApplicationsTable).get();
    return [
      for (final row in rows)
        if (includeDeleted || row.deletedAt == null) _mapApplication(row),
    ];
  }

  @override
  Future<JobApplication?> getApplication(String id) async {
    final row = await (_db.select(
      _db.jobApplicationsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapApplication(row);
  }

  @override
  Future<void> upsertApplication(
    JobApplication application, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.jobApplicationsTable)
        .insertOnConflictUpdate(_applicationCompanion(application));
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.jobApplications);
    }
  }

  @override
  Future<({JobApplication application, List<JobStatusEvent> events})>
  deleteApplication(String id) async {
    final existing = await getApplication(id);
    final now = utcNow();
    // Everything the user typed is blanked, not just hidden. The row survives
    // only as a tombstone the other devices need in order to learn about the
    // deletion at all — `watchCollection` drops Firestore document removals,
    // so an actually-deleted document is invisible to every other device and
    // would be pushed back by the first one that still holds it.
    final tombstone =
        (existing ??
                JobApplication(
                  id: id,
                  company: '',
                  title: '',
                  status: '',
                  dateApplied: now,
                  createdAt: now,
                  updatedAt: now,
                ))
            .copyWith(
              company: '',
              title: '',
              status: '',
              clearApplicationUrl: true,
              clearNotes: true,
              clearSeasonId: true,
              deletedAt: now,
            );
    await upsertApplication(tombstone, recordLocalActivity: false);

    final events = await listStatusEvents(id);
    final tombstonedEvents = [
      for (final event in events) event.copyWith(deletedAt: now),
    ];
    for (final event in tombstonedEvents) {
      await upsertStatusEvent(event, recordLocalActivity: false);
    }

    _syncActivity?.recordLocalSave(FirestoreCollections.jobApplications);
    return (application: tombstone, events: tombstonedEvents);
  }

  @override
  Future<List<JobStatusEvent>> listStatusEvents(
    String applicationId, {
    bool includeDeleted = false,
  }) async {
    final rows =
        await (_db.select(_db.jobStatusEventsTable)
              ..where((t) => t.applicationId.equals(applicationId))
              ..orderBy([(t) => OrderingTerm.asc(t.changedAt)]))
            .get();
    return [
      for (final row in rows)
        if (includeDeleted || row.deletedAt == null) _mapStatusEvent(row),
    ];
  }

  @override
  Future<void> upsertStatusEvent(
    JobStatusEvent event, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.jobStatusEventsTable)
        .insertOnConflictUpdate(_statusEventCompanion(event));
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.jobStatusEvents);
    }
  }

  @override
  Future<List<JobStage>> listStages({bool includeDeleted = false}) async {
    final rows =
        await (_db.select(_db.jobStagesTable)
              ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
            .get();
    return [
      for (final row in rows)
        if (includeDeleted || row.deletedAt == null) _mapStage(row),
    ];
  }

  @override
  Future<void> upsertStage(
    JobStage stage, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.jobStagesTable)
        .insertOnConflictUpdate(_stageCompanion(stage));
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.jobStages);
    }
  }

  @override
  Future<void> softDeleteStage(String id) async {
    await (_db.update(
      _db.jobStagesTable,
    )..where((t) => t.id.equals(id))).write(
      JobStagesTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.jobStages);
  }

  @override
  Future<List<JobStage>> reorderStages(List<String> orderedIds) async {
    final stages = await listStages();
    final byId = {for (final stage in stages) stage.id: stage};
    final written = <JobStage>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final stage = byId[orderedIds[i]];
      if (stage == null || stage.sortOrder == i) continue;
      written.add(stage.copyWith(sortOrder: i));
    }
    if (written.isEmpty) return const [];
    await _db.batch((batch) {
      for (final stage in written) {
        batch.update(
          _db.jobStagesTable,
          _stageCompanion(stage),
          where: (t) => t.id.equals(stage.id),
        );
      }
    });
    _syncActivity?.recordLocalSave(FirestoreCollections.jobStages);
    return written;
  }

  @override
  Future<List<JobCompany>> listCompanies({bool includeDeleted = false}) async {
    final rows = await _db.select(_db.jobCompaniesTable).get();
    final companies = [
      for (final row in rows)
        if (includeDeleted || row.deletedAt == null) _mapCompany(row),
    ];
    companies.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return companies;
  }

  @override
  Future<void> upsertCompany(
    JobCompany company, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.jobCompaniesTable)
        .insertOnConflictUpdate(_companyCompanion(company));
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.jobCompanies);
    }
  }

  @override
  Future<void> softDeleteCompany(String id) async {
    await (_db.update(
      _db.jobCompaniesTable,
    )..where((t) => t.id.equals(id))).write(
      JobCompaniesTableCompanion(
        deletedAt: Value(utcNow()),
        updatedAt: Value(utcNow()),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.jobCompanies);
  }

  @override
  Future<JobCompany?> ensureCompany(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final existing = await listCompanies();
    final key = jobCompanyKey(trimmed);
    if (existing.any((c) => jobCompanyKey(c.name) == key)) return null;
    final now = utcNow();
    final company = JobCompany(
      id: newId(),
      name: trimmed,
      createdAt: now,
      updatedAt: now,
    );
    await upsertCompany(company);
    return company;
  }

  @override
  Future<List<JobCategory>> listCategories({
    bool includeDeleted = false,
  }) async {
    final rows =
        await (_db.select(_db.jobCategoriesTable)
              ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
            .get();
    return [
      for (final row in rows)
        if (includeDeleted || row.deletedAt == null) _mapCategory(row),
    ];
  }

  @override
  Future<void> upsertCategory(
    JobCategory category, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.jobCategoriesTable)
        .insertOnConflictUpdate(_categoryCompanion(category));
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.jobCategories);
    }
  }

  @override
  Future<List<JobCompany>> softDeleteCategory(String id) async {
    final now = utcNow();
    await (_db.update(
      _db.jobCategoriesTable,
    )..where((t) => t.id.equals(id))).write(
      JobCategoriesTableCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.jobCategories);

    // Companies are cleared rather than left pointing at a tombstone: an
    // unresolvable categoryId and no categoryId render identically (neutral),
    // but only the cleared one survives the category row being purged.
    final orphaned = [
      for (final company in await listCompanies())
        if (company.categoryId == id) company.copyWith(clearCategoryId: true),
    ];
    for (final company in orphaned) {
      await upsertCompany(company, recordLocalActivity: false);
    }
    if (orphaned.isNotEmpty) {
      _syncActivity?.recordLocalSave(FirestoreCollections.jobCompanies);
    }
    return orphaned;
  }

  @override
  Future<List<JobSeason>> listSeasons({bool includeDeleted = false}) async {
    final rows =
        await (_db.select(_db.jobSeasonsTable)
              ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
            .get();
    return [
      for (final row in rows)
        if (includeDeleted || row.deletedAt == null) _mapSeason(row),
    ];
  }

  @override
  Future<void> upsertSeason(
    JobSeason season, {
    bool recordLocalActivity = true,
  }) async {
    await _db
        .into(_db.jobSeasonsTable)
        .insertOnConflictUpdate(_seasonCompanion(season));
    if (recordLocalActivity) {
      _syncActivity?.recordLocalSave(FirestoreCollections.jobSeasons);
    }
  }

  @override
  Future<List<JobApplication>> softDeleteSeason(String id) async {
    final now = utcNow();
    await (_db.update(
      _db.jobSeasonsTable,
    )..where((t) => t.id.equals(id))).write(
      JobSeasonsTableCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    _syncActivity?.recordLocalSave(FirestoreCollections.jobSeasons);

    // Back to active rather than stranded: an application whose season is gone
    // would otherwise be hidden from the default list with nothing left in the
    // UI to explain why or to un-archive it.
    final released = [
      for (final application in await listApplications())
        if (application.seasonId == id)
          application.copyWith(clearSeasonId: true),
    ];
    for (final application in released) {
      await upsertApplication(application, recordLocalActivity: false);
    }
    if (released.isNotEmpty) {
      _syncActivity?.recordLocalSave(FirestoreCollections.jobApplications);
    }
    return released;
  }

  @override
  Future<void> purgeExpiredDeleted(DateTime now) async {
    final cutoff = _policy.purgeCutoff(now);
    await (_db.delete(_db.jobStatusEventsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.jobApplicationsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.jobStagesTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.jobCompaniesTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.jobCategoriesTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
    await (_db.delete(_db.jobSeasonsTable)
          ..where((t) => t.deletedAt.isSmallerOrEqualValue(cutoff)))
        .go();
  }

  @override
  Future<List<JobApplication>> getAllApplications({
    bool includeDeleted = true,
  }) => listApplications(includeDeleted: includeDeleted);

  @override
  Future<List<JobStatusEvent>> getAllStatusEvents({
    bool includeDeleted = true,
  }) async {
    final rows = await _db.select(_db.jobStatusEventsTable).get();
    return [
      for (final row in rows)
        if (includeDeleted || row.deletedAt == null) _mapStatusEvent(row),
    ];
  }

  @override
  Future<List<JobStage>> getAllStages({bool includeDeleted = true}) =>
      listStages(includeDeleted: includeDeleted);

  @override
  Future<List<JobCompany>> getAllCompanies({bool includeDeleted = true}) =>
      listCompanies(includeDeleted: includeDeleted);

  @override
  Future<List<JobCategory>> getAllCategories({bool includeDeleted = true}) =>
      listCategories(includeDeleted: includeDeleted);

  @override
  Future<List<JobSeason>> getAllSeasons({bool includeDeleted = true}) =>
      listSeasons(includeDeleted: includeDeleted);

  JobApplicationsTableCompanion _applicationCompanion(
    JobApplication application,
  ) => JobApplicationsTableCompanion(
    id: Value(application.id),
    company: Value(application.company),
    title: Value(application.title),
    status: Value(application.status),
    dateApplied: Value(application.dateApplied),
    applicationUrl: Value(application.applicationUrl),
    notes: Value(application.notes),
    seasonId: Value(application.seasonId),
    createdAt: Value(application.createdAt),
    updatedAt: Value(application.updatedAt),
    version: Value(application.version),
    deletedAt: Value(application.deletedAt),
  );

  JobStatusEventsTableCompanion _statusEventCompanion(JobStatusEvent event) =>
      JobStatusEventsTableCompanion(
        id: Value(event.id),
        applicationId: Value(event.applicationId),
        fromStatus: Value(event.fromStatus),
        toStatus: Value(event.toStatus),
        changedAt: Value(event.changedAt),
        createdAt: Value(event.createdAt),
        updatedAt: Value(event.updatedAt),
        version: Value(event.version),
        deletedAt: Value(event.deletedAt),
      );

  JobStagesTableCompanion _stageCompanion(JobStage stage) =>
      JobStagesTableCompanion(
        id: Value(stage.id),
        name: Value(stage.name),
        sortOrder: Value(stage.sortOrder),
        createdAt: Value(stage.createdAt),
        updatedAt: Value(stage.updatedAt),
        version: Value(stage.version),
        deletedAt: Value(stage.deletedAt),
      );

  JobCompaniesTableCompanion _companyCompanion(JobCompany company) =>
      JobCompaniesTableCompanion(
        id: Value(company.id),
        name: Value(company.name),
        categoryId: Value(company.categoryId),
        createdAt: Value(company.createdAt),
        updatedAt: Value(company.updatedAt),
        version: Value(company.version),
        deletedAt: Value(company.deletedAt),
      );

  JobCategoriesTableCompanion _categoryCompanion(JobCategory category) =>
      JobCategoriesTableCompanion(
        id: Value(category.id),
        name: Value(category.name),
        colorValue: Value(category.colorValue),
        sortOrder: Value(category.sortOrder),
        createdAt: Value(category.createdAt),
        updatedAt: Value(category.updatedAt),
        version: Value(category.version),
        deletedAt: Value(category.deletedAt),
      );

  JobSeasonsTableCompanion _seasonCompanion(JobSeason season) =>
      JobSeasonsTableCompanion(
        id: Value(season.id),
        name: Value(season.name),
        sortOrder: Value(season.sortOrder),
        createdAt: Value(season.createdAt),
        updatedAt: Value(season.updatedAt),
        version: Value(season.version),
        deletedAt: Value(season.deletedAt),
      );

  JobApplication _mapApplication(JobApplicationsTableData row) =>
      JobApplication(
        id: row.id,
        company: row.company,
        title: row.title,
        status: row.status,
        dateApplied: row.dateApplied,
        applicationUrl: row.applicationUrl,
        notes: row.notes,
        seasonId: row.seasonId,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        version: row.version,
        deletedAt: row.deletedAt,
      );

  JobStatusEvent _mapStatusEvent(JobStatusEventsTableData row) =>
      JobStatusEvent(
        id: row.id,
        applicationId: row.applicationId,
        fromStatus: row.fromStatus,
        toStatus: row.toStatus,
        changedAt: row.changedAt,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        version: row.version,
        deletedAt: row.deletedAt,
      );

  JobStage _mapStage(JobStagesTableData row) => JobStage(
    id: row.id,
    name: row.name,
    sortOrder: row.sortOrder,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  JobCompany _mapCompany(JobCompaniesTableData row) => JobCompany(
    id: row.id,
    name: row.name,
    categoryId: row.categoryId,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  JobCategory _mapCategory(JobCategoriesTableData row) => JobCategory(
    id: row.id,
    name: row.name,
    colorValue: row.colorValue,
    sortOrder: row.sortOrder,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );

  JobSeason _mapSeason(JobSeasonsTableData row) => JobSeason(
    id: row.id,
    name: row.name,
    sortOrder: row.sortOrder,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    deletedAt: row.deletedAt,
  );
}
