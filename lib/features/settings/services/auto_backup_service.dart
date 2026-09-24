import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/features/settings/services/auto_backup_retention.dart';
import 'package:voyager/features/settings/services/data_export_service.dart';
import 'package:voyager/features/settings/services/data_import_service.dart';

/// The status row's health word — AUTO_BACKUP_HLD.md §9.3, evaluated in
/// declaration order.
enum AutoBackupHealth {
  backingUp,
  off,
  attention,
  notYetBackedUp,

  /// The newest backup is older than yesterday but the app has not been open
  /// since then: today's run is simply still due. Not an HLD row — the brief
  /// window between startup and the first check, which none of the others
  /// describe.
  due,
  healthy,
}

/// What the Settings status row shows (§9.2).
@immutable
class AutoBackupStatus {
  const AutoBackupStatus({
    required this.enabled,
    required this.backupCount,
    required this.snapshotCount,
    required this.totalBytes,
    required this.health,
    required this.detail,
    required this.failing,
  });

  final bool enabled;
  final int backupCount;
  final int snapshotCount;
  final int totalBytes;
  final AutoBackupHealth health;

  /// The second line: why, whenever [health] is not healthy.
  final String detail;

  /// No successful backup on the last two local days the app was open — the
  /// Inbox alert (§9.4).
  final bool failing;
}

/// One file in the backup list (§7.1).
@immutable
class BackupFileEntry {
  const BackupFileEntry({
    required this.file,
    required this.capturedAt,
    required this.isSnapshot,
    required this.bytes,
  });

  final File file;
  final DateTime capturedAt;

  /// A pre-restore snapshot (§7.2) rather than an automatic backup.
  final bool isSnapshot;
  final int bytes;
}

/// Takes one verified backup a day, keeps the §5 rotation, and guards
/// restores with a snapshot — AUTO_BACKUP_HLD.md.
///
/// `backups/state.json` holds the toggle and the last outcomes for the UI.
/// Retention never reads it: what to keep is decided from the directory alone.
class AutoBackupService extends ChangeNotifier {
  AutoBackupService({
    required Future<Directory> Function() directory,
    required DataExportService Function() exporter,
    required DataImportService Function() importer,
    required Future<int?> Function(String path) freeBytes,
    DateTime Function() now = DateTime.now,
  }) : _directory = directory,
       _exporter = exporter,
       _importer = importer,
       _freeBytes = freeBytes,
       _now = now;

  final Future<Directory> Function() _directory;
  final DataExportService Function() _exporter;
  final DataImportService Function() _importer;
  final Future<int?> Function(String path) _freeBytes;
  final DateTime Function() _now;

  static const _startupDelay = Duration(seconds: 30);
  static const _checkInterval = Duration(hours: 1);
  static const _snapshotLifetime = Duration(days: 7);
  static const _stateFileName = 'state.json';

  /// A retained backup that failed its re-check with damage is renamed with
  /// this suffix: out of the list and the rotation, but not deleted, in case
  /// the check was wrong.
  static const damagedSuffix = '.damaged';

  /// A retained backup in a format this build does not read is renamed with
  /// this suffix: kept for the build that made it, hidden from this one.
  static const unsupportedSuffix = '.unsupported';

  Timer? _startupTimer;
  Timer? _hourlyTimer;

  /// The run in progress, if any: the single-flight guard (§6.1), and what a
  /// snapshot waits behind so two exports never overlap.
  Future<void>? _running;

  /// Set while a restore runs, so a second one is refused rather than
  /// importing on top of the first.
  bool _restoring = false;

  /// Every `state.json` update runs behind the one before it, so two never
  /// read the same state and the second write loses the first's change.
  Future<void> _stateQueue = Future.value();

  AutoBackupStatus? _status;

  /// Null until the first read of the directory completes.
  AutoBackupStatus? get status => _status;

  /// Clears crash leftovers, renames backups still carrying the old UTC
  /// names, and schedules the checks: once shortly after startup, then hourly
  /// — which also covers a desktop left open past midnight, sleep, and
  /// time-zone changes.
  void start() {
    unawaited(
      _deletePartials()
          .then((_) => _renameLegacy())
          .then((_) => refreshStatus()),
    );
    _schedule();
  }

  void _schedule() {
    pause();
    _startupTimer = Timer(_startupDelay, () {
      unawaited(runIfDue());
      _hourlyTimer = Timer.periodic(_checkInterval, (_) => runIfDue());
    });
  }

