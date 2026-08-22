import 'dart:async';
import 'dart:convert';
import 'dart:math';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/sync/char_ops_encoder.dart';
import 'package:voyager/core/sync/crdt_document_resolver.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/scroll_activity_gate.dart';
import 'package:voyager/core/sync/sync_activity.dart';
import 'package:voyager/core/sync/sync_error_classification.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';

/// Ceiling for one `sync_operations` document's `payload` property.
///
/// Firestore rejects a property value over 1,048,487 bytes; the rest of the
/// headroom to that number covers the operation's other fields and Firestore's
/// own per-document overhead.
const int maxOperationPayloadBytes = 900000;

class SyncEngine {
  SyncEngine({
    required SyncRepository syncRepository,
    required String deviceId,
    Debouncer? debouncer,
    CharacterSequenceCrdtMerger? charMerger,
    CrdtDocumentResolver? crdtResolver,
    SyncActivityController? syncActivity,
    SyncRetryPolicy retryPolicy = const SyncRetryPolicy(),
  }) : _syncRepository = syncRepository,
       _deviceId = deviceId,
       _debouncer = debouncer ?? Debouncer(),
       _crdtResolver =
           crdtResolver ??
           CrdtDocumentResolver(
             merger: charMerger ?? CharacterSequenceCrdtMerger(),
           ),
       _syncActivity = syncActivity,
       _retryPolicy = retryPolicy;

  final SyncRepository _syncRepository;
  final String _deviceId;
  final Debouncer _debouncer;
  final CrdtDocumentResolver _crdtResolver;
  final SyncActivityController? _syncActivity;
  final SyncRetryPolicy _retryPolicy;
  final _keyedDebouncers = <String, Debouncer>{};
  int _sequence = 0;

  /// Raises the operation counter so the next operation sorts after
  /// [sequence].
  ///
  /// The counter lives only in memory, so a restart would otherwise begin again
  /// at 1 and mint operations that sort *before* everything the previous
  /// session wrote — [CrdtDocumentResolver] and [SyncRepository.listOperations]
  /// both order by `sequence` first. Whoever is about to read a document's
  /// existing log (see `RemoteSyncService.prepareEditingSession`) already knows
  /// the highest sequence in it and hands it here, which costs no extra query.
  void ensureSequenceAbove(int sequence) {
    if (sequence > _sequence) _sequence = sequence;
  }

  void cancelScheduledDocumentSync() => _debouncer.cancel();

  void scheduleDocumentSync({
    required String collection,
    required String documentId,
    required Map<String, dynamic> payload,
  }) {
    _debouncer.schedule(
      () => _syncDocument(
        collection: collection,
        documentId: documentId,
        payload: payload,
      ),
    );
  }

  void scheduleDebouncedDocumentSync({
    required String debounceKey,
    required String collection,
    required String documentId,
    required Map<String, dynamic> payload,
  }) {
    _debouncerFor(debounceKey).schedule(
      () => _syncDocument(
        collection: collection,
        documentId: documentId,
        payload: payload,
      ),
    );
  }

  Future<void> syncDocumentImmediately({
    required String collection,
    required String documentId,
    required Map<String, dynamic> payload,
    String? cancelDebounceKey,
    List<CharacterOperation>? charOps,
    bool logOperation = true,
  }) {
    if (cancelDebounceKey != null) {
      _debouncerFor(cancelDebounceKey).cancel();
    }
    return _syncDocument(
      collection: collection,
      documentId: documentId,
      payload: payload,
      charOps: charOps,
      logOperation: logOperation,
    );
  }

