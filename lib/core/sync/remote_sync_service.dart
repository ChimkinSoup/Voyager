import 'dart:async';
import 'dart:convert';

// ignore_for_file: prefer_initializing_formals
import 'package:flutter/foundation.dart';
import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/sync/char_ops_encoder.dart';
import 'package:voyager/core/sync/crdt_document_resolver.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
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
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/leetcode_cheat_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_deck_graph.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';
import 'package:voyager/domain/models/media_models.dart';
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
    required JobRepository jobRepository,
    required RankingRepository rankingRepository,
    required CalendarRepository calendarRepository,
    required TrackerRepository trackerRepository,
    required FinanceRepository financeRepository,
    required NotificationRepository notificationRepository,
    required ReminderRepository reminderRepository,
    required BucketListRepository bucketListRepository,
    required MediaRepository mediaRepository,
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
       _jobRepository = jobRepository,
       _rankingRepository = rankingRepository,
       _calendarRepository = calendarRepository,
       _trackerRepository = trackerRepository,
       _financeRepository = financeRepository,
       _notificationRepository = notificationRepository,
       _reminderRepository = reminderRepository,
       _bucketListRepository = bucketListRepository,
       _mediaRepository = mediaRepository,
       _settingsRepository = settingsRepository,
       _weatherService = weatherService,
       _syncEngine = syncEngine,
       _syncConflictRepository = syncConflictRepository,
       _syncActivity = syncActivity,
       _crdtResolver = crdtResolver ?? CrdtDocumentResolver(),
       _charOpRegistry = charOpRegistry ?? CharacterOpRegistry(),
       _ownsCharOpRegistry = charOpRegistry == null,
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
  final JobRepository _jobRepository;
  final RankingRepository _rankingRepository;
  final CalendarRepository _calendarRepository;
  final TrackerRepository _trackerRepository;
  final FinanceRepository _financeRepository;
  final NotificationRepository _notificationRepository;
  final ReminderRepository _reminderRepository;
  final BucketListRepository _bucketListRepository;
  final MediaRepository _mediaRepository;
  final SettingsRepository _settingsRepository;
  final WeatherService _weatherService;
  final SyncEngine _syncEngine;
  final SyncConflictRepository? _syncConflictRepository;
  final SyncActivityController? _syncActivity;
  final CrdtDocumentResolver _crdtResolver;
  final CharacterOpRegistry _charOpRegistry;

  /// False when the registry was handed in, in which case it outlives this
  /// service — see `charOpRegistryProvider`.
  final bool _ownsCharOpRegistry;
  final SyncConflictDetector _conflictDetector;
  final CharacterSequenceCrdtMerger _charMerger;
  final Duration _uploadDebounceDelay;
  final String deviceId;
  bool forceConflictUi;
  var _forceNextDownloadConflict = false;
  final Map<String, Timer> _activeDebouncers = {};
  final Map<String, Future<void>> _localSaveChains = {};
  final Map<String, Future<void> Function()> _pendingRemoteSaves = {};

  /// The collection and id behind each [_pendingRemoteSaves] key, which the
  /// key's `collection_id` spelling cannot be split back into.
  final Map<String, ({String collection, String documentId})>
  _pendingRemoteSaveTargets = {};

  /// Each document's uploads, one at a time — see [_runRemoteSave].
  final Map<String, Future<void>> _remoteSaveChains = {};
  final Map<String, int> _localSaveGenerations = {};
  final Set<String> _activelyEditedDocuments = {};
  final PendingTextMergeBuffer _pendingTextMergeBuffer =
      PendingTextMergeBuffer();

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
    _recordTextChange(
      FirestoreCollections.journalEntries,
      entryId,
      before: before,
      after: after,
    );
  }

  void recordDreamTextChange({
    required String entryId,
    required String before,
    required String after,
  }) {
    _recordTextChange(
      FirestoreCollections.dreamEntries,
      entryId,
      before: before,
      after: after,
    );
  }

  void recordTodoNotesChange({
    required String taskId,
    required String before,
    required String after,
  }) {
    _recordTextChange(
      FirestoreCollections.todoTasks,
      taskId,
      before: before,
      after: after,
    );
  }

  /// Records an editor's edit from [before] to [after] against the session.
  ///
  /// The session is supposed to spell [before] already, and when it does this
  /// is a plain diff. When it doesn't — the session has absorbed another
  /// device's characters the editor is not showing yet, or the editor was
  /// re-seeded by a route the session never saw — diffing [before] against it
  /// used to fall through to `resetFromText`, which re-seeds every character
  /// under fresh ids at fresh positions while the old ones stay live in the
  /// shared log: the whole document twice on the next merge. The user's edit is
  /// re-applied onto the session's own text instead, so only what they typed
  /// becomes operations.
  void _recordTextChange(
    String collection,
    String documentId, {
    required String before,
    required String after,
  }) {
    final session = _charOpRegistry.session(collection, documentId);
    final current = session?.text;
    // The editor catching up to text the session already holds — a pull it
    // has absorbed, re-seeded into the field — is not an edit.
    if (current != null && current != before && current == after) return;
    _charOpRegistry.recordTextChange(
      collection: collection,
      documentId: documentId,
      clientId: deviceId,
      before: current ?? before,
      after: current == null || current == before
          ? after
          : _rebaseEdit(onto: current, before: before, after: after),
    );
  }

  /// Replaces what an open editor shows with [text] from SQLite.
  ///
  /// Diffed from the session's own text rather than from what the editor held:
  /// after a pull the session has already absorbed the operations that produced
  /// [text], so there is usually nothing to record at all. Recording the
  /// editor's old text against [text] is what re-inserted another device's
  /// characters as this device's own.
  void reanchorEditorText({
    required String collection,
    required String documentId,
    required String text,
  }) {
    final session = _charOpRegistry.session(collection, documentId);
    if (session == null || session.text == text) return;
    _charOpRegistry.recordTextChange(
      collection: collection,
      documentId: documentId,
      clientId: deviceId,
      before: session.text,
      after: text,
    );
  }

  /// [after] is [before] with one contiguous edit; returns [onto] with that
  /// same edit applied where it can be placed unambiguously.
  ///
  /// Text the edit did not touch is never removed: a deletion inside a span
  /// where [before] and [onto] disagree is applied only if the deleted text can
  /// be found there, and an insertion there lands at the start of the span.
  static String _rebaseEdit({
    required String onto,
    required String before,
    required String after,
  }) {
    var start = 0;
    while (start < before.length &&
        start < after.length &&
        before.codeUnitAt(start) == after.codeUnitAt(start)) {
      start++;
    }
    var beforeEnd = before.length;
    var afterEnd = after.length;
    while (beforeEnd > start &&
        afterEnd > start &&
        before.codeUnitAt(beforeEnd - 1) == after.codeUnitAt(afterEnd - 1)) {
      beforeEnd--;
      afterEnd--;
    }
    final deleted = before.substring(start, beforeEnd);
    final inserted = after.substring(start, afterEnd);

    var shared = 0;
    while (shared < before.length &&
        shared < onto.length &&
        before.codeUnitAt(shared) == onto.codeUnitAt(shared)) {
      shared++;
    }
    var sharedTail = 0;
    while (sharedTail < before.length - shared &&
        sharedTail < onto.length - shared &&
        before.codeUnitAt(before.length - 1 - sharedTail) ==
            onto.codeUnitAt(onto.length - 1 - sharedTail)) {
      sharedTail++;
    }

    final int at;
    var removeLength = deleted.length;
    if (beforeEnd <= shared) {
      at = start;
    } else if (start >= before.length - sharedTail) {
      at = onto.length - (before.length - start);
    } else {
      final found = deleted.isEmpty ? -1 : onto.indexOf(deleted, shared);
      if (found >= 0 && found + deleted.length <= onto.length - sharedTail) {
        at = found;
      } else {
        at = shared;
        removeLength = 0;
      }
    }
    return onto.replaceRange(at, at + removeLength, inserted);
  }

  Future<List<SyncConflict>> listConflicts() async {
    final repo = _syncConflictRepository;
    if (repo == null) return const [];
    return repo.listConflicts();
  }

  /// Opens an editing session on the document's *current* operation log and
  /// diffs [target] onto it, so the resolution uploads only the delta.
  ///
  /// Every resolution path used to seed this session from the `_remoteCharOps`
  /// frozen into the conflict row instead. That snapshot is taken at detection
  /// time, so by the time the user picks a side its live operations can be
  /// stale — anchors tombstoned since are still live in it. A fractional index
  /// is a pure function of its two anchors, so inserting against stale anchors
  /// regenerates positions the real chain already uses. Colliding positions
  /// are what raised the conflict to begin with, which made resolving one a
  /// way to seed the next.
  ///
  /// Diffing from the session's own reconstruction rather than the conflict's
  /// recorded remote text matters for the same reason: the diff indices are
  /// applied to the loaded operations, and only that text is guaranteed to
  /// line up with them.
  Future<void> _rebaseCharOpsOnLiveChain({
    required String collection,
    required String documentId,
    required String target,
  }) async {
    final ops = await _listRemoteCharOps(
      firestoreDocumentIdForLocal(collection, documentId),
    );
    // Folded into an open editor's session rather than replacing it: loading
    // a fresh session threw away the keystrokes it had not uploaded yet.
    if (_charOpRegistry.session(collection, documentId) == null) {
      _charOpRegistry.loadSession(
        collection: collection,
        documentId: documentId,
        clientId: deviceId,
        operations: ops,
      );
    } else {
      _charOpRegistry.absorbRemote(collection, documentId, ops);
    }
    final session = _charOpRegistry.session(collection, documentId);
    if (session == null) return;
    _charOpRegistry.recordTextChange(
      collection: collection,
      documentId: documentId,
      clientId: deviceId,
      before: session.text,
      after: target,
    );
  }

  Future<void> resolveConflictKeepLocal(SyncConflict conflict) async {
    final repo = _syncConflictRepository;
    if (repo == null) return;
    if (conflict.collection == FirestoreCollections.journalEntries) {
      final local = await _journalRepository.getEntry(conflict.documentId);
      if (local != null) {
        await _rebaseCharOpsOnLiveChain(
          collection: FirestoreCollections.journalEntries,
          documentId: conflict.documentId,
          target: local.body,
        );
        await _uploadJournalEntryNow(local, bumpVersion: true);
      }
    } else if (conflict.collection == FirestoreCollections.dreamEntries) {
      final local = await _dreamRepository.getEntry(conflict.documentId);
      if (local != null) {
        await _rebaseCharOpsOnLiveChain(
          collection: FirestoreCollections.dreamEntries,
          documentId: conflict.documentId,
          target: local.body,
        );
        await _uploadDreamEntryNow(local, bumpVersion: true);
      }
    } else if (conflict.collection == FirestoreCollections.todoTasks) {
      final local = await _findTodoTask(conflict.documentId);
      if (local != null) {
        await _rebaseCharOpsOnLiveChain(
          collection: FirestoreCollections.todoTasks,
          documentId: conflict.documentId,
          target: local.notes ?? '',
        );
        await _uploadTodoTaskNow(local, bumpVersion: true);
      }
    }
    await repo.deleteConflict(conflict.id);
  }

  Future<void> resolveConflictKeepRemote(SyncConflict conflict) async {
    final repo = _syncConflictRepository;
    if (repo == null) return;
    final remote =
        jsonDecode(conflict.remotePayloadJson) as Map<String, dynamic>;
    if (conflict.collection == FirestoreCollections.journalEntries) {
      final local = await _journalRepository.getEntry(conflict.documentId);
      final merged = mergeJournalEntryFromRemote(
        remote,
        conflict.documentId,
        local: local,
      );
      await _journalRepository.upsertEntry(merged, recordLocalActivity: false);

      await _rebaseCharOpsOnLiveChain(
        collection: FirestoreCollections.journalEntries,
        documentId: conflict.documentId,
        target: merged.body,
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

      await _rebaseCharOpsOnLiveChain(
        collection: FirestoreCollections.dreamEntries,
        documentId: conflict.documentId,
        target: merged.body,
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

      await _rebaseCharOpsOnLiveChain(
        collection: FirestoreCollections.todoTasks,
        documentId: conflict.documentId,
        target: merged.notes ?? '',
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

      await _rebaseCharOpsOnLiveChain(
        collection: FirestoreCollections.journalEntries,
        documentId: conflict.documentId,
        target: mergedText,
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

      await _rebaseCharOpsOnLiveChain(
        collection: FirestoreCollections.dreamEntries,
        documentId: conflict.documentId,
        target: mergedText,
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

      await _rebaseCharOpsOnLiveChain(
        collection: FirestoreCollections.todoTasks,
        documentId: conflict.documentId,
        target: mergedText,
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
    final operationsDeleted = await _syncRepository.deleteOperationsForDocument(
      firestoreDocId,
    );

    _charOpRegistry.removeSession(collection, documentId);
    _pendingTextMergeBuffer.clearDocument(collection, documentId);

    final conflictRepo = _syncConflictRepository;
    if (conflictRepo != null) {
      await conflictRepo.deleteConflictsForDocument(collection, documentId);
    }

    return operationsDeleted;
  }

  /// Publishes a wholesale text rewrite of [entry] — the Search popup's save,
  /// where no sequential CRDT session was ever maintained — and returns the row
  /// that was actually written.
  ///
  /// Returns the published row rather than nothing, and persists it before
  /// uploading it, because the two must stay on the same version. Uploading a
  /// `copyWith(bumpVersion: true)` that never reached SQLite left the remote
  /// copy at `N+1` against a local row still at `N`, and `remoteVersionWins`
  /// then resolved every later pull in the remote's favour — reverting offline
  /// edits made after the save. See [_uploadJournalEntryNow]'s note.
  ///
  /// [queueOnFailure] is false when the outbox is the caller: a failure there
  /// must propagate so the drain can retry or park the row it already holds,
  /// rather than queueing a second one.
  Future<JournalEntry> forceOverwriteJournalEntryText(
    JournalEntry entry, {
    bool queueOnFailure = true,
  }) async {
    const collection = FirestoreCollections.journalEntries;

    // Another surface — the journal editor — owns this document's chain and
    // holds operations it has not uploaded yet. `resetSession` replaces a
    // session unconditionally (unlike `ensureSession`'s putIfAbsent), so the
    // wipe-and-reseed below would throw those away: the next upload would drain
    // the blank replacement, and the following `recordTextChange` would start a
    // fresh chain whose sequence counter restarts at 0 and sorts *before* the
    // surviving one. Rebasing composes with the live chain instead, which is
    // what conflict resolution does with the same problem, and leaves the
    // session in place for the editor to keep writing into.
    if (_charOpRegistry.session(collection, entry.id) != null) {
      final published = await _persistPublishedRevision(entry);
      await _rebaseCharOpsOnLiveChain(
        collection: collection,
        documentId: published.id,
        target: published.body,
      );
      await _uploadJournalEntryNow(published);
      await OutboxSyncWorker.recordSuccess(
        collection: collection,
        documentId: published.id,
      );
      return published;
    }

    // Wiping the log and re-seeding it from '' is only sound once the wipe is
    // known to have happened. Firestore answers reads from the local cache
    // while offline, so this used to return 0 with the remote log fully intact
    // and the reseed then stacked the whole body on top of the surviving chain
    // — the duplicated text this method exists to prevent.
    // `deleteOperationsForDocument` now forces a server round-trip and throws
    // instead of lying, which turns that silent corruption into a deferral.
    // Attempted before anything is written locally: a deferral must leave the
    // row exactly as it found it, or each pass of the outbox drain would bump
    // the version again and the retries alone would inflate it.
    try {
      await _syncRepository.deleteOperationsForDocument(entry.id);
    } catch (error, stackTrace) {
      if (!queueOnFailure) rethrow;
      // Nothing is written and nothing is uploaded here on purpose. The row
      // the caller already persisted outranks the remote copy on version, and
      // the remote log is untouched, so no device loses anything; the rewrite
      // is simply owed to the server until the outbox can prove the wipe.
      await OutboxSyncWorker.recordCrdtOverwrite(
        collection: collection,
        documentId: entry.id,
      );
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'RemoteSyncService',
          context: ErrorDescription(
            'while wiping the operation log for ${entry.id}; the text rewrite '
            'was queued for a later attempt',
          ),
        ),
      );
      return entry;
    }

    final published = await _persistPublishedRevision(entry);
    _charOpRegistry.resetSession(
      collection: collection,
      documentId: published.id,
      clientId: deviceId,
      text: '',
    );
    _charOpRegistry.recordTextChange(
      collection: collection,
      documentId: published.id,
      clientId: deviceId,
      before: '',
      after: published.body,
    );
    // No second bump: `published` is what SQLite holds.
    try {
      await _uploadJournalEntryNow(published);
    } catch (_) {
      // The log is already wiped and nothing has replaced it, so this device
      // is the only holder of the rewrite. The seed operations stay pending in
      // the session, but a session does not survive a restart; the outbox row
      // does, and replaying it re-publishes from the row.
      if (queueOnFailure) {
        await OutboxSyncWorker.recordCrdtOverwrite(
          collection: collection,
          documentId: published.id,
        );
      }
      rethrow;
    }

    _charOpRegistry.removeSession(collection, published.id);
    await OutboxSyncWorker.recordSuccess(
      collection: collection,
      documentId: published.id,
    );
    return published;
  }

  /// The revision [forceOverwriteJournalEntryText] publishes, written to SQLite
  /// before it is uploaded so the two can never disagree on version.
  Future<JournalEntry> _persistPublishedRevision(JournalEntry entry) async {
    final published = entry.copyWith(bumpVersion: true);
    await _journalRepository.upsertEntry(published, recordLocalActivity: false);
    return published;
  }

  /// [forceOverwriteJournalEntryText] for a dream: the Search page's dream
  /// popup saves a body without ever having held a sequential CRDT session,
  /// and `dreamEntries` is CRDT-backed too (see
  /// [FirestoreCollections.crdtBacked]), so the same wipe-and-reseed is owed.
  ///
  /// Every note on the journal version applies here — why the published row is
  /// persisted before it is uploaded, why an open editor's live chain is
  /// rebased rather than replaced, and why a failed wipe writes nothing and
  /// queues instead.
  Future<DreamEntry> forceOverwriteDreamEntryText(
    DreamEntry entry, {
    bool queueOnFailure = true,
  }) async {
    const collection = FirestoreCollections.dreamEntries;

    if (_charOpRegistry.session(collection, entry.id) != null) {
      final published = await _persistPublishedDreamRevision(entry);
      await _rebaseCharOpsOnLiveChain(
        collection: collection,
        documentId: published.id,
        target: published.body,
      );
      await _uploadDreamEntryNow(published);
      await OutboxSyncWorker.recordSuccess(
        collection: collection,
        documentId: published.id,
      );
      return published;
    }

    try {
      await _syncRepository.deleteOperationsForDocument(entry.id);
    } catch (error, stackTrace) {
      if (!queueOnFailure) rethrow;
      await OutboxSyncWorker.recordCrdtOverwrite(
        collection: collection,
        documentId: entry.id,
      );
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'RemoteSyncService',
          context: ErrorDescription(
            'while wiping the operation log for dream ${entry.id}; the text '
            'rewrite was queued for a later attempt',
          ),
        ),
      );
      return entry;
    }

    final published = await _persistPublishedDreamRevision(entry);
    _charOpRegistry.resetSession(
      collection: collection,
      documentId: published.id,
      clientId: deviceId,
      text: '',
    );
    _charOpRegistry.recordTextChange(
      collection: collection,
      documentId: published.id,
      clientId: deviceId,
      before: '',
      after: published.body,
    );
    try {
      await _uploadDreamEntryNow(published);
    } catch (_) {
      if (queueOnFailure) {
        await OutboxSyncWorker.recordCrdtOverwrite(
          collection: collection,
          documentId: published.id,
        );
      }
      rethrow;
    }

    _charOpRegistry.removeSession(collection, published.id);
    await OutboxSyncWorker.recordSuccess(
      collection: collection,
      documentId: published.id,
    );
    return published;
  }

  /// [_persistPublishedRevision] for a dream.
  Future<DreamEntry> _persistPublishedDreamRevision(DreamEntry entry) async {
    final published = entry.copyWith(bumpVersion: true);
    await _dreamRepository.upsertEntry(published, recordLocalActivity: false);
    return published;
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

  /// Settles [key]'s local writes, then runs its pending upload and waits for
  /// it.
  ///
  /// Through [_runRemoteSave], like every other upload: this is reached from
  /// teardown and from fire-and-forget panel closes, and running the save bare
  /// let a failure escape to the zone with nothing queued to retry it — the
  /// pending save had already been taken off [_pendingRemoteSaves].
  Future<void> flushPending(String key) async {
    await _localSaveChains[key]?.catchError((_) {});
    final remoteSave = _pendingRemoteSaves.remove(key);
    final target = _pendingRemoteSaveTargets.remove(key);
    _activeDebouncers.remove(key)?.cancel();
    if (remoteSave != null && target != null) {
      await _runRemoteSave(target.collection, target.documentId, remoteSave);
    }
  }

  Future<void> flushDocument(String collection, String documentId) {
    return flushPending(documentKey(collection, documentId));
  }

  /// Waits for [documentId]'s queued local writes to reach SQLite, and for
  /// nothing else.
  ///
  /// The half of [flushPending] that never touches the network. Callers that
  /// only need the document to be safely on disk before they act on it — an
  /// editor changing its selection, a delete about to read the row back — want
  /// this and not the upload, which with offline persistence never completes
  /// while Firestore is unreachable.
  ///
  /// A pending upload is left scheduled. It re-reads the row from SQLite when
  /// it runs, so it always carries whatever this settled, not the text it was
  /// queued for. Cancel it with [cancelDocument] if it must not run at all.
  Future<void> settleLocalWrites(String collection, String documentId) async {
    await _localSaveChains[documentKey(collection, documentId)]?.catchError(
      (_) {},
    );
  }

  /// [settleLocalWrites], then starts the pending upload without waiting for
  /// the server to acknowledge it.
  ///
  /// The commitment-point flush for a text editor: everything typed is on disk
  /// when this returns, and the round-trip is handed to the background through
  /// the same [_runRemoteSave] the debounce timer uses, so a failure is still
  /// recorded on the outbox. [flushDocument] awaits that round-trip instead,
  /// which on an unreachable server blocks the caller indefinitely.
  Future<void> flushDocumentLocal(String collection, String documentId) async {
    await settleLocalWrites(collection, documentId);
    final key = documentKey(collection, documentId);
    final remoteSave = _pendingRemoteSaves.remove(key);
    _pendingRemoteSaveTargets.remove(key);
    _activeDebouncers.remove(key)?.cancel();
    if (remoteSave != null) {
      unawaited(_runRemoteSave(collection, documentId, remoteSave));
    }
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
    _pendingRemoteSaveTargets.remove(key);
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
      //
      // Only when the difference is this device's own, though. The log is just
      // as often *ahead* of SQLite — another device edited and this one has not
      // pulled yet — and diffing then tombstoned the other device's text as if
      // this device had deleted it, everywhere, on the next upload. Characters
      // another client wrote are never deleted from here: the document is
      // pulled instead, which brings SQLite and the editor up to the log.
      final loaded = _charOpRegistry.session(collection, documentId);
      if (loaded != null &&
          loaded.text != initialText &&
          loaded
              .opsReplacedBy(initialText)
              .any((op) => op.clientId != deviceId)) {
        unawaited(
          pullForCollection(
            collection,
            documentIds: {firestoreDocumentIdForLocal(collection, documentId)},
          ).catchError((Object error, StackTrace stackTrace) {
            debugPrint('[sync] catch-up pull for $documentId failed: $error');
            return false;
          }),
        );
      } else if (loaded != null && loaded.text != initialText) {
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
    // Behind this entry's queued local saves, so the row merged into is the
    // latest one rather than one a save is about to overwrite.
    await settleLocalWrites(FirestoreCollections.journalEntries, entryId);
    final local = await _journalRepository.getEntry(entryId);
    if (local == null) return null;

    final merged = local.copyWith(
      body: body,
      // From the merged body: the remote's tags describe only its side.
      tags: extractTags(body),
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
    await settleLocalWrites(FirestoreCollections.dreamEntries, entryId);
    final local = await _dreamRepository.getEntry(entryId);
    if (local == null) return null;

    final merged = local.copyWith(
      body: body,
      tags: extractTags(body),
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
    await pullLeetCodeReviewLog();
    // Parents before children, so the orphan filter in the read query never
    // hides a section or entry whose tab simply has not landed yet.
    await pullLeetCodeCheatTabs();
    await pullLeetCodeCheatSections();
    await pullLeetCodeCheatEntries();
    await pullStudyFolders();
    await pullStudyDecks();
    await pullStudyCards();
    await pullStudyReviewLog();
    await pullStudyDeckLinks();
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
      case FirestoreCollections.mediaAssets:
        return pullMediaAssets(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.mediaReferences:
        return pullMediaReferences(
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
      case FirestoreCollections.leetcodeReviewLog:
        return pullLeetCodeReviewLog(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.leetcodeCheatTabs:
        return pullLeetCodeCheatTabs(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.leetcodeCheatSections:
        return pullLeetCodeCheatSections(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.leetcodeCheatEntries:
        return pullLeetCodeCheatEntries(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.studyReviewLog:
        return pullStudyReviewLog(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.studyDeckLinks:
        return pullStudyDeckLinks(
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
      case FirestoreCollections.jobApplications:
        return pullJobApplications(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.jobStatusEvents:
        return pullJobStatusEvents(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.jobStages:
        return pullJobStages(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.jobCompanies:
        return pullJobCompanies(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.jobCategories:
        return pullJobCategories(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.jobSeasons:
        return pullJobSeasons(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.rankingCategories:
        return pullRankingCategories(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.rankingParents:
        return pullRankingParents(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.rankingChildren:
        return pullRankingChildren(
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
        return pullAssets(documentIds: documentIds, documentData: documentData);
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
      case FirestoreCollections.contributionRooms:
        return pullContributionRooms(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.assetRoomEvents:
        return pullAssetRoomEvents(
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
      case FirestoreCollections.deviceRegistrations:
        return pullDeviceRegistrations(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.scheduledReminderRules:
        return pullScheduledReminderRules(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.entityReminders:
        return pullEntityReminders(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.reminderDeliveryStates:
        return pullReminderDeliveryStates(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.reminderDeliveryLogs:
        return pullReminderDeliveryLogs(
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
      case FirestoreCollections.snippets:
        return pullSnippets(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.jobExperienceSnippets:
        return pullJobExperienceSnippets(
          documentIds: documentIds,
          documentData: documentData,
        );
      case FirestoreCollections.flaggedWords:
        return pullFlaggedWords(
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

  Future<bool> pullLeetCodeReviewLog({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.leetcodeReviewLog,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        // Resolved against the local row: a log row can be taken back by an
        // undo, and without the local copy a stale remote revision would
        // un-delete a grade the user undid here.
        final local = await _leetCodeRepository.getReviewLog(id);
        final merged = mergeLeetCodeReviewLogFromRemote(data, id, local: local);
        await _leetCodeRepository.logReview(merged, recordLocalActivity: false);
      },
    );
  }

  Future<bool> pullLeetCodeCheatTabs({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.leetcodeCheatTabs,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _leetCodeRepository.getCheatTab(id);
        final merged = mergeLeetCodeCheatTabFromRemote(data, id, local: local);
        await _leetCodeRepository.upsertCheatTab(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullLeetCodeCheatSections({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.leetcodeCheatSections,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _leetCodeRepository.getCheatSection(id);
        final merged = mergeLeetCodeCheatSectionFromRemote(
          data,
          id,
          local: local,
        );
        await _leetCodeRepository.upsertCheatSection(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullLeetCodeCheatEntries({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.leetcodeCheatEntries,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _leetCodeRepository.getCheatEntry(id);
        final merged = mergeLeetCodeCheatEntryFromRemote(
          data,
          id,
          local: local,
        );
        await _leetCodeRepository.upsertCheatEntry(
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

  Future<bool> pullJobApplications({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.jobApplications,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _jobRepository.getApplication(id);
        final result = resolveJobApplicationFromRemote(data, id, local: local);
        await _jobRepository.upsertApplication(
          result.merged,
          recordLocalActivity: false,
        );
        // See [pullRankingParents].
        if (result.localWon) pushJobApplication(result.merged);
      },
    );
  }

  Future<bool> pullJobStatusEvents({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.jobStatusEvents,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        // Timeline entries are append-only and keyed by their own uuid, so
        // there is nothing to look up a local copy for — the remote row either
        // is this row or does not exist here yet.
        final merged = mergeJobStatusEventFromRemote(data, id);
        await _jobRepository.upsertStatusEvent(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullJobStages({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.jobStages,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final stages = await _jobRepository.getAllStages();
        final local = stages.cast<JobStage?>().firstWhere(
          (s) => s!.id == id,
          orElse: () => null,
        );
        final merged = mergeJobStageFromRemote(data, id, local: local);
        await _jobRepository.upsertStage(merged, recordLocalActivity: false);
      },
    );
  }

  Future<bool> pullJobCompanies({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.jobCompanies,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final companies = await _jobRepository.getAllCompanies();
        final local = companies.cast<JobCompany?>().firstWhere(
          (c) => c!.id == id,
          orElse: () => null,
        );
        final merged = mergeJobCompanyFromRemote(data, id, local: local);
        await _jobRepository.upsertCompany(merged, recordLocalActivity: false);
      },
    );
  }

  Future<bool> pullJobCategories({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.jobCategories,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final categories = await _jobRepository.getAllCategories();
        final local = categories.cast<JobCategory?>().firstWhere(
          (c) => c!.id == id,
          orElse: () => null,
        );
        final merged = mergeJobCategoryFromRemote(data, id, local: local);
        await _jobRepository.upsertCategory(merged, recordLocalActivity: false);
      },
    );
  }

  Future<bool> pullJobSeasons({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.jobSeasons,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final seasons = await _jobRepository.getAllSeasons();
        final local = seasons.cast<JobSeason?>().firstWhere(
          (s) => s!.id == id,
          orElse: () => null,
        );
        final merged = mergeJobSeasonFromRemote(data, id, local: local);
        await _jobRepository.upsertSeason(merged, recordLocalActivity: false);
      },
    );
  }

  Future<bool> pullRankingCategories({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.rankingCategories,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _rankingRepository.getCategory(id);
        final merged = mergeRankingCategoryFromRemote(data, id, local: local);
        await _rankingRepository.upsertCategory(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullRankingParents({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.rankingParents,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _rankingRepository.getParent(id);
        final result = resolveRankingParentFromRemote(data, id, local: local);
        await _rankingRepository.upsertParent(
          result.merged,
          recordLocalActivity: false,
        );
        // This device kept a field the document did not have, so it is the
        // only one holding the merged row until it uploads it.
        if (result.localWon) pushRankingParent(result.merged);
      },
    );
  }

  Future<bool> pullRankingChildren({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.rankingChildren,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _rankingRepository.getChild(id);
        final result = resolveRankingChildFromRemote(data, id, local: local);
        await _rankingRepository.upsertChild(
          result.merged,
          recordLocalActivity: false,
        );
        // See [pullRankingParents].
        if (result.localWon) pushRankingChild(result.merged);
      },
    );
  }

  Future<bool> pullMediaAssets({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.mediaAssets,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _mediaRepository.getAsset(id);
        final merged = mergeMediaAssetFromRemote(data, id, local: local);
        await _mediaRepository.upsertAsset(merged, recordLocalActivity: false);
      },
    );
  }

  Future<bool> pullMediaReferences({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.mediaReferences,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _mediaRepository.getReference(id);
        final merged = mergeMediaReferenceFromRemote(data, id, local: local);
        await _mediaRepository.upsertReference(
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
        // Resolved against the local row: a log row can now be taken back, and
        // without the local copy a stale remote revision would un-delete a
        // grade the user undid here.
        final local = await _studyRepository.getReviewLog(id);
        final merged = mergeStudyReviewLogFromRemote(data, id, local: local);
        await _studyRepository.logReview(merged, recordLocalActivity: false);
      },
    );
  }

  Future<bool> pullStudyDeckLinks({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    final applied = await _pullCollection(
      FirestoreCollections.studyDeckLinks,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _studyRepository.getDeckLink(id);
        final merged = mergeStudyDeckLinkFromRemote(data, id, local: local);
        await _studyRepository.upsertDeckLink(
          merged,
          recordLocalActivity: false,
        );
      },
    );
    if (applied) await _breakStudyDeckLinkCycles();
    return applied;
  }

  /// Linking refuses cycles locally, but two devices can each add half of one
  /// while apart. Once both halves are here, the newest link in the loop is
  /// tombstoned and pushed — the same one on every device, since
  /// [studyDeckLinksClosingCycles] depends only on the rows.
  Future<void> _breakStudyDeckLinkCycles() async {
    final closing = studyDeckLinksClosingCycles(
      await _studyRepository.listDeckLinks(),
    );
    for (final link in closing) {
      await _studyRepository.softDeleteDeckLink(link.id);
      final tombstone = await _studyRepository.getDeckLink(link.id);
      if (tombstone != null) pushStudyDeckLink(tombstone);
    }
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
        _charOpRegistry.absorbRemote(
          FirestoreCollections.journalEntries,
          id,
          remoteCharOps,
        );
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
          payloadWithOps['_remoteCharOps'] = remoteCharOps
              .map((o) => o.toJson())
              .toList();

          await _quarantineConflict(
            collection: FirestoreCollections.journalEntries,
            documentId: id,
            reason: detection.reason,
            local: local == null
                ? null
                : SyncConflictDetector.payloadJson(
                    journalEntryToFirestore(local),
                  ),
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
          crdtText: fromCrdt ? CrdtTextFields.fromJournalPayload(data) : null,
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
          final owed = local == null || !fromCrdt
              ? null
              : await _textOwedByThisDevice(
                  FirestoreCollections.journalEntries,
                  id,
                  localText: local.body,
                  logText: merged.body,
                  localIsNewer: _localIsNewer(
                    data,
                    version: local.version,
                    updatedAt: local.updatedAt,
                  ),
                  localIsSameRevision: _localIsSameRevision(
                    data,
                    version: local.version,
                    updatedAt: local.updatedAt,
                  ),
                );
          if (owed != null) {
            merged = JournalEntry(
              id: merged.id,
              journalId: merged.journalId,
              title: merged.title,
              body: owed,
              richBodyJson: owed == local!.body
                  ? local.richBodyJson
                  : merged.richBodyJson,
              entryDate: merged.entryDate,
              timestamp: merged.timestamp,
              tags: extractTags(owed),
              mood: merged.mood,
              quoteId: merged.quoteId,
              customQuote: merged.customQuote,
              weatherIcon: merged.weatherIcon,
              guidedPrompt: merged.guidedPrompt,
              createdAt: merged.createdAt,
              updatedAt: merged.updatedAt,
              version: merged.version,
              deletedAt: merged.deletedAt,
            );
          }
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
        _charOpRegistry.absorbRemote(
          FirestoreCollections.dreamEntries,
          id,
          remoteCharOps,
        );
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
          payloadWithOps['_remoteCharOps'] = remoteCharOps
              .map((o) => o.toJson())
              .toList();

          await _quarantineConflict(
            collection: FirestoreCollections.dreamEntries,
            documentId: id,
            reason: detection.reason,
            local: local == null
                ? null
                : SyncConflictDetector.payloadJson(
                    dreamEntryToFirestore(local),
                  ),
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
          crdtText: fromCrdt ? CrdtTextFields.fromDreamPayload(data) : null,
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
          final owed = local == null || !fromCrdt
              ? null
              : await _textOwedByThisDevice(
                  FirestoreCollections.dreamEntries,
                  id,
                  localText: local.body,
                  logText: merged.body,
                  localIsNewer: _localIsNewer(
                    data,
                    version: local.version,
                    updatedAt: local.updatedAt,
                  ),
                  localIsSameRevision: _localIsSameRevision(
                    data,
                    version: local.version,
                    updatedAt: local.updatedAt,
                  ),
                );
          if (owed != null) {
            merged = DreamEntry(
              id: merged.id,
              title: merged.title,
              body: owed,
              notes: merged.notes,
              entryDate: merged.entryDate,
              tags: extractTags(owed),
              createdAt: merged.createdAt,
              updatedAt: merged.updatedAt,
              version: merged.version,
              deletedAt: merged.deletedAt,
            );
          }
        }
        await _dreamRepository.upsertEntry(merged, recordLocalActivity: false);
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
        await _todoRepository.upsertList(merged, recordLocalActivity: false);
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
          _charOpRegistry.absorbRemote(
            FirestoreCollections.todoTasks,
            id,
            remoteCharOps,
          );
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
            payloadWithOps['_remoteCharOps'] = remoteCharOps
                .map((o) => o.toJson())
                .toList();

            await _quarantineConflict(
              collection: FirestoreCollections.todoTasks,
              documentId: id,
              reason: detection.reason,
              local: local == null
                  ? null
                  : SyncConflictDetector.payloadJson(
                      todoTaskToFirestore(local),
                    ),
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
            merged = merged.copyWith(notes: local.notes, bumpVersion: false);
          } else {
            _pendingTextMergeBuffer.recordRemoteText(
              FirestoreCollections.todoTasks,
              id,
              merged.notes ?? '',
            );
            final owed = local == null || !fromCrdt
                ? null
                : await _textOwedByThisDevice(
                    FirestoreCollections.todoTasks,
                    id,
                    localText: local.notes ?? '',
                    logText: merged.notes ?? '',
                    localIsNewer: _localIsNewer(
                      data,
                      version: local.version,
                      updatedAt: local.updatedAt,
                    ),
                    localIsSameRevision: _localIsSameRevision(
                      data,
                      version: local.version,
                      updatedAt: local.updatedAt,
                    ),
                  );
            if (owed != null) {
              merged = TodoTask(
                id: merged.id,
                listId: merged.listId,
                title: merged.title,
                notes: owed.isEmpty ? null : owed,
                dueDate: merged.dueDate,
                completed: merged.completed,
                starred: merged.starred,
                sortOrder: merged.sortOrder,
                dueDateSetAt: merged.dueDateSetAt,
                parentTaskId: merged.parentTaskId,
                recurrence: merged.recurrence,
                recurrenceAnchor: merged.recurrenceAnchor,
                createdAt: merged.createdAt,
                updatedAt: merged.updatedAt,
                version: merged.version,
                deletedAt: merged.deletedAt,
              );
            }
          }
          await _todoRepository.upsertTask(merged, recordLocalActivity: false);
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

  /// Whether the local row outranks the resolved remote snapshot [data] on
  /// version, then `updatedAt` — the inverse of `remoteVersionWins`.
  bool _localIsNewer(
    Map<String, dynamic> data, {
    required int version,
    required DateTime updatedAt,
  }) {
    return !remoteVersionWins(
      remoteVersion: parseVersion(data),
      localVersion: version,
      remoteUpdated: parseFirestoreDate(data['updatedAt']),
      localUpdated: updatedAt,
    );
  }

  /// Whether the local row is the very revision the resolved snapshot [data]
  /// describes: same version, same `updatedAt`.
  bool _localIsSameRevision(
    Map<String, dynamic> data, {
    required int version,
    required DateTime updatedAt,
  }) {
    final remoteUpdated = parseFirestoreDate(data['updatedAt']);
    return parseVersion(data) == version &&
        remoteUpdated != null &&
        remoteUpdated.isAtSameMomentAs(updatedAt);
  }

  /// Whether every character of [part] appears in [whole], in order.
  static bool _containsInOrder(String whole, String part) {
    var i = 0;
    for (var j = 0; j < whole.length && i < part.length; j++) {
      if (whole.codeUnitAt(j) == part.codeUnitAt(i)) i++;
    }
    return i == part.length;
  }

  /// Text a pull must keep instead of the log's [logText], or null when the
  /// log's text is the right one to write.
  ///
  /// A pull resolving a collaborative document takes its text from the
  /// operation log, bypassing the version comparison every other field goes
  /// through — correct for a log that has everything, and destructive for one
  /// that is missing what this device typed. That is the normal state of an
  /// offline edit: its operations were refused or never sent, live only in
  /// memory, and are gone after a restart. The pull then wrote the log's older
  /// text over the row, and the outbox replay re-read that reverted row and
  /// published it.
  ///
  /// Three things say this device has text the log lacks: operations still
  /// pending in its session (the session has absorbed the log by now, so its
  /// text is the merge of both), a local row that outranks the resolved
  /// snapshot and disagrees with it — which, with no session, can only be
  /// operations lost from memory — or a row at the snapshot's own revision
  /// holding every character of the log's text and more. The last is a row
  /// written without operations (a recovery straight into SQLite) and then
  /// published as it stood: the snapshot carries the row's version and
  /// `updatedAt`, so the row no longer outranks it, while the log still spells
  /// the older text. Only a strict superset qualifies — a row at the same
  /// revision that lacks some of the log's characters may be stale, and the
  /// log must win it. The latter two are queued so the replay re-derives the
  /// missing operations from the row.
  ///
  /// A quarantined conflict on the document also keeps the row as it is: the
  /// conflict's "keep mine" resolves from the row, so writing the log's text
  /// over it first would make that choice publish the other side.
  Future<String?> _textOwedByThisDevice(
    String collection,
    String documentId, {
    required String localText,
    required String logText,
    required bool localIsNewer,
    required bool localIsSameRevision,
  }) async {
    if (localText != logText &&
        await _syncConflictRepository?.getConflict(
              '${collection}_$documentId',
            ) !=
            null) {
      return localText;
    }
    final session = _charOpRegistry.session(collection, documentId);
    if (session != null && session.hasPendingOps && session.text != logText) {
      return session.text;
    }
    if (localText != logText &&
        (localIsNewer ||
            (localIsSameRevision && _containsInOrder(localText, logText)))) {
      if (session == null) {
        unawaited(
          OutboxSyncWorker.recordOwedUpload(
            collection: collection,
            documentId: documentId,
          ),
        );
      }
      return localText;
    }
    return null;
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
    if (collection == FirestoreCollections.calendars) {
      return calendarDocumentIdFromFirestore(firestoreId);
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
    unawaited(
      _runRemoteSave(
        FirestoreCollections.journals,
        journal.id,
        () => _uploadJournalNow(journal),
      ),
    );
  }

  void pushLeetCodeProblem(LeetCodeProblem problem) {
    cancelDocument(FirestoreCollections.leetcodeProblems, problem.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.leetcodeProblems,
        problem.id,
        () => _uploadLeetCodeProblemNow(problem),
      ),
    );
  }

  void pushLeetCodeReviewLog(LeetCodeReviewLog log) {
    cancelDocument(FirestoreCollections.leetcodeReviewLog, log.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.leetcodeReviewLog,
        log.id,
        () => _uploadLeetCodeReviewLogNow(log),
      ),
    );
  }

  void pushLeetCodeCheatTab(LeetCodeCheatTab tab) {
    cancelDocument(FirestoreCollections.leetcodeCheatTabs, tab.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.leetcodeCheatTabs,
        tab.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.leetcodeCheatTabs,
          localId: tab.id,
          payload: leetCodeCheatTabToFirestore(tab),
        ),
      ),
    );
  }

  void pushLeetCodeCheatSection(LeetCodeCheatSection section) {
    cancelDocument(FirestoreCollections.leetcodeCheatSections, section.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.leetcodeCheatSections,
        section.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.leetcodeCheatSections,
          localId: section.id,
          payload: leetCodeCheatSectionToFirestore(section),
        ),
      ),
    );
  }

  /// Batched counterpart to [pushLeetCodeCheatSection]: a renormalized
  /// reorder, and the cascade that goes with deleting the tab they sit in.
  Future<void> pushLeetCodeCheatSectionsBatch(
    List<LeetCodeCheatSection> sections,
  ) async {
    if (sections.isEmpty) return;
    for (final section in sections) {
      cancelDocument(FirestoreCollections.leetcodeCheatSections, section.id);
    }
    final payloads = {
      for (final section in sections)
        section.id: leetCodeCheatSectionToFirestore(section),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(
        FirestoreCollections.leetcodeCheatSections,
        entry.key,
        entry.value,
      );
    }
    await _runRemoteBatchSave(
      FirestoreCollections.leetcodeCheatSections,
      payloads,
    );
  }

  void pushLeetCodeCheatEntry(LeetCodeCheatEntry entry) {
    cancelDocument(FirestoreCollections.leetcodeCheatEntries, entry.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.leetcodeCheatEntries,
        entry.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.leetcodeCheatEntries,
          localId: entry.id,
          payload: leetCodeCheatEntryToFirestore(entry),
        ),
      ),
    );
  }

  /// Batched counterpart to [pushLeetCodeCheatEntry].
  Future<void> pushLeetCodeCheatEntriesBatch(
    List<LeetCodeCheatEntry> entries,
  ) async {
    if (entries.isEmpty) return;
    for (final entry in entries) {
      cancelDocument(FirestoreCollections.leetcodeCheatEntries, entry.id);
    }
    final payloads = {
      for (final entry in entries)
        entry.id: leetCodeCheatEntryToFirestore(entry),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(
        FirestoreCollections.leetcodeCheatEntries,
        entry.key,
        entry.value,
      );
    }
    await _runRemoteBatchSave(
      FirestoreCollections.leetcodeCheatEntries,
      payloads,
    );
  }

  void pushCustomQuote(CustomQuote quote) {
    cancelDocument(FirestoreCollections.customQuotes, quote.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.customQuotes,
        quote.id,
        () => _uploadCustomQuoteNow(quote),
      ),
    );
  }

  void pushMediaAsset(MediaAsset asset) {
    cancelDocument(FirestoreCollections.mediaAssets, asset.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.mediaAssets,
        asset.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.mediaAssets,
          localId: asset.id,
          payload: mediaAssetToFirestore(asset),
        ),
      ),
    );
  }

  void pushMediaReference(MediaReference reference) {
    cancelDocument(FirestoreCollections.mediaReferences, reference.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.mediaReferences,
        reference.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.mediaReferences,
          localId: reference.id,
          payload: mediaReferenceToFirestore(reference),
        ),
      ),
    );
  }

  void pushStudyFolder(StudyFolder folder) {
    cancelDocument(FirestoreCollections.studyFolders, folder.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.studyFolders,
        folder.id,
        () => _uploadStudyFolderNow(folder),
      ),
    );
  }

  void pushStudyDeck(StudyDeck deck) {
    cancelDocument(FirestoreCollections.studyDecks, deck.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.studyDecks,
        deck.id,
        () => _uploadStudyDeckNow(deck),
      ),
    );
  }

  void pushStudyCard(StudyCard card) {
    cancelDocument(FirestoreCollections.studyCards, card.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.studyCards,
        card.id,
        () => _uploadStudyCardNow(card),
      ),
    );
  }

  void pushStudyDeckLink(StudyDeckLink link) {
    cancelDocument(FirestoreCollections.studyDeckLinks, link.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.studyDeckLinks,
        link.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.studyDeckLinks,
          localId: link.id,
          payload: studyDeckLinkToFirestore(link),
        ),
      ),
    );
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
    await _runRemoteBatchSave(FirestoreCollections.studyCards, payloads);
  }

  void pushExercise(Exercise exercise) {
    cancelDocument(FirestoreCollections.exercises, exercise.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.exercises,
        exercise.id,
        () => _uploadExerciseNow(exercise),
      ),
    );
  }

  void pushWorkoutPlan(WorkoutPlan plan) {
    cancelDocument(FirestoreCollections.workoutPlans, plan.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.workoutPlans,
        plan.id,
        () => _uploadWorkoutPlanNow(plan),
      ),
    );
  }

  void pushWorkoutPlanEntry(WorkoutPlanEntry entry) {
    cancelDocument(FirestoreCollections.workoutPlanEntries, entry.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.workoutPlanEntries,
        entry.id,
        () => _uploadWorkoutPlanEntryNow(entry),
      ),
    );
  }

  void pushWorkoutSession(WorkoutSession session) {
    cancelDocument(FirestoreCollections.workoutSessions, session.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.workoutSessions,
        session.id,
        () => _uploadWorkoutSessionNow(session),
      ),
    );
  }

  void pushWorkoutSetLog(WorkoutSetLog log) {
    cancelDocument(FirestoreCollections.workoutSetLogs, log.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.workoutSetLogs,
        log.id,
        () => _uploadWorkoutSetLogNow(log),
      ),
    );
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
      _markSelfEcho(
        FirestoreCollections.workoutSetLogs,
        entry.key,
        entry.value,
      );
    }
    await _runRemoteBatchSave(FirestoreCollections.workoutSetLogs, payloads);
  }

  void pushJobApplication(JobApplication application) {
    cancelDocument(FirestoreCollections.jobApplications, application.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.jobApplications,
        application.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.jobApplications,
          localId: application.id,
          payload: jobApplicationToFirestore(application),
        ),
      ),
    );
  }

  /// Batched counterpart to [pushJobApplication], for the operations that
  /// rewrite many applications at once — deleting a season un-archives
  /// everything filed under it.
  Future<void> pushJobApplicationsBatch(
    List<JobApplication> applications,
  ) async {
    if (applications.isEmpty) return;
    for (final application in applications) {
      cancelDocument(FirestoreCollections.jobApplications, application.id);
    }
    final payloads = {
      for (final application in applications)
        application.id: jobApplicationToFirestore(application),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(
        FirestoreCollections.jobApplications,
        entry.key,
        entry.value,
      );
    }
    await _runRemoteBatchSave(FirestoreCollections.jobApplications, payloads);
  }

  void pushJobStatusEvent(JobStatusEvent event) {
    cancelDocument(FirestoreCollections.jobStatusEvents, event.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.jobStatusEvents,
        event.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.jobStatusEvents,
          localId: event.id,
          payload: jobStatusEventToFirestore(event),
        ),
      ),
    );
  }

  /// Batched counterpart to [pushJobStatusEvent]. Deleting an application
  /// tombstones its whole timeline in one go.
  Future<void> pushJobStatusEventsBatch(List<JobStatusEvent> events) async {
    if (events.isEmpty) return;
    for (final event in events) {
      cancelDocument(FirestoreCollections.jobStatusEvents, event.id);
    }
    final payloads = {
      for (final event in events) event.id: jobStatusEventToFirestore(event),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(
        FirestoreCollections.jobStatusEvents,
        entry.key,
        entry.value,
      );
    }
    await _runRemoteBatchSave(FirestoreCollections.jobStatusEvents, payloads);
  }

  void pushJobStage(JobStage stage) {
    cancelDocument(FirestoreCollections.jobStages, stage.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.jobStages,
        stage.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.jobStages,
          localId: stage.id,
          payload: jobStageToFirestore(stage),
        ),
      ),
    );
  }

  /// Batched counterpart to [pushJobStage]: one drag in the stage list
  /// renumbers every stage it moved past.
  Future<void> pushJobStagesBatch(List<JobStage> stages) async {
    if (stages.isEmpty) return;
    for (final stage in stages) {
      cancelDocument(FirestoreCollections.jobStages, stage.id);
    }
    final payloads = {
      for (final stage in stages) stage.id: jobStageToFirestore(stage),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(FirestoreCollections.jobStages, entry.key, entry.value);
    }
    await _runRemoteBatchSave(FirestoreCollections.jobStages, payloads);
  }

  void pushRankingCategory(RankingCategory category) {
    cancelDocument(FirestoreCollections.rankingCategories, category.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.rankingCategories,
        category.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.rankingCategories,
          localId: category.id,
          payload: rankingCategoryToFirestore(category),
        ),
      ),
    );
  }

  /// Batched counterpart to [pushRankingCategory]: one drag in the category
  /// strip renumbers every category it moved past.
  Future<void> pushRankingCategoriesBatch(
    List<RankingCategory> categories,
  ) async {
    if (categories.isEmpty) return;
    for (final category in categories) {
      cancelDocument(FirestoreCollections.rankingCategories, category.id);
    }
    final payloads = {
      for (final category in categories)
        category.id: rankingCategoryToFirestore(category),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(
        FirestoreCollections.rankingCategories,
        entry.key,
        entry.value,
      );
    }
    await _runRemoteBatchSave(FirestoreCollections.rankingCategories, payloads);
  }

  void pushRankingParent(RankingParent parent) {
    cancelDocument(FirestoreCollections.rankingParents, parent.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.rankingParents,
        parent.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.rankingParents,
          localId: parent.id,
          payload: rankingParentToFirestore(parent),
        ),
      ),
    );
  }

  /// Batched counterpart to [pushRankingParent]. A queue drag renumbers a run
  /// of entries, and deleting a category tombstones every entry in it at once.
  Future<void> pushRankingParentsBatch(List<RankingParent> parents) async {
    if (parents.isEmpty) return;
    for (final parent in parents) {
      cancelDocument(FirestoreCollections.rankingParents, parent.id);
    }
    final payloads = {
      for (final parent in parents) parent.id: rankingParentToFirestore(parent),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(
        FirestoreCollections.rankingParents,
        entry.key,
        entry.value,
      );
    }
    await _runRemoteBatchSave(FirestoreCollections.rankingParents, payloads);
  }

  void pushRankingChild(RankingChild child) {
    cancelDocument(FirestoreCollections.rankingChildren, child.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.rankingChildren,
        child.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.rankingChildren,
          localId: child.id,
          payload: rankingChildToFirestore(child),
        ),
      ),
    );
  }

  /// Batched counterpart to [pushRankingChild]: a child reorder, and the
  /// cascade that goes with deleting the parent they hang off.
  Future<void> pushRankingChildrenBatch(List<RankingChild> children) async {
    if (children.isEmpty) return;
    for (final child in children) {
      cancelDocument(FirestoreCollections.rankingChildren, child.id);
    }
    final payloads = {
      for (final child in children) child.id: rankingChildToFirestore(child),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(
        FirestoreCollections.rankingChildren,
        entry.key,
        entry.value,
      );
    }
    await _runRemoteBatchSave(FirestoreCollections.rankingChildren, payloads);
  }

  void pushJobCompany(JobCompany company) {
    cancelDocument(FirestoreCollections.jobCompanies, company.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.jobCompanies,
        company.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.jobCompanies,
          localId: company.id,
          payload: jobCompanyToFirestore(company),
        ),
      ),
    );
  }

  /// Batched counterpart to [pushJobCompany]: deleting a category clears it
  /// off every company that was filed under it, and the seed list is written
  /// in one go on first run.
  Future<void> pushJobCompaniesBatch(List<JobCompany> companies) async {
    if (companies.isEmpty) return;
    for (final company in companies) {
      cancelDocument(FirestoreCollections.jobCompanies, company.id);
    }
    final payloads = {
      for (final company in companies)
        company.id: jobCompanyToFirestore(company),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(FirestoreCollections.jobCompanies, entry.key, entry.value);
    }
    await _runRemoteBatchSave(FirestoreCollections.jobCompanies, payloads);
  }

  void pushJobCategory(JobCategory category) {
    cancelDocument(FirestoreCollections.jobCategories, category.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.jobCategories,
        category.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.jobCategories,
          localId: category.id,
          payload: jobCategoryToFirestore(category),
        ),
      ),
    );
  }

  void pushJobSeason(JobSeason season) {
    cancelDocument(FirestoreCollections.jobSeasons, season.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.jobSeasons,
        season.id,
        () => _uploadRecordNow(
          collection: FirestoreCollections.jobSeasons,
          localId: season.id,
          payload: jobSeasonToFirestore(season),
        ),
      ),
    );
  }

  /// Batched counterpart to [pushJobSeason]: one drag in the season list
  /// renumbers every season it moved past.
  Future<void> pushJobSeasonsBatch(List<JobSeason> seasons) async {
    if (seasons.isEmpty) return;
    for (final season in seasons) {
      cancelDocument(FirestoreCollections.jobSeasons, season.id);
    }
    final payloads = {
      for (final season in seasons) season.id: jobSeasonToFirestore(season),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(FirestoreCollections.jobSeasons, entry.key, entry.value);
    }
    await _runRemoteBatchSave(FirestoreCollections.jobSeasons, payloads);
  }

  void pushStudyReviewLog(StudyReviewLog log) {
    cancelDocument(FirestoreCollections.studyReviewLog, log.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.studyReviewLog,
        log.id,
        () => _uploadStudyReviewLogNow(log),
      ),
    );
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
    unawaited(
      _runRemoteSave(
        FirestoreCollections.journalEntries,
        entry.id,
        () => _uploadJournalEntryNow(entry),
      ),
    );
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
    unawaited(
      _runRemoteSave(
        FirestoreCollections.dreamEntries,
        entry.id,
        () => _uploadDreamEntryNow(entry),
      ),
    );
  }

  void pushTodoList(TodoListModel list) {
    cancelDocument(FirestoreCollections.todoLists, list.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.todoLists,
        list.id,
        () => _uploadTodoListNow(list),
      ),
    );
  }

  /// Uploads [task] and hands the failure back to the caller.
  ///
  /// Deliberately *not* wrapped in [_runRemoteSave], unlike its siblings: this
  /// is the form the callers that can handle a failure use, and two of them
  /// need it to throw. [TodoWriteCoordinator.saveTask] runs it inside a
  /// [_runRemoteSave] of its own, which would otherwise record success for a
  /// write that failed and clear the outbox row standing for it; the To-Do
  /// page's cascade attaches its own `catchError` to re-queue the rows it was
  /// pushing. Call sites that cannot await it want
  /// [pushTodoTaskInBackground] instead.
  Future<void> pushTodoTaskNow(TodoTask task) {
    cancelDocument(FirestoreCollections.todoTasks, task.id);
    return _uploadTodoTaskNow(task);
  }

  /// [pushTodoTaskNow] for the call sites that fire and forget.
  ///
  /// Dropping the future from [pushTodoTaskNow] loses the failure twice over:
  /// it escapes to the zone as an unhandled error, and — worse — the task is
  /// never queued for a retry, so an edit made while sync is paused is simply
  /// never uploaded and nothing anywhere records that. Routing through
  /// [_runRemoteSave] puts it on the outbox like every other push.
  void pushTodoTaskInBackground(TodoTask task) {
    cancelDocument(FirestoreCollections.todoTasks, task.id);
    unawaited(
      _runRemoteSave(
        FirestoreCollections.todoTasks,
        task.id,
        () => _uploadTodoTaskNow(task),
      ),
    );
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
      for (final task in tasks) task.id: todoTaskToFirestore(task),
    };
    for (final entry in payloads.entries) {
      _markSelfEcho(FirestoreCollections.todoTasks, entry.key, entry.value);
    }
    // Keeps its operation-log entry, unlike the other batch pushes: todo tasks
    // carry collaborative notes, and a mirror newer than the log would simply
    // be resolved away on the next pull.
    await _runRemoteBatchSave(
      FirestoreCollections.todoTasks,
      payloads,
      logOperation: true,
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
    await _runRemoteSave(
      FirestoreCollections.journals,
      journal.id,
      () => _uploadJournalNow(journal),
    );
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
  Future<void> pushOutboxDocument(
    String collection,
    String documentId, {
    bool forceCrdtOverwrite = false,
  }) async {
    cancelDocument(collection, documentId);
    switch (collection) {
      case FirestoreCollections.journalEntries:
        final entry = await _journalRepository.getEntry(documentId);
        if (entry == null) return;
        if (forceCrdtOverwrite) {
          // A rewrite the Search popup could not publish when it was made —
          // see [forceOverwriteJournalEntryText]. Failures propagate so the
          // drain retries or parks the row it is already holding.
          await forceOverwriteJournalEntryText(entry, queueOnFailure: false);
          return;
        }
        if (!await _recoverLostOperations(
          collection,
          documentId,
          text: entry.body,
          title: entry.title,
          payload: journalEntryToFirestore(entry),
        )) {
          return;
        }
        await _uploadJournalEntryNow(entry);
      case FirestoreCollections.dreamEntries:
        final entry = await _dreamRepository.getEntry(documentId);
        if (entry == null) return;
        if (forceCrdtOverwrite) {
          // A rewrite the Search popup's dream dialog could not publish when
          // it was made — see [forceOverwriteDreamEntryText].
          await forceOverwriteDreamEntryText(entry, queueOnFailure: false);
          return;
        }
        if (!await _recoverLostOperations(
          collection,
          documentId,
          text: entry.body,
          title: entry.title,
          payload: dreamEntryToFirestore(entry),
        )) {
          return;
        }
        await _uploadDreamEntryNow(entry);
      case FirestoreCollections.todoTasks:
        final task = await _findTodoTask(documentId);
        if (task == null) return;
        if (!await _recoverLostOperations(
          collection,
          documentId,
          text: task.notes ?? '',
          title: task.title,
          payload: todoTaskToFirestore(task),
        )) {
          return;
        }
        await _uploadTodoTaskNow(task);
    }
  }

  /// Re-derives the operations a queued document's text needs when the
  /// session that recorded them is gone — a restart, most often.
  ///
  /// A replay used to upload the row with whatever the session held, which
  /// after a restart is nothing: a snapshot newer than the log, and a log
  /// whose text wins the next pull on every device because a pull takes text
  /// from the log. Diffing the log's text to the row's puts the missing
  /// characters back in it.
  ///
  /// Returns false, having quarantined a conflict, when that diff would delete
  /// characters another device wrote. The row and the log have both moved
  /// since this device last uploaded, and deleting text the user never saw is
  /// not a choice to make silently; the conflict keeps both sides.
  Future<bool> _recoverLostOperations(
    String collection,
    String documentId, {
    required String text,
    required String title,
    required Map<String, dynamic> payload,
  }) async {
    if (_charOpRegistry.session(collection, documentId) != null) return true;
    final ops = await _listRemoteCharOps(
      firestoreDocumentIdForLocal(collection, documentId),
    );
    if (_charOpRegistry.session(collection, documentId) != null) return true;
    if (ops.isEmpty) {
      _charOpRegistry.ensureSession(
        collection: collection,
        documentId: documentId,
        clientId: deviceId,
        initialText: text,
        markSeedsAsPending: true,
      );
      return true;
    }
    _charOpRegistry.loadSession(
      collection: collection,
      documentId: documentId,
      clientId: deviceId,
      operations: ops,
    );
    final session = _charOpRegistry.session(collection, documentId)!;
    if (session.text == text) return true;
    if (session.opsReplacedBy(text).any((op) => op.clientId != deviceId)) {
      final logText = session.text;
      _charOpRegistry.removeSession(collection, documentId);
      final textField = collection == FirestoreCollections.todoTasks
          ? 'notes'
          : 'body';
      await _quarantineConflict(
        collection: collection,
        documentId: documentId,
        reason: SyncConflictReason.hardMetadataCollision,
        local: SyncConflictDetector.payloadJson(payload),
        remote: SyncConflictDetector.payloadJson({
          ...payload,
          textField: logText,
          '_remoteCharOps': [for (final op in ops) op.toJson()],
        }),
        localTitle: title,
        remoteTitle: title,
        localText: text,
        remoteText: logText,
      );
      return false;
    }
    _charOpRegistry.recordTextChange(
      collection: collection,
      documentId: documentId,
      clientId: deviceId,
      before: session.text,
      after: text,
    );
    return true;
  }

  void _scheduleRemoteUpload(
    String collection,
    String documentId,
    Future<void> Function() remoteSave,
  ) {
    final key = documentKey(collection, documentId);
    _activeDebouncers.remove(key)?.cancel();
    _pendingRemoteSaves[key] = remoteSave;
    _pendingRemoteSaveTargets[key] = (
      collection: collection,
      documentId: documentId,
    );
    _activeDebouncers[key] = Timer(_uploadDebounceDelay, () {
      final save = _pendingRemoteSaves.remove(key);
      _pendingRemoteSaveTargets.remove(key);
      _activeDebouncers.remove(key);
      if (save != null) {
        unawaited(_runRemoteSave(collection, documentId, save));
      }
    });
  }

  /// Runs an unawaited upload — debounced or immediate — making sure a
  /// failure lands somewhere.
  ///
  /// These uploads are deliberately not awaited by their callers, so without
  /// this an exception would escape to the zone as an unhandled error and the
  /// document would simply stay unsynced with nothing recording that it had
  /// tried. Transient failures go back on the outbox for a later attempt;
  /// permanent ones are parked so they stop consuming retries but remain
  /// visible.
  ///
  /// Uploads of one document run one at a time, in the order they were
  /// started. Run concurrently, two things went wrong under exactly the load
  /// the write gate exists for: a retry of an older snapshot could land after
  /// a newer one had, regressing the server copy to a lower version this
  /// device would never repair; and an older upload acknowledged late cleared
  /// the outbox row a newer, refused upload of the same document had just
  /// queued, so the newer edit was owed to nobody.
  Future<void> _runRemoteSave(
    String collection,
    String documentId,
    Future<void> Function() remoteSave,
  ) {
    return _runInDocumentChains(collection, [
      documentId,
    ], () => _runRemoteSaveNow(collection, documentId, remoteSave));
  }

  /// Runs [upload] once every upload already started for any of [documentIds]
  /// has finished, and holds each of their chains until it has.
  ///
  /// Batches and single saves share the chains: a batch carrying an older copy
  /// of a document otherwise raced a newer single save of it, and whichever
  /// was acknowledged last won the server — or cleared the outbox row the
  /// other had queued. [upload] must not throw; every caller routes its own
  /// failure to the outbox.
  Future<void> _runInDocumentChains(
    String collection,
    Iterable<String> documentIds,
    Future<void> Function() upload,
  ) {
    final keys = {
      for (final documentId in documentIds) documentKey(collection, documentId),
    };
    final previous = [for (final key in keys) ?_remoteSaveChains[key]];
    late final Future<void> next;
    next = (previous.isEmpty ? Future<void>.value() : Future.wait(previous))
        .then((_) => upload());
    for (final key in keys) {
      _remoteSaveChains[key] = next;
    }
    unawaited(
      next.whenComplete(() {
        for (final key in keys) {
          if (identical(_remoteSaveChains[key], next)) {
            _remoteSaveChains.remove(key);
          }
        }
      }),
    );
    return next;
  }

  Future<void> _runRemoteSaveNow(
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

  /// [_runRemoteSave] for a batch: the rows are already written locally at a
  /// higher version, so a batch that failed without reaching the outbox would
  /// never be uploaded, and no later pull would repair the difference.
  Future<void> _runRemoteBatchSave(
    String collection,
    Map<String, Map<String, dynamic>> payloads, {
    bool logOperation = false,
  }) {
    return _runInDocumentChains(
      collection,
      payloads.keys,
      () => _runRemoteBatchSaveNow(
        collection,
        payloads,
        logOperation: logOperation,
      ),
    );
  }

  Future<void> _runRemoteBatchSaveNow(
    String collection,
    Map<String, Map<String, dynamic>> payloads, {
    required bool logOperation,
  }) async {
    try {
      await _syncEngine.syncDocumentsImmediately(
        collection: collection,
        payloadsByDocumentId: payloads,
        logOperation: logOperation,
      );
      for (final documentId in payloads.keys) {
        await OutboxSyncWorker.recordSuccess(
          collection: collection,
          documentId: documentId,
        );
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[sync] batch upload failed for $collection '
        '(${payloads.length} documents): $error\n$stackTrace',
      );
      for (final documentId in payloads.keys) {
        await OutboxSyncWorker.recordFailure(
          collection: collection,
          documentId: documentId,
          error: error,
        );
      }
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

  /// [entry] is uploaded as-is unless a version bump is actually asked for.
  ///
  /// `copyWith` has no way to preserve [JournalEntry.updatedAt] — it always
  /// stamps `now` — so calling it purely to leave the version alone used to
  /// publish a document whose `updatedAt` was the *upload* time rather than
  /// the *edit* time. That made the remote copy unconditionally newer than the
  /// row it came from, and since the autosave path uploads at an unchanged
  /// version, `remoteVersionWins` falls through to the `updatedAt` tie-break
  /// and resolved every later pull in the remote's favour — reverting offline
  /// edits made after the upload. The bump-requesting callers (conflict
  /// resolution, first publish) do want a fresh revision, so they still copy.
  Future<void> _uploadJournalEntryNow(
    JournalEntry entry, {
    bool bumpVersion = false,
  }) {
    return _uploadCrdtDocumentNow(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      payload: journalEntryToFirestore(
        bumpVersion ? entry.copyWith(bumpVersion: true) : entry,
      ),
    );
  }

  /// [entry] is uploaded as-is unless a version bump is actually asked for —
  /// same hazard, and same reasoning, as [_uploadJournalEntryNow] above.
  Future<void> _uploadDreamEntryNow(
    DreamEntry entry, {
    bool bumpVersion = false,
  }) {
    return _uploadCrdtDocumentNow(
      collection: FirestoreCollections.dreamEntries,
      documentId: entry.id,
      payload: dreamEntryToFirestore(
        bumpVersion ? entry.copyWith(bumpVersion: true) : entry,
      ),
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

  Future<void> _uploadLeetCodeReviewLogNow(LeetCodeReviewLog log) {
    return _uploadRecordNow(
      collection: FirestoreCollections.leetcodeReviewLog,
      localId: log.id,
      payload: leetCodeReviewLogToFirestore(log),
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

  Future<void> _uploadTodoTaskNow(TodoTask task, {bool bumpVersion = false}) {
    return _uploadCrdtDocumentNow(
      collection: FirestoreCollections.todoTasks,
      documentId: task.id,
      // As-is unless a bump is asked for, like [_uploadJournalEntryNow]:
      // `copyWith` stamps `updatedAt`, so the server copy looked newer than
      // the row at the same version and won tie-breaks against later local
      // edits that don't bump.
      payload: todoTaskToFirestore(
        bumpVersion ? task.copyWith(bumpVersion: true) : task,
      ),
    );
  }

  void dispose() {
    for (final timer in _activeDebouncers.values) {
      timer.cancel();
    }
    _activeDebouncers.clear();
    // Queued, not dropped and not run. A save pending here has already reached
    // SQLite and is owed to the server; clearing it left nothing — no upload,
    // no outbox row — to say so. Running it here is no better: this service is
    // disposed because a dependency changed, most often the sync repository
    // itself as auth resolves, and the upload would go out through the one
    // being replaced — a signed-out no-op that reports success. The outbox
    // drains through whichever repository is current.
    for (final target in _pendingRemoteSaveTargets.values) {
      unawaited(
        OutboxSyncWorker.recordOwedUpload(
          collection: target.collection,
          documentId: target.documentId,
        ),
      );
    }
    _pendingRemoteSaves.clear();
    _pendingRemoteSaveTargets.clear();
    _localSaveChains.clear();
    _localSaveGenerations.clear();
    _activelyEditedDocuments.clear();
    _selfEchoes.clear();
    if (_ownsCharOpRegistry) _charOpRegistry.clear();
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

      // Compaction is pure housekeeping, and it is expensive twice over: a
      // baseline group close to a megabyte, then a delete for every operation
      // it supersedes. Neither is worth generating while writes are already
      // queued unsent — and [_compactingDocuments] cannot stop it happening,
      // because that guard lives in memory and a restart empties it. An
      // afternoon of hot restarts against a stalled connection therefore ran
      // this once per launch, each time piling another baseline onto a queue
      // that had not moved since the last one. Standing down instead costs a
      // log that stays long for another session, which is what the threshold
      // is for. See [SyncRepository.hasUnsentWriteBacklog].
      if (_syncRepository.hasUnsentWriteBacklog) return false;

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
      debugPrint(
        '[sync] op-log compaction failed for $documentId: $error\n$stackTrace',
      );
    }
  }

  Future<void> _quarantineConflict({
    required String collection,
    required String documentId,
    required SyncConflictReason? reason,
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
        reason: reason,
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
  static const syncBackfillVersion = 2;

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

    await _runInDocumentChains(
      collection,
      localIds,
      () => _pushRecordsNow(collection, payloads, localIds),
    );
  }

  Future<void> _pushRecordsNow(
    String collection,
    Map<String, Map<String, dynamic>> payloads,
    List<String> localIds,
  ) async {
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
        try {
          await _syncRepository.deleteOperationsForDocument(
            _firestoreDocumentId(collection, document.id),
          );
        } catch (error, stackTrace) {
          // The wipe now insists on a server round-trip and throws offline
          // rather than reporting a cache-answered zero. Report it and keep
          // restoring: the records still reach SQLite and the mirror, and one
          // unreachable document must not abandon the rest of the import
          // after its transaction has already committed. What survives is the
          // old log, which can still resolve this document's text away on a
          // later pull — the same outcome the silent zero produced, now
          // visible.
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'RemoteSyncService',
              context: ErrorDescription(
                'while clearing the operation log of restored '
                '$collection/${document.id}',
              ),
            ),
          );
        }
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
      case FirestoreCollections.leetcodeReviewLog:
        if (record is! LeetCodeReviewLog) return null;
        return (id: record.id, payload: leetCodeReviewLogToFirestore(record));
      case FirestoreCollections.leetcodeCheatTabs:
        if (record is! LeetCodeCheatTab) return null;
        return (id: record.id, payload: leetCodeCheatTabToFirestore(record));
      case FirestoreCollections.leetcodeCheatSections:
        if (record is! LeetCodeCheatSection) return null;
        return (
          id: record.id,
          payload: leetCodeCheatSectionToFirestore(record),
        );
      case FirestoreCollections.leetcodeCheatEntries:
        if (record is! LeetCodeCheatEntry) return null;
        return (id: record.id, payload: leetCodeCheatEntryToFirestore(record));
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
      case FirestoreCollections.studyDeckLinks:
        if (record is! StudyDeckLink) return null;
        return (id: record.id, payload: studyDeckLinkToFirestore(record));
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
      case FirestoreCollections.jobApplications:
        if (record is! JobApplication) return null;
        return (id: record.id, payload: jobApplicationToFirestore(record));
      case FirestoreCollections.jobStatusEvents:
        if (record is! JobStatusEvent) return null;
        return (id: record.id, payload: jobStatusEventToFirestore(record));
      case FirestoreCollections.jobStages:
        if (record is! JobStage) return null;
        return (id: record.id, payload: jobStageToFirestore(record));
      case FirestoreCollections.jobCompanies:
        if (record is! JobCompany) return null;
        return (id: record.id, payload: jobCompanyToFirestore(record));
      case FirestoreCollections.jobCategories:
        if (record is! JobCategory) return null;
        return (id: record.id, payload: jobCategoryToFirestore(record));
      case FirestoreCollections.jobSeasons:
        if (record is! JobSeason) return null;
        return (id: record.id, payload: jobSeasonToFirestore(record));
      case FirestoreCollections.rankingCategories:
        if (record is! RankingCategory) return null;
        return (id: record.id, payload: rankingCategoryToFirestore(record));
      case FirestoreCollections.rankingParents:
        if (record is! RankingParent) return null;
        return (id: record.id, payload: rankingParentToFirestore(record));
      case FirestoreCollections.rankingChildren:
        if (record is! RankingChild) return null;
        return (id: record.id, payload: rankingChildToFirestore(record));
      case FirestoreCollections.mediaAssets:
        if (record is! MediaAsset) return null;
        return (id: record.id, payload: mediaAssetToFirestore(record));
      case FirestoreCollections.mediaReferences:
        if (record is! MediaReference) return null;
        return (id: record.id, payload: mediaReferenceToFirestore(record));
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
      case FirestoreCollections.contributionRooms:
        if (record is! ContributionRoom) return null;
        return (id: record.id, payload: contributionRoomToFirestore(record));
      case FirestoreCollections.assetRoomEvents:
        if (record is! AssetRoomEvent) return null;
        return (id: record.id, payload: assetRoomEventToFirestore(record));
      case FirestoreCollections.pinnedNotes:
        if (record is! PinnedNote) return null;
        return (id: record.id, payload: pinnedNoteToFirestore(record));
      case FirestoreCollections.dismissedNotifications:
        if (record is! DismissedNotification) return null;
        return (
          id: record.key,
          payload: dismissedNotificationToFirestore(record),
        );
      case FirestoreCollections.deviceRegistrations:
        if (record is! DeviceRegistration) return null;
        return (id: record.id, payload: deviceRegistrationToFirestore(record));
      case FirestoreCollections.scheduledReminderRules:
        if (record is! ScheduledReminderRule) return null;
        return (
          id: record.id,
          payload: scheduledReminderRuleToFirestore(record),
        );
      case FirestoreCollections.entityReminders:
        if (record is! EntityReminder) return null;
        return (id: record.id, payload: entityReminderToFirestore(record));
      case FirestoreCollections.reminderDeliveryStates:
        if (record is! ReminderDeliveryState) return null;
        return (
          id: record.id,
          payload: reminderDeliveryStateToFirestore(record),
        );
      case FirestoreCollections.reminderDeliveryLogs:
        if (record is! ReminderDeliveryLog) return null;
        return (id: record.id, payload: reminderDeliveryLogToFirestore(record));
      case FirestoreCollections.bucketListItems:
        if (record is! BucketListItem) return null;
        return (id: record.id, payload: bucketListItemToFirestore(record));
      case FirestoreCollections.tagColors:
        if (record is! TagColorRecord) return null;
        return (id: record.tag, payload: tagColorToFirestore(record));
      case FirestoreCollections.customWords:
        if (record is! CustomWord) return null;
        return (id: record.word, payload: customWordToFirestore(record));
      case FirestoreCollections.snippets:
        if (record is! SyncedListItem<Snippet>) return null;
        return (id: record.item.id, payload: snippetToFirestore(record));
      case FirestoreCollections.jobExperienceSnippets:
        if (record is! SyncedListItem<JobExperienceSnippet>) return null;
        return (
          id: record.item.id,
          payload: jobExperienceSnippetToFirestore(record),
        );
      case FirestoreCollections.flaggedWords:
        if (record is! FlaggedWord) return null;
        return (id: record.word, payload: flaggedWordToFirestore(record));
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

  Future<bool> pullContributionRooms({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    final local = {
      for (final record in await _financeRepository.listContributionRooms(
        includeDeleted: true,
      ))
        record.id: record,
    };
    return _pullCollection(
      FirestoreCollections.contributionRooms,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        await _financeRepository.upsertContributionRoom(
          mergeContributionRoomFromRemote(data, id, local: local[id]),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullAssetRoomEvents({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) async {
    final local = {
      for (final record in await _financeRepository.listAssetRoomEvents(
        includeDeleted: true,
      ))
        record.id: record,
    };
    return _pullCollection(
      FirestoreCollections.assetRoomEvents,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        await _financeRepository.upsertAssetRoomEvent(
          mergeAssetRoomEventFromRemote(data, id, local: local[id]),
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

  Future<bool> pullDeviceRegistrations({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.deviceRegistrations,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _reminderRepository.getDevice(id);
        await _reminderRepository.upsertDevice(
          mergeDeviceRegistrationFromRemote(data, id, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullScheduledReminderRules({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.scheduledReminderRules,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _reminderRepository.getRule(id);
        await _reminderRepository.upsertRule(
          mergeScheduledReminderRuleFromRemote(data, id, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullEntityReminders({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.entityReminders,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _reminderRepository.getEntityReminder(id);
        await _reminderRepository.upsertEntityReminder(
          mergeEntityReminderFromRemote(data, id, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullReminderDeliveryStates({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.reminderDeliveryStates,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _reminderRepository.getDeliveryState(id);
        await _reminderRepository.upsertDeliveryState(
          mergeReminderDeliveryStateFromRemote(data, id, local: local),
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullReminderDeliveryLogs({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.reminderDeliveryLogs,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _reminderRepository.getLog(id);
        await _reminderRepository.upsertLog(
          mergeReminderDeliveryLogFromRemote(data, id, local: local),
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

  Future<bool> pullSnippets({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.snippets,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _settingsRepository.getSnippetRecord(id);
        final merged = mergeSnippetFromRemote(data, id, local: local);
        if (merged == null || identical(merged, local)) return;
        await _settingsRepository.upsertSnippetRecord(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullJobExperienceSnippets({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.jobExperienceSnippets,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (id, data, {required fromCrdt}) async {
        final local = await _settingsRepository.getJobExperienceSnippetRecord(
          id,
        );
        final merged = mergeJobExperienceSnippetFromRemote(
          data,
          id,
          local: local,
        );
        if (merged == null || identical(merged, local)) return;
        await _settingsRepository.upsertJobExperienceSnippetRecord(
          merged,
          recordLocalActivity: false,
        );
      },
    );
  }

  Future<bool> pullFlaggedWords({
    Set<String>? documentIds,
    Map<String, Map<String, dynamic>>? documentData,
  }) {
    return _pullCollection(
      FirestoreCollections.flaggedWords,
      onlyFirestoreDocumentIds: documentIds,
      documentData: documentData,
      resolveCrdt: false,
      apply: (word, data, {required fromCrdt}) async {
        final local = await _settingsRepository.getFlaggedWordRecord(word);
        await _settingsRepository.upsertFlaggedWord(
          mergeFlaggedWordFromRemote(data, word, local: local),
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
    final adopted = await _adoptLegacySnippets(remote);

    final local = await _settingsRepository.getSettings();
    final merged = mergeSettingsFromRemote(remote, local);
    if (identical(merged, local)) return adopted;

    await _settingsRepository.saveSettings(merged, recordLocalActivity: false);
    return true;
  }

  /// Takes in snippets that only exist in the settings document's old list
  /// fields — written by a build from before snippets were records, still
  /// running on another device, which never uploads them as records.
  ///
  /// Only ids this device has never had a row for are considered, and each is
  /// checked against its record first: if one exists, another device already
  /// adopted the snippet and may have edited or deleted it since, so the
  /// record wins and nothing is uploaded. Uploads carry no version check, so
  /// if that check can't be made (offline), the snippet waits for a later pull
  /// rather than risking an upload over the newer record.
  Future<bool> _adoptLegacySnippets(
    Map<String, dynamic> settingsDocument,
  ) async {
    final legacy = await _settingsRepository.unknownLegacySnippets(
      settingsDocument,
    );
    var adopted = false;
    for (final record in legacy.snippets) {
      adopted =
          await _adoptLegacyListItem(
            FirestoreCollections.snippets,
            record.item.id,
            record,
            merge: (data) => mergeSnippetFromRemote(data, record.item.id),
            write: (merged) => _settingsRepository.upsertSnippetRecord(
              merged,
              recordLocalActivity: false,
            ),
          ) ||
          adopted;
    }
    for (final record in legacy.jobExperienceSnippets) {
      adopted =
          await _adoptLegacyListItem(
            FirestoreCollections.jobExperienceSnippets,
            record.item.id,
            record,
            merge: (data) =>
                mergeJobExperienceSnippetFromRemote(data, record.item.id),
            write: (merged) =>
                _settingsRepository.upsertJobExperienceSnippetRecord(
                  merged,
                  recordLocalActivity: false,
                ),
          ) ||
          adopted;
    }
    return adopted;
  }

  Future<bool> _adoptLegacyListItem<T>(
    String collection,
    String id,
    SyncedListItem<T> record, {
    required SyncedListItem<T>? Function(Map<String, dynamic> data) merge,
    required Future<void> Function(SyncedListItem<T> record) write,
  }) async {
    final Map<String, dynamic>? existing;
    try {
      existing = await _syncRepository.getDocument(
        collection,
        _firestoreDocumentId(collection, id),
      );
    } catch (error) {
      debugPrint('[sync] legacy $collection $id not adopted yet: $error');
      return false;
    }
    if (existing != null) {
      final merged = merge(existing);
      if (merged == null) return false;
      await write(merged);
      return true;
    }
    await write(record);
    await pushRecords(collection, [record]);
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
    await pullContributionRooms();
    await pullAssetRoomEvents();
    await pullSavingsGoals();
    await pullGoalAllocations();
    await pullPinnedNotes();
    await pullDismissedNotifications();
    await pullDeviceRegistrations();
    await pullScheduledReminderRules();
    await pullEntityReminders();
    await pullReminderDeliveryStates();
    await pullReminderDeliveryLogs();
    await pullBucketListItems();
    await pullJobStages();
    await pullJobSeasons();
    await pullJobCategories();
    await pullJobCompanies();
    await pullJobApplications();
    await pullJobStatusEvents();
    await pullTagColors();
    await pullCustomWords();
    await pullSnippets();
    await pullJobExperienceSnippets();
  }

  /// Uploads everything in the newly synced collections once, so data that
  /// predates this device syncing them still reaches the account.
  ///
  /// Runs after the pull, never before: by then the local rows are the merged
  /// result of both sides, so uploading them can only bring the server in
  /// line with that merge. Pushing first would let a stale local row
  /// overwrite a newer one from another device, since a push — unlike a pull —
  /// does no version comparison.
  ///
  /// Each version uploads only the collections it added, so a device that
  /// already ran an earlier one doesn't re-upload everything.
  Future<void> backfillSyncedCollections() async {
    final settings = await _settingsRepository.getSettings();
    if (settings.syncBackfillVersion >= syncBackfillVersion) return;

    if (settings.syncBackfillVersion < 1) await _backfillVersion1();

    // 2: snippets left the settings document for collections of their own.
    // The v115 migration put this device's lists into them; the pull above
    // has already merged in any copies other devices uploaded first.
    await pushRecords(
      FirestoreCollections.snippets,
      await _settingsRepository.getSnippetRecords(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.jobExperienceSnippets,
      await _settingsRepository.getJobExperienceSnippetRecords(
        includeDeleted: true,
      ),
    );

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

  Future<void> _backfillVersion1() async {
    await pushRecords(
      FirestoreCollections.calendars,
      await _calendarRepository.listCalendars(includeDeleted: true),
    );
    await pushRecords(FirestoreCollections.calendarEvents, [
      for (final event in await _calendarRepository.listEvents(
        includeDeleted: true,
      ))
        // Google-imported events are rebuilt per device and never sync.
        if (event.source != EventSource.google) event,
    ]);

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
      FirestoreCollections.deviceRegistrations,
      await _reminderRepository.listDevices(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.scheduledReminderRules,
      await _reminderRepository.listRules(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.entityReminders,
      await _reminderRepository.listEntityReminders(includeDeleted: true),
    );
    await pushRecords(
      FirestoreCollections.reminderDeliveryStates,
      await _reminderRepository.listDeliveryStates(),
    );
    await pushRecords(
      FirestoreCollections.reminderDeliveryLogs,
      await _reminderRepository.listLogs(includeDeleted: true),
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
    await pushRecords(
      FirestoreCollections.flaggedWords,
      await _settingsRepository.getFlaggedWordRecords(),
    );
    await pushSettings(await _settingsRepository.getSettings());
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

  /// Ids whose pull failed past [_maxRequeueAttempts], retried with the next
  /// change.
  final _deferredIdsByCollection = <String, Set<String>>{};

  static const _watchedCollections = [
    FirestoreCollections.journals,
    FirestoreCollections.journalEntries,
    FirestoreCollections.dreamEntries,
    FirestoreCollections.todoLists,
    FirestoreCollections.todoTasks,
    FirestoreCollections.leetcodeProblems,
    FirestoreCollections.leetcodeReviewLog,
    FirestoreCollections.leetcodeCheatTabs,
    FirestoreCollections.leetcodeCheatSections,
    FirestoreCollections.leetcodeCheatEntries,
    FirestoreCollections.studyFolders,
    FirestoreCollections.studyDecks,
    FirestoreCollections.studyCards,
    FirestoreCollections.studyReviewLog,
    FirestoreCollections.studyDeckLinks,
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
    FirestoreCollections.contributionRooms,
    FirestoreCollections.assetRoomEvents,
    FirestoreCollections.savingsGoals,
    FirestoreCollections.goalAllocations,
    FirestoreCollections.pinnedNotes,
    FirestoreCollections.dismissedNotifications,
    FirestoreCollections.deviceRegistrations,
    FirestoreCollections.scheduledReminderRules,
    FirestoreCollections.entityReminders,
    FirestoreCollections.reminderDeliveryStates,
    FirestoreCollections.reminderDeliveryLogs,
    FirestoreCollections.bucketListItems,
    FirestoreCollections.jobApplications,
    FirestoreCollections.jobStatusEvents,
    FirestoreCollections.jobStages,
    FirestoreCollections.jobCompanies,
    FirestoreCollections.jobCategories,
    FirestoreCollections.jobSeasons,
    FirestoreCollections.rankingCategories,
    FirestoreCollections.rankingParents,
    FirestoreCollections.rankingChildren,
    FirestoreCollections.tagColors,
    FirestoreCollections.customWords,
    FirestoreCollections.flaggedWords,
    FirestoreCollections.snippets,
    FirestoreCollections.jobExperienceSnippets,
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
    // Re-read rather than replayed with their old snapshot data, which is
    // what failed.
    for (final entry in _deferredIdsByCollection.entries) {
      _queuedIdsByCollection
          .putIfAbsent(entry.key, () => <String>{})
          .addAll(entry.value);
    }
    _deferredIdsByCollection.clear();
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
              // Out of immediate retries, but not dropped: held until the
              // next change arrives, so a document that fails for a while
              // still lands without waiting for the next launch's full pull.
              _requeueAttempts.remove(entry.key);
              _deferredIdsByCollection
                  .putIfAbsent(entry.key, () => <String>{})
                  .addAll(entry.value);
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
    _deferredIdsByCollection.clear();
    _started = false;
  }
}
