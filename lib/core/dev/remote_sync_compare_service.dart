import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/dev/sync_compare_logger.dart';
import 'package:voyager/core/sync/crdt_document_resolver.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';

enum SyncCompareSyncStatus {
  inSync,
  mismatch,
  missingOnRemote,
  missingOnLocal,
  remoteFetchFailed,
}

class FieldDiff {
  const FieldDiff({
    required this.field,
    required this.local,
    required this.remote,
  });

  final String field;
  final String local;
  final String remote;
}

class JournalEntryCompareResult {
  const JournalEntryCompareResult({
    required this.entryId,
    required this.status,
    this.diffs = const [],
    this.detail,
    this.remoteCharOpCount,
    this.remoteOpChainValid,
  });

  final String entryId;
  final SyncCompareSyncStatus status;
  final List<FieldDiff> diffs;
  final String? detail;
  final int? remoteCharOpCount;
  final bool? remoteOpChainValid;

  bool get matched => status == SyncCompareSyncStatus.inSync;
}

class JournalCompareReport {
  const JournalCompareReport({
    required this.results,
    required this.comparedAt,
  });

  final List<JournalEntryCompareResult> results;
  final DateTime comparedAt;

  int get matchedCount => results.where((r) => r.matched).length;

  int get mismatchCount =>
      results.where((r) => r.status == SyncCompareSyncStatus.mismatch).length;

  int get missingOnRemoteCount => results
      .where((r) => r.status == SyncCompareSyncStatus.missingOnRemote)
      .length;

  int get missingOnLocalCount => results
      .where((r) => r.status == SyncCompareSyncStatus.missingOnLocal)
      .length;

  bool get allMatched => results.every((r) => r.matched);
}

class TodoListCompareResult {
  const TodoListCompareResult({
    required this.listId,
    required this.listName,
    required this.status,
    this.listDiffs = const [],
    this.mismatchedTaskCount = 0,
    this.localOnlyTaskCount = 0,
    this.remoteOnlyTaskCount = 0,
    this.taskDetails = const [],
    this.detail,
  });

  final String listId;
  final String listName;
  final SyncCompareSyncStatus status;
  final List<FieldDiff> listDiffs;
  final int mismatchedTaskCount;
  final int localOnlyTaskCount;
  final int remoteOnlyTaskCount;
  final List<String> taskDetails;
  final String? detail;

  bool get matched => status == SyncCompareSyncStatus.inSync;
}

class TodoListsCompareReport {
  const TodoListsCompareReport({
    required this.results,
    required this.comparedAt,
  });

  final List<TodoListCompareResult> results;
  final DateTime comparedAt;

  int get matchedCount => results.where((r) => r.matched).length;

  int get mismatchCount =>
      results.where((r) => r.status == SyncCompareSyncStatus.mismatch).length;

  int get missingOnRemoteCount => results
      .where((r) => r.status == SyncCompareSyncStatus.missingOnRemote)
      .length;

  int get missingOnLocalCount => results
      .where((r) => r.status == SyncCompareSyncStatus.missingOnLocal)
      .length;

  bool get allMatched => results.every((r) => r.matched);
}

class RemoteSyncCompareService {
  RemoteSyncCompareService({
    required JournalRepository journalRepository,
    required TodoRepository todoRepository,
    required SyncRepository syncRepository,
    required SyncCompareLogger logger,
    CrdtDocumentResolver? crdtResolver,
    CharacterSequenceCrdtMerger? charMerger,
  }) : _journalRepository = journalRepository,
       _todoRepository = todoRepository,
       _syncRepository = syncRepository,
       _logger = logger,
       _crdtResolver = crdtResolver ?? CrdtDocumentResolver(),
       _charMerger = charMerger ?? CharacterSequenceCrdtMerger();

  final JournalRepository _journalRepository;
  final TodoRepository _todoRepository;
  final SyncRepository _syncRepository;
  final SyncCompareLogger _logger;
  final CrdtDocumentResolver _crdtResolver;
  final CharacterSequenceCrdtMerger _charMerger;

