import 'dart:async';
import 'dart:convert';

// ignore_for_file: prefer_initializing_formals
import 'package:flutter/foundation.dart';
import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/sync/crdt_document_resolver.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/utils/journal_tags.dart';import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/pending_text_merge.dart';
import 'package:voyager/core/sync/scroll_activity_gate.dart';
import 'package:voyager/core/sync/text_delta_injector.dart';
import 'package:voyager/core/sync/sync_activity.dart';
import 'package:voyager/core/sync/sync_conflict_detector.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/domain/models/sync_conflict.dart';
import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/weather_service.dart';

class RemoteSyncService {
  RemoteSyncService({
    required SyncRepository syncRepository,
    required JournalRepository journalRepository,
    required DreamRepository dreamRepository,
    required TodoRepository todoRepository,
    required WeatherService weatherService,
    required SyncEngine syncEngine,
    SyncConflictRepository? syncConflictRepository,
    SyncActivityController? syncActivity,
    CrdtDocumentResolver? crdtResolver,
    CharacterOpRegistry? charOpRegistry,
    SyncConflictDetector? conflictDetector,
    Duration uploadDebounceDelay = const Duration(seconds: syncDebounceSeconds),
    this.deviceId = 'local-device',
    this.forceConflictUi = false,
  }) : _syncRepository = syncRepository,
       _journalRepository = journalRepository,
       _dreamRepository = dreamRepository,
       _todoRepository = todoRepository,
       _weatherService = weatherService,
       _syncEngine = syncEngine,
       _syncConflictRepository = syncConflictRepository,
       _syncActivity = syncActivity,
       _crdtResolver = crdtResolver ?? CrdtDocumentResolver(),
       _charOpRegistry = charOpRegistry ?? CharacterOpRegistry(),
       _conflictDetector = conflictDetector ?? SyncConflictDetector(),
       _charMerger = CharacterSequenceCrdtMerger(),
       _uploadDebounceDelay = uploadDebounceDelay;

  final SyncRepository _syncRepository;
  final JournalRepository _journalRepository;
  final DreamRepository _dreamRepository;
  final TodoRepository _todoRepository;
  final WeatherService _weatherService;
  final SyncEngine _syncEngine;
  final SyncConflictRepository? _syncConflictRepository;
  final SyncActivityController? _syncActivity;
  final CrdtDocumentResolver _crdtResolver;
  final CharacterOpRegistry _charOpRegistry;
  final SyncConflictDetector _conflictDetector;
  final CharacterSequenceCrdtMerger _charMerger;
  final Duration _uploadDebounceDelay;
  final String deviceId;
  bool forceConflictUi;
  var _forceNextDownloadConflict = false;
  final Map<String, Timer> _activeDebouncers = {};
  final Map<String, Future<void>> _localSaveChains = {};
  final Map<String, Future<void> Function()> _pendingRemoteSaves = {};
  final Map<String, int> _localSaveGenerations = {};
  final Set<String> _activelyEditedDocuments = {};
  final PendingTextMergeBuffer _pendingTextMergeBuffer = PendingTextMergeBuffer();

  /// Documents this device pushed to remote recently, keyed by
  /// [documentKey]. Firestore's snapshot listener fires for our own writes
  /// as soon as they land in the local cache — not just for changes from
  /// other devices — so [LiveSyncController] would otherwise re-fetch,
  /// CRDT-merge, and re-write every document we just saved a second time.
  /// Since we already hold the freshest local state for anything we just
  /// pushed, that echo is safe to skip within [_selfEchoWindow].
  final Map<String, DateTime> _selfEchoAt = {};
  static const _selfEchoWindow = Duration(seconds: 15);

  void _markSelfEcho(String collection, String localDocumentId) {
    _selfEchoAt[documentKey(collection, localDocumentId)] = DateTime.now();
  }

  bool _consumeSelfEcho(String collection, String localDocumentId) {
    final key = documentKey(collection, localDocumentId);
    final at = _selfEchoAt.remove(key);
    if (at == null) return false;
    return DateTime.now().difference(at) < _selfEchoWindow;
  }

  CharacterOpRegistry get charOpRegistry => _charOpRegistry;

  void recordJournalTextChange({
    required String entryId,
    required String before,
    required String after,
  }) {
    _charOpRegistry.recordTextChange(
      collection: FirestoreCollections.journalEntries,
      documentId: entryId,
      clientId: deviceId,
      before: before,
      after: after,
    );
  }

  void recordDreamTextChange({
    required String entryId,
    required String before,
    required String after,
  }) {
    _charOpRegistry.recordTextChange(
      collection: FirestoreCollections.dreamEntries,
      documentId: entryId,
      clientId: deviceId,
      before: before,
      after: after,
    );
  }

  void recordTodoNotesChange({
    required String taskId,
    required String before,
    required String after,
  }) {
    _charOpRegistry.recordTextChange(
      collection: FirestoreCollections.todoTasks,
      documentId: taskId,
      clientId: deviceId,
      before: before,
      after: after,
    );
  }

  Future<List<SyncConflict>> listConflicts() async {
    final repo = _syncConflictRepository;
    if (repo == null) return const [];
    return repo.listConflicts();
  }

