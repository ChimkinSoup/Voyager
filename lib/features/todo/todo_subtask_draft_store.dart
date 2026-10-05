import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';

/// Unsubmitted "Add subtask" text, one slot per parent task, kept on this
/// device only.
///
/// Same reasoning as the jobs and LeetCode track draft stores: a draft never
/// syncs and never appears in a list, so it lives in a file rather than a
/// Drift table.
abstract class TodoSubtaskDraftStore {
  /// The draft typed for [taskId], or null when there is none.
  Future<String?> load(String taskId);

  /// Replaces [taskId]'s draft; blank [text] removes it.
  void save(String taskId, String text);
}

const _draftsFileName = 'todo_subtask_drafts.json';

class FileTodoSubtaskDraftStore implements TodoSubtaskDraftStore {
  /// [directory] defaults to [appDataDirectory] — the same place
  /// the database lives. Tests point it somewhere temporary.
  FileTodoSubtaskDraftStore({Future<Directory> Function()? directory})
    : _directory = directory ?? appDataDirectory;

  final Future<Directory> Function() _directory;

  /// Read once, then kept: [save] runs on every keystroke and only the file
  /// write behind it is asynchronous.
  Future<Map<String, String>>? _drafts;

  /// Writes are chained so an older snapshot can never land after a newer one.
  Future<void> _chain = Future<void>.value();

  /// Set while a write is queued but hasn't started. That write serialises the
  /// map when it runs, so keystrokes in the meantime ride along with it rather
  /// than each queueing a file write of their own.
  bool _writeQueued = false;

  Future<File> _file() async {
    final dir = await _directory();
    return File(p.join(dir.path, _draftsFileName));
  }

  Future<Map<String, String>> _loaded() => _drafts ??= () async {
    try {
      final file = await _file();
      if (!await file.exists()) return <String, String>{};
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return <String, String>{};
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (error) {
      // Unreadable — start empty; the next save overwrites it.
      debugPrint('Subtask drafts could not be read: $error');
      return <String, String>{};
    }
  }();

  @override
  Future<String?> load(String taskId) async => (await _loaded())[taskId];

  @override
  void save(String taskId, String text) {
    unawaited(
      _loaded().then((drafts) {
        if (text.trim().isEmpty) {
          if (drafts.remove(taskId) == null) return;
        } else {
          if (drafts[taskId] == text) return;
          drafts[taskId] = text;
        }
        _queueWrite(drafts);
      }),
    );
  }

  void _queueWrite(Map<String, String> drafts) {
    if (_writeQueued) return;
    _writeQueued = true;
    _chain = _chain.then((_) async {
      _writeQueued = false;
      try {
        final file = await _file();
        await file.writeAsString(jsonEncode(drafts), flush: true);
      } catch (error) {
        // A draft that can't be written is a convenience lost, never an error
        // worth interrupting typing for.
        debugPrint('Subtask drafts could not be saved: $error');
      }
    });
  }
}

/// In-memory slots, for tests.
class MemoryTodoSubtaskDraftStore implements TodoSubtaskDraftStore {
  final drafts = <String, String>{};

  @override
  Future<String?> load(String taskId) async => drafts[taskId];

  @override
  void save(String taskId, String text) {
    if (text.trim().isEmpty) {
      drafts.remove(taskId);
    } else {
      drafts[taskId] = text;
    }
  }
}

final todoSubtaskDraftStoreProvider = Provider<TodoSubtaskDraftStore>(
  (ref) => FileTodoSubtaskDraftStore(),
);