  /// Batched counterpart to [syncDocumentImmediately] for a set of documents
  /// in the same collection that don't carry pending char-ops (a plain
  /// snapshot upload is enough — e.g. sort-order-only changes). Commits all
  /// operation-log entries in one Firestore batch, then all document mirrors
  /// in another, instead of one round-trip pair per document. See
  /// [SyncRepository.appendOperationsBatch] for why this exists.
  Future<void> syncDocumentsImmediately({
    required String collection,
    required Map<String, Map<String, dynamic>> payloadsByDocumentId,
    bool logOperation = true,
  }) async {
    if (payloadsByDocumentId.isEmpty) return;
    if (DevFlags.verboseSync) {
      debugPrint(
        '[sync] batch upsert $collection ${payloadsByDocumentId.keys.toList()}',
      );
    }

    final now = DateTime.now().toUtc();
    final operations = [
      if (logOperation)
        for (final entry in payloadsByDocumentId.entries)
          SyncOperation(
            id: _operationId(entry.key, ++_sequence),
            documentId: entry.key,
            sequence: _sequence,
            payload: jsonEncode(entry.value),
            deviceId: _deviceId,
            timestamp: now,
          ),
    ];

    await ScrollActivityGate.instance.waitUntilIdle();
    final callStart = DevFlags.verboseSync ? DateTime.now() : null;
    if (operations.isNotEmpty) {
      await _retryPolicy.run(
        () => _syncRepository.appendOperationsBatch(operations),
      );
    }
    await _retryPolicy.run(
      () => _syncRepository.upsertDocumentsBatch(
        collection,
        payloadsByDocumentId,
      ),
    );
    if (callStart != null) {
      final elapsed = DateTime.now().difference(callStart).inMilliseconds;
      debugPrint('[sync] firestore batch calls for $collection took ${elapsed}ms');
    }
    _syncActivity?.recordUpload(collection);
  }

  Future<Map<String, dynamic>?> resolveDocumentPayload(String documentId) {
    return _crdtResolver.resolvePayload(_syncRepository, documentId);
  }

  Future<String> resolveConflicts(
    String documentId, {
    List<SyncOperation> localOperations = const [],
  }) async {
    final payload = await _crdtResolver.resolvePayload(
      _syncRepository,
      documentId,
      localOperations: localOperations,
    );
    if (payload == null) return '';
    return jsonEncode(payload);
  }

  Future<void> pullOnStartup({
    required Future<void> Function() localRefresh,
    required Future<void> Function() purgeExpiredDeleted,
    Future<void> Function()? pullFromRemote,
  }) async {
    // The purge runs *after* the pull, not before it. Expired tombstones live
    // in Firestore too, and nothing stops the pull from materialising one that
    // has just been purged — with `local == null` the merge functions apply the
    // remote document unconditionally, `deletedAt` and all. Purging first meant
    // deleting N rows and then re-inserting the same N rows, every launch,
    // forever. Purging afterwards sweeps up whatever the pull brought back in
    // the same pass.
    if (pullFromRemote != null) {
      await pullFromRemote();
    }
    await purgeExpiredDeleted();
    await localRefresh();
  }

  void dispose() {
    _debouncer.dispose();
    for (final debouncer in _keyedDebouncers.values) {
      debouncer.dispose();
    }
    _keyedDebouncers.clear();
  }

  Debouncer _debouncerFor(String key) {
    return _keyedDebouncers.putIfAbsent(
      key,
      () => Debouncer(delay: _debouncer.debounceDelay),
    );
  }

  /// Distinguishes this engine's operations from those of any other run.
  ///
  /// [_sequence] alone is not unique across runs of the app: it starts at 0
  /// every launch, so the first document synced in a new session used to mint
  /// the very id the first document of an earlier session already holds — and
  /// `appendOperation` writes with `set`, which overwrites it silently,
  /// destroying that session's characters.
  ///
  /// A timestamp on its own would not fix it either: two runs can start inside
  /// the same clock tick, and Windows in particular does not hand out
  /// microsecond-resolution wall time. The random half is what actually
  /// guarantees separation; the timestamp is kept because it makes an id
  /// readable when someone is staring at the operation log.
  final String _runId =
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${Random().nextInt(1 << 32).toRadixString(36)}';

  /// The Firestore document name for one operation group.
  ///
  /// Ids are opaque everywhere they are used — compaction and deletion both
  /// carry them around whole and never parse them — so widening the shape
  /// costs nothing.
  String _operationId(String documentId, int sequence) {
    return '${_deviceId}_${documentId}_${_runId}_$sequence';
  }