  Future<void> resolveConflictKeepLocal(SyncConflict conflict) async {
    final repo = _syncConflictRepository;
    if (repo == null) return;
    if (conflict.collection == FirestoreCollections.journalEntries) {
      final local = await _journalRepository.getEntry(conflict.documentId);
      if (local != null) {
        final remotePayload = jsonDecode(conflict.remotePayloadJson) as Map<String, dynamic>;
        final opsList = remotePayload['_remoteCharOps'] as List<dynamic>?;
        final ops = opsList?.map((e) => CharacterOperation.fromJson(e as Map<String, dynamic>)).toList() ?? const [];
        
        _charOpRegistry.loadSession(
          collection: FirestoreCollections.journalEntries,
          documentId: conflict.documentId,
          clientId: deviceId,
          operations: ops,
        );
        _charOpRegistry.recordTextChange(
          collection: FirestoreCollections.journalEntries,
          documentId: conflict.documentId,
          clientId: deviceId,
          before: conflict.remoteText ?? '',
          after: local.body,
        );
        await _uploadJournalEntryNow(local, bumpVersion: true);
      }
    } else if (conflict.collection == FirestoreCollections.dreamEntries) {
      final local = await _dreamRepository.getEntry(conflict.documentId);
      if (local != null) {
        final remotePayload = jsonDecode(conflict.remotePayloadJson) as Map<String, dynamic>;
        final opsList = remotePayload['_remoteCharOps'] as List<dynamic>?;
        final ops = opsList?.map((e) => CharacterOperation.fromJson(e as Map<String, dynamic>)).toList() ?? const [];

        _charOpRegistry.loadSession(
          collection: FirestoreCollections.dreamEntries,
          documentId: conflict.documentId,
          clientId: deviceId,
          operations: ops,
        );
        _charOpRegistry.recordTextChange(
          collection: FirestoreCollections.dreamEntries,
          documentId: conflict.documentId,
          clientId: deviceId,
          before: conflict.remoteText ?? '',
          after: local.body,
        );
        await _uploadDreamEntryNow(local, bumpVersion: true);
      }
    } else if (conflict.collection == FirestoreCollections.todoTasks) {
      final local = await _findTodoTask(conflict.documentId);
      if (local != null) {
        final remotePayload = jsonDecode(conflict.remotePayloadJson) as Map<String, dynamic>;
        final opsList = remotePayload['_remoteCharOps'] as List<dynamic>?;
        final ops = opsList?.map((e) => CharacterOperation.fromJson(e as Map<String, dynamic>)).toList() ?? const [];

        _charOpRegistry.loadSession(
          collection: FirestoreCollections.todoTasks,
          documentId: conflict.documentId,
          clientId: deviceId,
          operations: ops,
        );
        _charOpRegistry.recordTextChange(
          collection: FirestoreCollections.todoTasks,
          documentId: conflict.documentId,
          clientId: deviceId,
          before: conflict.remoteText ?? '',
          after: local.notes ?? '',
        );
        await _uploadTodoTaskNow(local, bumpVersion: true);
      }
    }
    await repo.deleteConflict(conflict.id);
  }

  Future<void> resolveConflictKeepRemote(SyncConflict conflict) async {
    final repo = _syncConflictRepository;
    if (repo == null) return;
    final remote = jsonDecode(conflict.remotePayloadJson) as Map<String, dynamic>;
    if (conflict.collection == FirestoreCollections.journalEntries) {
      final local = await _journalRepository.getEntry(conflict.documentId);
      final merged = mergeJournalEntryFromRemote(
        remote,
        conflict.documentId,
        local: local,
      );
      await _journalRepository.upsertEntry(merged, recordLocalActivity: false);
      
      final opsList = remote['_remoteCharOps'] as List<dynamic>?;
      final ops = opsList?.map((e) => CharacterOperation.fromJson(e as Map<String, dynamic>)).toList() ?? const [];
      _charOpRegistry.loadSession(
        collection: FirestoreCollections.journalEntries,
        documentId: conflict.documentId,
        clientId: deviceId,
        operations: ops,
      );
      _charOpRegistry.recordTextChange(
        collection: FirestoreCollections.journalEntries,
        documentId: conflict.documentId,
        clientId: deviceId,
        before: conflict.remoteText ?? '',
        after: merged.body,
      );
      await _uploadJournalEntryNow(merged, bumpVersion: true);
    } else if (conflict.collection == FirestoreCollections.dreamEntries) {
      final local = await _dreamRepository.getEntry(conflict.documentId);
      final merged = mergeDreamEntryFromRemote(
        remote,
        conflict.documentId,
        local: local,
      );
      await _dreamRepository.upsertEntry(merged, recordLocalActivity: false);

      final opsList = remote['_remoteCharOps'] as List<dynamic>?;
      final ops = opsList?.map((e) => CharacterOperation.fromJson(e as Map<String, dynamic>)).toList() ?? const [];
      _charOpRegistry.loadSession(
        collection: FirestoreCollections.dreamEntries,
        documentId: conflict.documentId,
        clientId: deviceId,
        operations: ops,
      );
      _charOpRegistry.recordTextChange(
        collection: FirestoreCollections.dreamEntries,
        documentId: conflict.documentId,
        clientId: deviceId,
        before: conflict.remoteText ?? '',
        after: merged.body,
      );
      await _uploadDreamEntryNow(merged, bumpVersion: true);
    } else if (conflict.collection == FirestoreCollections.todoTasks) {
      final local = await _findTodoTask(conflict.documentId);
      final merged = mergeTodoTaskFromRemote(
        remote,
        conflict.documentId,
        local: local,
      );
      await _todoRepository.upsertTask(merged, recordLocalActivity: false);

      final opsList = remote['_remoteCharOps'] as List<dynamic>?;
      final ops = opsList?.map((e) => CharacterOperation.fromJson(e as Map<String, dynamic>)).toList() ?? const [];
      _charOpRegistry.loadSession(
        collection: FirestoreCollections.todoTasks,
        documentId: conflict.documentId,
        clientId: deviceId,
        operations: ops,
      );
      _charOpRegistry.recordTextChange(
        collection: FirestoreCollections.todoTasks,
        documentId: conflict.documentId,
        clientId: deviceId,
        before: conflict.remoteText ?? '',
        after: merged.notes ?? '',
      );
      await _uploadTodoTaskNow(merged, bumpVersion: true);
    }
    await repo.deleteConflict(conflict.id);
  }

