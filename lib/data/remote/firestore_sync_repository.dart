import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:voyager/core/sync/firestore_write_gate.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/weather_forecast_merge.dart';

/// Mutations per `WriteBatch`.
///
/// Firestore's own ceiling is 500, and that is what this used to be — but 500
/// is the limit on what one *batch* may contain, not on what the write stream
/// will carry. The client keeps several batches in flight at once, so batching
/// at the maximum let a single burst put thousands of queued writes on one
/// stream, which is what the backend refuses with `RESOURCE_EXHAUSTED: Write
/// stream exhausted maximum allowed queued writes`. Small batches cost more
/// round-trips on a good connection and are the difference between syncing
/// slowly and not syncing at all on a bad one.
const int firestoreWriteChunkSize = 40;

class FirestoreSyncRepository implements SyncRepository {
  FirestoreSyncRepository(
    this._firestore,
    this._userId, {
    FirestoreWriteGate? writeGate,
  }) : writeGate =
           writeGate ??
           FirestoreWriteGate(
             waitForPendingWrites: _firestore.waitForPendingWrites,
           );

  final FirebaseFirestore _firestore;
  final String _userId;

  /// Bounds how many writes are handed to Firestore before it acknowledges
  /// them — see [FirestoreWriteGate].
  final FirestoreWriteGate writeGate;

  @override
  bool get hasUnsentWriteBacklog =>
      writeGate.hasStartupBacklog || writeGate.isPaused;

  DocumentReference<Map<String, dynamic>> _doc(String collection, String id) {
    return _firestore.doc('users/$_userId/$collection/$id');
  }

  CollectionReference<Map<String, dynamic>> _collection(String collection) {
    return _firestore.collection('users/$_userId/$collection');
  }

