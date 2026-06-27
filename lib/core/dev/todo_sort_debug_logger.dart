import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';

const _logFileName = 'todo_sort_debug.log';
const _maxLogBytes = 2 * 1024 * 1024;

/// Persists a rolling text log of todo list state and sort-related mutations.
class TodoSortDebugLogger extends ChangeNotifier {
  TodoSortDebugLogger({
    SettingsRepository? settingsRepository,
    TodoRepository? todoRepository,
  })  : _settingsRepository = settingsRepository,
        _todoRepository = todoRepository;

  final SettingsRepository? _settingsRepository;
  final TodoRepository? _todoRepository;

  bool enabled = false;
  Future<void>? _writeChain = Future<void>.value();

  Future<void> loadFromSettings() async {
    final repo = _settingsRepository;
    if (repo == null) return;
    final settings = await repo.getSettings();
    applySettings(settings);
  }

  void applySettings(AppSettings settings) {
    if (enabled == settings.devTodoSortDebugLog) return;
    enabled = settings.devTodoSortDebugLog;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (enabled == value) return;
    enabled = value;
    notifyListeners();

    final repo = _settingsRepository;
    if (repo != null) {
      final settings = await repo.getSettings();
      await repo.saveSettings(settings.copyWith(devTodoSortDebugLog: value));
    }

    if (value) {
      await _enqueue(() async {
        await _append(
          'LOG_ENABLED',
          details: 'Todo sort debug logging started.',
        );
      });
    } else {
      await _enqueue(() async {
        await _append('LOG_DISABLED', details: 'Todo sort debug logging stopped.');
      });
    }
  }

  Future<String> logFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _logFileName);
  }

  Future<String> readLog() async {
    final file = File(await logFilePath());
    if (!await file.exists()) return '';
    return file.readAsString();
  }

  Future<void> clearLog() async {
    final file = File(await logFilePath());
    if (await file.exists()) {
      await file.writeAsString('');
    }
    if (enabled) {
      await _enqueue(() async {
        await _append('LOG_CLEARED', details: 'Log file cleared.');
      });
    }
  }

  Future<void> recordEvent(
    String event, {
    TodoTask? task,
    String? details,
  }) async {
    if (!enabled) return;
    await _enqueue(() async {
      await _append(event, task: task, details: details);
    });
  }

  Future<void> _append(
    String event, {
    TodoTask? task,
    String? details,
  }) async {
    final repo = _todoRepository;
    if (repo == null) return;

    final timestamp = DateTime.now().toUtc().toIso8601String();
    final buffer = StringBuffer()
      ..writeln('=' * 80)
      ..writeln('$timestamp | $event');

    if (task != null) {
      buffer.writeln(_formatTaskHeader(task));
    }
    if (details != null && details.isNotEmpty) {
      buffer.writeln(details);
    }

    buffer.writeln('-' * 80);
    buffer.write(await _formatAllListsSnapshot(repo));
    buffer.writeln('=' * 80);
    buffer.writeln();

    final entry = buffer.toString();
    debugPrint('[todo-sort-debug]\n$entry');

    final file = File(await logFilePath());
    await _trimIfNeeded(file);
    await file.writeAsString(entry, mode: FileMode.append, flush: true);
  }

  Future<void> _trimIfNeeded(File file) async {
    if (!await file.exists()) return;
    final length = await file.length();
    if (length <= _maxLogBytes) return;

    final content = await file.readAsString();
    final trimmed = content.substring(content.length - (_maxLogBytes ~/ 2));
    final nextIndex = trimmed.indexOf('=' * 80);
    final kept = nextIndex >= 0 ? trimmed.substring(nextIndex) : trimmed;
    await file.writeAsString(
      '... log truncated ...\n$kept',
      flush: true,
    );
  }

  Future<String> _formatAllListsSnapshot(TodoRepository repo) async {
    final lists = await repo.listLists();
    final buffer = StringBuffer()
      ..writeln('ALL LISTS SNAPSHOT (${lists.length} lists)');

    for (final list in lists) {
      final tasks = await repo.listTasks(list.id, topLevelOnly: false);
      final topLevel = tasks.where((t) => !t.isSubtask).toList();
      final active = sortTodoTasks(topLevel.where((t) => !t.completed));
      final completed = sortTodoTasks(topLevel.where((t) => t.completed));
      final subtasks = tasks.where((t) => t.isSubtask).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      buffer.writeln('');
      buffer.writeln('List "${list.name}" (${list.id})');
      buffer.writeln(
        '  totals: active=${active.length} completed=${completed.length} '
        'subtasks=${subtasks.length}',
      );

      if (active.isNotEmpty) {
        buffer.writeln('  ACTIVE (display order):');
        for (var i = 0; i < active.length; i++) {
          buffer.writeln('    ${_formatTaskLine(i, active[i])}');
        }
      }

      if (completed.isNotEmpty) {
        buffer.writeln('  COMPLETED:');
        for (var i = 0; i < completed.length; i++) {
          buffer.writeln('    ${_formatTaskLine(i, completed[i])}');
        }
      }

      if (subtasks.isNotEmpty) {
        buffer.writeln('  SUBTASKS:');
        for (final subtask in subtasks) {
          buffer.writeln(
            '    parent=${subtask.parentTaskId} '
            '${_formatTaskLine(-1, subtask)}',
          );
        }
      }
    }

    return buffer.toString();
  }

  String _formatTaskHeader(TodoTask task) {
    return 'Task id=${task.id} title="${task.title}" listId=${task.listId}';
  }

  String _formatTaskLine(int index, TodoTask task) {
    final prefix = index >= 0 ? '[$index]' : '[—]';
    final star = task.starred ? '★' : ' ';
    final due = task.dueDate != null
        ? 'due=${task.dueDate!.toUtc().toIso8601String()}'
        : 'undated';
    final dueSet = task.dueDateSetAt != null
        ? ' dueSet=${task.dueDateSetAt!.toUtc().toIso8601String()}'
        : '';
    final preStar = task.preStarSortOrder != null
        ? ' preStar=${task.preStarSortOrder}'
        : '';
    final completed = task.completed ? ' done' : '';
    return '$prefix $star id=${task.id} sort=${task.sortOrder} $due$dueSet$preStar'
        '$completed title="${task.title}"';
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _writeChain = _writeChain!.then((_) => action());
    return _writeChain!;
  }
}

void logTodoSortDebug(
  TodoSortDebugLogger? logger,
  String event, {
  TodoTask? task,
  String? details,
}) {
  if (logger == null || !logger.enabled) return;
  unawaited(logger.recordEvent(event, task: task, details: details));
}