  Future<JournalCompareReport> compareAllJournalEntries() async {
    final comparedAt = DateTime.now().toUtc();
    final localEntries = await _journalRepository.listEntries(
      includeDeleted: false,
    );
    final remoteDocs = await _loadRemoteDocuments(
      FirestoreCollections.journalEntries,
    );
    final rawRemoteDocs = await _loadRawRemoteDocuments(
      FirestoreCollections.journalEntries,
    );

    final results = <JournalEntryCompareResult>[];
    final localIds = localEntries.map((e) => e.id).toSet();
    final remoteIds = remoteDocs.keys.toSet();

    for (final entry in localEntries) {
      results.add(
        await _compareJournalEntry(
          entry,
          remoteDocs[entry.id],
          rawRemote: rawRemoteDocs[entry.id],
        ),
      );
    }

    for (final remoteId in remoteIds.difference(localIds)) {
      results.add(
        JournalEntryCompareResult(
          entryId: remoteId,
          status: SyncCompareSyncStatus.missingOnLocal,
          detail: 'Entry exists on remote but not in local database.',
        ),
      );
    }

    results.sort((a, b) => a.entryId.compareTo(b.entryId));
    final report = JournalCompareReport(
      results: results,
      comparedAt: comparedAt,
    );
    await _logJournalReport(report);
    return report;
  }

  Future<TodoListsCompareReport> compareAllTodoLists() async {
    final comparedAt = DateTime.now().toUtc();
    final localLists = await _todoRepository.listLists(includeDeleted: false);
    final remoteListDocs = await _loadRemoteDocuments(
      FirestoreCollections.todoLists,
    );
    final remoteTaskDocs = await _loadRemoteDocuments(
      FirestoreCollections.todoTasks,
    );
    final rawRemoteListDocs = await _loadRawRemoteDocuments(
      FirestoreCollections.todoLists,
    );
    final rawRemoteTaskDocs = await _loadRawRemoteDocuments(
      FirestoreCollections.todoTasks,
    );

    final results = <TodoListCompareResult>[];
    final localIds = localLists.map((list) => list.id).toSet();

    for (final list in localLists) {
      results.add(
        await _compareTodoList(
          list: list,
          remoteListDocs: remoteListDocs,
          remoteTaskDocs: remoteTaskDocs,
          rawRemoteListDocs: rawRemoteListDocs,
          rawRemoteTaskDocs: rawRemoteTaskDocs,
        ),
      );
    }

    for (final remoteId in remoteListDocs.keys.toSet().difference(localIds)) {
      final remote = remoteListDocs[remoteId]!;
      if (parseFirestoreDate(remote['deletedAt']) != null) continue;
      results.add(
        TodoListCompareResult(
          listId: remoteId,
          listName: remote['name'] as String? ?? '(unknown)',
          status: SyncCompareSyncStatus.missingOnLocal,
          detail: 'List exists on remote but not in local database.',
        ),
      );
    }

    results.sort((a, b) => a.listName.compareTo(b.listName));
    final report = TodoListsCompareReport(
      results: results,
      comparedAt: comparedAt,
    );
    await _logTodoListsReport(report);
    return report;
  }

  Future<TodoListCompareResult> compareTodoList(String listId) async {
    final comparedAt = DateTime.now().toUtc();
    final lists = await _todoRepository.listLists(includeDeleted: true);
    final list = lists.cast<TodoListModel?>().firstWhere(
      (item) => item!.id == listId,
      orElse: () => null,
    );
    if (list == null) {
      final result = TodoListCompareResult(
        listId: listId,
        listName: '(unknown)',
        status: SyncCompareSyncStatus.remoteFetchFailed,
        detail: 'Todo list not found locally.',
      );
      await _logTodoResult(result, comparedAt);
      return result;
    }

    final remoteListDocs = await _loadRemoteDocuments(
      FirestoreCollections.todoLists,
    );
    final remoteTaskDocs = await _loadRemoteDocuments(
      FirestoreCollections.todoTasks,
    );
    final rawRemoteListDocs = await _loadRawRemoteDocuments(
      FirestoreCollections.todoLists,
    );
    final rawRemoteTaskDocs = await _loadRawRemoteDocuments(
      FirestoreCollections.todoTasks,
    );

    final result = await _compareTodoList(
      list: list,
      remoteListDocs: remoteListDocs,
      remoteTaskDocs: remoteTaskDocs,
      rawRemoteListDocs: rawRemoteListDocs,
      rawRemoteTaskDocs: rawRemoteTaskDocs,
    );
    await _logTodoResult(result, comparedAt);
    return result;
  }