  Future<void> _syncDocument({
    required String collection,
    required String documentId,
    required Map<String, dynamic> payload,
    List<CharacterOperation>? charOps,
    bool logOperation = true,
  }) async {
    if (DevFlags.verboseSync) {
      debugPrint('[sync] upsert $collection/$documentId $payload');
    }

    // Plain records carry no collaborative text, so an operation-log entry
    // would only ever be read back as a whole-document snapshot the mirrored
    // document already holds. Skipping it halves the writes per save and
    // spares every later pull the per-document operation query — see
    // [FirestoreCollections.snapshotOnly].
    if (!logOperation) {
      await ScrollActivityGate.instance.waitUntilIdle();
      await _retryPolicy.run(
        () => _syncRepository.upsertDocument(collection, documentId, payload),
      );
      _syncActivity?.recordUpload(collection);
      return;
    }

    // Sequence/operation are computed once per call (outside any retry loop)
    // so that if the operation-log write below needs to be retried, every
    // attempt targets the same operation id instead of minting a new one.
    final sequence = ++_sequence;
    final timestamp = DateTime.now().toUtc();
    final baseId = _operationId(documentId, sequence);

    // A full-document reseed emits one character operation per character, so a
    // single save can carry far more than one document's worth of them. Split
    // it and commit the pieces atomically rather than letting the write be
    // rejected outright — see [CharOpsPayload.intoChunks].
    final List<SyncOperation> operations;
    if (charOps != null && charOps.isNotEmpty) {
      final encoded = await encodeCharOpPayloads(
        charOps: charOps,
        snapshot: payload,
        groupId: baseId,
        maxPayloadBytes: maxOperationPayloadBytes,
      );
      operations = [
        for (var i = 0; i < encoded.length; i++)
          SyncOperation(
            // Unsplit writes keep the historical id shape exactly.
            id: encoded.length == 1 ? baseId : '${baseId}_c$i',
            documentId: documentId,
            sequence: sequence,
            payload: encoded[i],
            deviceId: _deviceId,
            timestamp: timestamp,
          ),
      ];
    } else {
      operations = [
        SyncOperation(
          id: baseId,
          documentId: documentId,
          sequence: sequence,
          payload: jsonEncode(payload),
          deviceId: _deviceId,
          timestamp: timestamp,
        ),
      ];
    }

    // Write the operation-log entry (which embeds a full snapshot of
    // [payload]) before the mirrored document, each with its own retry
    // scope. If the app is killed between these two writes, the document
    // mirror may be left stale, but that's safely recoverable: pulls prefer
    // the CRDT-resolved payload from sync_operations over the raw document,
    // and the next editing session will see the complete char-op history
    // instead of reseeding from scratch and colliding with it. Writing the
    // document first (the old order) could leave sync_operations missing
    // the final edit while the document already reflects it, which is what
    // causes "duplicate fractional position" conflicts after an interrupted
    // sync. Retrying each write independently (rather than retrying both
    // together) keeps a retry of the document write from re-appending an
    // already-succeeded operation entry.
    await ScrollActivityGate.instance.waitUntilIdle();
    final callStart = DevFlags.verboseSync ? DateTime.now() : null;
    await _retryPolicy.run(
      () => _syncRepository.appendOperationGroup(operations),
    );
    await _retryPolicy.run(
      () => _syncRepository.upsertDocument(collection, documentId, payload),
    );
    if (callStart != null) {
      final elapsed = DateTime.now().difference(callStart).inMilliseconds;
      debugPrint('[sync] firestore calls for $collection/$documentId took ${elapsed}ms');
    }
    _syncActivity?.recordUpload(collection);
  }
}

class SyncRetryPolicy {
  const SyncRetryPolicy({
    this.maxAttempts = 3,
    this.initialBackoff = const Duration(milliseconds: 250),
    this.backoffMultiplier = 2,
  });

  final int maxAttempts;
  final Duration initialBackoff;
  final int backoffMultiplier;

  Future<void> run(Future<void> Function() operation) async {
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        await operation();
        return;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        // A rejected-on-its-merits write fails the same way every attempt, so
        // burning the remaining attempts and their backoff only delays the
        // caller's own error handling.
        if (classifySyncFailure(error) == SyncFailureKind.permanent) break;
        if (attempt == maxAttempts - 1) break;
        await Future<void>.delayed(_delayForAttempt(attempt));
      }
    }

    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Duration _delayForAttempt(int attempt) {
    var multiplier = 1;
    for (var i = 0; i < attempt; i++) {
      multiplier *= backoffMultiplier;
    }
    return initialBackoff * multiplier;
  }
}