  @override
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    await writeGate.run(
      () => _doc(collection, id).set(data, SetOptions(merge: true)),
    );
  }

  @override
  Stream<Map<String, dynamic>> watchDocument(String collection, String id) {
    return _doc(collection, id).snapshots().map((snap) {
      if (!snap.exists || snap.data() == null) return <String, dynamic>{};
      return snap.data()!;
    });
  }

  @override
  Stream<Map<String, Map<String, dynamic>>> watchCollection(String collection) {
    return _collection(collection).snapshots().map(
      (snap) => {
        for (final change in snap.docChanges)
          if (change.type != DocumentChangeType.removed &&
              change.doc.data() != null)
            change.doc.id: Map<String, dynamic>.from(change.doc.data()!),
      },
    );
  }

  @override
  Future<Map<String, dynamic>?> getDocument(String collection, String id) async {
    final snap = await _doc(collection, id).get();
    if (!snap.exists || snap.data() == null) return null;
    return snap.data();
  }

  @override
  Future<List<({String id, Map<String, dynamic> data})>> listCollectionDocuments(
    String collection,
  ) async {
    final query = await _collection(collection).get();
    return query.docs
        .map((doc) => (id: doc.id, data: Map<String, dynamic>.from(doc.data())))
        .toList();
  }

  DocumentReference<Map<String, dynamic>> get _settingsDoc =>
      _firestore.doc('users/$_userId/settings/app');

  @override
  Future<Map<String, dynamic>?> getRemoteSettings() async {
    final snap = await _settingsDoc.get();
    if (!snap.exists || snap.data() == null) return null;
    return snap.data();
  }

  @override
  Future<void> upsertRemoteSettings(Map<String, dynamic> data) async {
    await writeGate.run(() => _settingsDoc.set(data, SetOptions(merge: true)));
  }

  @override
  Future<void> ping() async {
    // A document that is never written: the read costs the same whether it
    // exists or not, and a missing one can't be answered from a warm cache by
    // accident. Source.server is the request for a real round-trip, and the
    // isFromCache check is what enforces it — a platform that quietly ignores
    // the option would otherwise report a cached miss as a healthy connection.
    final snap = await _doc(
      'meta',
      'ping',
    ).get(const GetOptions(source: Source.server));
    if (snap.metadata.isFromCache) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'unavailable',
        message: 'Ping was answered from the local cache.',
      );
    }
  }

  @override
  Future<GoogleCalendarSyncLock?> getCalendarLock() async {
    final snap = await _firestore
        .doc('users/$_userId/sync_locks/calendar')
        .get();
    if (!snap.exists || snap.data() == null) return null;
    final data = snap.data()!;
    return GoogleCalendarSyncLock(
      deviceId: data['deviceId'] as String,
      lockedAt: DateTime.parse(data['lockedAt'] as String).toUtc(),
      expiresAt: DateTime.parse(data['expiresAt'] as String).toUtc(),
    );
  }

  @override
  Future<bool> claimCalendarLock(GoogleCalendarSyncLock lock) async {
    final ref = _firestore.doc('users/$_userId/sync_locks/calendar');
    try {
      return await _firestore.runTransaction((txn) async {
        final snap = await txn.get(ref);
        final now = DateTime.now().toUtc();
        if (!snap.exists || snap.data() == null) {
          txn.set(ref, {
            'deviceId': lock.deviceId,
            'lockedAt': lock.lockedAt.toIso8601String(),
            'expiresAt': lock.expiresAt.toIso8601String(),
          });
          return true;
        }
        final existing = GoogleCalendarSyncLock(
          deviceId: snap.data()!['deviceId'] as String,
          lockedAt: DateTime.parse(snap.data()!['lockedAt'] as String).toUtc(),
          expiresAt: DateTime.parse(snap.data()!['expiresAt'] as String).toUtc(),
        );
        if (existing.isValid(lock.deviceId, now)) {
          txn.set(ref, {
            'deviceId': lock.deviceId,
            'lockedAt': lock.lockedAt.toIso8601String(),
            'expiresAt': lock.expiresAt.toIso8601String(),
          });
          return true;
        }
        return false;
      });
    } catch (e) {
      debugPrint('Error claiming calendar lock: $e');
      return false;
    }
  }

  @override
  Future<void> releaseCalendarLock(String deviceId) async {
    final ref = _firestore.doc('users/$_userId/sync_locks/calendar');
    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(ref);
      if (!snap.exists || snap.data() == null) return;
      if (snap.data()!['deviceId'] == deviceId) {
        txn.delete(ref);
      }
    });
  }

  @override
  Future<WeatherFetchLock?> getWeatherFetchLock() async {
    final snap = await _firestore
        .doc('users/$_userId/sync_locks/weather_fetch')
        .get();
    if (!snap.exists || snap.data() == null) return null;
    return WeatherFetchLock.fromJson(snap.data()!);
  }

  @override
  Future<bool> claimWeatherFetchLock(WeatherFetchLock lock) async {
    final ref = _firestore.doc('users/$_userId/sync_locks/weather_fetch');
    try {
      return await _firestore.runTransaction((txn) async {
        final snap = await txn.get(ref);
        final now = DateTime.now().toUtc();
        if (!snap.exists || snap.data() == null) {
          txn.set(ref, lock.toJson());
          return true;
        }
        final existing = WeatherFetchLock.fromJson(snap.data()!);
        if (existing.isValid(lock.deviceId, now)) {
          txn.set(ref, lock.toJson());
          return true;
        }
        return false;
      });
    } catch (e) {
      debugPrint('Error claiming weather fetch lock: $e');
      return false;
    }
  }

  @override
  Future<void> releaseWeatherFetchLock(String deviceId) async {
    final ref = _firestore.doc('users/$_userId/sync_locks/weather_fetch');
    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(ref);
      if (!snap.exists || snap.data() == null) return;
      if (snap.data()!['deviceId'] == deviceId) {
        txn.delete(ref);
      }
    });
  }

  @override
  Future<WeatherSnapshot?> getCurrentWeather() async {
    final snap = await _firestore.doc('users/$_userId/weather/current').get();
    if (!snap.exists || snap.data() == null) return null;
    return WeatherSnapshot.fromJson(snap.data()!);
  }

  @override
  Future<void> upsertCurrentWeather(WeatherSnapshot weather) async {
    await writeGate.run(
      () => _firestore
          .doc('users/$_userId/weather/current')
          .set(weather.toJson(), SetOptions(merge: true)),
    );
  }

  DocumentReference<Map<String, dynamic>> get _forecastDoc =>
      _firestore.doc('users/$_userId/weather/forecast');

  @override
  Future<WeatherForecast?> getStoredForecast() async {
    final snap = await _forecastDoc.get();
    if (!snap.exists || snap.data() == null) return null;
    try {
      return weatherForecastFromFirestoreArchive(snap.data()!);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _operationData(SyncOperation operation) => {
    'id': operation.id,
    'documentId': operation.documentId,
    'sequence': operation.sequence,
    'payload': operation.payload,
    'deviceId': operation.deviceId,
    'timestamp': operation.timestamp.toUtc().toIso8601String(),
  };

  @override
  Future<void> appendOperation(SyncOperation operation) async {
    await writeGate.run(
      () => _doc('sync_operations', operation.id).set(_operationData(operation)),
    );
  }

  @override
  Future<void> appendOperationsBatch(List<SyncOperation> operations) async {
    for (final chunk in _chunked(operations, firestoreWriteChunkSize)) {
      final batch = _firestore.batch();
      for (final operation in chunk) {
        batch.set(_doc('sync_operations', operation.id), _operationData(operation));
      }
      await writeGate.run(batch.commit, weight: chunk.length);
    }
  }

  @override
  Future<void> appendOperationGroup(List<SyncOperation> operations) async {
    if (operations.isEmpty) return;
    if (operations.length == 1) {
      await appendOperation(operations.single);
      return;
    }
    // As few commits as fit Firestore's 10 MiB request limit — each chunk holds
    // close to a megabyte of character operations, so a large reseed or
    // compaction in one batch was rejected outright, every time it was
    // retried. Splitting is safe because readers ignore a group until every
    // one of its `chunkCount` chunks is present: a commit that fails partway
    // leaves a partial group nobody resolves, never partial text.
    var batch = _firestore.batch();
    var bytes = 0;
    var count = 0;
    for (final operation in operations) {
      final size = utf8.encode(operation.payload).length + _operationOverheadBytes;
      if (count > 0 && bytes + size > _maxCommitBytes) {
        await writeGate.run(batch.commit, weight: count);
        batch = _firestore.batch();
        bytes = 0;
        count = 0;
      }
      batch.set(_doc('sync_operations', operation.id), _operationData(operation));
      bytes += size;
      count++;
    }
    await writeGate.run(batch.commit, weight: count);
  }

  /// Under the 10 MiB request limit with room for the per-write envelope.
  static const _maxCommitBytes = 8 * 1024 * 1024;
  static const _operationOverheadBytes = 1024;

  @override
  Future<void> upsertDocumentsBatch(
    String collection,
    Map<String, Map<String, dynamic>> documentsById,
  ) async {
    for (final chunk in _chunked(documentsById.entries.toList(), firestoreWriteChunkSize)) {
      final batch = _firestore.batch();
      for (final entry in chunk) {
        batch.set(
          _doc(collection, entry.key),
          entry.value,
          SetOptions(merge: true),
        );
      }
      await writeGate.run(batch.commit, weight: chunk.length);
    }
  }

  Iterable<List<T>> _chunked<T>(List<T> items, int size) sync* {
    for (var i = 0; i < items.length; i += size) {
      yield items.sublist(i, i + size > items.length ? items.length : i + size);
    }
  }

  @override
  Future<List<SyncOperation>> listOperations(String documentId) async {
    final query = await _collection(
      'sync_operations',
    ).where('documentId', isEqualTo: documentId).get();
    final operations = query.docs.map((doc) {
      final data = doc.data();
      return SyncOperation(
        id: data['id'] as String,
        documentId: data['documentId'] as String,
        sequence: (data['sequence'] as num).toInt(),
        payload: data['payload'] as String,
        deviceId: data['deviceId'] as String,
        timestamp: DateTime.parse(data['timestamp'] as String).toUtc(),
      );
    }).toList();
    operations.sort((a, b) {
      final sequenceOrder = a.sequence.compareTo(b.sequence);
      if (sequenceOrder != 0) return sequenceOrder;
      return a.timestamp.compareTo(b.timestamp);
    });
    return operations;
  }

  @override
  Future<void> deleteDocument(String collection, String id) async {
    await writeGate.run(() => _doc(collection, id).delete());
  }

  /// Forces a server round-trip, so an offline caller is told rather than
  /// handed a lie.
  ///
  /// Firestore answers reads from the local cache while offline and never
  /// fails, so at the default source a cold or evicted cache returns zero
  /// documents and this reported "deleted 0 operations" with the remote log
  /// fully intact. Every caller uses the result to decide the log is gone —
  /// [RemoteSyncService.forceOverwriteJournalEntryText] then re-seeds a chain
  /// on top of the surviving one, producing exactly the duplicated text it
  /// exists to prevent. The `isFromCache` check is what enforces the option,
  /// the same way [ping] does: a platform that quietly ignored it would
  /// otherwise report a cached miss as a completed wipe.
  @override
  Future<int> deleteOperationsForDocument(String documentId) async {
    final query = await _collection('sync_operations')
        .where('documentId', isEqualTo: documentId)
        .get(const GetOptions(source: Source.server));
    if (query.metadata.isFromCache) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'unavailable',
        message:
            'Operation-log wipe for $documentId was answered from the local '
            'cache, so the remote log could not be read.',
      );
    }
    if (query.docs.isEmpty) return 0;

    const batchSize = firestoreWriteChunkSize;
    var deleted = 0;
    for (var i = 0; i < query.docs.length; i += batchSize) {
      final batch = _firestore.batch();
      var count = 0;
      for (final doc in query.docs.skip(i).take(batchSize)) {
        batch.delete(doc.reference);
        deleted++;
        count++;
      }
      await writeGate.run(batch.commit, weight: count);
    }
    return deleted;
  }

  @override
  Future<int> deleteOperations(
    String documentId,
    List<String> operationIds,
  ) async {
    if (operationIds.isEmpty) return 0;
    var deleted = 0;
    // The operation id is the document name (see [appendOperation]), so these
    // delete without a query.
    for (final chunk in _chunked(operationIds, firestoreWriteChunkSize)) {
      final batch = _firestore.batch();
      for (final id in chunk) {
        batch.delete(_doc('sync_operations', id));
        deleted++;
      }
      await writeGate.run(batch.commit, weight: chunk.length);
    }
    return deleted;
  }
}