  Future<void> resolveConflictManualMerge(
    SyncConflict conflict, {
    required String mergedText,
  }) async {
    final repo = _syncConflictRepository;
    if (repo == null) return;
    if (conflict.collection == FirestoreCollections.journalEntries) {
      final local = await _journalRepository.getEntry(conflict.documentId);
      if (local == null) return;
      final updated = local.copyWith(
        body: mergedText,
        tags: extractTags(mergedText),
        bumpVersion: true,
      );
      await _journalRepository.upsertEntry(updated, recordLocalActivity: false);
      
      final remotePayload = jsonDecode(conflict.remotePayloadJson) as Map<String, dynamic>;
      final opsList = remotePayload['_remoteCharOps'] as List<dynamic>?;
      final ops = opsList?.map((e) => CharacterOperation.fromJson(e as Map<String, dynamic>)).toList() ?? const [];
      _charOpRegistry.loadSession(
        collection: FirestoreCollections.journalEntries,
        documentId: conflict.documentId,
        clientId: deviceId,
        operations: ops,
      );
      _charOpRegistry.recordTextChange(
        collection: FirestoreCollections.journalEntries,
        documentId: conflict.documentId,
        clientId: deviceId,
        before: conflict.remoteText ?? '',
        after: mergedText,
      );
      await _uploadJournalEntryNow(updated, bumpVersion: true);
    } else if (conflict.collection == FirestoreCollections.dreamEntries) {
      final local = await _dreamRepository.getEntry(conflict.documentId);
      if (local == null) return;
      final updated = local.copyWith(
        body: mergedText,
        tags: extractTags(mergedText),
        bumpVersion: true,
      );
      await _dreamRepository.upsertEntry(updated, recordLocalActivity: false);

      final remotePayload = jsonDecode(conflict.remotePayloadJson) as Map<String, dynamic>;
      final opsList = remotePayload['_remoteCharOps'] as List<dynamic>?;
      final ops = opsList?.map((e) => CharacterOperation.fromJson(e as Map<String, dynamic>)).toList() ?? const [];
      _charOpRegistry.loadSession(
        collection: FirestoreCollections.dreamEntries,
        documentId: conflict.documentId,
        clientId: deviceId,
        operations: ops,
      );
      _charOpRegistry.recordTextChange(
        collection: FirestoreCollections.dreamEntries,
        documentId: conflict.documentId,
        clientId: deviceId,
        before: conflict.remoteText ?? '',
        after: mergedText,
      );
      await _uploadDreamEntryNow(updated, bumpVersion: true);
    } else if (conflict.collection == FirestoreCollections.todoTasks) {
      final local = await _findTodoTask(conflict.documentId);
      if (local == null) return;
      final updated = local.copyWith(
        notes: mergedText.isEmpty ? null : mergedText,
        clearNotes: mergedText.isEmpty,
        bumpVersion: true,
      );
      await _todoRepository.upsertTask(updated, recordLocalActivity: false);

      final remotePayload = jsonDecode(conflict.remotePayloadJson) as Map<String, dynamic>;
      final opsList = remotePayload['_remoteCharOps'] as List<dynamic>?;
      final ops = opsList?.map((e) => CharacterOperation.fromJson(e as Map<String, dynamic>)).toList() ?? const [];
      _charOpRegistry.loadSession(
        collection: FirestoreCollections.todoTasks,
        documentId: conflict.documentId,
        clientId: deviceId,
        operations: ops,
      );
      _charOpRegistry.recordTextChange(
        collection: FirestoreCollections.todoTasks,
        documentId: conflict.documentId,
        clientId: deviceId,
        before: conflict.remoteText ?? '',
        after: mergedText.isEmpty ? '' : mergedText,
      );
      await _uploadTodoTaskNow(updated, bumpVersion: true);
    }
    await repo.deleteConflict(conflict.id);
  }

  Future<void> resolveAllConflictsKeepLocal() async {
    final conflicts = await listConflicts();
    for (final conflict in List<SyncConflict>.from(conflicts)) {
      await resolveConflictKeepLocal(conflict);
    }
  }

  Future<void> resolveAllConflictsKeepRemote() async {
    final conflicts = await listConflicts();
    for (final conflict in List<SyncConflict>.from(conflicts)) {
      await resolveConflictKeepRemote(conflict);
    }
  }

  /// Hard-deletes a document and its char-op history from Firestore.
  ///
  /// Clears local quarantine/conflict state but does not remove the local row.
  /// Returns how many [sync_operations] rows were deleted.
  Future<int> permanentlyDeleteFromRemote({
    required String collection,
    required String documentId,
  }) async {
    cancelDocument(collection, documentId);
    await flushDocument(collection, documentId);

    final firestoreDocId = firestoreDocumentIdForLocal(collection, documentId);
    await _syncRepository.deleteDocument(collection, firestoreDocId);
    final operationsDeleted =
        await _syncRepository.deleteOperationsForDocument(documentId);

    _charOpRegistry.removeSession(collection, documentId);
    _pendingTextMergeBuffer.clearDocument(collection, documentId);

    final conflictRepo = _syncConflictRepository;
    if (conflictRepo != null) {
      await conflictRepo.deleteConflictsForDocument(collection, documentId);
    }

    return operationsDeleted;
  }

