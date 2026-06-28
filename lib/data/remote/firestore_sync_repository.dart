import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/weather_forecast_merge.dart';

class FirestoreSyncRepository implements SyncRepository {
  FirestoreSyncRepository(this._firestore, this._userId);

  final FirebaseFirestore _firestore;
  final String _userId;

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
    await _doc(collection, id).set(data, SetOptions(merge: true));
  }

  @override
  Stream<Map<String, dynamic>> watchDocument(String collection, String id) {
    return _doc(collection, id).snapshots().map((snap) {
      if (!snap.exists || snap.data() == null) return <String, dynamic>{};
      return snap.data()!;
    });
  }

  @override
  Stream<void> watchCollection(String collection) {
    return _collection(collection).snapshots().map((_) {});
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
    await _settingsDoc.set(data, SetOptions(merge: true));
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
    return _firestore.runTransaction((txn) async {
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
    return _firestore.runTransaction((txn) async {
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
    await _firestore
        .doc('users/$_userId/weather/current')
        .set(weather.toJson(), SetOptions(merge: true));
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

  @override
  Future<void> appendOperation(SyncOperation operation) async {
    await _doc('sync_operations', operation.id).set({
      'id': operation.id,
      'documentId': operation.documentId,
      'sequence': operation.sequence,
      'payload': operation.payload,
      'deviceId': operation.deviceId,
      'timestamp': operation.timestamp.toUtc().toIso8601String(),
    });
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
    await _doc(collection, id).delete();
  }

  @override
  Future<int> deleteOperationsForDocument(String documentId) async {
    final query = await _collection(
      'sync_operations',
    ).where('documentId', isEqualTo: documentId).get();
    if (query.docs.isEmpty) return 0;

    const batchSize = 500;
    var deleted = 0;
    for (var i = 0; i < query.docs.length; i += batchSize) {
      final batch = _firestore.batch();
      for (final doc in query.docs.skip(i).take(batchSize)) {
        batch.delete(doc.reference);
        deleted++;
      }
      await batch.commit();
    }
    return deleted;
  }
}

class NoOpSyncRepository implements SyncRepository {
  @override
  Future<void> appendOperation(SyncOperation operation) async {}

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
  Stream<void> watchCollection(String collection) {
    return const Stream.empty();
  }

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
  Future<void> deleteDocument(String collection, String id) async {}

  @override
  Future<int> deleteOperationsForDocument(String documentId) async => 0;
}