class NoOpSyncRepository implements SyncRepository {
  @override
  bool get hasUnsentWriteBacklog => false;

  @override
  Future<void> appendOperation(SyncOperation operation) async {}

  @override
  Future<void> appendOperationsBatch(List<SyncOperation> operations) async {}

  @override
  Future<void> appendOperationGroup(List<SyncOperation> operations) async {}

  @override
  Future<void> upsertDocumentsBatch(
    String collection,
    Map<String, Map<String, dynamic>> documentsById,
  ) async {}

  @override
  Future<bool> claimCalendarLock(GoogleCalendarSyncLock lock) async => false;

  @override
  Future<bool> claimWeatherFetchLock(WeatherFetchLock lock) async => false;

  @override
  Future<GoogleCalendarSyncLock?> getCalendarLock() async => null;

  @override
  Future<WeatherFetchLock?> getWeatherFetchLock() async => null;

  @override
  Future<WeatherSnapshot?> getCurrentWeather() async => null;

  @override
  Future<List<SyncOperation>> listOperations(String documentId) async =>
      const [];

  @override
  Future<void> releaseCalendarLock(String deviceId) async {}

  @override
  Future<void> releaseWeatherFetchLock(String deviceId) async {}

  @override
  Future<void> upsertCurrentWeather(WeatherSnapshot weather) async {}

  @override
  Future<WeatherForecast?> getStoredForecast() async => null;

  @override
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {}

  @override
  Stream<Map<String, dynamic>> watchDocument(String collection, String id) {
    return const Stream.empty();
  }

  @override
  Stream<Map<String, Map<String, dynamic>>> watchCollection(String collection) {
    return const Stream.empty();
  }

  @override
  Future<Map<String, dynamic>?> getDocument(String collection, String id) async => null;

  @override
  Future<List<({String id, Map<String, dynamic> data})>> listCollectionDocuments(
    String collection,
  ) async =>
      const [];

  @override
  Future<Map<String, dynamic>?> getRemoteSettings() async => null;

  @override
  Future<void> upsertRemoteSettings(Map<String, dynamic> data) async {}

  @override
  Future<void> ping() async {}

  @override
  Future<void> deleteDocument(String collection, String id) async {}

  @override
  Future<int> deleteOperationsForDocument(String documentId) async => 0;

  @override
  Future<int> deleteOperations(
    String documentId,
    List<String> operationIds,
  ) async => 0;
}
