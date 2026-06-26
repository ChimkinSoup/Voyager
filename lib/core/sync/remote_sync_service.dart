import 'dart:async';

// ignore_for_file: prefer_initializing_formals
import 'package:flutter/foundation.dart';
import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/core/sync/crdt_document_resolver.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/constants/todo_constants.dart';
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
    Duration uploadDebounceDelay = const Duration(seconds: syncDebounceSeconds),
  }) : _syncRepository = syncRepository,
       _journalRepository = journalRepository,
       _todoRepository = todoRepository,
       _weatherService = weatherService,
       _syncEngine = syncEngine,
       _syncActivity = syncActivity,
       _crdtResolver = crdtResolver ?? CrdtDocumentResolver(),
       _uploadDebounceDelay = uploadDebounceDelay;

  final SyncRepository _syncRepository;
  final JournalRepository _journalRepository;
  final TodoRepository _todoRepository;
  final WeatherService _weatherService;
  final SyncEngine _syncEngine;
  final SyncActivityController? _syncActivity;
  final CrdtDocumentResolver _crdtResolver;
  final Duration _uploadDebounceDelay;
  final Map<String, Timer> _activeDebouncers = {};
  final Map<String, Future<void>> _localSaveChains = {};
  final Map<String, Future<void> Function()> _pendingRemoteSaves = {};
  final Map<String, int> _localSaveGenerations = {};
  final Set<String> _activelyEditedDocuments = {};

  String documentKey(String collection, String documentId) {
    return '${collection}_$documentId';
  }

  Future<void> saveLocalThenScheduleUpload({
    required String collection,
    required String documentId,
    required Future<void> Function() saveLocal,
    required Future<void> Function() saveRemote,
  }) {
    final key = documentKey(collection, documentId);
    final generation = (_localSaveGenerations[key] ?? 0) + 1;
    _localSaveGenerations[key] = generation;

    final previous = _localSaveChains[key] ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .catchError((_) {
          // Keep the queue moving after a failed save; FlutterError already
          // reports async failures at call sites that await this future.
        })
        .then((_) async {
          if (_localSaveGenerations[key] != generation) {
            return;
          }
          await saveLocal();
          if (_localSaveGenerations[key] == generation) {
            _scheduleRemoteUpload(key, saveRemote);
          }
        });
    _localSaveChains[key] = next.whenComplete(() {
      if (identical(_localSaveChains[key], next)) {
        _localSaveChains.remove(key);
      }
    });
    return next;
  }

  Future<void> saveJournalEntryThenScheduleUpload({
    required String entryId,
    required Future<void> Function() saveLocal,
  }) {
    return saveLocalThenScheduleUpload(
      collection: FirestoreCollections.journalEntries,
      documentId: entryId,
      saveLocal: saveLocal,
      saveRemote: () async {
        final latest = await _journalRepository.getEntry(entryId);
        if (latest != null) {
          await _uploadJournalEntryNow(latest);
        }
      },
    );
  }

  Future<void> saveTodoTaskThenScheduleUpload(TodoTask task) {
    return saveLocalThenScheduleUpload(
      collection: FirestoreCollections.todoTasks,
      documentId: task.id,
      saveLocal: () => _todoRepository.upsertTask(task),
      saveRemote: () async {
        final latest = await _findTodoTask(task.id);
        if (latest != null) {
          await _uploadTodoTaskNow(latest);
        }
      },
    );
  }

  Future<void> flushPending(String key) async {
    await _localSaveChains[key]?.catchError((_) {});
    final remoteSave = _pendingRemoteSaves.remove(key);
    _activeDebouncers.remove(key)?.cancel();
    if (remoteSave != null) {
      await remoteSave();
    }
  }

  Future<void> flushDocument(String collection, String documentId) {
    return flushPending(documentKey(collection, documentId));
  }

  Future<void> flushAllPending() async {
    final keys = <String>{
      ..._activeDebouncers.keys,
      ..._pendingRemoteSaves.keys,
      ..._localSaveChains.keys,
    };
    await Future.wait(keys.map(flushPending));
  }

  void cancelPending(String key) {
    _activeDebouncers.remove(key)?.cancel();
    _pendingRemoteSaves.remove(key);
  }

  void cancelDocument(String collection, String documentId) {
    cancelPending(documentKey(collection, documentId));
  }

  void setDocumentEditing({
    required String collection,
    required String documentId,
    required bool isEditing,
  }) {
    final key = documentKey(collection, documentId);
    if (isEditing) {
      _activelyEditedDocuments.add(key);
    } else {
      _activelyEditedDocuments.remove(key);
    }
  }

  bool isDocumentEditing(String collection, String documentId) {
    return _activelyEditedDocuments.contains(
      documentKey(collection, documentId),
    );
  }

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
        await _journalRepository.upsertJournal(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<void> pullJournalEntries() async {
    await _pullCollection(
      FirestoreCollections.journalEntries,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _journalRepository.getEntry(id);
        var merged = mergeJournalEntryFromRemote(
          data,
          id,
          local: fromCrdt ? null : local,
        );
        if (local != null &&
            isDocumentEditing(FirestoreCollections.journalEntries, id)) {
          merged = merged.copyWith(
            body: local.body,
            richBodyJson: local.richBodyJson,
            tags: local.tags,
          );
        }
        await _journalRepository.upsertEntry(
          merged,
          recordLocalActivity: false,
        );
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
        await _todoRepository.upsertList(
          merged,
          recordLocalActivity: false,
        );
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
          await _todoRepository.upsertTask(
            merged,
            recordLocalActivity: false,
          );
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
      final firestoreDocId = doc.data['id'] as String? ?? doc.id;
      final localDocId = _localDocumentId(collection, firestoreDocId);
      final crdtPayload = await _crdtResolver.resolvePayload(
        _syncRepository,
        _firestoreDocumentId(collection, localDocId),
      );
      if (crdtPayload != null) {
        await apply(
          localDocId,
          _normalizeRemoteDocument(collection, crdtPayload),
          fromCrdt: true,
        );
      } else {
        await apply(
          localDocId,
          _normalizeRemoteDocument(collection, doc.data),
          fromCrdt: false,
        );
      }
    }
  }

  String _firestoreDocumentId(String collection, String localId) {
    if (collection == FirestoreCollections.journals) {
      return journalDocumentIdForFirestore(localId);
    }
    if (collection == FirestoreCollections.todoLists) {
      return todoListDocumentIdForFirestore(localId);
    }
    return localId;
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
    cancelDocument(FirestoreCollections.journals, journal.id);
    unawaited(_uploadJournalNow(journal));
  }

  void pushJournalEntry(JournalEntry entry) {
    _scheduleRemoteUpload(
      documentKey(FirestoreCollections.journalEntries, entry.id),
      () => _uploadJournalEntryNow(entry),
    );
  }

  void pushJournalEntryNow(JournalEntry entry) {
    cancelDocument(FirestoreCollections.journalEntries, entry.id);
    unawaited(_uploadJournalEntryNow(entry));
  }

  void pushTodoList(TodoListModel list) {
    cancelDocument(FirestoreCollections.todoLists, list.id);
    unawaited(_uploadTodoListNow(list));
  }

  Future<void> pushTodoTaskNow(TodoTask task) {
    cancelDocument(FirestoreCollections.todoTasks, task.id);
    return _uploadTodoTaskNow(task);
  }

  void pushTodoTaskTitleDebounced(TodoTask task) {
    _scheduleRemoteUpload(
      documentKey(FirestoreCollections.todoTasks, task.id),
      () => _uploadTodoTaskNow(task),
    );
  }

  Future<void> pushJournalById(String id) async {
    final journal = await _journalRepository.getJournal(id);
    if (journal != null) pushJournal(journal);
  }

  Future<TodoTask?> _findTodoTask(String taskId) async {
    final tasks = await _loadTaskIndex();
    return tasks[taskId];
  }

  void _scheduleRemoteUpload(String key, Future<void> Function() remoteSave) {
    _activeDebouncers.remove(key)?.cancel();
    _pendingRemoteSaves[key] = remoteSave;
    _activeDebouncers[key] = Timer(_uploadDebounceDelay, () {
      final save = _pendingRemoteSaves.remove(key);
      _activeDebouncers.remove(key);
      if (save != null) {
        unawaited(save());
      }
    });
  }

  Future<void> _uploadJournalEntryNow(JournalEntry entry) {
    return _syncEngine.syncDocumentImmediately(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      payload: journalEntryToFirestore(entry),
    );
  }

  Future<void> _uploadJournalNow(Journal journal) {
    return _syncEngine.syncDocumentImmediately(
      collection: FirestoreCollections.journals,
      documentId: journalDocumentIdForFirestore(journal.id),
      payload: journalToFirestore(journal),
    );
  }

  Future<void> _uploadTodoListNow(TodoListModel list) {
    return _syncEngine.syncDocumentImmediately(
      collection: FirestoreCollections.todoLists,
      documentId: todoListDocumentIdForFirestore(list.id),
      payload: todoListToFirestore(list),
    );
  }

  Future<void> _uploadTodoTaskNow(TodoTask task) {
    return _syncEngine.syncDocumentImmediately(
      collection: FirestoreCollections.todoTasks,
      documentId: task.id,
      payload: todoTaskToFirestore(task),
    );
  }

  void dispose() {
    for (final timer in _activeDebouncers.values) {
      timer.cancel();
    }
    _activeDebouncers.clear();
    _pendingRemoteSaves.clear();
    _localSaveChains.clear();
    _localSaveGenerations.clear();
    _activelyEditedDocuments.clear();
  }
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