  Future<TodoListCompareResult> _compareTodoList({
    required TodoListModel list,
    required Map<String, Map<String, dynamic>> remoteListDocs,
    required Map<String, Map<String, dynamic>> remoteTaskDocs,
    required Map<String, Map<String, dynamic>> rawRemoteListDocs,
    required Map<String, Map<String, dynamic>> rawRemoteTaskDocs,
  }) async {
    final listId = list.id;
    final remoteList = remoteListDocs[listId];
    final listDiffs = remoteList == null
        ? const <FieldDiff>[]
        : _diffTodoList(list, remoteList);

    if (remoteList == null) {
      return TodoListCompareResult(
        listId: listId,
        listName: list.name,
        status: SyncCompareSyncStatus.missingOnRemote,
        detail: _diagnoseMissingOnRemote(
          documentId: listId,
          collection: FirestoreCollections.todoLists,
          localSummary:
              'local v=${list.version} '
              'updated=${list.updatedAt.toUtc().toIso8601String()} '
              'name="${_preview(list.name, 60)}"',
          rawRemote: rawRemoteListDocs[listId],
        ),
      );
    }

    final localTasks = await _todoRepository.listTasks(
      listId,
      includeDeleted: false,
      topLevelOnly: false,
    );

    return _compareTodoListTasks(
      list: list,
      listDiffs: listDiffs,
      localTasks: localTasks,
      remoteTaskDocs: remoteTaskDocs,
      rawRemoteTaskDocs: rawRemoteTaskDocs,
    );
  }