  /// Android backs up only in the foreground (§6.1): the app calls this when
  /// it is paused, so a run never starts just before the OS freezes or kills
  /// the process, and a day spent in the background is not counted as a day
  /// the app was open.
  void pause() {
    _startupTimer?.cancel();
    _hourlyTimer?.cancel();
  }

  /// Back in the foreground: checks again shortly, then hourly.
  void resume() => _schedule();

  @override
  void dispose() {
    _startupTimer?.cancel();
    _hourlyTimer?.cancel();
    super.dispose();
  }

  /// `<app support>/backups`, created on first use.
  Future<Directory> backupsDirectory() async {
    final dir = await _directory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Gives backups named in the old UTC format their current name, so they
  /// stay listed and in the rotation. Never renames over an existing file.
  Future<void> _renameLegacy() async {
    final dir = await backupsDirectory();
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final renamed = legacyBackupRename(p.basename(entity.path));
      if (renamed == null) continue;
      final target = File(p.join(dir.path, renamed));
      if (!await target.exists()) await entity.rename(target.path);
    }
  }

  Future<void> _deletePartials() async {
    final dir = await backupsDirectory();
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.partial')) {
        await entity.delete();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // State file

  Future<Map<String, dynamic>> _readState() async {
    try {
      final file = File(
        p.join((await backupsDirectory()).path, _stateFileName),
      );
      if (!await file.exists()) return {};
      return Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
    } catch (_) {
      // A damaged state file reads as a missing one: toggle on, no history.
      return {};
    }
  }

  /// Written beside the file and renamed over it, so a crash mid-write
  /// leaves the old state rather than a truncated one. A leftover `.partial`
  /// is cleared on start like any other.
  Future<void> _writeState(Map<String, dynamic> state) async {
    final path = p.join((await backupsDirectory()).path, _stateFileName);
    final partial = File('$path.partial');
    await partial.writeAsString(jsonEncode(state), flush: true);
    await partial.rename(path);
  }

  Future<void> _updateState(void Function(Map<String, dynamic>) change) {
    final update = _stateQueue.then((_) async {
      final state = await _readState();
      change(state);
      await _writeState(state);
    });
    _stateQueue = update.then((_) {}, onError: (_) {});
    return update;
  }

  /// Dev page: make every run fail with a simulated error, so the failure
  /// path — status, Inbox alert, Retry — can be seen without breaking
  /// anything. Kept in `state.json`, so it survives a restart until turned off.
  Future<bool> simulatesFailure() async =>
      (await _readState())['debugSimulateFailure'] == true;

  /// Runs the check at once either way. Turning it off takes a real backup
  /// even if today already has one, so the simulated failure is superseded
  /// rather than left showing until tomorrow.
  Future<void> setSimulateFailure(bool value) async {
    await _updateState((s) => s['debugSimulateFailure'] = value);
    _forceNextRun = !value;
    await runIfDue();
  }

  /// Set by [setSimulateFailure] to run once despite today's backup.
  bool _forceNextRun = false;

  /// Turning it on runs the check at once rather than at the next tick.
  Future<void> setEnabled(bool enabled) async {
    await _updateState((s) => s['enabled'] = enabled);
    await refreshStatus();
    if (enabled) await runIfDue();
  }

  // ---------------------------------------------------------------------------
  // Listing

  /// Every automatic backup and pre-restore snapshot, newest first. Files
  /// whose names are not exactly ours are not listed, and so never touched.
  Future<List<BackupFileEntry>> listBackups() async {
    final dir = await backupsDirectory();
    final entries = <BackupFileEntry>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final auto = parseBackupTimestamp(name, autoBackupNamePattern);
      final snapshot = parseBackupTimestamp(name, preRestoreNamePattern);
      final capturedAt = auto ?? snapshot;
      if (capturedAt == null) continue;
      entries.add(
        BackupFileEntry(
          file: entity,
          capturedAt: capturedAt,
          isSnapshot: snapshot != null,
          bytes: await entity.length(),
        ),
      );
    }
    entries.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    return entries;
  }

  // ---------------------------------------------------------------------------
  // Daily run

