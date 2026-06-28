import 'dart:async';

/// Bridges UI editing lifecycles with app-level termination safety.
///
/// Registered callbacks run before [RemoteSyncService.flushAllPending].
class PendingFlushRegistry {
  PendingFlushRegistry._();

  static final instance = PendingFlushRegistry._();

  final _callbacks = <Future<void> Function()>[];

  void register(Future<void> Function() callback) {
    if (!_callbacks.contains(callback)) {
      _callbacks.add(callback);
    }
  }

  void unregister(Future<void> Function() callback) {
    _callbacks.remove(callback);
  }

  Future<void> flushAll() async {
    for (final callback in List<Future<void> Function()>.from(_callbacks)) {
      await callback().catchError((_) {});
    }
  }
}
