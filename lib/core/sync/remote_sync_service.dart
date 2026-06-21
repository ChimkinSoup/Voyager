import 'dart:async';

// ignore_for_file: prefer_initializing_formals
import 'package:flutter/foundation.dart';
import 'package:voyager/core/sync/crdt_document_resolver.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/sync_activity.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/weather_service.dart';

class RemoteSyncService {
  RemoteSyncService({
    required SyncRepository syncRepository,
    required JournalRepository journalRepository,
    required TodoRepository todoRepository,
    required WeatherService weatherService,
    required SyncEngine syncEngine,
    SyncActivityController? syncActivity,
    CrdtDocumentResolver? crdtResolver,
  }) : _syncRepository = syncRepository,
       _journalRepository = journalRepository,
       _todoRepository = todoRepository,
       _weatherService = weatherService,
       _syncEngine = syncEngine,
       _syncActivity = syncActivity,
       _crdtResolver = crdtResolver ?? CrdtDocumentResolver();

  final SyncRepository _syncRepository;
  final JournalRepository _journalRepository;
  final TodoRepository _todoRepository;
  final WeatherService _weatherService;
  final SyncEngine _syncEngine;
  final SyncActivityController? _syncActivity;
  final CrdtDocumentResolver _crdtResolver;

  Future<void> pullAll({bool skipWeather = false}) async {
    await pullJournalAndTodoData();
    if (!skipWeather) {
      await Future.wait<void>([
        _weatherService.syncLocationFromRemote(),
        _weatherService.syncForecastFromRemote(),
      ]);
    }
  }

  Future<void> pullJournalAndTodoData() async {
    await pullJournals();
    await pullJournalEntries();
    await pullTodoLists();
    await pullTodoTasks();
  }

  Future<void> pullForCollection(String collection) async {
    switch (collection) {
      case FirestoreCollections.journals:
        await pullJournals();
      case FirestoreCollections.journalEntries:
        await pullJournalEntries();
      case FirestoreCollections.todoLists:
        await pullTodoLists();
      case FirestoreCollections.todoTasks:
        await pullTodoTasks();
    }
  }

  Future<void> pullJournals() async {
    await _pullCollection(
      FirestoreCollections.journals,
      apply: (id, data, {required fromCrdt}) async {
        final local = fromCrdt ? null : await _journalRepository.getJournal(id);
        final merged = mergeJournalFromRemote(data, id, local: local);
        await _journalRepository.upsertJournal(merged);
      },
    );
  }

  Future<void> pullJournalEntries() async {
    await _pullCollection(
      FirestoreCollections.journalEntries,
      apply: (id, data, {required fromCrdt}) async {
        final local = fromCrdt ? null : await _journalRepository.getEntry(id);
        final merged = mergeJournalEntryFromRemote(data, id, local: local);
        await _journalRepository.upsertEntry(merged);
      },
    );
  }

  Future<void> pullTodoLists() async {
    await _pullCollection(
      FirestoreCollections.todoLists,
      apply: (id, data, {required fromCrdt}) async {
        TodoListModel? local;
        if (!fromCrdt) {
          final lists = await _todoRepository.listLists(includeDeleted: true);
          local = lists.cast<TodoListModel?>().firstWhere(
            (list) => list!.id == id,
            orElse: () => null,
          );
        }
        final merged = mergeTodoListFromRemote(data, id, local: local);
        await _todoRepository.upsertList(merged);
      },
    );
  }

  Future<void> pullTodoTasks() async {
    final localTasks = await _loadTaskIndex();
    await _pullCollection(
      FirestoreCollections.todoTasks,
      apply: (id, data, {required fromCrdt}) async {
        try {
          final merged = mergeTodoTaskFromRemote(
            data,
            id,
            local: fromCrdt ? null : localTasks[id],
          );
          await _todoRepository.upsertTask(merged);
          localTasks[id] = merged;
        } on StateError {
          // Skip malformed remote documents.
        }
      },
    );
  }

  Future<void> _pullCollection(
    String collection, {
    required Future<void> Function(
      String id,
      Map<String, dynamic> data, {
      required bool fromCrdt,
    })
    apply,
  }) async {
    _syncActivity?.recordDownloadCheck(collection);
    final docs = await _syncRepository.listCollectionDocuments(collection);
    for (final doc in docs) {
      final id = doc.data['id'] as String? ?? doc.id;
      final crdtPayload = await _crdtResolver.resolvePayload(
        _syncRepository,
        id,
      );
      if (crdtPayload != null) {
        await apply(id, crdtPayload, fromCrdt: true);
      } else {
        await apply(id, doc.data, fromCrdt: false);
      }
    }
  }