  /// Forces an overwrite of the journal entry text by wiping remote CRDT operations,
  /// resetting the local editing session, recording the new text, and pushing.
  /// Used for out-of-band wholesale text edits (like the Search page popup) 
  /// where an active sequential CRDT session isn't maintained.
  Future<void> forceOverwriteJournalEntryText(JournalEntry entry) async {
    await _syncRepository.deleteOperationsForDocument(entry.id);
    _charOpRegistry.resetSession(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      clientId: deviceId,
      text: '',
    );
    _charOpRegistry.recordTextChange(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      clientId: deviceId,
      before: '',
      after: entry.body,
    );
    await _uploadJournalEntryNow(entry, bumpVersion: true);
    
    _charOpRegistry.removeSession(
      FirestoreCollections.journalEntries,
      entry.id,
    );
  }

  /// Hard-deletes a journal entry from Firestore (if present) and this device.
  Future<({int remoteOperationsDeleted, bool localDeleted})>
  purgeJournalEntryEverywhere(String entryId) async {
    var remoteOperationsDeleted = 0;
    try {
      remoteOperationsDeleted = await permanentlyDeleteFromRemote(
        collection: FirestoreCollections.journalEntries,
        documentId: entryId,
      );
    } on Object {
      // Remote may already be gone; still remove the local row.
    }

    final localEntry = await _journalRepository.getEntry(entryId);
    if (localEntry != null) {
      await _journalRepository.hardDeleteEntry(entryId);
    }

    return (
      remoteOperationsDeleted: remoteOperationsDeleted,
      localDeleted: localEntry != null,
    );
  }

  /// Hard-deletes a dream entry from Firestore (if present) and this device.
  Future<({int remoteOperationsDeleted, bool localDeleted})>
  purgeDreamEntryEverywhere(String entryId) async {
    var remoteOperationsDeleted = 0;
    try {
      remoteOperationsDeleted = await permanentlyDeleteFromRemote(
        collection: FirestoreCollections.dreamEntries,
        documentId: entryId,
      );
    } on Object {
      // Remote may already be gone; still remove the local row.
    }

    final localEntry = await _dreamRepository.getEntry(entryId);
    if (localEntry != null) {
      await _dreamRepository.hardDeleteEntry(entryId);
    }

    return (
      remoteOperationsDeleted: remoteOperationsDeleted,
      localDeleted: localEntry != null,
    );
  }

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
          final callStart = DevFlags.verboseSync ? DateTime.now() : null;
          await saveLocal();
          if (callStart != null) {
            final elapsed = DateTime.now().difference(callStart).inMilliseconds;
            debugPrint('[sync] local save for $key took ${elapsed}ms');
          }
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

