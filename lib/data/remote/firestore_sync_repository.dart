import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:voyager/core/sync/firestore_document_mapper.dart';
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
    http.Client? httpClient,
  }) : writeGate =
           writeGate ??
           FirestoreWriteGate(
             waitForPendingWrites: _firestore.waitForPendingWrites,
           ),
       _http = httpClient ?? http.Client();

  final FirebaseFirestore _firestore;
  final String _userId;
  final http.Client _http;

  String get userId => _userId;

  /// Bounds how many writes are handed to Firestore before it acknowledges
  /// them — see [FirestoreWriteGate].
  final FirestoreWriteGate writeGate;

  @override
  bool get hasUnsentWriteBacklog =>
      writeGate.hasStartupBacklog || writeGate.isPaused;

  @override
  Future<void> waitForPendingWrites() => _firestore.waitForPendingWrites();

  DocumentReference<Map<String, dynamic>> _doc(String collection, String id) {
    return _firestore.doc('users/$_userId/$collection/$id');
  }

  CollectionReference<Map<String, dynamic>> _collection(String collection) {
    return _firestore.collection('users/$_userId/$collection');
  }

  /// When the server last wrote a document, stamped on every upsert so a pull
  /// can ask for only what changed. The server's clock, not this device's:
  /// a device whose clock runs slow would otherwise write into the past, below
  /// a mark another device has already moved beyond.
  static const _writeTimeField = '_serverWrittenAt';

  /// [data] with the server write time added. Every write to a synced
  /// collection must go through this — [OutboxSyncWorker] included — or the
  /// change is invisible to incremental pulls and live listeners.
  static Map<String, dynamic> stamped(Map<String, dynamic> data) => {
    ...data,
    _writeTimeField: FieldValue.serverTimestamp(),
  };

  /// A document as the rest of the app knows it — the write time is this
  /// class's business, and a pending one reads as null anyway.
  static Map<String, dynamic> _unstamped(Map<String, dynamic> data) =>
      Map<String, dynamic>.from(data)..remove(_writeTimeField);

  /// Whether a snapshot of a document is this device's own [stamped] write,
  /// still waiting in the local cache for the server.
  ///
  /// Such a snapshot needs no delivering: the server's acknowledgement fills
  /// in the write time, which changes the data and so fires the listener again
  /// — carrying our write and anything another device merged into it. A write
  /// that skips [stamped] (the settings patch) gets no such second snapshot
  /// when only the metadata changes, so it is never held back here.
  @visibleForTesting
  static bool isUnconfirmedStampedWrite({
    required bool hasPendingWrites,
    required Map<String, dynamic> data,
  }) =>
      hasPendingWrites &&
      data.containsKey(_writeTimeField) &&
      data[_writeTimeField] == null;

  Query<Map<String, dynamic>> _changedSince(
    String collection,
    DateTime? since,
  ) {
    final all = _collection(collection);
    if (since == null) return all;
    return all.where(_writeTimeField, isGreaterThan: Timestamp.fromDate(since));
  }

  @override
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    await writeGate.run(
      () => _doc(collection, id).set(stamped(data), SetOptions(merge: true)),
    );
  }

  @override
  Stream<Map<String, dynamic>> watchDocument(String collection, String id) {
    return _doc(collection, id).snapshots().map((snap) {
      if (!snap.exists || snap.data() == null) return <String, dynamic>{};
      return _unstamped(snap.data()!);
    });
  }

  @override
  Stream<Map<String, Map<String, dynamic>>> watchCollection(
    String collection, {
    DateTime? changedSince,
  }) {
    return _changedSince(collection, changedSince).snapshots().map(
      (snap) => {
        for (final change in snap.docChanges)
          if (change.type != DocumentChangeType.removed &&
              change.doc.data() != null &&
              !isUnconfirmedStampedWrite(
                hasPendingWrites: change.doc.metadata.hasPendingWrites,
                data: change.doc.data()!,
              ))
            change.doc.id: _unstamped(change.doc.data()!),
      },
    );
  }

  @override
  Future<Map<String, dynamic>?> getDocument(
    String collection,
    String id,
  ) async {
    final snap = await _doc(collection, id).get();
    if (!snap.exists || snap.data() == null) return null;
    return _unstamped(snap.data()!);
  }

  @override
  Future<List<({String id, Map<String, dynamic> data})>>
  listCollectionDocuments(String collection) async {
    final query = await _collection(collection).get();
    return query.docs
        .map((doc) => (id: doc.id, data: _unstamped(doc.data())))
        .toList();
  }

  @override
  Future<
    ({
      List<({String id, Map<String, dynamic> data})> documents,
      DateTime? newestWrite,
      bool fromServer,
    })
  >
  listChangedDocuments(String collection, {DateTime? since}) async {
    final query = await _changedSince(collection, since).get();
    DateTime? newest;
    for (final doc in query.docs) {
      final written = doc.data()[_writeTimeField];
      if (written is! Timestamp) continue;
      final at = written.toDate().toUtc();
      if (newest == null || at.isAfter(newest)) newest = at;
    }
    return (
      documents: [
        for (final doc in query.docs)
          (id: doc.id, data: _unstamped(doc.data())),
      ],
      newestWrite: newest,
      fromServer: !query.metadata.isFromCache,
    );
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
  Future<void> uploadSettings(AppSettings settings) =>
      writeGate.run(() => writeSettings(_firestore, _settingsDoc, settings));

  /// Reads the settings document and writes [settingsUploadPatch] in one
  /// transaction, so a setting changed on another device since this one last
  /// pulled is never written over with this device's older value.
  static Future<void> writeSettings(
    FirebaseFirestore firestore,
    DocumentReference<Map<String, dynamic>> doc,
    AppSettings settings,
  ) => firestore.runTransaction((txn) async {
    final snap = await txn.get(doc);
    final patch = settingsUploadPatch(settings, snap.data());
    if (patch.isEmpty) return;
    // An update rather than a merging set leaves the weather keys sharing this
    // document alone just the same, and fake_cloud_firestore's transaction
    // ignores `SetOptions`.
    if (snap.exists) {
      txn.update(doc, patch);
    } else {
      txn.set(doc, patch);
    }
  });

  @override
  Future<void> ping() async {
    // Plain HTTPS to Firestore's host first, not a read through the SDK: the
    // SDK runs everything on one worker, so a document read waited behind a
    // full pull's queries for minutes and the badge reported a busy client as
    // offline (BUG-002). Any HTTP answer, even an error status, means the
    // network reached Google — over TLS, so no captive portal can fake one.
    try {
      await _pingHost();
    } catch (_) {
      // dart:io ignores the Windows system proxy, which the SDK's own stack
      // honours: behind one, only the SDK can say whether Firestore is
      // reachable.
      await _pingThroughSdk();
    }
  }

  /// Half the connectivity probe's 8 s timeout, leaving the SDK read time to
  /// answer when the request fails.
  static const _hostPingTimeout = Duration(seconds: 4);

  Future<void> _pingHost() async {
    // Aborted, not just abandoned: a probe every 10 s while offline would
    // otherwise pile up requests waiting on the OS connect timeout.
    final abort = Completer<void>();
    final timer = Timer(_hostPingTimeout, abort.complete);
    try {
      final response = await _http.send(
        http.AbortableRequest(
          'HEAD',
          Uri.https('firestore.googleapis.com'),
          abortTrigger: abort.future,
        ),
      );
      await response.stream.drain<void>();
    } finally {
      timer.cancel();
    }
  }

  Future<void> _pingThroughSdk() async {
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

  /// Releases the connections [ping] keeps alive. The repository is rebuilt
  /// on every sign-in change, so each one left open would leak.
  void close() => _http.close();

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
          expiresAt: DateTime.parse(
            snap.data()!['expiresAt'] as String,
          ).toUtc(),
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

  /// Stamped like any synced write, so [listOperationDocumentIdsSince] can
  /// ask by when an operation reached the server rather than by `timestamp`,
  /// the writer's clock at the edit — days behind for one queued offline.
  Map<String, dynamic> _operationData(SyncOperation operation) => stamped({
    'id': operation.id,
    'documentId': operation.documentId,
    'sequence': operation.sequence,
    'payload': operation.payload,
    'deviceId': operation.deviceId,
    'timestamp': operation.timestamp.toUtc().toIso8601String(),
  });

  @override
  Future<void> appendOperation(SyncOperation operation) async {
    await writeGate.run(
      () =>
          _doc('sync_operations', operation.id).set(_operationData(operation)),
    );
  }

  @override
  Future<void> appendOperationsBatch(List<SyncOperation> operations) async {
    for (final chunk in _chunked(operations, firestoreWriteChunkSize)) {
      final batch = _firestore.batch();
      for (final operation in chunk) {
        batch.set(
          _doc('sync_operations', operation.id),
          _operationData(operation),
        );
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
      final size =
          utf8.encode(operation.payload).length + _operationOverheadBytes;
      if (count > 0 && bytes + size > _maxCommitBytes) {
        await writeGate.run(batch.commit, weight: count);
        batch = _firestore.batch();
        bytes = 0;
        count = 0;
      }
      batch.set(
        _doc('sync_operations', operation.id),
        _operationData(operation),
      );
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
    for (final chunk in _chunked(
      documentsById.entries.toList(),
      firestoreWriteChunkSize,
    )) {
      final batch = _firestore.batch();
      for (final entry in chunk) {
        batch.set(
          _doc(collection, entry.key),
          stamped(entry.value),
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
    return _sortOperations(
      query.docs.map((doc) => _parseOperation(doc.data())).toList(),
    );
  }

  static SyncOperation _parseOperation(Map<String, dynamic> data) =>
      SyncOperation(
        id: data['id'] as String,
        documentId: data['documentId'] as String,
        sequence: (data['sequence'] as num).toInt(),
        payload: data['payload'] as String,
        deviceId: data['deviceId'] as String,
        timestamp: DateTime.parse(data['timestamp'] as String).toUtc(),
      );

  static List<SyncOperation> _sortOperations(List<SyncOperation> operations) =>
      operations..sort((a, b) {
        final sequenceOrder = a.sequence.compareTo(b.sequence);
        if (sequenceOrder != 0) return sequenceOrder;
        return a.timestamp.compareTo(b.timestamp);
      });

  /// Payload per page of [listAllOperations]. Firestore can only limit a page
  /// by count, and operations run from a few kilobytes to near a megabyte
  /// (one chunk of a large rewrite), so a fixed 1,000 could fetch hundreds of
  /// megabytes at once. Each page is sized from the ones before it instead.
  static const _operationPageBytes = 16 * 1024 * 1024;

  /// The first page's size, before any sizes are known: 16 MB of operations
  /// averaging ~64 KB, when the measured account's averaged ~12 KB.
  static const _firstOperationPageSize = 250;

  /// How many operations the next page of [listAllOperations] asks for, given
  /// the [count] read so far and their payload [bytes].
  @visibleForTesting
  static int nextOperationPageSize({required int count, required int bytes}) {
    if (count == 0 || bytes == 0) return _firstOperationPageSize;
    return (_operationPageBytes * count ~/ bytes).clamp(50, 1000);
  }

  @override
  Future<
    ({Map<String, List<SyncOperation>> logs, DateTime? newestWriteAtStart})
  >
  listAllOperations() async {
    // Taken before the first page, not as the newest write the pages held:
    // they're read one after another, so an operation written mid-read into
    // a page already passed is missed, while a later one in a page still to
    // come would lift a max-of-what-was-read past it. Anything written once
    // this has answered is stamped after it.
    final newest = await _collection('sync_operations')
        .orderBy(_writeTimeField, descending: true)
        .limit(1)
        .get(const GetOptions(source: Source.server));
    _throwIfFromCache(newest);
    final newestWriteAtStart = newest.docs.isEmpty
        ? null
        : (newest.docs.single.data()[_writeTimeField] as Timestamp)
              .toDate()
              .toUtc();
    final logs = <String, List<SyncOperation>>{};
    // By document name, the order a per-document query returns them in, so
    // each log reaches [_sortOperations] exactly as [listOperations]' does.
    final ordered = _collection(
      'sync_operations',
    ).orderBy(FieldPath.documentId);
    QueryDocumentSnapshot<Map<String, dynamic>>? last;
    var count = 0;
    var bytes = 0;
    while (true) {
      final size = nextOperationPageSize(count: count, bytes: bytes);
      final query = last == null ? ordered : ordered.startAfterDocument(last);
      final page = await query
          .limit(size)
          .get(const GetOptions(source: Source.server));
      _throwIfFromCache(page);
      for (final doc in page.docs) {
        final operation = _parseOperation(doc.data());
        logs.putIfAbsent(operation.documentId, () => []).add(operation);
        count++;
        bytes += operation.payload.length;
      }
      if (page.docs.length < size) break;
      last = page.docs.last;
    }
    logs.updateAll((_, operations) => _sortOperations(operations));
    return (logs: logs, newestWriteAtStart: newestWriteAtStart);
  }

  static void _throwIfFromCache(QuerySnapshot<Map<String, dynamic>> query) {
    if (query.metadata.isFromCache) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'unavailable',
        message: 'Operation logs were answered from the local cache.',
      );
    }
  }

  @override
  Future<Set<String>> listOperationDocumentIdsSince(DateTime since) async {
    final query = await _collection('sync_operations')
        .where(
          _writeTimeField,
          isGreaterThanOrEqualTo: Timestamp.fromDate(since),
        )
        .get(const GetOptions(source: Source.server));
    if (query.metadata.isFromCache) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'unavailable',
        message: 'Recent operations were answered from the local cache.',
      );
    }
    return {for (final doc in query.docs) doc.data()['documentId'] as String};
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
  /// exists to prevent. The `isFromCache` check is what enforces the option:
  /// a platform that quietly ignored it would otherwise report a cached miss
  /// as a completed wipe.
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
  Future<void> waitForPendingWrites() async {}

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
  Future<Set<String>> listOperationDocumentIdsSince(DateTime since) async => {};

  @override
  Future<
    ({Map<String, List<SyncOperation>> logs, DateTime? newestWriteAtStart})
  >
  listAllOperations() async =>
      (logs: <String, List<SyncOperation>>{}, newestWriteAtStart: null);

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
  Stream<Map<String, Map<String, dynamic>>> watchCollection(
    String collection, {
    DateTime? changedSince,
  }) {
    return const Stream.empty();
  }

  @override
  Future<Map<String, dynamic>?> getDocument(
    String collection,
    String id,
  ) async => null;

  @override
  Future<List<({String id, Map<String, dynamic> data})>>
  listCollectionDocuments(String collection) async => const [];

  @override
  Future<
    ({
      List<({String id, Map<String, dynamic> data})> documents,
      DateTime? newestWrite,
      bool fromServer,
    })
  >
  listChangedDocuments(String collection, {DateTime? since}) async => (
    documents: const <({String id, Map<String, dynamic> data})>[],
    newestWrite: null,
    fromServer: false,
  );

  @override
  Future<Map<String, dynamic>?> getRemoteSettings() async => null;

  @override
  Future<void> upsertRemoteSettings(Map<String, dynamic> data) async {}

  @override
  Future<void> uploadSettings(AppSettings settings) async {}

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
