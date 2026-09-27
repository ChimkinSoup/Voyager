import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voyager/core/dev/error_logger.dart';

/// Where Voyager keeps its database, media and state files: the app-support
/// directory (`%APPDATA%\Voyager\voyager` on Windows).
///
/// They used to live in Documents, which Known Folder Move often redirects to
/// OneDrive, and cloud-syncing a live SQLite file corrupts it. The first call
/// moves anything still there. Logs stay in Documents, where they're easy to
/// find.
Future<Directory> appDataDirectory() => _resolved ??= _resolve();
Future<Directory>? _resolved;

@visibleForTesting
void resetAppDataDirectory() => _resolved = null;

/// Whether [appDataDirectory] still has something to move, so startup can
/// show that it's working rather than sit with no window.
Future<bool> appDataMovePending() async {
  final target = await getApplicationSupportDirectory();
  final documents = await getApplicationDocumentsDirectory();
  if (Platform.isWindows &&
      await Directory(_legacyCompanyPath(target)).exists()) {
    return true;
  }
  for (final name in [_database, ..._movedEntries]) {
    final from = p.join(documents.path, name);
    if (await Directory(from).exists()) return true;
    if (await File(from).exists() &&
        !await File(p.join(target.path, name)).exists()) {
      return true;
    }
  }
  return false;
}

/// Until CompanyName was set in Runner.rc, the support directory was
/// com.example\voyager beside this one. Auto-backups were already there.
String _legacyCompanyPath(Directory target) =>
    p.join(p.dirname(p.dirname(target.path)), 'com.example');

const _database = 'voyager.sqlite';

/// SQLite's sidecars, moved with the database so no committed write is lost.
const _databaseSidecars = [
  'voyager.sqlite-wal',
  'voyager.sqlite-shm',
  'voyager.sqlite-journal',
];

const _movedEntries = [
  'media',
  'session_checkpoints',
  'finance_ui_prefs.json',
  'quick_journal_entry.json',
  'jobs_track_draft.json',
  'leetcode_track_draft.json',
];

/// Windows can't rename across volumes, e.g. when Documents is on another
/// drive. Those entries are copied instead.
const _errorNotSameDevice = 17;

Future<Directory> _resolve() async {
  final target = await getApplicationSupportDirectory();
  final documents = await getApplicationDocumentsDirectory();

  if (Platform.isWindows) {
    final legacyCompany = _legacyCompanyPath(target);
    await _moveEntry(p.join(legacyCompany, 'voyager'), target.path);
    try {
      await _deleteIfEmpty(Directory(legacyCompany));
    } catch (error, stack) {
      ErrorLogger.instance.record(
        error,
        stack,
        context: 'Deleting $legacyCompany',
      );
    }
  }

  final oldDatabase = p.join(documents.path, _database);
  final newDatabase = p.join(target.path, _database);
  if (await File(oldDatabase).exists() && !await File(newDatabase).exists()) {
    // The database and its sidecars move together or not at all: a database
    // opened without its WAL silently loses the writes still in it.
    final moved = <String>[];
    try {
      for (final name in [_database, ..._databaseSidecars]) {
        final from = File(p.join(documents.path, name));
        if (!await from.exists()) continue;
        await _moveFile(from, p.join(target.path, name));
        moved.add(name);
      }
    } catch (error, stack) {
      // Most likely another Voyager has it open. Stay in Documents this run,
      // rather than start on an empty database, and try again next launch.
      ErrorLogger.instance.record(
        error,
        stack,
        context: 'Moving the database out of Documents',
      );
      for (final name in moved.reversed) {
        try {
          await _moveFile(
            File(p.join(target.path, name)),
            p.join(documents.path, name),
          );
        } catch (error, stack) {
          ErrorLogger.instance.record(
            error,
            stack,
            context: 'Moving $name back to Documents',
          );
        }
      }
      // Unless the database itself couldn't go back: then it's used here.
      if (!await File(newDatabase).exists()) return documents;
    }
  }

  for (final name in _movedEntries) {
    await _moveEntry(p.join(documents.path, name), p.join(target.path, name));
  }
  return target;
}

/// Moves a file, or merges a directory file by file, never overwriting what's
/// already at [to]; a file already there with the same bytes, such as a
/// media blob (named by its hash), is just dropped from [from]. A failure is
/// logged and leaves that file for next launch.
Future<void> _moveEntry(String from, String to) async {
  try {
    if (await File(from).exists()) {
      if (!await File(to).exists()) {
        await _moveFile(File(from), to);
      } else if (await _sameBytes(File(from), File(to))) {
        await File(from).delete();
      }
      return;
    }
    final dir = Directory(from);
    if (!await dir.exists()) return;
    await Directory(to).create(recursive: true);
    for (final child in await dir.list().toList()) {
      await _moveEntry(child.path, p.join(to, p.basename(child.path)));
    }
    await _deleteIfEmpty(dir);
  } catch (error, stack) {
    ErrorLogger.instance.record(error, stack, context: 'Moving $from to $to');
  }
}

Future<void> _moveFile(File from, String to) async {
  try {
    await from.rename(to);
  } on FileSystemException catch (error) {
    if (error.osError?.errorCode != _errorNotSameDevice) rethrow;
    await from.copy(to);
    try {
      await from.delete();
    } catch (_) {
      // Left in both places, the copy would pass for the moved file next
      // launch while [from] is still the one in use.
      await File(to).delete();
      rethrow;
    }
  }
}

Future<bool> _sameBytes(File a, File b) async {
  if (await a.length() != await b.length()) return false;
  return listEquals(await a.readAsBytes(), await b.readAsBytes());
}

Future<void> _deleteIfEmpty(Directory dir) async {
  if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
}