  /// Takes today's backup if there is no verified one yet (§6.1), or
  /// finishes one whose re-check or pruning failed. Failures are recorded for
  /// the status row, never thrown.
  Future<void> runIfDue() {
    return _running ??= () async {
      final now = _now();
      try {
        await _runIfDue(now);
      } catch (error) {
        // Recording can fail too — a full disk is one reason a run fails —
        // and then there is nowhere left to report it.
        await _updateState((s) {
          s['lastAttemptFailed'] = true;
          s['lastFailureAt'] = _iso(now);
          s['lastFailureReason'] = _reason(error);
        }).then((_) {}, onError: (_) {});
      } finally {
        _running = null;
      }
      await refreshStatus().then((_) {}, onError: (_) {});
    }();
  }

  Future<void> _runIfDue(DateTime now) async {
    await _updateState((s) {
      final today = _dayKey(now);
      final opened = [...?(s['openedDays'] as List?)?.cast<String>()];
      if (opened.isEmpty || opened.last != today) opened.add(today);
      s['openedDays'] = opened.length > 10
          ? opened.sublist(opened.length - 10)
          : opened;
    });
    // Before the toggle: snapshots are taken with backups off, so they
    // expire with backups off too (§7.2).
    await _expireSnapshots(now);
    final state = await _readState();
    if (state['enabled'] == false) return;
    final simulateFailure = state['debugSimulateFailure'] == true;
    final force = _forceNextRun;
    _forceNextRun = false;

    final autos = (await listBackups()).where((e) => !e.isSnapshot).toList();
    final hasToday = autos.any((e) => backupAgeDays(e.capturedAt, now) == 0);
    // A backup from today whose run failed afterwards is finished — re-check
    // and prune — rather than joined by another, which would push an older
    // day out of the three dailies.
    if (!simulateFailure && !force && hasToday && !_lastAttemptFailed(state)) {
      return;
    }

    final status = _status;
    if (status != null) {
      _status = _withHealth(status, _backingUp);
      notifyListeners();
    }

    if (simulateFailure) {
      throw _BackupFailure('Simulated failure (Dev page)');
    }
    final dir = await backupsDirectory();
    File? fresh;
    if (force || !hasToday) {
      await _checkSpace(dir, autos);
      fresh = await _writeVerified(
        dir,
        '$autoBackupPrefix${backupTimestamp(now)}.zip',
      );
    }

    // Re-verified before pruning rather than after, so a file that fails is
    // out of the retention input and its tier refills from the next good
    // file instead of that file having already been pruned (§6.2 step 6).
    final damaged = <String>[];
    final unchecked = <String>[];
    final good = <DateTime, File>{};
    for (final entry in autos) {
      try {
        await verifyBackupFile(entry.file);
        good[entry.capturedAt] = entry.file;
      } on BackupVersionException {
        // Made by a build that reads another format. Nothing is wrong with
        // it, but this build cannot restore it, so it cannot hold a slot.
        await entry.file.rename('${entry.file.path}$unsupportedSuffix');
      } on BackupDamagedException {
        damaged.add(p.basename(entry.file.path));
        await entry.file.rename('${entry.file.path}$damagedSuffix');
      } catch (_) {
        // Could not be read just now — held open by a virus scanner or a ZIP
        // tool, or too big for memory. That says nothing about the file, so
        // it stays, and stays out of today's pruning.
        unchecked.add(p.basename(entry.file.path));
      }
    }
    if (fresh != null) {
      good[parseBackupTimestamp(
            p.basename(fresh.path),
            autoBackupNamePattern,
          )!] =
          fresh;
    }

    final keep = backupsToKeep(good.keys.toSet(), now);
    for (final entry in good.entries) {
      if (!keep.contains(entry.key)) await entry.value.delete();
    }
    // Recorded last, so a failure anywhere above shows as the last attempt
    // failing instead of hiding behind this success.
    await _updateState((s) {
      s['lastAttemptFailed'] = false;
      s['lastSuccessAt'] = _iso(now);
      s['lastRecheckAt'] = _iso(now);
      s['recheckDamaged'] = damaged;
      s['recheckUnchecked'] = unchecked;
    });
  }

  /// Deletes pre-restore snapshots past their lifetime (§7.2). One that
  /// cannot be deleted now is left for the next check.
  Future<void> _expireSnapshots(DateTime now) async {
    for (final entry in await listBackups()) {
      if (!entry.isSnapshot) continue;
      if (now.difference(entry.capturedAt) <= _snapshotLifetime) continue;
      try {
        await entry.file.delete();
      } on FileSystemException {
        // Held open elsewhere; tried again within the hour.
      }
    }
  }

