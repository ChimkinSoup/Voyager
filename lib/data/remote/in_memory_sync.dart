import 'dart:async';

import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class InMemoryAuthRepository implements AuthRepository {
  InMemoryAuthRepository() {
    _controller.onListen = () {
      if (!_hasEmitted) {
        _hasEmitted = true;
        _controller.add(_userId != null);
      }
    };
  }

  final _controller = StreamController<bool>.broadcast();
  String? _userId;
  var _hasEmitted = false;

  @override
  Stream<bool> get authStateChanges => _controller.stream;

  @override
  String? get currentUserId => _userId;

  @override
  Future<void> signInWithEmail(String email, String password) async {
    _userId = 'email:$email';
    _controller.add(true);
  }

  @override
  Future<void> signUpWithEmail(String email, String password) async {
    _userId = 'email:$email';
    _controller.add(true);
  }

  @override
  Future<void> signInWithGoogle() async {
    _userId = 'google:user';
    _controller.add(true);
  }

  @override
  Future<void> signOut() async {
    _userId = null;
    _controller.add(false);
  }

  void dispose() => _controller.close();
}

class InMemorySyncRepository implements SyncRepository {
  final _documents = <String, Map<String, dynamic>>{};
  final _watchers = <String, StreamController<Map<String, dynamic>>>{};
  final _collectionWatchers = <String, StreamController<void>>{};
  final _operations = <String, List<SyncOperation>>{};
  GoogleCalendarSyncLock? _calendarLock;

  String _key(String collection, String id) => '$collection/$id';

  void _notifyCollection(String collection) {
    final controller = _collectionWatchers[collection];
    if (controller != null && !controller.isClosed) {
      controller.add(null);
    }
  }

  @override
  Future<void> upsertDocument(String collection, String id, Map<String, dynamic> data) async {
    final key = _key(collection, id);
    _documents[key] = data;
    _watchers[key]?.add(data);
    _notifyCollection(collection);
  }

  @override
  Stream<Map<String, dynamic>> watchDocument(String collection, String id) {
    final key = _key(collection, id);
    final controller = _watchers.putIfAbsent(key, StreamController<Map<String, dynamic>>.broadcast);
    if (_documents.containsKey(key)) {
      controller.add(_documents[key]!);
    }
    return controller.stream;
  }

  @override
  Stream<void> watchCollection(String collection) {
    final controller = _collectionWatchers.putIfAbsent(collection, StreamController<void>.broadcast);
    return controller.stream;
  }

  @override
  Future<GoogleCalendarSyncLock?> getCalendarLock() async => _calendarLock;

  @override
  Future<bool> claimCalendarLock(GoogleCalendarSyncLock lock) async {
    final now = DateTime.now().toUtc();
    if (_calendarLock == null || now.isAfter(_calendarLock!.expiresAt)) {
      _calendarLock = lock;
      return true;
    }
    if (_calendarLock!.deviceId == lock.deviceId) {
      _calendarLock = lock;
      return true;
    }
    return false;
  }

  @override
  Future<void> releaseCalendarLock(String deviceId) async {
    if (_calendarLock?.deviceId == deviceId) {
      _calendarLock = null;
    }
  }

  @override
  Future<void> appendOperation(SyncOperation operation) async {
    _operations.putIfAbsent(operation.documentId, () => []).add(operation);
  }

  @override
  Future<List<SyncOperation>> listOperations(String documentId) async {
    return List.unmodifiable(_operations[documentId] ?? const []);
  }
}