  TodoListCompareResult _compareTodoListTasks({
    required TodoListModel list,
    required List<FieldDiff> listDiffs,
    required List<TodoTask> localTasks,
    required Map<String, Map<String, dynamic>> remoteTaskDocs,
    required Map<String, Map<String, dynamic>> rawRemoteTaskDocs,
  }) {
    final listId = list.id;
    final remoteTasks = <String, Map<String, dynamic>>{};
    for (final entry in remoteTaskDocs.entries) {
      final data = entry.value;
      final remoteListId = todoListDocumentIdFromFirestore(
        data['listId'] as String? ?? '',
      );
      if (remoteListId != listId) continue;
      if (parseFirestoreDate(data['deletedAt']) != null) continue;
      remoteTasks[entry.key] = data;
    }

    final taskDetails = <String>[];
    var mismatched = 0;
    var localOnly = 0;
    var remoteOnly = 0;

    for (final task in localTasks) {
      final remote = remoteTasks.remove(task.id);
      if (remote == null) {
        localOnly++;
        taskDetails.add(
          'Task ${task.id} "${task.title}": '
          '${_diagnoseMissingOnRemote(
            documentId: task.id,
            collection: FirestoreCollections.todoTasks,
            localSummary: _formatLocalTodoSummary(task),
            rawRemote: rawRemoteTaskDocs[task.id],
          ).replaceAll('\n', ' ')}',
        );
        continue;
      }
      final diffs = _diffTodoTask(task, remote);
      if (diffs.isEmpty) continue;
      mismatched++;
      taskDetails.add(
        'Task ${task.id} "${task.title}": ${_formatDiffs(diffs)}',
      );
    }

    for (final entry in remoteTasks.entries) {
      remoteOnly++;
      final title = entry.value['title'] as String? ?? '(untitled)';
      taskDetails.add('Task ${entry.key}: missing locally ($title)');
    }

    final tasksMatched = mismatched == 0 && localOnly == 0 && remoteOnly == 0;
    final SyncCompareSyncStatus status;
    if (listDiffs.isEmpty && tasksMatched) {
      status = SyncCompareSyncStatus.inSync;
    } else {
      status = SyncCompareSyncStatus.mismatch;
    }

    return TodoListCompareResult(
      listId: listId,
      listName: list.name,
      status: status,
      listDiffs: listDiffs,
      mismatchedTaskCount: mismatched,
      localOnlyTaskCount: localOnly,
      remoteOnlyTaskCount: remoteOnly,
      taskDetails: taskDetails,
    );
  }

  Future<JournalEntryCompareResult> _compareJournalEntry(
    JournalEntry local,
    Map<String, dynamic>? remoteData, {
    Map<String, dynamic>? rawRemote,
  }) async {
    if (remoteData == null) {
      return JournalEntryCompareResult(
        entryId: local.id,
        status: SyncCompareSyncStatus.missingOnRemote,
        detail: _diagnoseMissingOnRemote(
          documentId: local.id,
          collection: FirestoreCollections.journalEntries,
          localSummary: _formatLocalJournalSummary(local),
          rawRemote: rawRemote,
        ),
      );
    }

    final remoteCharOps = await _listRemoteCharOps(local.id);
    var opChainValid = true;
    try {
      _charMerger.validateOpChain(remoteCharOps);
    } catch (_) {
      opChainValid = false;
    }

    final diffs = _diffJournalEntry(local, remoteData);
    if (diffs.isEmpty) {
      return JournalEntryCompareResult(
        entryId: local.id,
        status: SyncCompareSyncStatus.inSync,
        remoteCharOpCount: remoteCharOps.length,
        remoteOpChainValid: opChainValid,
      );
    }

    return JournalEntryCompareResult(
      entryId: local.id,
      status: SyncCompareSyncStatus.mismatch,
      diffs: diffs,
      remoteCharOpCount: remoteCharOps.length,
      remoteOpChainValid: opChainValid,
    );
  }

  Future<Map<String, Map<String, dynamic>>> _loadRemoteDocuments(
    String collection,
  ) async {
    final docs = await _syncRepository.listCollectionDocuments(collection);
    final resolved = <String, Map<String, dynamic>>{};
    for (final doc in docs) {
      final firestoreDocId = doc.data['id'] as String? ?? doc.id;
      final localDocId = _localDocumentId(collection, firestoreDocId);
      try {
        final remote = await _resolveRemoteDocument(
          collection: collection,
          localDocumentId: localDocId,
          firestoreDocumentId: firestoreDocId,
          rawData: doc.data,
        );
        if (remote != null &&
            parseFirestoreDate(remote['deletedAt']) == null) {
          resolved[localDocId] = remote;
        }
      } catch (_) {
        // Skip malformed remote documents.
      }
    }
    return resolved;
  }

  Future<Map<String, Map<String, dynamic>>> _loadRawRemoteDocuments(
    String collection,
  ) async {
    final docs = await _syncRepository.listCollectionDocuments(collection);
    final raw = <String, Map<String, dynamic>>{};
    for (final doc in docs) {
      final firestoreDocId = doc.data['id'] as String? ?? doc.id;
      final localDocId = _localDocumentId(collection, firestoreDocId);
      raw[localDocId] = doc.data;
    }
    return raw;
  }

  Future<Map<String, dynamic>?> _resolveRemoteDocument({
    required String collection,
    required String localDocumentId,
    required String firestoreDocumentId,
    required Map<String, dynamic> rawData,
  }) async {
    final crdtPayload = await _crdtResolver.resolvePayload(
      _syncRepository,
      firestoreDocumentId,
    );
    if (crdtPayload != null) {
      return _normalizeRemoteDocument(collection, crdtPayload);
    }
    return _normalizeRemoteDocument(collection, rawData);
  }

  List<FieldDiff> _diffJournalEntry(
    JournalEntry local,
    Map<String, dynamic> remote,
  ) {
    final diffs = <FieldDiff>[];
    void compare(String field, String localValue, String remoteValue) {
      if (localValue != remoteValue) {
        diffs.add(
          FieldDiff(field: field, local: localValue, remote: remoteValue),
        );
      }
    }

    compare('title', local.title, remote['title'] as String? ?? '');
    compare('body', local.body, remote['body'] as String? ?? '');
    compare(
      'journalId',
      local.journalId,
      journalReferenceIdFromFirestore(
        remote['journalId'] as String? ?? local.journalId,
      ),
    );
    compare('mood', '${local.mood}', '${remote['mood']}');
    compare(
      'weatherIcon',
      local.weatherIcon ?? '',
      remote['weatherIcon'] as String? ?? '',
    );
    compare('tags', local.tags.join('|'), _tagsFromRemote(remote).join('|'));
    compare('version', '${local.version}', '${parseVersion(remote)}');
    _addInstantDiff(
      diffs,
      'updatedAt',
      local.updatedAt,
      parseFirestoreDate(remote['updatedAt']) ?? local.updatedAt,
    );
    return diffs;
  }

  List<FieldDiff> _diffTodoList(
    TodoListModel local,
    Map<String, dynamic> remote,
  ) {
    final diffs = <FieldDiff>[];
    void compare(String field, String localValue, String remoteValue) {
      if (localValue != remoteValue) {
        diffs.add(
          FieldDiff(field: field, local: localValue, remote: remoteValue),
        );
      }
    }

    compare('name', local.name, remote['name'] as String? ?? '');
    compare(
      'colorValue',
      '${local.colorValue}',
      '${remote['colorValue']}',
    );
    compare('version', '${local.version}', '${parseVersion(remote)}');
    _addInstantDiff(
      diffs,
      'updatedAt',
      local.updatedAt,
      parseFirestoreDate(remote['updatedAt']) ?? local.updatedAt,
    );
    return diffs;
  }

  List<FieldDiff> _diffTodoTask(TodoTask local, Map<String, dynamic> remote) {
    final diffs = <FieldDiff>[];
    void compare(String field, String localValue, String remoteValue) {
      if (localValue != remoteValue) {
        diffs.add(
          FieldDiff(field: field, local: localValue, remote: remoteValue),
        );
      }
    }

    compare('title', local.title, remote['title'] as String? ?? '');
    compare('notes', local.notes ?? '', remote['notes'] as String? ?? '');
    compare('completed', '${local.completed}', '${remote['completed']}');
    compare('starred', '${local.starred}', '${remote['starred']}');
    compare('sortOrder', '${local.sortOrder}', '${remote['sortOrder']}');
    _addInstantDiff(
      diffs,
      'dueDate',
      local.dueDate,
      parseFirestoreDate(remote['dueDate']),
    );
    compare(
      'parentTaskId',
      local.parentTaskId ?? '',
      remote['parentTaskId'] as String? ?? '',
    );
    compare('version', '${local.version}', '${parseVersion(remote)}');
    _addInstantDiff(
      diffs,
      'updatedAt',
      local.updatedAt,
      parseFirestoreDate(remote['updatedAt']) ?? local.updatedAt,
    );
    return diffs;
  }

  void _addInstantDiff(
    List<FieldDiff> diffs,
    String field,
    DateTime? local,
    DateTime? remote,
  ) {
    if (_instantsMatchAtSecondPrecision(local, remote)) return;
    diffs.add(
      FieldDiff(
        field: field,
        local: local?.toUtc().toIso8601String() ?? '',
        remote: remote?.toUtc().toIso8601String() ?? '',
      ),
    );
  }

  bool _instantsMatchAtSecondPrecision(DateTime? local, DateTime? remote) {
    if (local == null && remote == null) return true;
    if (local == null || remote == null) return false;
    final a = local.toUtc();
    final b = remote.toUtc();
    return a.year == b.year &&
        a.month == b.month &&
        a.day == b.day &&
        a.hour == b.hour &&
        a.minute == b.minute &&
        a.second == b.second;
  }

  String _formatLocalJournalSummary(JournalEntry entry) {
    return 'local v=${entry.version} '
        'updated=${entry.updatedAt.toUtc().toIso8601String()} '
        'title="${_preview(entry.title, 60)}" journalId=${entry.journalId}';
  }

  String _formatLocalTodoSummary(TodoTask task) {
    return 'local v=${task.version} '
        'updated=${task.updatedAt.toUtc().toIso8601String()} '
        'listId=${task.listId}';
  }

  String _diagnoseMissingOnRemote({
    required String documentId,
    required String collection,
    required String localSummary,
    Map<String, dynamic>? rawRemote,
  }) {
    final buffer = StringBuffer(
      'Entry exists locally but not in resolved remote set.\n',
    )
      ..writeln('  $localSummary');
    if (rawRemote == null) {
      buffer.writeln(
        '  Remote: no document found in $collection with id $documentId '
        '(never uploaded, upload failed, or still pending).',
      );
      return buffer.toString().trimRight();
    }

    final deletedAt = parseFirestoreDate(rawRemote['deletedAt']);
    if (deletedAt != null) {
      buffer.writeln(
        '  Remote: document exists but soft-deleted at '
        '${deletedAt.toUtc().toIso8601String()}.',
      );
      return buffer.toString().trimRight();
    }

    buffer.writeln(
      '  Remote: raw document exists but was excluded from compare '
      '(CRDT resolution failed or malformed payload).',
    );
    return buffer.toString().trimRight();
  }

  List<String> _tagsFromRemote(Map<String, dynamic> remote) {
    if (remote['tags'] == null) return const [];
    return List<String>.from(remote['tags'] as List);
  }

  String _formatDiffs(List<FieldDiff> diffs) {
    return diffs
        .map((d) => '${d.field}: local="${_preview(d.local)}" remote="${_preview(d.remote)}"')
        .join('; ');
  }

  String _preview(String value, [int max = 80]) {
    final normalized = value.replaceAll('\n', '\\n');
    if (normalized.length <= max) return normalized;
    return '${normalized.substring(0, max)}…';
  }

  Future<List<CharacterOperation>> _listRemoteCharOps(String documentId) async {
    final ops = await _syncRepository.listOperations(documentId);
    return _charMerger.mergeOperations(const [], ops);
  }

  String _localDocumentId(String collection, String firestoreId) {
    if (collection == FirestoreCollections.journals) {
      return journalDocumentIdFromFirestore(firestoreId);
    }
    if (collection == FirestoreCollections.todoLists) {
      return todoListDocumentIdFromFirestore(firestoreId);
    }
    return firestoreId;
  }

  Map<String, dynamic> _normalizeRemoteDocument(
    String collection,
    Map<String, dynamic> data,
  ) {
    final normalized = Map<String, dynamic>.from(data);
    if (collection == FirestoreCollections.journals &&
        normalized['id'] is String) {
      normalized['id'] = journalDocumentIdFromFirestore(
        normalized['id'] as String,
      );
    }
    if (collection == FirestoreCollections.todoLists &&
        normalized['id'] is String) {
      normalized['id'] = todoListDocumentIdFromFirestore(
        normalized['id'] as String,
      );
    }
    if (collection == FirestoreCollections.journalEntries &&
        normalized['journalId'] is String) {
      normalized['journalId'] = journalReferenceIdFromFirestore(
        normalized['journalId'] as String,
      );
    }
    if (collection == FirestoreCollections.todoTasks &&
        normalized['listId'] is String) {
      normalized['listId'] = todoListDocumentIdFromFirestore(
        normalized['listId'] as String,
      );
    }
    return normalized;
  }

  Future<void> _logJournalReport(JournalCompareReport report) async {
    final buffer = StringBuffer()
      ..writeln('=' * 80)
      ..writeln('${report.comparedAt.toIso8601String()} | JOURNAL_COMPARE')
      ..writeln(
        'Compared ${report.results.length} entries — '
        '${report.matchedCount} in sync, '
        '${report.mismatchCount} field mismatches, '
        '${report.missingOnRemoteCount} missing on remote, '
        '${report.missingOnLocalCount} missing locally',
      );

    for (final result in report.results) {
      if (result.matched) continue;
      buffer.writeln('-' * 40);
      buffer.writeln('Entry ${result.entryId}: ${result.status.name}');
      if (result.detail != null) {
        buffer.writeln('  ${result.detail}');
      }
      for (final diff in result.diffs) {
        buffer.writeln(
          '  ${diff.field}: local="${_preview(diff.local, 200)}" '
          'remote="${_preview(diff.remote, 200)}"',
        );
      }
      if (result.remoteCharOpCount != null) {
        buffer.writeln(
          '  remoteCharOps=${result.remoteCharOpCount} '
          'opChainValid=${result.remoteOpChainValid}',
        );
      }
    }

    if (report.allMatched) {
      buffer.writeln('All journal entries match remote.');
    }
    buffer.writeln('=' * 80);
    buffer.writeln();
    await _logger.log(buffer.toString());
  }

  Future<void> _logTodoResult(
    TodoListCompareResult result,
    DateTime comparedAt,
  ) async {
    final buffer = StringBuffer()
      ..writeln('=' * 80)
      ..writeln('${comparedAt.toIso8601String()} | TODO_LIST_COMPARE')
      ..writeln('List "${result.listName}" (${result.listId}): ${result.status.name}');

    if (result.detail != null) {
      buffer.writeln('  ${result.detail}');
    }

    if (result.matched) {
      buffer.writeln('All tasks match remote.');
    } else {
      for (final diff in result.listDiffs) {
        buffer.writeln(
          '  list.${diff.field}: local="${_preview(diff.local, 200)}" '
          'remote="${_preview(diff.remote, 200)}"',
        );
      }
      buffer.writeln(
        '  mismatched=${result.mismatchedTaskCount} '
        'localOnly=${result.localOnlyTaskCount} '
        'remoteOnly=${result.remoteOnlyTaskCount}',
      );
      for (final detail in result.taskDetails) {
        buffer.writeln('  $detail');
      }
    }

    buffer.writeln('=' * 80);
    buffer.writeln();
    await _logger.log(buffer.toString());
  }

  Future<void> _logTodoListsReport(TodoListsCompareReport report) async {
    final buffer = StringBuffer()
      ..writeln('=' * 80)
      ..writeln('${report.comparedAt.toIso8601String()} | TODO_LISTS_COMPARE')
      ..writeln(
        'Compared ${report.results.length} lists — '
        '${report.matchedCount} in sync, '
        '${report.mismatchCount} with mismatches, '
        '${report.missingOnRemoteCount} missing on remote, '
        '${report.missingOnLocalCount} missing locally',
      );

    for (final result in report.results) {
      if (result.matched) continue;
      buffer.writeln('-' * 40);
      buffer.writeln(
        'List "${result.listName}" (${result.listId}): ${result.status.name}',
      );
      if (result.detail != null) {
        buffer.writeln('  ${result.detail}');
      }
      for (final diff in result.listDiffs) {
        buffer.writeln(
          '  list.${diff.field}: local="${_preview(diff.local, 200)}" '
          'remote="${_preview(diff.remote, 200)}"',
        );
      }
      if (result.mismatchedTaskCount > 0 ||
          result.localOnlyTaskCount > 0 ||
          result.remoteOnlyTaskCount > 0) {
        buffer.writeln(
          '  mismatched=${result.mismatchedTaskCount} '
          'localOnly=${result.localOnlyTaskCount} '
          'remoteOnly=${result.remoteOnlyTaskCount}',
        );
        for (final detail in result.taskDetails) {
          buffer.writeln('  $detail');
        }
      }
    }

    if (report.allMatched) {
      buffer.writeln('All todo lists and tasks match remote.');
    }
    buffer.writeln('=' * 80);
    buffer.writeln();
    await _logger.log(buffer.toString());
  }
}