  Future<void> saveDreamEntryThenScheduleUpload({
    required String entryId,
    required Future<void> Function() saveLocal,
  }) {
    return saveLocalThenScheduleUpload(
      collection: FirestoreCollections.dreamEntries,
      documentId: entryId,
      saveLocal: saveLocal,
      saveRemote: () async {
        final latest = await _dreamRepository.getEntry(entryId);
        if (latest != null) {
          await _uploadDreamEntryNow(latest);
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

  Future<void> prepareEditingSession({
    required String collection,
    required String documentId,
    required String initialText,
  }) async {
    if (_charOpRegistry.session(collection, documentId) != null) return;

    final ops = await _listRemoteCharOps(documentId);
    // The caller can keep editing while the remote op-log is being fetched, in
    // which case recordTextChange has already opened a session seeded from the
    // on-screen text. Loading the (now outdated) remote chain over the top
    // would discard those pending ops and leave the session diffing against a
    // stale baseline, so leave the live session alone — same as the fast-path
    // bail-out above.
    if (_charOpRegistry.session(collection, documentId) != null) return;

    if (ops.isNotEmpty) {
      _charOpRegistry.loadSession(
        collection: collection,
        documentId: documentId,
        clientId: deviceId,
        operations: ops,
      );
      // If the reconstructed op-chain text doesn't match what's actually
      // on screen/in SQLite (e.g. an earlier session's final char-ops were
      // never flushed to remote before an app restart), diff from the
      // stale reconstructed text to the known-good text *on the loaded
      // session* rather than discarding it and reseeding from scratch.
      // Reseeding created a second, disconnected set of char ops (fresh
      // ids/positions) for text that already had live ops on the remote
      // chain — since those old ops were never tombstoned, merging the two
      // later re-included both, interleaving every character twice. Diffing
      // in place reuses the existing ids for the unchanged span and tombs
      // only the parts that actually differ.
      final loaded = _charOpRegistry.session(collection, documentId);
      if (loaded != null && loaded.text != initialText) {
        _charOpRegistry.recordTextChange(
          collection: collection,
          documentId: documentId,
          clientId: deviceId,
          before: loaded.text,
          after: initialText,
        );
      }
    } else {
      // No remote ops exist yet — brand-new document.  Upload the full seed
      // so other devices have a complete CRDT chain to merge against later.
      // This is the ONLY code path where seeds are marked as pending; every
      // other path (e.g. the race path where the user typed before this async
      // fetch completed) must NOT upload seeds, because the remote already
      // has an authoritative chain and re-seeding would create a second set
      // of ops at the same fractional positions with different IDs — exactly
      // the collision that doubles every character on merge.
      _charOpRegistry.ensureSession(
        collection: collection,
        documentId: documentId,
        clientId: deviceId,
        initialText: initialText,
        markSeedsAsPending: true,
      );
    }
  }

  bool isDocumentEditing(String collection, String documentId) {
    return _activelyEditedDocuments.contains(
      documentKey(collection, documentId),
    );
  }

  void addPendingTextMergeListener({
    required String collection,
    required String documentId,
    required PendingTextMergeListener listener,
  }) {
    _pendingTextMergeBuffer.addListener(collection, documentId, listener);
  }

  void removePendingTextMergeListener({
    required String collection,
    required String documentId,
    required PendingTextMergeListener listener,
  }) {
    _pendingTextMergeBuffer.removeListener(collection, documentId, listener);
  }

  /// Applies buffered remote text into SQLite before a final local flush.
  Future<JournalEntry?> applyPendingJournalEntryTextMerge({
    required String entryId,
    required String currentLocalText,
  }) async {
    final pending = _pendingTextMergeBuffer.take(
      FirestoreCollections.journalEntries,
      entryId,
    );
    if (pending == null) return null;

    final body = TextDeltaInjector.injectRemoteDelta(
      localText: currentLocalText,
      oldRemoteText: pending.previousRemoteText,
      newRemoteText: pending.remoteText,
    );
    final local = await _journalRepository.getEntry(entryId);
    if (local == null) return null;

    final merged = local.copyWith(
      body: body,
      tags: pending.remoteTags,
      richBodyJson: pending.remoteRichBodyJson ?? local.richBodyJson,
      bumpVersion: false,
    );
    await _journalRepository.upsertEntry(merged);
    _pendingTextMergeBuffer.recordRemoteText(
      FirestoreCollections.journalEntries,
      entryId,
      body,
    );
    return merged;
  }

  /// Applies buffered remote text into SQLite before a final local flush.
  Future<DreamEntry?> applyPendingDreamEntryTextMerge({
    required String entryId,
    required String currentLocalText,
  }) async {
    final pending = _pendingTextMergeBuffer.take(
      FirestoreCollections.dreamEntries,
      entryId,
    );
    if (pending == null) return null;

    final body = TextDeltaInjector.injectRemoteDelta(
      localText: currentLocalText,
      oldRemoteText: pending.previousRemoteText,
      newRemoteText: pending.remoteText,
    );
    final local = await _dreamRepository.getEntry(entryId);
    if (local == null) return null;

    final merged = local.copyWith(
      body: body,
      tags: pending.remoteTags,
      bumpVersion: false,
    );
    await _dreamRepository.upsertEntry(merged);
    _pendingTextMergeBuffer.recordRemoteText(
      FirestoreCollections.dreamEntries,
      entryId,
      body,
    );
    return merged;
  }

  /// Applies buffered remote notes into SQLite before a final local flush.
  Future<TodoTask?> applyPendingTodoTaskNotesMerge({
    required String taskId,
    required String currentLocalNotes,
  }) async {
    final pending = _pendingTextMergeBuffer.take(
      FirestoreCollections.todoTasks,
      taskId,
    );
    if (pending == null) return null;

    final notes = TextDeltaInjector.injectRemoteDelta(
      localText: currentLocalNotes,
      oldRemoteText: pending.previousRemoteText,
      newRemoteText: pending.remoteText,
    );
    final local = await _findTodoTask(taskId);
    if (local == null) return null;

    final merged = local.copyWith(
      notes: notes.isEmpty ? null : notes,
      clearNotes: notes.isEmpty,
      bumpVersion: false,
    );
    await _todoRepository.upsertTask(merged);
    _pendingTextMergeBuffer.recordRemoteText(
      FirestoreCollections.todoTasks,
      taskId,
      notes,
    );
    return merged;
  }

  Future<void> pullAll({bool skipWeather = false}) async {
    if (forceConflictUi) {
      _forceNextDownloadConflict = true;
    }
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
    await pullDreamEntries();
    await pullTodoLists();
    await pullTodoTasks();
  }

  /// Returns whether anything was actually applied — false when every id in
  /// [documentIds] turned out to be a self-echo of our own recent write (see
  /// [_consumeSelfEcho]). [LiveSyncController] uses this to decide whether a
  /// UI refresh is warranted: invalidating every data provider in the app on
  /// every save (including saves that only echoed themselves back) is what
  /// was causing the todo list to rebuild a second time on top of its own
  /// already-batched refresh.
  Future<bool> pullForCollection(
    String collection, {
    Set<String>? documentIds,
  }) async {
    switch (collection) {
      case FirestoreCollections.journals:
        return pullJournals(documentIds: documentIds);
      case FirestoreCollections.journalEntries:
        return pullJournalEntries(documentIds: documentIds);
      case FirestoreCollections.dreamEntries:
        return pullDreamEntries(documentIds: documentIds);
      case FirestoreCollections.todoLists:
        return pullTodoLists(documentIds: documentIds);
      case FirestoreCollections.todoTasks:
        return pullTodoTasks(documentIds: documentIds);
    }
    return false;
  }

  Future<bool> pullJournals({Set<String>? documentIds}) {
    return _pullCollection(
      FirestoreCollections.journals,
      onlyFirestoreDocumentIds: documentIds,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _journalRepository.getJournal(id);
        final merged = mergeJournalFromRemote(data, id, local: local);
        await _journalRepository.upsertJournal(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullJournalEntries({Set<String>? documentIds}) {
    return _pullCollection(
      FirestoreCollections.journalEntries,
      onlyFirestoreDocumentIds: documentIds,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _journalRepository.getEntry(id);
        final remoteCharOps = await _listRemoteCharOps(id);
        final force = _forceNextDownloadConflict;
        if (force) _forceNextDownloadConflict = false;

        final detection = _conflictDetector.detectJournalEntryConflict(
          local: local,
          remoteData: data,
          remoteCharOps: remoteCharOps,
          forceConflict: force,
        );
        if (detection.isConflict) {
          if (local == null) {
            final fallbackEntry = mergeJournalEntryFromRemote(
              data,
              id,
              local: null,
            );
            await _journalRepository.upsertEntry(
              fallbackEntry,
              recordLocalActivity: false,
            );
          }
          final payloadWithOps = Map<String, dynamic>.from(data);
          payloadWithOps['_remoteCharOps'] = remoteCharOps.map((o) => o.toJson()).toList();

          await _quarantineConflict(
            collection: FirestoreCollections.journalEntries,
            documentId: id,
            local: local == null
                ? null
                : SyncConflictDetector.payloadJson(journalEntryToFirestore(local)),
            remote: SyncConflictDetector.payloadJson(payloadWithOps),
            localTitle: local?.title,
            remoteTitle: data['title'] as String?,
            localText: local?.body,
            remoteText: data['body'] as String?,
          );
          return;
        }

        var merged = mergeJournalEntryFromRemote(
          data,
          id,
          local: local,
          crdtText: fromCrdt
              ? CrdtTextFields.fromJournalPayload(data)
              : null,
        );
        if (local != null &&
            isDocumentEditing(FirestoreCollections.journalEntries, id)) {
          _pendingTextMergeBuffer.bufferWhileEditing(
            collection: FirestoreCollections.journalEntries,
            documentId: id,
            remoteText: merged.body,
            remoteRichBodyJson: merged.richBodyJson,
            remoteTags: merged.tags,
          );
          merged = merged.copyWith(
            body: local.body,
            richBodyJson: local.richBodyJson,
            tags: local.tags,
            bumpVersion: false,
          );
        } else {
          _pendingTextMergeBuffer.recordRemoteText(
            FirestoreCollections.journalEntries,
            id,
            merged.body,
          );
        }
        await _journalRepository.upsertEntry(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullDreamEntries({Set<String>? documentIds}) {
    return _pullCollection(
      FirestoreCollections.dreamEntries,
      onlyFirestoreDocumentIds: documentIds,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _dreamRepository.getEntry(id);
        final remoteCharOps = await _listRemoteCharOps(id);
        final force = _forceNextDownloadConflict;
        if (force) _forceNextDownloadConflict = false;

        final detection = _conflictDetector.detectDreamEntryConflict(
          local: local,
          remoteData: data,
          remoteCharOps: remoteCharOps,
          forceConflict: force,
        );
        if (detection.isConflict) {
          if (local == null) {
            final fallbackEntry = mergeDreamEntryFromRemote(
              data,
              id,
              local: null,
            );
            await _dreamRepository.upsertEntry(
              fallbackEntry,
              recordLocalActivity: false,
            );
          }
          final payloadWithOps = Map<String, dynamic>.from(data);
          payloadWithOps['_remoteCharOps'] = remoteCharOps.map((o) => o.toJson()).toList();

          await _quarantineConflict(
            collection: FirestoreCollections.dreamEntries,
            documentId: id,
            local: local == null
                ? null
                : SyncConflictDetector.payloadJson(dreamEntryToFirestore(local)),
            remote: SyncConflictDetector.payloadJson(payloadWithOps),
            localTitle: local?.title,
            remoteTitle: data['title'] as String?,
            localText: local?.body,
            remoteText: data['body'] as String?,
          );
          return;
        }

        var merged = mergeDreamEntryFromRemote(
          data,
          id,
          local: local,
          crdtText: fromCrdt
              ? CrdtTextFields.fromDreamPayload(data)
              : null,
        );
        if (local != null &&
            isDocumentEditing(FirestoreCollections.dreamEntries, id)) {
          _pendingTextMergeBuffer.bufferWhileEditing(
            collection: FirestoreCollections.dreamEntries,
            documentId: id,
            remoteText: merged.body,
            remoteTags: merged.tags,
          );
          merged = merged.copyWith(
            body: local.body,
            tags: local.tags,
            bumpVersion: false,
          );
        } else {
          _pendingTextMergeBuffer.recordRemoteText(
            FirestoreCollections.dreamEntries,
            id,
            merged.body,
          );
        }
        await _dreamRepository.upsertEntry(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullTodoLists({Set<String>? documentIds}) {
    return _pullCollection(
      FirestoreCollections.todoLists,
      onlyFirestoreDocumentIds: documentIds,
      apply: (id, data, {required fromCrdt}) async {
        final lists = await _todoRepository.listLists(includeDeleted: true);
        final local = lists.cast<TodoListModel?>().firstWhere(
          (list) => list!.id == id,
          orElse: () => null,
        );
        final merged = mergeTodoListFromRemote(data, id, local: local);
        await _todoRepository.upsertList(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullTodoTasks({Set<String>? documentIds}) async {
    // A scoped pull only touches a handful of ids, so a per-id lookup is
    // cheaper than building an index of every task in every list; a full
    // pull still benefits from loading the index once up front.
    final localTasks = documentIds == null ? await _loadTaskIndex() : null;
    return _pullCollection(
      FirestoreCollections.todoTasks,
      onlyFirestoreDocumentIds: documentIds,
      apply: (id, data, {required fromCrdt}) async {
        try {
          final local = localTasks != null
              ? localTasks[id]
              : await _todoRepository.getTask(id);
          final remoteCharOps = await _listRemoteCharOps(id);
          final force = _forceNextDownloadConflict;
          if (force) _forceNextDownloadConflict = false;

          final detection = _conflictDetector.detectTodoTaskConflict(
            local: local,
            remoteData: data,
            remoteCharOps: remoteCharOps,
            forceConflict: force,
          );
          if (detection.isConflict) {
            final payloadWithOps = Map<String, dynamic>.from(data);
            payloadWithOps['_remoteCharOps'] = remoteCharOps.map((o) => o.toJson()).toList();

            await _quarantineConflict(
              collection: FirestoreCollections.todoTasks,
              documentId: id,
              local: local == null
                  ? null
                  : SyncConflictDetector.payloadJson(todoTaskToFirestore(local)),
              remote: SyncConflictDetector.payloadJson(payloadWithOps),
              localTitle: local?.title,
              remoteTitle: data['title'] as String?,
              localText: local?.notes,
              remoteText: data['notes'] as String?,
            );
            return;
          }

          var merged = mergeTodoTaskFromRemote(
            data,
            id,
            local: local,
            crdtText: fromCrdt ? CrdtTextFields.fromTodoPayload(data) : null,
          );
          if (local != null &&
              isDocumentEditing(FirestoreCollections.todoTasks, id)) {
            _pendingTextMergeBuffer.bufferWhileEditing(
              collection: FirestoreCollections.todoTasks,
              documentId: id,
              remoteText: merged.notes ?? '',
            );
            merged = merged.copyWith(
              notes: local.notes,
              bumpVersion: false,
            );
          } else {
            _pendingTextMergeBuffer.recordRemoteText(
              FirestoreCollections.todoTasks,
              id,
              merged.notes ?? '',
            );
          }
          await _todoRepository.upsertTask(
            merged,
            recordLocalActivity: false,
          );
          localTasks?[id] = merged;
        } on StateError {
          // Skip malformed remote documents.
        }
      },
    );
  }

  Future<bool> _pullCollection(
    String collection, {
    required Future<void> Function(
      String id,
      Map<String, dynamic> data, {
      required bool fromCrdt,
    })
    apply,
    Set<String>? onlyFirestoreDocumentIds,
  }) async {
    _syncActivity?.recordDownloadCheck(collection);
    // Reads hit the same Firestore native call path as writes — defer them
    // too, or a live-sync pull triggered by another device's edit could
    // still stall an in-progress scroll the same way an un-gated write did.
    await ScrollActivityGate.instance.waitUntilIdle();

    final List<({String id, Map<String, dynamic> data})> docs;
    if (onlyFirestoreDocumentIds != null) {
      final scoped = <({String id, Map<String, dynamic> data})>[];
      for (final firestoreDocId in onlyFirestoreDocumentIds) {
        final localDocId = _localDocumentId(collection, firestoreDocId);
        if (_consumeSelfEcho(collection, localDocId)) {
          if (DevFlags.verboseSync) {
            debugPrint('[sync] skip self-echo $collection/$localDocId');
          }
          continue;
        }
        final data = await _syncRepository.getDocument(collection, firestoreDocId);
        if (data == null) continue;
        scoped.add((id: firestoreDocId, data: data));
      }
      docs = scoped;
    } else {
      docs = await _syncRepository.listCollectionDocuments(collection);
    }

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
    return docs.isNotEmpty;
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

  void pushDreamEntry(DreamEntry entry) {
    _scheduleRemoteUpload(
      documentKey(FirestoreCollections.dreamEntries, entry.id),
      () => _uploadDreamEntryNow(entry),
    );
  }

  void pushDreamEntryNow(DreamEntry entry) {
    cancelDocument(FirestoreCollections.dreamEntries, entry.id);
    unawaited(_uploadDreamEntryNow(entry));
  }

  void pushTodoList(TodoListModel list) {
    cancelDocument(FirestoreCollections.todoLists, list.id);
    unawaited(_uploadTodoListNow(list));
  }

  Future<void> pushTodoTaskNow(TodoTask task) {
    cancelDocument(FirestoreCollections.todoTasks, task.id);
    return _uploadTodoTaskNow(task);
  }

  /// Batched counterpart to [pushTodoTaskNow] for a set of tasks that only
  /// need a plain snapshot upload — no pending char-ops (title/notes edits go
  /// through [pushTodoTaskNow] individually so their char-ops are preserved).
  /// Use this for sort-order-only cascades: uncompleting one task in a large
  /// list can shift every row below it, and pushing each shifted row as its
  /// own immediate Firestore write floods the UI isolate with dozens of
  /// concurrent round-trips right as the local save lands.
  Future<void> pushTodoTasksBatch(List<TodoTask> tasks) async {
    if (tasks.isEmpty) return;
    for (final task in tasks) {
      cancelDocument(FirestoreCollections.todoTasks, task.id);
    }
    final payloads = {
      for (final task in tasks)
        task.id: todoTaskToFirestore(task.copyWith(bumpVersion: false)),
    };
    await _syncEngine.syncDocumentsImmediately(
      collection: FirestoreCollections.todoTasks,
      payloadsByDocumentId: payloads,
    );
    for (final task in tasks) {
      _markSelfEcho(FirestoreCollections.todoTasks, task.id);
    }
  }

  void pushTodoTaskTitleDebounced(TodoTask task) {
    _scheduleRemoteUpload(
      documentKey(FirestoreCollections.todoTasks, task.id),
      () => _uploadTodoTaskNow(task),
    );
  }

  Future<void> pushJournalById(String id) async {
    final journal = await _journalRepository.getJournal(id);
    if (journal == null) return;
    cancelDocument(FirestoreCollections.journals, journal.id);
    await _uploadJournalNow(journal);
  }

  Future<TodoTask?> _findTodoTask(String taskId) {
    return _todoRepository.getTask(taskId);
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

  Future<void> _uploadJournalEntryNow(
    JournalEntry entry, {
    bool bumpVersion = false,
  }) async {
    final charOps = _charOpRegistry.takePendingOps(
      FirestoreCollections.journalEntries,
      entry.id,
    );
    final payloadEntry = bumpVersion
        ? entry.copyWith(bumpVersion: true)
        : entry.copyWith(bumpVersion: false);
    await _syncEngine.syncDocumentImmediately(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      payload: journalEntryToFirestore(payloadEntry),
      charOps: charOps,
    );
    _markSelfEcho(FirestoreCollections.journalEntries, entry.id);
  }

  Future<void> _uploadDreamEntryNow(
    DreamEntry entry, {
    bool bumpVersion = false,
  }) async {
    final charOps = _charOpRegistry.takePendingOps(
      FirestoreCollections.dreamEntries,
      entry.id,
    );
    final payloadEntry = bumpVersion
        ? entry.copyWith(bumpVersion: true)
        : entry.copyWith(bumpVersion: false);
    await _syncEngine.syncDocumentImmediately(
      collection: FirestoreCollections.dreamEntries,
      documentId: entry.id,
      payload: dreamEntryToFirestore(payloadEntry),
      charOps: charOps,
    );
    _markSelfEcho(FirestoreCollections.dreamEntries, entry.id);
  }

  Future<void> _uploadJournalNow(Journal journal) async {
    await _syncEngine.syncDocumentImmediately(
      collection: FirestoreCollections.journals,
      documentId: journalDocumentIdForFirestore(journal.id),
      payload: journalToFirestore(journal),
    );
    _markSelfEcho(FirestoreCollections.journals, journal.id);
  }

  Future<void> _uploadTodoListNow(TodoListModel list) async {
    await _syncEngine.syncDocumentImmediately(
      collection: FirestoreCollections.todoLists,
      documentId: todoListDocumentIdForFirestore(list.id),
      payload: todoListToFirestore(list),
    );
    _markSelfEcho(FirestoreCollections.todoLists, list.id);
  }

  Future<void> _uploadTodoTaskNow(
    TodoTask task, {
    bool bumpVersion = false,
  }) async {
    final charOps = _charOpRegistry.takePendingOps(
      FirestoreCollections.todoTasks,
      task.id,
    );
    final payloadTask = bumpVersion
        ? task.copyWith(bumpVersion: true)
        : task.copyWith(bumpVersion: false);
    await _syncEngine.syncDocumentImmediately(
      collection: FirestoreCollections.todoTasks,
      documentId: task.id,
      payload: todoTaskToFirestore(payloadTask),
      charOps: charOps,
    );
    _markSelfEcho(FirestoreCollections.todoTasks, task.id);
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
    _selfEchoAt.clear();
    _charOpRegistry.clear();
  }

  Future<List<CharacterOperation>> _listRemoteCharOps(String documentId) async {
    final ops = await _syncRepository.listOperations(documentId);
    return _charMerger.mergeOperations(const [], ops);
  }

  Future<void> _quarantineConflict({
    required String collection,
    required String documentId,
    required String? local,
    required String remote,
    required String? localTitle,
    required String? remoteTitle,
    required String? localText,
    required String? remoteText,
  }) async {
    final repo = _syncConflictRepository;
    if (repo == null) return;
    await repo.upsertConflict(
      SyncConflict(
        id: '${collection}_$documentId',
        collection: collection,
        documentId: documentId,
        localPayloadJson: local ?? '{}',
        remotePayloadJson: remote,
        localTitle: localTitle,
        remoteTitle: remoteTitle,
        localText: localText,
        remoteText: remoteText,
        detectedAt: DateTime.now().toUtc(),
      ),
    );
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
  final List<StreamSubscription<Set<String>>> _subscriptions = [];
  var _started = false;
  var _pullInFlight = false;
  final _queuedIdsByCollection = <String, Set<String>>{};

  static const _watchedCollections = [
    FirestoreCollections.journals,
    FirestoreCollections.journalEntries,
    FirestoreCollections.dreamEntries,
    FirestoreCollections.todoLists,
    FirestoreCollections.todoTasks,
  ];

  void start() {
    if (_started || _syncRepository is NoOpSyncRepository) return;
    _started = true;

    for (final collection in _watchedCollections) {
      _subscriptions.add(
        _syncRepository.watchCollection(collection).listen((changedIds) {
          if (changedIds.isEmpty) return;
          unawaited(_handleRemoteChange(collection, changedIds));
        }),
      );
    }
  }

  Future<void> _handleRemoteChange(String collection, Set<String> ids) async {
    _queuedIdsByCollection
        .putIfAbsent(collection, () => <String>{})
        .addAll(ids);
    if (_pullInFlight) return;

    _pullInFlight = true;
    try {
      while (_queuedIdsByCollection.isNotEmpty) {
        final pending = Map<String, Set<String>>.from(_queuedIdsByCollection);
        _queuedIdsByCollection.clear();
        for (final entry in pending.entries) {
          try {
            final applied = await _remoteSync.pullForCollection(
              entry.key,
              documentIds: entry.value,
            );
            // Skip the refresh entirely when every id in this batch turned
            // out to be an echo of our own write — onChanged invalidates
            // nearly every data provider in the app, and callers that
            // triggered the write (e.g. the todo page's completion batch)
            // already do their own narrower, coalesced refresh.
            if (applied) {
              if (DevFlags.verboseSync) {
                debugPrint(
                  '[sync] live-sync onChanged fired for ${entry.key} '
                  '(${entry.value.length} id(s))',
                );
              }
              _onChanged();
            } else if (DevFlags.verboseSync) {
              debugPrint(
                '[sync] live-sync onChanged skipped for ${entry.key} '
                '(all ${entry.value.length} id(s) were self-echoes)',
              );
            }
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
    _queuedIdsByCollection.clear();
    _started = false;
  }
}