  /// Refuses to start without room for roughly two backups' worth (§6.3).
  /// Old backups are never deleted to make room.
  Future<void> _checkSpace(Directory dir, List<BackupFileEntry> autos) async {
    if (autos.isEmpty) return;
    final needed = autos.first.bytes * 2;
    final free = await _freeBytes(dir.path);
    if (free != null && free < needed) {
      throw _BackupFailure(
        'Not enough free space (needs ${formatBackupBytes(needed)})',
      );
    }
  }

  /// Writes a backup under a temporary name, proves this build can restore
  /// it, then gives it [name] (§6.2). Leaves nothing behind on failure.
  Future<File> _writeVerified(Directory dir, String name) async {
    final partial = File(p.join(dir.path, '$name.partial'));
    try {
      await _exporter().exportDataToZip(partial);
      await verifyBackupFile(partial);
      // Names are unique to the second, but a rename replaces whatever it
      // lands on — on Windows too — so a clash must not reach it.
      final target = File(p.join(dir.path, name));
      if (await target.exists()) {
        throw _BackupFailure('A backup named $name already exists');
      }
      return await partial.rename(target.path);
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Restore

  /// Restores [backup] behind a verified snapshot of the current state
  /// (§7.2). If [backup] is damaged, or the snapshot cannot be taken, nothing
  /// is touched and this throws.
  Future<BackupImportSummary> restore(File backup) async {
    if (_restoring) throw _BackupFailure('A restore is already running');
    _restoring = true;
    try {
      await verifyBackupFile(backup);
      final dir = await backupsDirectory();
      // No await between the wait ending and [_running] being claimed, so a
      // daily run cannot slip in and export alongside the snapshot.
      while (_running != null) {
        await _running;
      }
      final snapshot = _writeVerified(
        dir,
        '$preRestorePrefix${backupTimestamp(_now())}.zip',
      );
      _running = snapshot.then<void>((_) {}, onError: (_) {});
      try {
        await snapshot;
      } finally {
        _running = null;
      }
      return await _importer().importFromZip(backup);
    } finally {
      _restoring = false;
      await refreshStatus();
    }
  }

  // ---------------------------------------------------------------------------
  // Status

  static const _backingUp = (
    AutoBackupHealth.backingUp,
    "Taking today's backup",
  );

  AutoBackupStatus _withHealth(
    AutoBackupStatus status,
    (AutoBackupHealth, String) health,
  ) => AutoBackupStatus(
    enabled: status.enabled,
    backupCount: status.backupCount,
    snapshotCount: status.snapshotCount,
    totalBytes: status.totalBytes,
    health: health.$1,
    detail: health.$2,
    failing: status.failing,
  );

  /// Re-reads the directory and state file. Never computes health from
  /// anything else.
  Future<AutoBackupStatus> refreshStatus() async {
    final now = _now();
    final state = await _readState();
    final entries = await listBackups();
    final autos = entries.where((e) => !e.isSnapshot).toList();
    final enabled = state['enabled'] != false;

    final lastSuccess = _parse(state['lastSuccessAt']);
    final lastAttemptFailed = _lastAttemptFailed(state);
    final damaged = [...?(state['recheckDamaged'] as List?)];
    final unchecked = [...?(state['recheckUnchecked'] as List?)];
    final opened = [...?(state['openedDays'] as List?)?.cast<String>()];
    final newest = autos.isEmpty ? null : autos.first.capturedAt;
    final todayKey = _dayKey(now);

    // An open day after the newest backup and before today: the app ran then
    // and still did not back up.
    final missedDay =
        newest != null &&
        opened.any(
          (d) =>
              d.compareTo(_dayKey(newest.toLocal())) > 0 &&
              d.compareTo(todayKey) < 0,
        );

    final autoDays = {for (final e in autos) _dayKey(e.capturedAt.toLocal())};
    final lastTwo = opened.length < 2
        ? const <String>[]
        : opened.sublist(opened.length - 2);
    // The simulation stands in for the two failed days, so the alert shows
    // as soon as the first simulated run fails.
    final failing =
        enabled &&
        lastAttemptFailed &&
        (state['debugSimulateFailure'] == true ||
            lastTwo.length == 2 && lastTwo.every((d) => !autoDays.contains(d)));

    final (AutoBackupHealth, String) health;
    if (_running != null) {
      health = _backingUp;
    } else if (!enabled) {
      health = (
        AutoBackupHealth.off,
        'Automatic backups are off · '
            '${newest == null ? 'no backups yet' : 'last backup ${_ago(newest, now)}'}',
      );
    } else if (lastAttemptFailed) {
      health = (
        AutoBackupHealth.attention,
        state['lastFailureReason'] as String? ?? 'The last backup failed',
      );
    } else if (damaged.isNotEmpty) {
      health = (
        AutoBackupHealth.attention,
        '${damaged.length} backup(s) failed re-verification and were set '
            'aside',
      );
    } else if (unchecked.isNotEmpty) {
      health = (
        AutoBackupHealth.attention,
        '${unchecked.length} backup(s) could not be re-checked',
      );
    } else if (missedDay) {
      health = (
        AutoBackupHealth.attention,
        'No backup since ${_ago(newest, now)}',
      );
    } else if (newest == null && lastSuccess == null) {
      health = (
        AutoBackupHealth.notYetBackedUp,
        'First backup runs shortly after startup',
      );
    } else if (newest != null && backupAgeDays(newest, now) <= 1) {
      health = (
        AutoBackupHealth.healthy,
        'Last backup ${_describeTime(newest, now)}, verified',
      );
    } else {
      health = (AutoBackupHealth.due, "Today's backup runs shortly");
    }

    final status = AutoBackupStatus(
      enabled: enabled,
      backupCount: autos.length,
      snapshotCount: entries.length - autos.length,
      totalBytes: entries.fold(0, (sum, e) => sum + e.bytes),
      health: health.$1,
      detail: health.$2,
      failing: failing,
    );
    _status = status;
    notifyListeners();
    return status;
  }
}

class _BackupFailure implements Exception {
  _BackupFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

String _reason(Object error) => switch (error) {
  _BackupFailure(:final message) => message,
  BackupFormatException(:final message) => 'Verification failed: $message',
  FileSystemException(:final message, :final osError) =>
    'Could not write the backup: ${osError?.message ?? message}',
  _ => 'Backup failed: $error',
};

String _iso(DateTime time) => time.toUtc().toIso8601String();

/// Whether the last run failed. A flag rather than a comparison of
/// `lastFailureAt` with `lastSuccessAt`, which cannot order two stamped the
/// same instant.
bool _lastAttemptFailed(Map<String, dynamic> state) =>
    state['lastAttemptFailed'] == true;

DateTime? _parse(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// `2026-09-24` for [time]'s local date — sorts the same as the dates.
String _dayKey(DateTime time) {
  final t = time.toLocal();
  return '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

String _ago(DateTime capturedAt, DateTime now) {
  final age = backupAgeDays(capturedAt, now);
  return switch (age) {
    <= 0 => 'today',
    1 => 'yesterday',
    _ => '$age days ago',
  };
}

String _hhmm(DateTime time) {
  final t = time.toLocal();
  return '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

/// "today 09:14", "yesterday 22:30", "3 days ago 08:00".
String _describeTime(DateTime capturedAt, DateTime now) =>
    '${_ago(capturedAt, now)} ${_hhmm(capturedAt)}';

/// The list's age label (§7.1): "Yesterday", "3 days ago",
/// "Weekly · 9 days ago", "Monthly · 34 days ago", "Before restore · today
/// 14:02".
String backupAgeLabel(BackupFileEntry entry, DateTime now) {
  final age = backupAgeDays(entry.capturedAt, now);
  if (entry.isSnapshot) {
    return 'Before restore · ${_describeTime(entry.capturedAt, now)}';
  }
  final ago = _ago(entry.capturedAt, now);
  final label = '${ago[0].toUpperCase()}${ago.substring(1)}';
  if (age >= retentionTiers[1]) return 'Monthly · $ago';
  if (age >= retentionTiers[0]) return 'Weekly · $ago';
  return label;
}

String formatBackupBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// The manifest of the backup at [file], for the list's record counts. Read
/// off the UI isolate; does not verify — [verifyBackupFile] does that.
Future<Map<String, dynamic>> readBackupManifest(File file) {
  return compute(_readManifestIsolate, file.path);
}

/// Reads the ZIP's directory and the manifest alone from disk rather than
/// the whole archive, so listing seven backups does not load seven of them.
Map<String, dynamic> _readManifestIsolate(String path) {
  final input = InputFileStream(path);
  try {
    final manifest = ZipDecoder()
        .decodeBuffer(input)
        .findFile(backupManifestFileName);
    if (manifest == null) return const {};
    return Map<String, dynamic>.from(
      jsonDecode(utf8.decode(manifest.content as List<int>)) as Map,
    );
  } finally {
    input.closeSync();
  }
}
