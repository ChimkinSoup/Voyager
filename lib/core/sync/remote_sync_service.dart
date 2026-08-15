import 'dart:async';
import 'dart:convert';

// ignore_for_file: prefer_initializing_formals
import 'package:flutter/foundation.dart';
import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/sync/char_ops_encoder.dart';
import 'package:voyager/core/sync/crdt_document_resolver.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/utils/journal_tags.dart';import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
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
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/models/workout_models.dart';
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
    required LeetCodeRepository leetCodeRepository,
    required StudyRepository studyRepository,
    required WorkoutRepository workoutRepository,
    required CalendarRepository calendarRepository,
    required TrackerRepository trackerRepository,
    required FinanceRepository financeRepository,
    required NotificationRepository notificationRepository,
    required BucketListRepository bucketListRepository,
    required SettingsRepository settingsRepository,
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
       _leetCodeRepository = leetCodeRepository,
       _studyRepository = studyRepository,
       _workoutRepository = workoutRepository,
       _calendarRepository = calendarRepository,
       _trackerRepository = trackerRepository,
       _financeRepository = financeRepository,
       _notificationRepository = notificationRepository,
       _bucketListRepository = bucketListRepository,
       _settingsRepository = settingsRepository,
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
  final LeetCodeRepository _leetCodeRepository;
  final StudyRepository _studyRepository;
  final WorkoutRepository _workoutRepository;
  final CalendarRepository _calendarRepository;
  final TrackerRepository _trackerRepository;
  final FinanceRepository _financeRepository;
  final NotificationRepository _notificationRepository;
  final BucketListRepository _bucketListRepository;
  final SettingsRepository _settingsRepository;
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

  /// Operation-log length that triggers compaction — see
  /// [compactOperationLog]. High enough that ordinary editing never pays for
  /// it, low enough that resolving a document stays cheap.
  static const operationLogCompactionThreshold = 200;

  /// How stale every other device's operations must be before this one will
  /// rewrite the shared log.
  static const _compactionForeignWriteCooloff = Duration(hours: 24);

  /// Documents with compaction in flight, so two overlapping triggers can't
  /// both write a baseline and delete each other's.
  final Set<String> _compactingDocuments = {};

  /// What this device last pushed for a document, keyed by [documentKey].
  ///
  /// Firestore's snapshot listener fires for our own writes as soon as they
  /// land in the local cache — not just for changes from other devices — so
  /// [LiveSyncController] would otherwise CRDT-merge and re-write every
  /// document we just saved a second time. Since we already hold the freshest
  /// local state for anything we just pushed, that echo is safe to skip.
  ///
  /// Matched on *content*, not on time. A mark that suppressed anything
  /// arriving within a fixed window would also swallow a genuine edit another
  /// device made inside it — and because consuming removes the entry, nothing
  /// would ever redeliver it: two devices on one todo list would silently
  /// diverge. Comparing the delivered document against what we pushed skips
  /// only our own echo and lets everything else through.
  final Map<String, _SelfEcho> _selfEchoes = {};

  /// How long a mark stays eligible. Only a backstop now that the test is
  /// content-based — it bounds the map rather than deciding correctness.
  static const _selfEchoWindow = Duration(seconds: 15);

  void _markSelfEcho(
    String collection,
    String localDocumentId,
    Map<String, dynamic> payload,
  ) {
    final now = DateTime.now();
    // Pruned on every write, so a signed-out session (whose pulls never
    // consume anything) can't accumulate one entry per document forever.
    _selfEchoes.removeWhere(
      (_, echo) => now.difference(echo.at) >= _selfEchoWindow,
    );
    _selfEchoes[documentKey(collection, localDocumentId)] = _SelfEcho(
      at: now,
      keys: payload.keys.toList(growable: false),
      fingerprint: _payloadFingerprint(payload),
    );
  }

  /// Whether [remote] is the echo of our own recent write to this document.
  bool _consumeSelfEcho(
    String collection,
    String localDocumentId,
    Map<String, dynamic>? remote,
  ) {
    final key = documentKey(collection, localDocumentId);
    final echo = _selfEchoes[key];
    if (echo == null) return false;

    _selfEchoes.remove(key);
    if (remote == null) return false;
    if (DateTime.now().difference(echo.at) >= _selfEchoWindow) return false;

    // Uploads write with `merge: true`, so the stored document is a superset of
    // what we sent. Comparing only the keys we actually pushed is what makes a
    // field some other writer left on the document (the weather cache on
    // `settings`, say) stop looking like a foreign edit.
    final pushed = {
      for (final key in echo.keys)
        if (remote.containsKey(key)) key: remote[key],
    };
    return _payloadFingerprint(pushed) == echo.fingerprint;
  }

  /// A payload rendered so two of them compare equal when their contents are.
  ///
  /// Keys are sorted because a document coming back from Firestore carries no
  /// promise about the order its fields arrive in.
  String _payloadFingerprint(Map<String, dynamic> payload) {
    final keys = payload.keys.toList()..sort();
    return jsonEncode({for (final key in keys) key: payload[key]});
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
    // The Firestore id, not the local one: the uploads store operations under
    // whatever id the document itself lives at, and for a legacy-id journal or
    // todo list the two differ. Passing the local id there matched nothing, so
    // the document's entire operation history stayed behind — ready to be
    // resolved back over any later document that reuses the id.
    final operationsDeleted =
        await _syncRepository.deleteOperationsForDocument(firestoreDocId);

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
            _scheduleRemoteUpload(collection, documentId, saveRemote);
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

    // Opening an entry is the one moment the whole operation log is already
    // being read, so the compaction check below costs no extra round-trip.
    final rawOps = await _syncRepository.listOperations(documentId);
    // The engine's counter restarts at 0 every launch, and `sequence` is the
    // primary sort key for replaying a log. Opening a document is the one
    // moment its whole log is in hand, so this is a free chance to lift the
    // counter above everything already written — without it, this session's
    // operations sort before the previous session's and replay in the wrong
    // order.
    for (final op in rawOps) {
      _syncEngine.ensureSequenceAbove(op.sequence);
    }
    final ops = _charMerger.mergeOperations(const [], rawOps);
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

    unawaited(_compactInBackground(documentId, rawOps));
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
    await pullSecondaryData();
    if (!skipWeather) {
      await Future.wait<void>([
        _weatherService.syncLocationFromRemote(),
        _weatherService.syncForecastFromRemote(),
      ]);
    }
    // After the pull, never before — see [backfillSyncedCollections].
    await backfillSyncedCollections();
  }

  Future<void> pullJournalAndTodoData() async {
    await pullJournals();
    await pullJournalEntries();
    await pullDreamEntries();
    await pullTodoLists();
    await pullTodoTasks();
    await pullLeetCodeProblems();
    await pullStudyFolders();
    await pullStudyDecks();
    await pullStudyCards();
    await pullStudyReviewLog();
    await pullExercises();
    await pullWorkoutPlans();
    await pullWorkoutPlanEntries();
    await pullWorkoutSessions();
    await pullWorkoutSetLogs();
    await pullCustomQuotes();
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
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    switch (collection) {
      case FirestoreCollections.journals:
        return pullJournals(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.journalEntries:
        return pullJournalEntries(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.dreamEntries:
        return pullDreamEntries(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.todoLists:
        return pullTodoLists(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.todoTasks:
        return pullTodoTasks(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.leetcodeProblems:
        return pullLeetCodeProblems(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.studyFolders:
        return pullStudyFolders(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.studyDecks:
        return pullStudyDecks(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.studyCards:
        return pullStudyCards(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.studyReviewLog:
        return pullStudyReviewLog(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.exercises:
        return pullExercises(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.workoutPlans:
        return pullWorkoutPlans(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.workoutPlanEntries:
        return pullWorkoutPlanEntries(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.workoutSessions:
        return pullWorkoutSessions(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.workoutSetLogs:
        return pullWorkoutSetLogs(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.customQuotes:
        return pullCustomQuotes(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.calendars:
        return pullCalendars(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.calendarEvents:
        return pullCalendarEvents(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.trackers:
        return pullTrackers(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.trackerValues:
        return pullTrackerValues(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.transactions:
        return pullTransactions(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.subscriptions:
        return pullSubscriptions(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.budgets:
        return pullBudgets(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.financeCategories:
        return pullFinanceCategories(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.assets:
        return pullAssets(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.assetValuations:
        return pullAssetValuations(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.savingsGoals:
        return pullSavingsGoals(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.goalAllocations:
        return pullGoalAllocations(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.pinnedNotes:
        return pullPinnedNotes(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.dismissedNotifications:
        return pullDismissedNotifications(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.bucketListItems:
        return pullBucketListItems(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.tagColors:
        return pullTagColors(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.customWords:
        return pullCustomWords(
          documentIds: documentIds,
          documentData: documentData,
        );
      // The settings document is watched as a one-document collection; the
      // weather service writes to it too, so a tick here often means nothing
      // changed for us and [pullSettings] says so.
      case FirestoreCollections.settings:
        return pullSettings();
    }
    return false;
  }

  Future<bool> pullCustomQuotes({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.customQuotes,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _settingsRepository.getCustomQuote(id);
        final merged = mergeCustomQuoteFromRemote(data, id, local: local);
        await _settingsRepository.upsertCustomQuote(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullJournals({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.journals,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
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

  Future<bool> pullLeetCodeProblems({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.leetcodeProblems,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _leetCodeRepository.getProblem(id);
        final merged = mergeLeetCodeProblemFromRemote(data, id, local: local);
        await _leetCodeRepository.upsertProblem(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullExercises({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.exercises,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _workoutRepository.getExercise(id);
        final merged = mergeExerciseFromRemote(data, id, local: local);
        await _workoutRepository.upsertExercise(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullWorkoutPlans({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.workoutPlans,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _workoutRepository.getPlan(id);
        final merged = mergeWorkoutPlanFromRemote(data, id, local: local);
        await _workoutRepository.upsertPlan(merged, recordLocalActivity: false);
      },
    );
  }

  Future<bool> pullWorkoutPlanEntries({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.workoutPlanEntries,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _workoutRepository.getPlanEntry(id);
        final merged = mergeWorkoutPlanEntryFromRemote(data, id, local: local);
        await _workoutRepository.upsertPlanEntry(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullWorkoutSessions({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.workoutSessions,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _workoutRepository.getSession(id);
        final merged = mergeWorkoutSessionFromRemote(data, id, local: local);
        await _workoutRepository.upsertSession(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullWorkoutSetLogs({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.workoutSetLogs,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _workoutRepository.getSetLog(id);
        final merged = mergeWorkoutSetLogFromRemote(data, id, local: local);
        await _workoutRepository.upsertSetLog(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullStudyFolders({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.studyFolders,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _studyRepository.getFolder(id);
        final merged = mergeStudyFolderFromRemote(data, id, local: local);
        await _studyRepository.upsertFolder(merged, recordLocalActivity: false);
      },
    );
  }

  Future<bool> pullStudyDecks({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.studyDecks,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _studyRepository.getDeck(id);
        final merged = mergeStudyDeckFromRemote(data, id, local: local);
        await _studyRepository.upsertDeck(merged, recordLocalActivity: false);
      },
    );
  }

  Future<bool> pullStudyCards({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.studyCards,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _studyRepository.getCard(id);
        final merged = mergeStudyCardFromRemote(data, id, local: local);
        await _studyRepository.upsertCard(merged, recordLocalActivity: false);
      },
    );
  }

  Future<bool> pullStudyReviewLog({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.studyReviewLog,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final merged = mergeStudyReviewLogFromRemote(data, id);
        await _studyRepository.logReview(merged);
      },
    );
  }

  Future<bool> pullJournalEntries({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.journalEntries,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
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

  Future<bool> pullDreamEntries({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.dreamEntries,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
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

  Future<bool> pullTodoLists({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.todoLists,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
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

  Future<bool> pullTodoTasks({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    // A scoped pull only touches a handful of ids, so a per-id lookup is
    // cheaper than building an index of every task in every list; a full
    // pull still benefits from loading the index once up front.
    final localTasks = documentIds == null ? await _loadTaskIndex() : null;
    return _pullCollection(
      FirestoreCollections.todoTasks,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
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
    Map<String, Map<String, dynamic>>? documentData,
    bool resolveCrdt = true,
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
        // The snapshot that told us this id changed carried the document with
        // it. Only ids handed over without one cost a round trip.
        final data =
            documentData?[firestoreDocId] ??
            await _syncRepository.getDocument(collection, firestoreDocId);
        if (data == null) continue;
        if (_consumeSelfEcho(collection, localDocId, data)) {
          if (DevFlags.verboseSync) {
            debugPrint('[sync] skip self-echo $collection/$localDocId');
          }
          continue;
        }
        scoped.add((id: firestoreDocId, data: data));
      }
      docs = scoped;
    } else {
      docs = await _syncRepository.listCollectionDocuments(collection);
    }

    for (final doc in docs) {
      final firestoreDocId = doc.data['id'] as String? ?? doc.id;
      final localDocId = _localDocumentId(collection, firestoreDocId);
      // Snapshot-only collections never wrote an operation log, so resolving
      // one would spend an indexed query per document to learn nothing.
      final crdtPayload = resolveCrdt
          ? await _crdtResolver.resolvePayload(
              _syncRepository,
              _firestoreDocumentId(collection, localDocId),
            )
          : null;
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
    return firestoreDocumentIdForLocal(collection, localId);
  }

  String _localDocumentId(String collection, String firestoreId) {
    if (collection == FirestoreCollections.journals) {
      return journalDocumentIdFromFirestore(firestoreId);
    }
    if (collection == FirestoreCollections.todoLists) {
      return todoListDocumentIdFromFirestore(firestoreId);
    }
    if (encodedIdCollections.contains(collection)) {
      return decodeDocumentId(firestoreId) ?? firestoreId;
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

  void pushLeetCodeProblem(LeetCodeProblem problem) {
    cancelDocument(FirestoreCollections.leetcodeProblems, problem.id);
    unawaited(_uploadLeetCodeProblemNow(problem));
  }

  void pushCustomQuote(CustomQuote quote) {
    cancelDocument(FirestoreCollections.customQuotes, quote.id);
    unawaited(_uploadCustomQuoteNow(quote));
  }

  void pushStudyFolder(StudyFolder folder) {
    cancelDocument(FirestoreCollections.studyFolders, folder.id);
    unawaited(_uploadStudyFolderNow(folder));
  }

  void pushStudyDeck(StudyDeck deck) {
    cancelDocument(FirestoreCollections.studyDecks, deck.id);
    unawaited(_uploadStudyDeckNow(deck));
  }

  void pushStudyCard(StudyCard card) {
    cancelDocument(FirestoreCollections.studyCards, card.id);
    unawaited(_uploadStudyCardNow(card));
  }

  /// Batched counterpart to [pushStudyCard] for a set of cards that only
  /// need a plain snapshot upload (e.g. after a multi-select move) — see
  /// [pushTodoTasksBatch] for why batching matters for cascading writes.
  Future<void> pushStudyCardsBatch(List<StudyCard> cards) async {
    if (cards.isEmpty) return;
    for (final card in cards) {
      cancelDocument(FirestoreCollections.studyCards, card.id);
    }
    final payloads = {
      for (final card in cards) card.id: studyCardToFirestore(card),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(FirestoreCollections.studyCards, entry.key, entry.value);
    }
    await _syncEngine.syncDocumentsImmediately(
      collection: FirestoreCollections.studyCards,
      payloadsByDocumentId: payloads,
      logOperation: false,
    );
  }

  void pushExercise(Exercise exercise) {
    cancelDocument(FirestoreCollections.exercises, exercise.id);
    unawaited(_uploadExerciseNow(exercise));
  }

  void pushWorkoutPlan(WorkoutPlan plan) {
    cancelDocument(FirestoreCollections.workoutPlans, plan.id);
    unawaited(_uploadWorkoutPlanNow(plan));
  }

  void pushWorkoutPlanEntry(WorkoutPlanEntry entry) {
    cancelDocument(FirestoreCollections.workoutPlanEntries, entry.id);
    unawaited(_uploadWorkoutPlanEntryNow(entry));
  }

  void pushWorkoutSession(WorkoutSession session) {
    cancelDocument(FirestoreCollections.workoutSessions, session.id);
    unawaited(_uploadWorkoutSessionNow(session));
  }

  void pushWorkoutSetLog(WorkoutSetLog log) {
    cancelDocument(FirestoreCollections.workoutSetLogs, log.id);
    unawaited(_uploadWorkoutSetLogNow(log));
  }

  /// Batched counterpart to [pushWorkoutSetLog]. Materialising a session
  /// writes every set of every planned exercise at once — see
  /// [pushTodoTasksBatch] for why that must not become N round-trips.
  Future<void> pushWorkoutSetLogsBatch(List<WorkoutSetLog> logs) async {
    if (logs.isEmpty) return;
    for (final log in logs) {
      cancelDocument(FirestoreCollections.workoutSetLogs, log.id);
    }
    final payloads = {
      for (final log in logs) log.id: workoutSetLogToFirestore(log),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(FirestoreCollections.workoutSetLogs, entry.key, entry.value);
    }
    await _syncEngine.syncDocumentsImmediately(
      collection: FirestoreCollections.workoutSetLogs,
      payloadsByDocumentId: payloads,
      logOperation: false,
    );
  }

  void pushStudyReviewLog(StudyReviewLog log) {
    cancelDocument(FirestoreCollections.studyReviewLog, log.id);
    unawaited(_uploadStudyReviewLogNow(log));
  }

  void pushJournalEntry(JournalEntry entry) {
    _scheduleRemoteUpload(
      FirestoreCollections.journalEntries,
      entry.id,
      () => _uploadJournalEntryNow(entry),
    );
  }

  void pushJournalEntryNow(JournalEntry entry) {
    cancelDocument(FirestoreCollections.journalEntries, entry.id);
    unawaited(_uploadJournalEntryNow(entry));
  }

  void pushDreamEntry(DreamEntry entry) {
    _scheduleRemoteUpload(
      FirestoreCollections.dreamEntries,
      entry.id,
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
    for (final entry in payloads.entries) {
      _markSelfEcho(FirestoreCollections.todoTasks, entry.key, entry.value);
    }
    // Keeps its operation-log entry, unlike the other batch pushes: todo tasks
    // carry collaborative notes, and a mirror newer than the log would simply
    // be resolved away on the next pull.
    await _syncEngine.syncDocumentsImmediately(
      collection: FirestoreCollections.todoTasks,
      payloadsByDocumentId: payloads,
    );
  }

  void pushTodoTaskTitleDebounced(TodoTask task) {
    _scheduleRemoteUpload(
      FirestoreCollections.todoTasks,
      task.id,
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

  /// Re-sends a document the outbox queued after an earlier upload failed.
  ///
  /// Only the collections that keep a character-operation log come through
  /// here — see [OutboxSyncWorker.pushDocument] for why they cannot simply be
  /// written back as a document mirror. Going through the ordinary upload path
  /// gets them an operation-log entry at the current sequence, so the log is
  /// never left describing an older text than the document beside it.
  ///
  /// A document that no longer exists locally is a no-op: the queued row has
  /// nothing left to stand for.
  Future<void> pushOutboxDocument(String collection, String documentId) async {
    cancelDocument(collection, documentId);
    switch (collection) {
      case FirestoreCollections.journalEntries:
        final entry = await _journalRepository.getEntry(documentId);
        if (entry != null) await _uploadJournalEntryNow(entry);
      case FirestoreCollections.dreamEntries:
        final entry = await _dreamRepository.getEntry(documentId);
        if (entry != null) await _uploadDreamEntryNow(entry);
      case FirestoreCollections.todoTasks:
        final task = await _findTodoTask(documentId);
        if (task != null) await _uploadTodoTaskNow(task);
    }
  }

  void _scheduleRemoteUpload(
    String collection,
    String documentId,
    Future<void> Function() remoteSave,
  ) {
    final key = documentKey(collection, documentId);
    _activeDebouncers.remove(key)?.cancel();
    _pendingRemoteSaves[key] = remoteSave;
    _activeDebouncers[key] = Timer(_uploadDebounceDelay, () {
      final save = _pendingRemoteSaves.remove(key);
      _activeDebouncers.remove(key);
      if (save != null) {
        unawaited(_runRemoteSave(collection, documentId, save));
      }
    });
  }

  /// Runs a debounced upload, making sure a failure lands somewhere.
  ///
  /// These uploads are deliberately not awaited by their callers, so without
  /// this an exception would escape to the zone as an unhandled error and the
  /// document would simply stay unsynced with nothing recording that it had
  /// tried. Transient failures go back on the outbox for a later attempt;
  /// permanent ones are parked so they stop consuming retries but remain
  /// visible.
  Future<void> _runRemoteSave(
    String collection,
    String documentId,
    Future<void> Function() remoteSave,
  ) async {
    try {
      await remoteSave();
      await OutboxSyncWorker.recordSuccess(
        collection: collection,
        documentId: documentId,
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[sync] upload failed for $collection/$documentId: $error\n$stackTrace',
      );
      await OutboxSyncWorker.recordFailure(
        collection: collection,
        documentId: documentId,
        error: error,
      );
    }
  }

  /// Uploads one plain record — no collaborative text, so no operation-log
  /// entry and no CRDT resolution on the way back down. See
  /// [FirestoreCollections.snapshotOnly].
  ///
  /// [localId] and [firestoreId] differ only for the two legacy-id collections;
  /// the self-echo mark is keyed by the local id because that is what a pull
  /// resolves an incoming document to.
  Future<void> _uploadRecordNow({
    required String collection,
    required String localId,
    required Map<String, dynamic> payload,
    String? firestoreId,
  }) async {
    // Marked *before* the write, not after. `set()` resolves on server
    // acknowledgement, while the snapshot listener fires from the local write
    // cache almost immediately — so a mark written afterwards is always too
    // late for its own echo, and lands in place to swallow the next, genuine
    // change instead. Exactly backwards from what it is for.
    _markSelfEcho(collection, localId, payload);
    await _syncEngine.syncDocumentImmediately(
      collection: collection,
      documentId: firestoreId ?? localId,
      payload: payload,
      logOperation: false,
    );
  }

  /// Uploads a document whose text two devices can edit at once, carrying the
  /// character operations recorded since the last upload.
  ///
  /// The operations are handed back to the session if the write fails.
  /// [CharacterOpRegistry.takePendingOps] clears unconditionally, so without
  /// this an upload that threw — offline, rejected, oversized — dropped them
  /// for good: they remain in the session's reconstructed text, so no later
  /// keystroke re-emits them, and the paragraph typed offline never reaches
  /// `sync_operations` at all.
  Future<void> _uploadCrdtDocumentNow({
    required String collection,
    required String documentId,
    required Map<String, dynamic> payload,
  }) async {
    final charOps = _charOpRegistry.takePendingOps(collection, documentId);
    _markSelfEcho(collection, documentId, payload);
    try {
      await _syncEngine.syncDocumentImmediately(
        collection: collection,
        documentId: documentId,
        payload: payload,
        charOps: charOps,
      );
    } catch (_) {
      _charOpRegistry.restorePendingOps(collection, documentId, charOps);
      rethrow;
    }
  }

  Future<void> _uploadJournalEntryNow(
    JournalEntry entry, {
    bool bumpVersion = false,
  }) {
    return _uploadCrdtDocumentNow(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      payload: journalEntryToFirestore(entry.copyWith(bumpVersion: bumpVersion)),
    );
  }

  Future<void> _uploadDreamEntryNow(
    DreamEntry entry, {
    bool bumpVersion = false,
  }) {
    return _uploadCrdtDocumentNow(
      collection: FirestoreCollections.dreamEntries,
      documentId: entry.id,
      payload: dreamEntryToFirestore(entry.copyWith(bumpVersion: bumpVersion)),
    );
  }

  Future<void> _uploadJournalNow(Journal journal) {
    return _uploadRecordNow(
      collection: FirestoreCollections.journals,
      localId: journal.id,
      firestoreId: journalDocumentIdForFirestore(journal.id),
      payload: journalToFirestore(journal),
    );
  }

  Future<void> _uploadLeetCodeProblemNow(LeetCodeProblem problem) {
    return _uploadRecordNow(
      collection: FirestoreCollections.leetcodeProblems,
      localId: problem.id,
      payload: leetCodeProblemToFirestore(problem),
    );
  }

  Future<void> _uploadCustomQuoteNow(CustomQuote quote) {
    return _uploadRecordNow(
      collection: FirestoreCollections.customQuotes,
      localId: quote.id,
      payload: customQuoteToFirestore(quote),
    );
  }

  Future<void> _uploadStudyFolderNow(StudyFolder folder) {
    return _uploadRecordNow(
      collection: FirestoreCollections.studyFolders,
      localId: folder.id,
      payload: studyFolderToFirestore(folder),
    );
  }

  Future<void> _uploadStudyDeckNow(StudyDeck deck) {
    return _uploadRecordNow(
      collection: FirestoreCollections.studyDecks,
      localId: deck.id,
      payload: studyDeckToFirestore(deck),
    );
  }

  Future<void> _uploadStudyCardNow(StudyCard card) {
    return _uploadRecordNow(
      collection: FirestoreCollections.studyCards,
      localId: card.id,
      payload: studyCardToFirestore(card),
    );
  }

  Future<void> _uploadStudyReviewLogNow(StudyReviewLog log) {
    return _uploadRecordNow(
      collection: FirestoreCollections.studyReviewLog,
      localId: log.id,
      payload: studyReviewLogToFirestore(log),
    );
  }

  Future<void> _uploadExerciseNow(Exercise exercise) {
    return _uploadRecordNow(
      collection: FirestoreCollections.exercises,
      localId: exercise.id,
      payload: exerciseToFirestore(exercise),
    );
  }

  Future<void> _uploadWorkoutPlanNow(WorkoutPlan plan) {
    return _uploadRecordNow(
      collection: FirestoreCollections.workoutPlans,
      localId: plan.id,
      payload: workoutPlanToFirestore(plan),
    );
  }

  Future<void> _uploadWorkoutPlanEntryNow(WorkoutPlanEntry entry) {
    return _uploadRecordNow(
      collection: FirestoreCollections.workoutPlanEntries,
      localId: entry.id,
      payload: workoutPlanEntryToFirestore(entry),
    );
  }

  Future<void> _uploadWorkoutSessionNow(WorkoutSession session) {
    return _uploadRecordNow(
      collection: FirestoreCollections.workoutSessions,
      localId: session.id,
      payload: workoutSessionToFirestore(session),
    );
  }

  Future<void> _uploadWorkoutSetLogNow(WorkoutSetLog log) {
    return _uploadRecordNow(
      collection: FirestoreCollections.workoutSetLogs,
      localId: log.id,
      payload: workoutSetLogToFirestore(log),
    );
  }

  Future<void> _uploadTodoListNow(TodoListModel list) {
    return _uploadRecordNow(
      collection: FirestoreCollections.todoLists,
      localId: list.id,
      firestoreId: todoListDocumentIdForFirestore(list.id),
      payload: todoListToFirestore(list),
    );
  }

  Future<void> _uploadTodoTaskNow(
    TodoTask task, {
    bool bumpVersion = false,
  }) {
    return _uploadCrdtDocumentNow(
      collection: FirestoreCollections.todoTasks,
      documentId: task.id,
      payload: todoTaskToFirestore(task.copyWith(bumpVersion: bumpVersion)),
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
    _selfEchoes.clear();
    _charOpRegistry.clear();
  }

  Future<List<CharacterOperation>> _listRemoteCharOps(String documentId) async {
    final ops = await _syncRepository.listOperations(documentId);
    return _charMerger.mergeOperations(const [], ops);
  }

  /// Collapses a document's operation log into one baseline group.
  ///
  /// Nothing prunes the log otherwise: every save appends, and resolving a
  /// document reads all of it, so an entry edited over months accumulates
  /// operations — and read cost, memory and merge time with them — without
  /// bound. Compaction replaces the accumulated log with a single group
  /// holding the live characters and the resolved snapshot, discarding
  /// tombstones for characters nobody can see any more.
  ///
  /// Returns whether it actually compacted.
  Future<bool> compactOperationLog(
    String documentId, {
    List<SyncOperation>? knownOperations,
  }) async {
    if (!_compactingDocuments.add(documentId)) return false;
    try {
      final ops =
          knownOperations ?? await _syncRepository.listOperations(documentId);
      if (ops.length < operationLogCompactionThreshold) return false;

      // Rewriting the log drops tombstones, so a device that is mid-edit could
      // re-send a character this one believes deleted. Requiring every foreign
      // operation to be stale makes that practically impossible without
      // needing a distributed lock.
      final now = DateTime.now().toUtc();
      final foreignWriteIsRecent = ops.any(
        (op) =>
            op.deviceId != deviceId &&
            now.difference(op.timestamp) < _compactionForeignWriteCooloff,
      );
      if (foreignWriteIsRecent) return false;

      final resolvedJson = _charMerger.applyMergedPayload(ops);
      if (resolvedJson.isEmpty) return false;
      final snapshot = jsonDecode(resolvedJson);
      if (snapshot is! Map<String, dynamic>) return false;

      final live = _charMerger
          .mergeOperations(const [], ops)
          .where((op) => !op.deleted)
          .toList();

      final supersededIds = [for (final op in ops) op.id];
      final sequence =
          ops.fold<int>(0, (highest, op) {
            return op.sequence > highest ? op.sequence : highest;
          }) +
          1;
      final baseId = '${deviceId}_${documentId}_compact_$sequence';
      final timestamp = DateTime.now().toUtc();
      // Always over [charOpEncodeIsolateThreshold] in practice — compaction
      // doesn't run below 200 operations — so this reliably lands on a
      // background isolate. It matters here more than anywhere: compaction is
      // kicked off by [prepareEditingSession], i.e. while an entry is opening.
      final encoded = await encodeCharOpPayloads(
        charOps: live,
        snapshot: snapshot,
        groupId: baseId,
        maxPayloadBytes: maxOperationPayloadBytes,
      );
      final baseline = [
        for (var i = 0; i < encoded.length; i++)
          SyncOperation(
            id: encoded.length == 1 ? baseId : '${baseId}_c$i',
            documentId: documentId,
            sequence: sequence,
            payload: encoded[i],
            deviceId: deviceId,
            timestamp: timestamp,
          ),
      ];

      // Baseline first, superseded operations second. Interrupted in between,
      // the log holds both — which resolves to exactly the same text, since
      // the baseline reuses the ids and fractional positions of the very
      // operations it replaces, so merging them is a union of equals. Deleting
      // first would open a window where the log is simply gone.
      await _syncRepository.appendOperationGroup(baseline);
      await _syncRepository.deleteOperations(documentId, supersededIds);
      return true;
    } finally {
      _compactingDocuments.remove(documentId);
    }
  }

  Future<void> _compactInBackground(
    String documentId,
    List<SyncOperation> ops,
  ) async {
    try {
      await compactOperationLog(documentId, knownOperations: ops);
    } catch (error, stackTrace) {
      // Housekeeping must never take editing down with it.
      debugPrint('[sync] op-log compaction failed for $documentId: $error\n$stackTrace');
    }
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

  // -------------------------------------------------------------------------
  // Calendars, analytics, finance, the notification inbox, the bucket list,
  // tag colors, custom words and the settings document.
  //
  // Uploads here arrive through [SyncedWriteNotifier] instead of an explicit
  // push call at every edit site — see that class for why. All of it is
  // snapshot-only: no operation-log entry on the way up, and no CRDT
  // resolution on the way down (see [FirestoreCollections.snapshotOnly]).
  // -------------------------------------------------------------------------

  /// Bump when a new collection joins the list, to re-run the one-time upload
  /// on every device and carry that collection's existing rows up with it.
  static const syncBackfillVersion = 1;

  /// Uploads records a repository just wrote locally.
  ///
  /// Failures land on the outbox exactly as the debounced per-entity uploads
  /// do, so a write lost to a dropped connection is still recorded somewhere.
  Future<void> pushRecords(String collection, List<Object> records) async {
    if (collection == FirestoreCollections.settings) {
      final settings = records.last;
      if (settings is AppSettings) await pushSettings(settings);
      return;
    }

    final payloads = <String, Map<String, dynamic>>{};
    // Outbox rows are keyed by the *local* id throughout — that is what
    // `_runRemoteSave` queues, and what the drain needs to look the entity back
    // up in SQLite. Recording these by Firestore id instead left the encoded-id
    // collections (tag colors, custom words, dismissed notifications) with rows
    // that could never be matched, and so never cleared.
    final localIds = <String>[];
    for (final record in records) {
      final document = _recordDocument(collection, record);
      if (document == null) continue;
      payloads[_firestoreDocumentId(collection, document.id)] =
          document.payload;
      localIds.add(document.id);
      _markSelfEcho(collection, document.id, document.payload);
    }
    if (payloads.isEmpty) return;

    try {
      await _syncEngine.syncDocumentsImmediately(
        collection: collection,
        payloadsByDocumentId: payloads,
        logOperation: false,
      );
      for (final documentId in localIds) {
        await OutboxSyncWorker.recordSuccess(
          collection: collection,
          documentId: documentId,
        );
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[sync] upload failed for $collection '
        '${payloads.keys.toList()}: $error\n$stackTrace',
      );
      for (final documentId in localIds) {
        await OutboxSyncWorker.recordFailure(
          collection: collection,
          documentId: documentId,
          error: error,
        );
      }
    }
  }

  /// Uploads records a backup restore just wrote to SQLite.
  ///
  /// Identical to [pushRecords] for plain records. For the collections that
  /// keep a character-operation log it first clears that log, because a
  /// restore replaces the document's text wholesale while `sync_operations`
  /// still describes the text it replaced — and pulls prefer the CRDT-resolved
  /// payload over the document. Without this, an entry restored to recover a
  /// body the user accidentally cleared looked right until the next startup
  /// pull, at which point the log resolved the cleared body straight back over
  /// it and undid the recovery.
  ///
  /// Backups deliberately exclude `sync_operations` ("a transport detail"), so
  /// there is no log to restore in its place: dropping it makes the restored
  /// document authoritative and the next editing session seeds a fresh chain
  /// from it, exactly as [forceOverwriteJournalEntryText] does.
  Future<void> pushRestoredRecords(
    String collection,
    List<Object> records,
  ) async {
    if (FirestoreCollections.crdtBacked.contains(collection)) {
      for (final record in records) {
        final document = _recordDocument(collection, record);
        if (document == null) continue;
        await _syncRepository.deleteOperationsForDocument(
          _firestoreDocumentId(collection, document.id),
        );
        _charOpRegistry.removeSession(collection, document.id);
        _pendingTextMergeBuffer.clearDocument(collection, document.id);
      }
    }
    await pushRecords(collection, records);
  }

  /// The Firestore id and payload for one record, or null if [collection]
  /// isn't one of these or [record] isn't the type it implies.
  ({String id, Map<String, dynamic> payload})? _recordDocument(
    String collection,
    Object record,
  ) {
    switch (collection) {
      case FirestoreCollections.journals:
        if (record is! Journal) return null;
        return (id: record.id, payload: journalToFirestore(record));
      case FirestoreCollections.journalEntries:
        if (record is! JournalEntry) return null;
        return (id: record.id, payload: journalEntryToFirestore(record));
      case FirestoreCollections.dreamEntries:
        if (record is! DreamEntry) return null;
        return (id: record.id, payload: dreamEntryToFirestore(record));
      case FirestoreCollections.todoLists:
        if (record is! TodoListModel) return null;
        return (id: record.id, payload: todoListToFirestore(record));
      case FirestoreCollections.todoTasks:
        if (record is! TodoTask) return null;
        return (id: record.id, payload: todoTaskToFirestore(record));
      case FirestoreCollections.leetcodeProblems:
        if (record is! LeetCodeProblem) return null;
        return (id: record.id, payload: leetCodeProblemToFirestore(record));
      case FirestoreCollections.studyFolders:
        if (record is! StudyFolder) return null;
        return (id: record.id, payload: studyFolderToFirestore(record));
      case FirestoreCollections.studyDecks:
        if (record is! StudyDeck) return null;
        return (id: record.id, payload: studyDeckToFirestore(record));
      case FirestoreCollections.studyCards:
        if (record is! StudyCard) return null;
        return (id: record.id, payload: studyCardToFirestore(record));
      case FirestoreCollections.studyReviewLog:
        if (record is! StudyReviewLog) return null;
        return (id: record.id, payload: studyReviewLogToFirestore(record));
      case FirestoreCollections.exercises:
        if (record is! Exercise) return null;
        return (id: record.id, payload: exerciseToFirestore(record));
      case FirestoreCollections.workoutPlans:
        if (record is! WorkoutPlan) return null;
        return (id: record.id, payload: workoutPlanToFirestore(record));
      case FirestoreCollections.workoutPlanEntries:
        if (record is! WorkoutPlanEntry) return null;
        return (id: record.id, payload: workoutPlanEntryToFirestore(record));
      case FirestoreCollections.workoutSessions:
        if (record is! WorkoutSession) return null;
        return (id: record.id, payload: workoutSessionToFirestore(record));
      case FirestoreCollections.workoutSetLogs:
        if (record is! WorkoutSetLog) return null;
        return (id: record.id, payload: workoutSetLogToFirestore(record));
      case FirestoreCollections.customQuotes:
        if (record is! CustomQuote) return null;
        return (id: record.id, payload: customQuoteToFirestore(record));
      case FirestoreCollections.calendars:
        if (record is! Calendar) return null;
        return (id: record.id, payload: calendarToFirestore(record));
      case FirestoreCollections.calendarEvents:
        if (record is! CalendarEvent) return null;
        return (id: record.id, payload: calendarEventToFirestore(record));
      case FirestoreCollections.trackers:
        if (record is! StatisticTracker) return null;
        return (id: record.id, payload: trackerToFirestore(record));
      case FirestoreCollections.trackerValues:
        if (record is! TrackerValue) return null;
        return (id: record.id, payload: trackerValueToFirestore(record));
      case FirestoreCollections.transactions:
        if (record is! FinancialTransaction) return null;
        return (id: record.id, payload: transactionToFirestore(record));
      case FirestoreCollections.subscriptions:
        if (record is! Subscription) return null;
        return (id: record.id, payload: subscriptionToFirestore(record));
      case FirestoreCollections.budgets:
        if (record is! Budget) return null;
        return (id: record.id, payload: budgetToFirestore(record));
      case FirestoreCollections.financeCategories:
        if (record is! FinanceCategory) return null;
        return (id: record.id, payload: financeCategoryToFirestore(record));
      case FirestoreCollections.assets:
        if (record is! Asset) return null;
        return (id: record.id, payload: assetToFirestore(record));
      case FirestoreCollections.assetValuations:
        if (record is! AssetValuation) return null;
        return (id: record.id, payload: assetValuationToFirestore(record));
      case FirestoreCollections.savingsGoals:
        if (record is! SavingsGoal) return null;
        return (id: record.id, payload: savingsGoalToFirestore(record));
      case FirestoreCollections.goalAllocations:
        if (record is! GoalAllocation) return null;
        return (id: record.id, payload: goalAllocationToFirestore(record));
      case FirestoreCollections.pinnedNotes:
        if (record is! PinnedNote) return null;
        return (id: record.id, payload: pinnedNoteToFirestore(record));
      case FirestoreCollections.dismissedNotifications:
        if (record is! DismissedNotification) return null;
        return (
          id: record.key,
          payload: dismissedNotificationToFirestore(record),
        );
      case FirestoreCollections.bucketListItems:
        if (record is! BucketListItem) return null;
        return (id: record.id, payload: bucketListItemToFirestore(record));
      case FirestoreCollections.tagColors:
        if (record is! TagColorRecord) return null;
        return (id: record.tag, payload: tagColorToFirestore(record));
      case FirestoreCollections.customWords:
        if (record is! CustomWord) return null;
        return (id: record.word, payload: customWordToFirestore(record));
    }
    return null;
  }

  Future<bool> pullCalendars({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.calendars,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _calendarRepository.getCalendar(id);
        await _calendarRepository.upsertCalendar(
          mergeCalendarFromRemote(data, id, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullCalendarEvents({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.calendarEvents,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _calendarRepository.getEvent(id);
        await _calendarRepository.upsertEvent(
          mergeCalendarEventFromRemote(data, id, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullTrackers({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.trackers,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _trackerRepository.getTracker(id);
        await _trackerRepository.upsertTracker(
          mergeTrackerFromRemote(data, id, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullTrackerValues({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.trackerValues,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _trackerRepository.getValue(id);
        await _trackerRepository.upsertValue(
          mergeTrackerValueFromRemote(data, id, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  // The finance repository reads by list rather than by id, so each pull
  // indexes the local rows once up front instead of scanning the table per
  // document.
  Future<bool> pullTransactions({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    final local = {
      for (final record in await _financeRepository.listTransactions(
        includeDeleted: true,
      ))
        record.id: record,
    };
    return _pullCollection(
      FirestoreCollections.transactions,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        await _financeRepository.upsertTransaction(
          mergeTransactionFromRemote(data, id, local: local[id]),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullSubscriptions({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    final local = {
      for (final record in await _financeRepository.listSubscriptions(
        includeDeleted: true,
      ))
        record.id: record,
    };
    return _pullCollection(
      FirestoreCollections.subscriptions,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        await _financeRepository.upsertSubscription(
          mergeSubscriptionFromRemote(data, id, local: local[id]),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullBudgets({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    final local = {
      for (final record in await _financeRepository.listBudgets(
        includeDeleted: true,
      ))
        record.id: record,
    };
    return _pullCollection(
      FirestoreCollections.budgets,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        await _financeRepository.upsertBudget(
          mergeBudgetFromRemote(data, id, local: local[id]),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullFinanceCategories({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    final local = {
      for (final record in await _financeRepository.listCategories(
        includeDeleted: true,
      ))
        record.id: record,
    };
    return _pullCollection(
      FirestoreCollections.financeCategories,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        await _financeRepository.upsertCategory(
          mergeFinanceCategoryFromRemote(data, id, local: local[id]),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullAssets({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    final local = {
      for (final record in await _financeRepository.listAssets(
        includeDeleted: true,
      ))
        record.id: record,
    };
    return _pullCollection(
      FirestoreCollections.assets,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        await _financeRepository.upsertAsset(
          mergeAssetFromRemote(data, id, local: local[id]),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullAssetValuations({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    final local = {
      for (final record in await _financeRepository.listAssetValuations(
        includeDeleted: true,
      ))
        record.id: record,
    };
    return _pullCollection(
      FirestoreCollections.assetValuations,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        await _financeRepository.upsertAssetValuation(
          mergeAssetValuationFromRemote(data, id, local: local[id]),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullSavingsGoals({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    final local = {
      for (final record in await _financeRepository.listSavingsGoals(
        includeDeleted: true,
      ))
        record.id: record,
    };
    return _pullCollection(
      FirestoreCollections.savingsGoals,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        await _financeRepository.upsertSavingsGoal(
          mergeSavingsGoalFromRemote(data, id, local: local[id]),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullGoalAllocations({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    final local = {
      for (final record in await _financeRepository.listGoalAllocations(
        includeDeleted: true,
      ))
        record.id: record,
    };
    return _pullCollection(
      FirestoreCollections.goalAllocations,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        await _financeRepository.upsertGoalAllocation(
          mergeGoalAllocationFromRemote(data, id, local: local[id]),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullPinnedNotes({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.pinnedNotes,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _notificationRepository.getPinnedNote(id);
        await _notificationRepository.upsertPinnedNote(
          mergePinnedNoteFromRemote(data, id, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullDismissedNotifications({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.dismissedNotifications,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (key, data, {required fromCrdt}) async {
        final local = await _notificationRepository.getDismissal(key);
        await _notificationRepository.upsertDismissal(
          mergeDismissedNotificationFromRemote(data, key, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullBucketListItems({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.bucketListItems,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _bucketListRepository.getItem(id);
        await _bucketListRepository.upsertItem(
          mergeBucketListItemFromRemote(data, id, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullTagColors({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.tagColors,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (tag, data, {required fromCrdt}) async {
        final local = await _settingsRepository.getTagColorRecord(tag);
        await _settingsRepository.upsertTagColor(
          mergeTagColorFromRemote(data, tag, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullCustomWords({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.customWords,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (word, data, {required fromCrdt}) async {
        final local = await _settingsRepository.getCustomWordRecord(word);
        await _settingsRepository.upsertCustomWord(
          mergeCustomWordFromRemote(data, word, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<void> pushSettings(AppSettings settings) async {
    try {
      // Merged into the existing `settings/app` document rather than
      // overwriting it, so the weather location living there survives.
      await _syncRepository.upsertRemoteSettings(settingsToFirestore(settings));
      _syncActivity?.recordUpload(FirestoreCollections.settings);
      await OutboxSyncWorker.recordSuccess(
        collection: FirestoreCollections.settings,
        documentId: FirestoreCollections.settingsDocumentId,
      );
    } catch (error, stackTrace) {
      debugPrint('[sync] upload failed for settings: $error\n$stackTrace');
      await OutboxSyncWorker.recordFailure(
        collection: FirestoreCollections.settings,
        documentId: FirestoreCollections.settingsDocumentId,
        error: error,
      );
    }
  }

  /// Applies the remote settings document, whole-document last-write-wins.
  ///
  /// Returns whether anything changed, so a live-sync tick triggered by the
  /// weather service's own writes to this document doesn't rebuild the app.
  Future<bool> pullSettings() async {
    _syncActivity?.recordDownloadCheck(FirestoreCollections.settings);
    final remote = await _syncRepository.getRemoteSettings();
    if (remote == null) return false;

    final local = await _settingsRepository.getSettings();
    final merged = mergeSettingsFromRemote(remote, local);
    if (identical(merged, local)) return false;

    await _settingsRepository.saveSettings(merged, recordLocalActivity: false);
    return true;
  }

  /// Pulls everything that isn't journal/todo-shaped.
  Future<void> pullSecondaryData() async {
    await pullSettings();
    await pullCalendars();
    await pullCalendarEvents();
    await pullTrackers();
    await pullTrackerValues();
    await pullTransactions();
    await pullSubscriptions();
    await pullBudgets();
    await pullFinanceCategories();
    await pullAssets();
    await pullAssetValuations();
    await pullSavingsGoals();
    await pullGoalAllocations();
    await pullPinnedNotes();
    await pullDismissedNotifications();
    await pullBucketListItems();
    await pullTagColors();
    await pullCustomWords();
  }

  /// Uploads everything in the newly synced collections once, so data that
  /// predates this device syncing them still reaches the account.
  ///
  /// Runs after the pull, never before: by then the local rows are the merged
  /// result of both sides, so uploading them can only bring the server in
  /// line with that merge. Pushing first would let a stale local row
  /// overwrite a newer one from another device, since a push — unlike a pull —
  /// does no version comparison.
  Future<void> backfillSyncedCollections() async {
    final settings = await _settingsRepository.getSettings();
    if (settings.syncBackfillVersion >= syncBackfillVersion) return;

    await pushRecords(
      FirestoreCollections.calendars,
      await _calendarRepository.listCalendars(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.calendarEvents,
      [
        for (final event in await _calendarRepository.listEvents(
          includeDeleted: true,
        ))
          // Google-imported events are rebuilt per device and never sync.
          if (event.source != EventSource.google) event,
      ],
    );

    final trackers = await _trackerRepository.listTrackers(
      includeDeleted: true,
    );
    await pushRecords(FirestoreCollections.trackers, trackers);
    for (final tracker in trackers) {
      await pushRecords(
        FirestoreCollections.trackerValues,
        await _trackerRepository.listValues(tracker.id),
      );
    }

    await pushRecords(
      FirestoreCollections.transactions,
      await _financeRepository.listTransactions(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.subscriptions,
      await _financeRepository.listSubscriptions(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.budgets,
      await _financeRepository.listBudgets(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.financeCategories,
      await _financeRepository.listCategories(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.assets,
      await _financeRepository.listAssets(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.assetValuations,
      await _financeRepository.listAssetValuations(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.savingsGoals,
      await _financeRepository.listSavingsGoals(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.goalAllocations,
      await _financeRepository.listGoalAllocations(includeDeleted: true),
    );

    await pushRecords(
      FirestoreCollections.pinnedNotes,
      await _notificationRepository.listPinnedNotes(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.dismissedNotifications,
      await _notificationRepository.listDismissalRecords(),
    );
    await pushRecords(
      FirestoreCollections.bucketListItems,
      await _bucketListRepository.listItems(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.tagColors,
      await _settingsRepository.getTagColorRecords(),
    );
    await pushRecords(
      FirestoreCollections.customWords,
      await _settingsRepository.getCustomWordRecords(),
    );
    await pushSettings(await _settingsRepository.getSettings());

    // Recorded last, and only on a clean run: an interrupted backfill should
    // be retried on the next launch rather than half-skipped. Re-read rather
    // than reusing the snapshot from the top of this method, which is now
    // stale — the pushes above can have taken a while.
    final current = await _settingsRepository.getSettings();
    await _settingsRepository.saveSettings(
      current.copyWith(syncBackfillVersion: syncBackfillVersion),
      recordLocalActivity: false,
    );
  }
}

/// One record of "this device just pushed this" — see
/// [RemoteSyncService._selfEchoes].
class _SelfEcho {
  const _SelfEcho({
    required this.at,
    required this.keys,
    required this.fingerprint,
  });

  final DateTime at;

  /// The fields the upload actually sent, so the comparison can ignore
  /// anything else the merged document happens to hold.
  final List<String> keys;

  final String fingerprint;
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
  final List<StreamSubscription<Map<String, Map<String, dynamic>>>>
  _subscriptions = [];
  var _started = false;
  var _pullInFlight = false;
  final _queuedIdsByCollection = <String, Set<String>>{};

  /// The payloads the snapshots arrived with, keyed the same way, so the pull
  /// doesn't have to buy them a second time.
  final _queuedDataByCollection = <String, Map<String, Map<String, dynamic>>>{};

  /// Collections whose last pull threw, and how many times in a row.
  ///
  /// A document that fails every time — malformed, or rejected by rules — must
  /// not be able to spin the drain loop, so retries stop after
  /// [_maxRequeueAttempts] and the batch is dropped with the error already
  /// reported.
  final _requeueAttempts = <String, int>{};
  static const _maxRequeueAttempts = 3;

  static const _watchedCollections = [
    FirestoreCollections.journals,
    FirestoreCollections.journalEntries,
    FirestoreCollections.dreamEntries,
    FirestoreCollections.todoLists,
    FirestoreCollections.todoTasks,
    FirestoreCollections.leetcodeProblems,
    FirestoreCollections.studyFolders,
    FirestoreCollections.studyDecks,
    FirestoreCollections.studyCards,
    FirestoreCollections.studyReviewLog,
    FirestoreCollections.exercises,
    FirestoreCollections.workoutPlans,
    FirestoreCollections.workoutPlanEntries,
    FirestoreCollections.workoutSessions,
    FirestoreCollections.workoutSetLogs,
    FirestoreCollections.customQuotes,
    FirestoreCollections.calendars,
    FirestoreCollections.calendarEvents,
    FirestoreCollections.trackers,
    FirestoreCollections.trackerValues,
    FirestoreCollections.transactions,
    FirestoreCollections.subscriptions,
    FirestoreCollections.budgets,
    FirestoreCollections.financeCategories,
    FirestoreCollections.assets,
    FirestoreCollections.assetValuations,
    FirestoreCollections.savingsGoals,
    FirestoreCollections.goalAllocations,
    FirestoreCollections.pinnedNotes,
    FirestoreCollections.dismissedNotifications,
    FirestoreCollections.bucketListItems,
    FirestoreCollections.tagColors,
    FirestoreCollections.customWords,
    FirestoreCollections.settings,
  ];

  void start() {
    if (_started || _syncRepository is NoOpSyncRepository) return;
    _started = true;

    for (final collection in _watchedCollections) {
      _subscriptions.add(
        _syncRepository.watchCollection(collection).listen((changed) {
          if (changed.isEmpty) return;
          unawaited(_handleRemoteChange(collection, changed));
        }),
      );
    }
  }

  Future<void> _handleRemoteChange(
    String collection,
    Map<String, Map<String, dynamic>> changed,
  ) async {
    _queuedIdsByCollection
        .putIfAbsent(collection, () => <String>{})
        .addAll(changed.keys);
    _queuedDataByCollection
        .putIfAbsent(collection, () => <String, Map<String, dynamic>>{})
        .addAll(changed);
    if (_pullInFlight) return;

    _pullInFlight = true;
    try {
      while (_queuedIdsByCollection.isNotEmpty) {
        final pending = Map<String, Set<String>>.from(_queuedIdsByCollection);
        final pendingData = Map<String, Map<String, Map<String, dynamic>>>.from(
          _queuedDataByCollection,
        );
        _queuedIdsByCollection.clear();
        _queuedDataByCollection.clear();
        for (final entry in pending.entries) {
          try {
            final applied = await _remoteSync.pullForCollection(
              entry.key,
              documentIds: entry.value,
              documentData: pendingData[entry.key],
            );
            _requeueAttempts.remove(entry.key);
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
            // The ids were taken off the queue before the pull, and Firestore
            // delivers a docChange exactly once — so dropping them here lost
            // those documents' updates on this device until the next full pull
            // at launch. Put them back, bounded, so a permanently-failing
            // document can't spin the loop instead.
            final attempts = (_requeueAttempts[entry.key] ?? 0) + 1;
            if (attempts <= _maxRequeueAttempts) {
              _requeueAttempts[entry.key] = attempts;
              _queuedIdsByCollection
                  .putIfAbsent(entry.key, () => <String>{})
                  .addAll(entry.value);
              final data = pendingData[entry.key];
              if (data != null) {
                _queuedDataByCollection
                    .putIfAbsent(
                      entry.key,
                      () => <String, Map<String, dynamic>>{},
                    )
                    .addAll(data);
              }
            } else {
              _requeueAttempts.remove(entry.key);
            }
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
    _queuedDataByCollection.clear();
    _requeueAttempts.clear();
    _started = false;
  }
}
