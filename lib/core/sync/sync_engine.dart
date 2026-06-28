import 'dart:async';
import 'dart:convert';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/sync/crdt_document_resolver.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/sync_activity.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';

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
  }) {
    if (cancelDebounceKey != null) {
      _debouncerFor(cancelDebounceKey).cancel();
    }
    return _syncDocument(
      collection: collection,
      documentId: documentId,
      payload: payload,
      charOps: charOps,
    );
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
    await purgeExpiredDeleted();
    if (pullFromRemote != null) {
      await pullFromRemote();
    }
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

  Future<void> _syncDocument({
    required String collection,
    required String documentId,
    required Map<String, dynamic> payload,
    List<CharacterOperation>? charOps,
  }) async {
    await _retryPolicy.run(() async {
      if (DevFlags.verboseSync) {
        debugPrint('[sync] upsert $collection/$documentId $payload');
      }

      await _syncRepository.upsertDocument(collection, documentId, payload);
      final sequence = ++_sequence;

      final opPayload = charOps != null && charOps.isNotEmpty
          ? CharOpsPayload(
              charOps: charOps,
              snapshot: payload,
            ).encode()
          : jsonEncode(payload);

      await _syncRepository.appendOperation(
        SyncOperation(
          id: '${_deviceId}_${documentId}_$sequence',
          documentId: documentId,
          sequence: sequence,
          payload: opPayload,
          deviceId: _deviceId,
          timestamp: DateTime.now().toUtc(),
        ),
      );
      _syncActivity?.recordUpload(collection);
    });
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
    required TodoRepository todoRepository,
    required CalendarRepository calendarRepository,
    required TrackerRepository trackerRepository,
  }) : _journalRepository = journalRepository,
       _todoRepository = todoRepository,
       _calendarRepository = calendarRepository,
       _trackerRepository = trackerRepository;

  final JournalRepository _journalRepository;
  final TodoRepository _todoRepository;
  final CalendarRepository _calendarRepository;
  final TrackerRepository _trackerRepository;

  Future<void> purgeExpiredDeleted({DateTime? now}) async {
    final cutoff = now ?? DateTime.now().toUtc();
    await Future.wait<void>([
      _journalRepository.purgeExpiredDeleted(cutoff),
      _todoRepository.purgeExpiredDeleted(cutoff),
      _calendarRepository.purgeExpiredDeleted(cutoff),
      _trackerRepository.purgeExpiredDeleted(cutoff),
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