class BackgroundSyncOrchestrator {
  const BackgroundSyncOrchestrator({
    required JournalRepository journalRepository,
    required DreamRepository dreamRepository,
    required TodoRepository todoRepository,
    required CalendarRepository calendarRepository,
    required TrackerRepository trackerRepository,
    required FinanceRepository financeRepository,
    required LeetCodeRepository leetCodeRepository,
    required StudyRepository studyRepository,
    required WorkoutRepository workoutRepository,
    required JobRepository jobRepository,
    required NotificationRepository notificationRepository,
    required BucketListRepository bucketListRepository,
    required SettingsRepository settingsRepository,
  }) : _journalRepository = journalRepository,
       _dreamRepository = dreamRepository,
       _todoRepository = todoRepository,
       _calendarRepository = calendarRepository,
       _trackerRepository = trackerRepository,
       _financeRepository = financeRepository,
       _leetCodeRepository = leetCodeRepository,
       _studyRepository = studyRepository,
       _workoutRepository = workoutRepository,
       _jobRepository = jobRepository,
       _notificationRepository = notificationRepository,
       _bucketListRepository = bucketListRepository,
       _settingsRepository = settingsRepository;

  final JournalRepository _journalRepository;
  final DreamRepository _dreamRepository;
  final TodoRepository _todoRepository;
  final CalendarRepository _calendarRepository;
  final TrackerRepository _trackerRepository;
  final FinanceRepository _financeRepository;
  final LeetCodeRepository _leetCodeRepository;
  final StudyRepository _studyRepository;
  final WorkoutRepository _workoutRepository;
  final JobRepository _jobRepository;
  final NotificationRepository _notificationRepository;
  final BucketListRepository _bucketListRepository;
  final SettingsRepository _settingsRepository;

  Future<void> purgeExpiredDeleted({DateTime? now}) async {
    final cutoff = now ?? DateTime.now().toUtc();
    await Future.wait<void>([
      _journalRepository.purgeExpiredDeleted(cutoff),
      _dreamRepository.purgeExpiredDeleted(cutoff),
      _todoRepository.purgeExpiredDeleted(cutoff),
      _calendarRepository.purgeExpiredDeleted(cutoff),
      _trackerRepository.purgeExpiredDeleted(cutoff),
      _financeRepository.purgeExpiredDeleted(cutoff),
      _leetCodeRepository.purgeExpiredDeleted(cutoff),
      _studyRepository.purgeExpiredDeleted(cutoff),
      _workoutRepository.purgeExpiredDeleted(cutoff),
      // Job applications are the one entity the user hard-deletes, so their
      // tombstones are the only record of the deletion the other devices ever
      // see. Purging on the same retention as everything else is what stops
      // them accumulating forever.
      _jobRepository.purgeExpiredDeleted(cutoff),
      // The tombstones that let an unpin, an un-dismissal, a removed bucket
      // list item or a removed dictionary word reach the other devices.
      _notificationRepository.purgeExpiredDeleted(cutoff),
      _bucketListRepository.purgeExpiredDeleted(cutoff),
      _settingsRepository.purgeExpiredDeleted(cutoff),
    ]);
  }
}

class GoogleCalendarSyncService {
  GoogleCalendarSyncService(
    this._syncRepository,
    this._calendarRepository,
    this._deviceId,
  );

  final SyncRepository _syncRepository;
  final CalendarRepository _calendarRepository;
  final String _deviceId;

  Future<void> syncReadOnly(List<dynamic> googleEvents) async {
    final now = DateTime.now().toUtc();
    final lock = GoogleCalendarSyncLock(
      deviceId: _deviceId,
      lockedAt: now,
      expiresAt: now.add(const Duration(minutes: 5)),
    );
    final claimed = await _syncRepository.claimCalendarLock(lock);
    if (!claimed) return;

    try {
      // googleEvents would be mapped from Google API in production.
      await _calendarRepository.replaceGoogleEvents([]);
    } finally {
      await _syncRepository.releaseCalendarLock(_deviceId);
    }
  }
}

class LazyLoadService {
  LazyLoadService(this._journalRepository);

  final JournalRepository _journalRepository;

  Future<List<JournalEntry>> loadRecentEntries({int limit = 30}) {
    return _journalRepository.listEntries(limit: limit);
  }

  Future<List<JournalEntry>> loadHistoricalEntries({required DateTime before}) {
    return _journalRepository.listEntries(to: before);
  }
}