  Future<Map<String, TodoTask>> _loadTaskIndex() async {
    final index = <String, TodoTask>{};
    final lists = await _todoRepository.listLists(includeDeleted: true);
    for (final list in lists) {
      final tasks = await _todoRepository.listTasks(
        list.id,
        includeDeleted: true,
        topLevelOnly: false,
      );
      for (final task in tasks) {
        index[task.id] = task;
      }
    }
    return index;
  }

  void pushJournal(Journal journal) {
    _syncEngine.scheduleDocumentSync(
      collection: FirestoreCollections.journals,
      documentId: journal.id,
      payload: journalToFirestore(journal),
    );
  }

  void pushJournalEntry(JournalEntry entry) {
    _syncEngine.scheduleDocumentSync(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      payload: journalEntryToFirestore(entry),
    );
  }

  void pushJournalEntryNow(JournalEntry entry) {
    _syncEngine.cancelScheduledDocumentSync();
    unawaited(
      _syncEngine.syncDocumentImmediately(
        collection: FirestoreCollections.journalEntries,
        documentId: entry.id,
        payload: journalEntryToFirestore(entry),
      ),
    );
  }

  void pushTodoList(TodoListModel list) {
    unawaited(
      _syncEngine.syncDocumentImmediately(
        collection: FirestoreCollections.todoLists,
        documentId: list.id,
        payload: todoListToFirestore(list),
      ),
    );
  }

  void pushTodoTaskNow(TodoTask task) {
    unawaited(
      _syncEngine.syncDocumentImmediately(
        collection: FirestoreCollections.todoTasks,
        documentId: task.id,
        payload: todoTaskToFirestore(task),
        cancelDebounceKey: _todoTaskDebounceKey(task.id),
      ),
    );
  }

  void pushTodoTaskTitleDebounced(TodoTask task) {
    _syncEngine.scheduleDebouncedDocumentSync(
      debounceKey: _todoTaskDebounceKey(task.id),
      collection: FirestoreCollections.todoTasks,
      documentId: task.id,
      payload: todoTaskToFirestore(task),
    );
  }

  Future<void> pushJournalById(String id) async {
    final journal = await _journalRepository.getJournal(id);
    if (journal != null) pushJournal(journal);
  }

  String _todoTaskDebounceKey(String taskId) => 'todo_task_$taskId';
}

class LiveSyncController {
  LiveSyncController({
    required RemoteSyncService remoteSync,
    required SyncRepository syncRepository,
    required VoidCallback onChanged,
  }) : _remoteSync = remoteSync,
       _syncRepository = syncRepository,
       _onChanged = onChanged;

  final RemoteSyncService _remoteSync;
  final SyncRepository _syncRepository;
  final VoidCallback _onChanged;
  final List<StreamSubscription<void>> _subscriptions = [];
  var _started = false;
  var _pullInFlight = false;
  final _queuedCollections = <String>{};

  static const _watchedCollections = [
    FirestoreCollections.journals,
    FirestoreCollections.journalEntries,
    FirestoreCollections.todoLists,
    FirestoreCollections.todoTasks,
  ];

  void start() {
    if (_started || _syncRepository is NoOpSyncRepository) return;
    _started = true;

    for (final collection in _watchedCollections) {
      _subscriptions.add(
        _syncRepository.watchCollection(collection).listen((_) {
          unawaited(_handleRemoteChange(collection));
        }),
      );
    }
  }

  Future<void> _handleRemoteChange(String collection) async {
    if (_pullInFlight) {
      _queuedCollections.add(collection);
      return;
    }

    _pullInFlight = true;
    try {
      var pending = {collection};
      while (pending.isNotEmpty) {
        for (final next in pending) {
          try {
            await _remoteSync.pullForCollection(next);
            _onChanged();
          } catch (error, stackTrace) {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stackTrace,
                library: 'LiveSyncController',
                context: ErrorDescription('while applying live remote sync'),
              ),
            );
          }
        }
        pending = Set<String>.from(_queuedCollections);
        _queuedCollections.clear();
      }
    } finally {
      _pullInFlight = false;
    }
  }

  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _started = false;
  }
}
