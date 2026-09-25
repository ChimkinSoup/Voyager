import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voyager/core/dev/error_logger.dart';
import 'package:voyager/core/session_resume/session_checkpoint.dart';

/// Every unfinished Study or Cram run this device is holding, one slot per
/// kind and scope.
///
/// The same contract the Track and scratch drafts keep: device-local JSON,
/// never synced, and a slot that cannot be read is treated as empty rather
/// than as an error.
abstract class SessionCheckpointStore {
  /// The checkpoint for this slot, or null when there is none. A file that
  /// cannot be read is discarded and reported as none.
  Future<SessionCheckpoint?> load(SessionCheckpointKind kind, String scopeKey);

  Future<void> save(SessionCheckpoint checkpoint);

  Future<void> clear(SessionCheckpointKind kind, String scopeKey);
}

const _checkpointDirName = 'session_checkpoints';

class FileSessionCheckpointStore implements SessionCheckpointStore {
  /// [directory] defaults to the app's documents directory — the same place
  /// the database lives. Tests point it somewhere temporary.
  FileSessionCheckpointStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _directory;

  /// Writes are chained rather than fired in parallel: a dispose flush and a
  /// still-pending debounce can both land on the same slot, and the later one
  /// has to win. Reads join the same chain so a load never sees a half file.
  Future<void> _chain = Future<void>.value();

  Future<File> _file(SessionCheckpointKind kind, String scopeKey) async {
    final dir = Directory(
      p.join((await _directory()).path, _checkpointDirName),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, _slot(kind, scopeKey)));
  }

  /// Scope keys carry deck ids, so they are already tame — but a name is a
  /// path component and nothing else is allowed to decide that.
  static String _slot(SessionCheckpointKind kind, String scopeKey) {
    final scope = scopeKey.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return scope.isEmpty ? '${kind.name}.json' : '${kind.name}__$scope.json';
  }

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final result = _chain.then((_) => op());
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<SessionCheckpoint?> load(
    SessionCheckpointKind kind,
    String scopeKey,
  ) => _enqueue(() async {
    try {
      final file = await _file(kind, scopeKey);
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      return SessionCheckpoint.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (error, stackTrace) {
      // Unreadable or from another schema — drop it and open a clean session.
      debugPrint('Session checkpoint could not be read: $error');
      ErrorLogger.instance.record(
        error,
        stackTrace,
        context: 'session checkpoint read',
      );
      await _deleteQuietly(kind, scopeKey);
      return null;
    }
  });

  @override
  Future<void> save(SessionCheckpoint checkpoint) => _enqueue(() async {
    try {
      final file = await _file(checkpoint.kind, checkpoint.scopeKey);
      await file.writeAsString(jsonEncode(checkpoint.toJson()), flush: true);
    } catch (error, stackTrace) {
      // A checkpoint that cannot be written is a resume lost, never an error
      // worth interrupting a review session for.
      debugPrint('Session checkpoint could not be saved: $error');
      ErrorLogger.instance.record(
        error,
        stackTrace,
        context: 'session checkpoint save',
      );
    }
  });

  @override
  Future<void> clear(SessionCheckpointKind kind, String scopeKey) =>
      _enqueue(() => _deleteQuietly(kind, scopeKey));

  Future<void> _deleteQuietly(
    SessionCheckpointKind kind,
    String scopeKey,
  ) async {
    try {
      final file = await _file(kind, scopeKey);
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('Session checkpoint could not be cleared: $error');
    }
  }
}

/// In-memory slots, for tests and for any build where the platform has no
/// documents directory to write to.
class MemorySessionCheckpointStore implements SessionCheckpointStore {
  final checkpoints = <String, SessionCheckpoint>{};

  static String _slot(SessionCheckpointKind kind, String scopeKey) =>
      '${kind.name}__$scopeKey';

  @override
  Future<SessionCheckpoint?> load(
    SessionCheckpointKind kind,
    String scopeKey,
  ) async => checkpoints[_slot(kind, scopeKey)];

  @override
  Future<void> save(SessionCheckpoint checkpoint) async =>
      checkpoints[_slot(checkpoint.kind, checkpoint.scopeKey)] = checkpoint;

  @override
  Future<void> clear(SessionCheckpointKind kind, String scopeKey) async =>
      checkpoints.remove(_slot(kind, scopeKey));
}

final sessionCheckpointStoreProvider = Provider<SessionCheckpointStore>(
  (ref) => FileSessionCheckpointStore(),
);
