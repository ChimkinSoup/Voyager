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

  /// Runs every registered callback in turn.
  ///
  /// [perCallbackDeadline] bounds each one separately rather than the loop as a
  /// whole: a callback typically writes locally and then pushes the same
  /// document to Firestore, and that push can hang for as long as the server is
  /// unreachable. Without a per-callback bound, one such hang starves every
  /// callback behind it of the local write that is the part actually worth
  /// waiting for. The abandoned push keeps running on its own.
  Future<void> flushAll({Duration? perCallbackDeadline}) async {
    for (final callback in List<Future<void> Function()>.from(_callbacks)) {
      final flush = callback().catchError((_) {});
      if (perCallbackDeadline == null) {
        await flush;
      } else {
        await flush.timeout(perCallbackDeadline, onTimeout: () {});
      }
    }
  }
}
