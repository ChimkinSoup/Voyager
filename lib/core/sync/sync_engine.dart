import 'dart:async';
import 'dart:convert';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/sequence_crdt_merger.dart';

class SyncEngine {
  SyncEngine({
    required SyncRepository syncRepository,
    required String deviceId,
    Debouncer? debouncer,
    SequenceCrdtMerger? merger,
    SyncRetryPolicy retryPolicy = const SyncRetryPolicy(),
  }) : _syncRepository = syncRepository,
       _deviceId = deviceId,
       _debouncer = debouncer ?? Debouncer(),
       _merger = merger ?? SequenceCrdtMerger(),
       _retryPolicy = retryPolicy;

  final SyncRepository _syncRepository;
  final String _deviceId;
  final Debouncer _debouncer;
  final SequenceCrdtMerger _merger;
  final SyncRetryPolicy _retryPolicy;
  int _sequence = 0;

  void scheduleDocumentSync({
    required String collection,
    required String documentId,
    required Map<String, dynamic> payload,
  }) {
    _debouncer.schedule(
      () async => _syncDocument(
        collection: collection,
        documentId: documentId,
        payload: payload,
      ),
    );
  }

  Future<String> resolveConflicts(
    String documentId, {
    List<SyncOperation> localOperations = const [],
  }) async {
    final remote = await _syncRepository.listOperations(documentId);
    final merged = _merger.merge(localOperations, remote);
    return _merger.applyMergedPayload(merged);
  }

  Future<void> pullOnStartup({
    required Future<void> Function() localRefresh,
    required Future<void> Function() purgeExpiredDeleted,
  }) async {
    await purgeExpiredDeleted();
    await localRefresh();
  }

  void dispose() => _debouncer.dispose();

  Future<void> _syncDocument({
    required String collection,
    required String documentId,
    required Map<String, dynamic> payload,
  }) async {
    await _retryPolicy.run(() async {
      if (DevFlags.verboseSync) {
        debugPrint('[sync] upsert $collection/$documentId $payload');
      }

      await _syncRepository.upsertDocument(collection, documentId, payload);
      final sequence = ++_sequence;
      await _syncRepository.appendOperation(
        SyncOperation(
          id: '${_deviceId}_${documentId}_$sequence',
          documentId: documentId,
          sequence: sequence,
          payload: jsonEncode(payload),
          deviceId: _deviceId,
          timestamp: DateTime.now().toUtc(),
        ),
      );
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
