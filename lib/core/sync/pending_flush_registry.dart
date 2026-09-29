import 'dart:async';

import 'package:flutter/foundation.dart';

/// Backup restores finished in this run. Raised once a restore has rewritten
/// the database, which remounts every shell page (see `app_router.dart`) so
/// none goes on showing — and saving — what it loaded before.
final restoreGeneration = ValueNotifier<int>(0);

/// Whether a backup restore has finished since this was made.
///
/// A page holds one and refuses to save once it is stale. Its old instance
/// still holds the pre-restore text, and the remount that replaces it runs
/// the old one's dispose and focus-loss flushes, which would write that text
/// straight back over the restore.
class RestoreFence {
  RestoreFence() : _generation = restoreGeneration.value;

  final int _generation;

  bool get isStale => _generation != restoreGeneration.value;
}

/// Bridges UI editing lifecycles with app-level termination safety.
///
/// Registered callbacks run before [RemoteSyncService.flushAllPending].
class PendingFlushRegistry {
  PendingFlushRegistry._();

  static final instance = PendingFlushRegistry._();

  final _callbacks = <Future<void> Function()>[];

  /// Set while a backup restore runs. [flushAll] does nothing meanwhile: the
  /// editors were flushed just before, so all a flush could still write is
  /// their pre-restore text, possibly after the restore has committed.
  bool restoring = false;

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
    if (restoring) return;
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
