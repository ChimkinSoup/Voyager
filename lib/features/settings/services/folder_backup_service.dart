import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/features/settings/services/auto_backup_retention.dart';
import 'package:voyager/features/settings/services/folder_backup_archive.dart';
import 'package:voyager/features/settings/services/folder_backup_retention.dart';

export 'package:voyager/features/settings/services/folder_backup_archive.dart'
    show FolderBackupFailure;

/// The interval presets (§4): below an hour a large folder could spend most
/// of its time zipping; above a week the weekly tier stops meaning anything.
const folderBackupIntervals = [
  Duration(hours: 1),
  Duration(hours: 3),
  Duration(hours: 6),
  Duration(hours: 12),
  Duration(days: 1),
  Duration(days: 2),
  Duration(days: 3),
  Duration(days: 7),
];
const defaultFolderBackupInterval = Duration(days: 1);
const defaultSizeDropThreshold = 20;
const minSizeDropThreshold = 5;
const maxSizeDropThreshold = 90;

/// One backed-up folder (§4). The source folder and [slug] are fixed at
/// creation; everything else can be edited.
@immutable
class FolderBackupSource {
  const FolderBackupSource({
    required this.id,
    required this.name,
    required this.slug,
    required this.sourcePath,
    required this.destination,
    required this.interval,
    required this.thresholdPercent,
    required this.enabled,
  });

  final String id;
  final String name;

  /// From the name at creation, so renaming never orphans the files (§6.4).
  final String slug;
  final String sourcePath;
  final String destination;
  final Duration interval;
  final int thresholdPercent;
  final bool enabled;

  /// `<slug>_<first 8 of id>`.
  String get subfolderName => folderBackupSubfolderName(slug, id);
  String get subfolderPath => p.join(destination, subfolderName);

  FolderBackupSource copyWith({
    String? name,
    String? destination,
    Duration? interval,
    int? thresholdPercent,
    bool? enabled,
  }) => FolderBackupSource(
    id: id,
    name: name ?? this.name,
    slug: slug,
    sourcePath: sourcePath,
    destination: destination ?? this.destination,
    interval: interval ?? this.interval,
    thresholdPercent: thresholdPercent ?? this.thresholdPercent,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'slug': slug,
    'sourcePath': sourcePath,
    'destination': destination,
    'intervalMinutes': interval.inMinutes,
    'thresholdPercent': thresholdPercent,
    'enabled': enabled,
  };

  static FolderBackupSource fromJson(Map<String, dynamic> json) =>
      FolderBackupSource(
        id: json['id'] as String,
        name: json['name'] as String,
        slug: json['slug'] as String,
        sourcePath: json['sourcePath'] as String,
        destination: json['destination'] as String,
        interval: Duration(minutes: (json['intervalMinutes'] as num).toInt()),
        thresholdPercent: (json['thresholdPercent'] as num).toInt(),
        enabled: json['enabled'] as bool? ?? true,
      );
}

String folderBackupSubfolderName(String slug, String id) =>
    '${slug}_${id.replaceAll('-', '').substring(0, 8)}';

/// A file-name-safe slug from a source's name.
String folderBackupSlug(String name) {
  final slug = name
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
      .replaceAll(RegExp('_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  if (slug.isEmpty) return 'Folder';
  return slug.length > 40 ? slug.substring(0, 40) : slug;
}

/// Backups Voyager no longer manages but still tracks (§9.6): a removed
/// source's, or a destination left behind by Change without moving.
@immutable
class RetiredFolderBackups {
  const RetiredFolderBackups({
    required this.id,
    required this.name,
    required this.slug,
    required this.path,
    required this.retiredAt,
    required this.lastKnownBytes,
    required this.lastKnownCount,
  });

  final String id;
  final String name;
  final String slug;

  /// The subfolder holding the backups.
  final String path;
  final DateTime retiredAt;
  final int lastKnownBytes;
  final int lastKnownCount;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'slug': slug,
    'path': path,
    'retiredAt': retiredAt.toUtc().toIso8601String(),
    'lastKnownBytes': lastKnownBytes,
    'lastKnownCount': lastKnownCount,
  };

  static RetiredFolderBackups fromJson(Map<String, dynamic> json) =>
      RetiredFolderBackups(
        id: json['id'] as String,
        name: json['name'] as String,
        slug: json['slug'] as String,
        path: json['path'] as String,
        retiredAt: DateTime.parse(json['retiredAt'] as String),
        lastKnownBytes: (json['lastKnownBytes'] as num?)?.toInt() ?? 0,
        lastKnownCount: (json['lastKnownCount'] as num?)?.toInt() ?? 0,
      );
}

/// One backup in a list (§9.2).
@immutable
class FolderBackupEntry {
  const FolderBackupEntry({
    required this.file,
    required this.capturedAt,
    required this.pinned,
    required this.bytes,
  });

  final File file;
  final DateTime capturedAt;
  final bool pinned;
  final int bytes;
}

/// The row's health word (§9.3), evaluated in declaration order.
enum FolderBackupHealth {
  /// §9.5: the backups are being moved to a new destination.
  moving,
  backingUp,
  review,
  off,
  attention,
  notYetBackedUp,
  healthy,
}

/// What the Inbox shows for a source (§8.4).
enum FolderBackupAlert { review, failing }

@immutable
class FolderBackupSourceStatus {
  const FolderBackupSourceStatus({
    required this.source,
    required this.health,
    required this.detail,
    required this.reachable,
    required this.backupCount,
    required this.pinnedCount,
    required this.totalBytes,
    required this.spaceWarning,
    required this.alert,
  });

  final FolderBackupSource source;
  final FolderBackupHealth health;

  /// The second line.
  final String detail;

  /// Whether the destination folder exists. The subfolder may not yet: it is
  /// made by the first backup. The counts are 0 when either is missing.
  final bool reachable;
  final int backupCount;
  final int pinnedCount;

  /// Every file of ours in the subfolder, set-aside ones included.
  final int totalBytes;

  /// Set when the backups take more than half the destination's free space
  /// (§9.4) — which is how a long hold surfaces.
  final String? spaceWarning;
  final FolderBackupAlert? alert;
}

@immutable
class RetiredFolderBackupsStatus {
  const RetiredFolderBackupsStatus({
    required this.entry,
    required this.reachable,
    required this.count,
    required this.bytes,
  });

  final RetiredFolderBackups entry;
  final bool reachable;

  /// Live when [reachable], else the last known values.
  final int count;
  final int bytes;
}

@immutable
class FolderBackupStatus {
  const FolderBackupStatus({required this.sources, required this.retired});

  final List<FolderBackupSourceStatus> sources;
  final List<RetiredFolderBackupsStatus> retired;

  int get totalBytes =>
      sources.fold(0, (sum, s) => sum + s.totalBytes) +
      retired.fold(0, (sum, r) => sum + r.bytes);
}

/// The old destination can't be reached, so its backups can't be moved
/// (§9.5). The dialog offers Change without moving.
class FolderBackupOldDestinationMissing extends FolderBackupFailure {
  FolderBackupOldDestinationMissing(String destination)
    : super('Connect $destination to move its backups');
}

/// Backs up user-chosen folders on a schedule, keeps Voyager's rotation of
/// them, and holds pruning when a folder shrinks sharply —
/// FOLDER_BACKUP_HLD.md.
///
/// `<app support>/folder_backups/sources.json` holds the registry and each
/// source's `<id>/state.json` its status. Retention never reads either: what
/// to keep is decided from the destination directory alone.
class FolderBackupService extends ChangeNotifier {
  FolderBackupService({
    required Future<Directory> Function() directory,
    required Future<int?> Function(String path) freeBytes,
    required Future<void> Function(String key, String title, String body)
    notify,
    DateTime Function() now = DateTime.now,
    bool Function(String a, String b) sameDrive = folderBackupSameDrive,
  }) : _directory = directory,
       _freeBytes = freeBytes,
       _notify = notify,
       _now = now,
       _sameDrive = sameDrive;

  final Future<Directory> Function() _directory;
  final Future<int?> Function(String path) _freeBytes;
  final Future<void> Function(String key, String title, String body) _notify;
  final DateTime Function() _now;

  /// The service's clock, so the UI dates backups the way the service does.
  DateTime now() => _now();

  /// Whether two paths share a drive, which decides how a move goes (§9.5).
  final bool Function(String a, String b) _sameDrive;

  static const _startupDelay = Duration(seconds: 30);
  static const _tickInterval = Duration(minutes: 15);

  /// Prefix of an OS notification's payload, so a click can be told apart
  /// from a reminder's.
  static const notificationKeyPrefix = 'folderBackup:';

  Timer? _startupTimer;
  Timer? _tickTimer;
  bool _disposed = false;

  /// Runs, moves and removals, one at a time (§6.1): two large folders never
  /// fight over the disk, and nothing moves a subfolder mid-backup.
  Future<void> _queue = Future.value();
  bool _dueQueued = false;

  /// Every write to `sources.json` or a `state.json` runs behind the one
  /// before it, so none reads a state another is about to replace.
  Future<void> _fileQueue = Future.value();

  /// Moves, and the pins, unpins and deletes that rename or remove backups,
  /// one at a time. A pin landing mid-move renames a file the move already
  /// copied, and the move then deletes the renamed original (§9.5). Apart
  /// from [_queue] so a pin doesn't wait out a whole backup run.
  Future<void> _moveLock = Future.value();

  String? _runningId;
  int? _runningFiles;
  final _moves = <String, (int, int)>{};

  FolderBackupStatus? _status;

  /// Refreshes overlap, and one slow on a network drive can finish after a
  /// later one: the newest refresh started that has finished so far wins.
  int _refreshesStarted = 0;
  int _refreshApplied = 0;

  /// Null until the first read completes.
  FolderBackupStatus? get status => _status;

  /// Finishes or undoes interrupted moves, clears leftover `.partial` files,
  /// then checks 30 s after startup and every 15 minutes after that.
  void start() {
    unawaited(
      _enqueue(
        recover,
      ).then((_) => refreshStatus()).then((_) {}, onError: (_) {}),
    );
    _startupTimer = Timer(_startupDelay, () {
      _tick();
      _tickTimer = Timer.periodic(_tickInterval, (_) => _tick());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _startupTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final result = _queue.then((_) => job());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<T> _underMoveLock<T>(Future<T> Function() job) {
    final result = _moveLock.then((_) => job());
    _moveLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  void _tick() {
    if (_dueQueued) return;
    _dueQueued = true;
    unawaited(runDue().then((_) {}, onError: (_) {}));
  }

  // ---------------------------------------------------------------------------
  // Registry and state files

  Future<Directory> _root() async {
    final dir = await _directory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Map<String, dynamic>> _readJson(File file) async {
    try {
      if (!await file.exists()) return {};
      return Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
    } catch (_) {
      // A damaged file reads as a missing one.
      return {};
    }
  }

  /// Written beside the file and renamed over it, so a crash leaves the old
  /// contents rather than a truncated file.
  Future<void> _writeJson(File file, Map<String, dynamic> json) async {
    await file.parent.create(recursive: true);
    final partial = File('${file.path}.partial');
    await partial.writeAsString(jsonEncode(json), flush: true);
    await partial.rename(file.path);
  }

  Future<void> _serial(Future<void> Function() job) {
    final update = _fileQueue.then((_) => job());
    _fileQueue = update.then((_) {}, onError: (_) {});
    return update;
  }

  Future<File> _registryFile() async =>
      File(p.join((await _root()).path, 'sources.json'));

  Future<File> _stateFile(String id) async =>
      File(p.join((await _root()).path, id, 'state.json'));

  /// Every source, in the order they were added.
  Future<List<FolderBackupSource>> sources() async {
    final json = await _readJson(await _registryFile());
    return [
      for (final s in (json['sources'] as List? ?? const []))
        FolderBackupSource.fromJson(Map<String, dynamic>.from(s as Map)),
    ];
  }

  Future<List<RetiredFolderBackups>> retired() async {
    final json = await _readJson(await _registryFile());
    return [
      for (final r in (json['retired'] as List? ?? const []))
        RetiredFolderBackups.fromJson(Map<String, dynamic>.from(r as Map)),
    ];
  }

  Future<FolderBackupSource?> _source(String id) async =>
      (await sources()).where((s) => s.id == id).firstOrNull;

  Future<void> _updateRegistry(
    void Function(
      List<FolderBackupSource> sources,
      List<RetiredFolderBackups> retired,
    )
    change,
  ) => _serial(() async {
    final file = await _registryFile();
    final current = await sources();
    final old = await retired();
    change(current, old);
    await _writeJson(file, {
      'sources': [for (final s in current) s.toJson()],
      'retired': [for (final r in old) r.toJson()],
    });
  });

  Future<Map<String, dynamic>> _readState(String id) async =>
      _readJson(await _stateFile(id));

  Future<void> _updateState(
    String id,
    void Function(Map<String, dynamic> state) change,
  ) => _serial(() async {
    final file = await _stateFile(id);
    final state = await _readJson(file);
    change(state);
    await _writeJson(file, state);
  });

  // ---------------------------------------------------------------------------
  // Listing

  /// The backups in [source]'s subfolder — rotation and pinned — newest
  /// first. Files whose names aren't exactly ours are never listed.
  Future<List<FolderBackupEntry>> listBackups(FolderBackupSource source) =>
      _listIn(source.subfolderPath, source.slug);

  Future<List<FolderBackupEntry>> listRetiredBackups(
    RetiredFolderBackups retired,
  ) => _listIn(retired.path, retired.slug);

  Future<List<FolderBackupEntry>> _listIn(String path, String slug) async {
    final dir = Directory(path);
    if (!await dir.exists()) return const [];
    final rotation = folderBackupRotationPattern(slug);
    final pinned = folderBackupPinnedPattern(slug);
    final entries = <FolderBackupEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final inRotation = parseBackupTimestamp(name, rotation);
      final pinnedAt = parseBackupTimestamp(name, pinned);
      final capturedAt = inRotation ?? pinnedAt;
      if (capturedAt == null) continue;
      entries.add(
        FolderBackupEntry(
          file: entity,
          capturedAt: capturedAt,
          pinned: pinnedAt != null,
          bytes: await entity.length(),
        ),
      );
    }
    entries.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    return entries;
  }

  /// Every file of ours in [path]: what counts toward storage, and what a
  /// move carries or a delete removes.
  Future<List<File>> _ourFiles(String path, String slug) async {
    final dir = Directory(path);
    if (!await dir.exists()) return const [];
    return [
      await for (final entity in dir.list(followLinks: false))
        if (entity is File &&
            isFolderBackupFileName(slug, p.basename(entity.path)))
          entity,
    ];
  }

  // ---------------------------------------------------------------------------
  // Adding, editing, removing

  /// Adds a source and runs its first check at once. Throws a
  /// [FolderBackupFailure] naming what §9.4 refuses.
  Future<FolderBackupSource> addSource({
    required String name,
    required String sourcePath,
    required String destination,
    Duration interval = defaultFolderBackupInterval,
    int thresholdPercent = defaultSizeDropThreshold,
  }) async {
    if (name.trim().isEmpty) throw FolderBackupFailure('Give it a name');
    if (!await Directory(sourcePath).exists()) {
      throw FolderBackupFailure('Folder not found');
    }
    final source = FolderBackupSource(
      id: newId(),
      name: name.trim(),
      slug: folderBackupSlug(name.trim()),
      sourcePath: p.normalize(sourcePath),
      destination: p.normalize(destination),
      interval: interval,
      thresholdPercent: thresholdPercent,
      enabled: true,
    );
    await checkPlacement(source, source.destination);
    await _updateRegistry((sources, _) => sources.add(source));
    await refreshStatus();
    unawaited(backUpNow(source.id).then((_) {}, onError: (_) {}));
    return source;
  }

  /// Refuses a destination (§9.4): one inside the folder or holding it, a
  /// folder overlapping another source's, a destination inside another
  /// source's folder or a folder holding another source's backups, or a
  /// subfolder that already exists.
  Future<void> checkPlacement(
    FolderBackupSource source,
    String destination,
  ) async {
    if (!await Directory(destination).exists()) {
      throw FolderBackupFailure('Destination not found');
    }
    if (_within(destination, source.sourcePath)) {
      throw FolderBackupFailure('The destination is inside the folder');
    }
    if (_within(source.sourcePath, destination)) {
      throw FolderBackupFailure('The folder is inside the destination');
    }
    for (final other in await sources()) {
      if (other.id == source.id) continue;
      if (_within(source.sourcePath, other.sourcePath) ||
          _within(other.sourcePath, source.sourcePath)) {
        throw FolderBackupFailure(
          'This folder overlaps "${other.name}", which is already backed up',
        );
      }
      // Either way round, one source's backups would change the other's
      // folder on every run: it re-zips them, and a prune reads as a shrink.
      if (_within(destination, other.sourcePath)) {
        throw FolderBackupFailure(
          'The destination is inside "${other.name}", which is backed up',
        );
      }
      if (_within(other.subfolderPath, source.sourcePath)) {
        throw FolderBackupFailure(
          'This folder holds the backups of "${other.name}"',
        );
      }
    }
    if (await Directory(p.join(destination, source.subfolderName)).exists()) {
      throw FolderBackupFailure(
        'The destination already holds a folder named '
        '${source.subfolderName}',
      );
    }
  }

  /// Name, interval, threshold and the toggle (§9.4). A new destination goes
  /// through [changeDestination].
  Future<void> updateSource(FolderBackupSource updated) async {
    if (updated.name.trim().isEmpty) {
      throw FolderBackupFailure('Give it a name');
    }
    await _updateRegistry((sources, _) {
      final i = sources.indexWhere((s) => s.id == updated.id);
      if (i < 0) return;
      sources[i] = sources[i].copyWith(
        name: updated.name.trim(),
        interval: updated.interval,
        thresholdPercent: updated.thresholdPercent,
        enabled: updated.enabled,
      );
    });
    await refreshStatus();
    if (updated.enabled) _tick();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final source = await _source(id);
    if (source != null) await updateSource(source.copyWith(enabled: enabled));
  }

  /// Stops managing the source and keeps its backups as retired (§9.6).
  /// Nothing is deleted.
  Future<void> removeSource(String id) => _enqueue(() async {
    final source = await _source(id);
    if (source == null) return;
    await _retire(source, source.subfolderPath);
    await _updateRegistry(
      (sources, _) => sources.removeWhere((s) => s.id == id),
    );
    final stateDir = (await _stateFile(id)).parent;
    if (await stateDir.exists()) await stateDir.delete(recursive: true);
    await refreshStatus();
  });

  Future<void> _retire(FolderBackupSource source, String path) async {
    // The destination is there but the subfolder never was: nothing to keep,
    // and an entry for it would read as an unplugged drive forever.
    if (!await Directory(path).exists() &&
        await Directory(source.destination).exists()) {
      return;
    }
    final previous = _status?.sources
        .where((s) => s.source.id == source.id)
        .firstOrNull;
    await _updateRegistry(
      (_, retired) => retired.add(
        RetiredFolderBackups(
          id: newId(),
          name: source.name,
          slug: source.slug,
          path: path,
          retiredAt: _now(),
          lastKnownBytes: previous?.totalBytes ?? 0,
          lastKnownCount:
              (previous?.backupCount ?? 0) + (previous?.pinnedCount ?? 0),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Running

  /// Checks every enabled source whose interval has passed since its last
  /// successful check (§6.1), one after another.
  Future<void> runDue() {
    _dueQueued = true;
    return _enqueue(() async {
      _dueQueued = false;
      for (final source in await sources()) {
        if (!source.enabled) continue;
        final last = parseBackupTime(
          (await _readState(source.id))['lastCheckedAt'],
        );
        if (last != null && _now().difference(last) < source.interval) {
          continue;
        }
        await _run(source.id);
      }
    });
  }

  /// Back up now (§6.1): checks at once, ignoring the interval. Still writes
  /// nothing if the folder hasn't changed.
  Future<void> backUpNow(String id) => _enqueue(() => _run(id));

  /// "This was intentional" (§8.3): accepts the shrunken state as the new
  /// baseline, clears the hold, and checks at once, which prunes.
  ///
  /// Queued behind any run in progress: that run saves the hold it read
  /// before the click, and would put back the one cleared here.
  Future<void> acceptDrop(String id) => _enqueue(() async {
    await _updateState(id, (s) {
      final hold = s['hold'];
      if (hold is Map) s['acceptedFrom'] = hold['captured'];
      s.remove('hold');
    });
    await refreshStatus();
    await _run(id);
  });

  /// The §6.2 pipeline for one source. Failures are recorded, never thrown.
  Future<void> _run(String id) async {
    final source = await _source(id);
    if (source == null || !source.enabled) return;
    final now = _now();
    _runningId = id;
    _runningFiles = null;
    await refreshStatus().then((_) {}, onError: (_) {});
    try {
      await _pipeline(source, now);
    } catch (error) {
      await _updateState(id, (s) {
        s['lastAttemptFailed'] = true;
        s['lastFailureAt'] = _iso(_now());
        s['lastFailureReason'] = _reason(error);
        s['lastFailureVerification'] = error is FolderBackupDamaged;
        s['firstFailureAt'] ??= _iso(_now());
      }).then((_) {}, onError: (_) {});
    } finally {
      _runningId = null;
      _runningFiles = null;
    }
    await refreshStatus().then((_) {}, onError: (_) {});
  }

  Future<void> _pipeline(FolderBackupSource source, DateTime now) async {
    await _preflight(source);
    final walk = await _walk(source.sourcePath);
    if (walk.fileCount == 0) throw FolderBackupFailure('Folder is empty');
    _runningFiles = walk.fileCount;
    notifyListeners();

    final state = await _readState(source.id);
    final backups = await listBackups(source);
    final newest = backups.isEmpty
        ? null
        : await _summaryOrNull(backups.first.file);

    FolderBackupEntry? fresh;
    String? drop;
    if (newest?.fingerprint != walk.fingerprint) {
      drop = await _sizeDrop(
        source,
        walk,
        backups,
        parseBackupTime(state['acceptedFrom']),
      );
      await _checkSpace(source, backups, walk);
      fresh = await _writeVerified(source, walk, now);
    }

    // At most once a local day (§6.2 step 9), on the day's first successful
    // check whether or not it wrote a file, so an idle folder's backups are
    // still checked for bit rot.
    final today = backupDayKey(now);
    final recheck = state['lastRecheckDay'] != today;
    var damaged = <String>[...?(state['recheckDamaged'] as List?)?.cast()];
    var unchecked = <String>[...?(state['recheckUnchecked'] as List?)?.cast()];
    if (recheck) {
      damaged = [];
      unchecked = [];
      for (final entry in backups) {
        final name = p.basename(entry.file.path);
        try {
          await _verify(entry.file.path);
        } on FolderBackupUnsupported {
          await entry.file.rename(
            '${entry.file.path}$folderBackupUnsupportedSuffix',
          );
        } on FolderBackupDamaged {
          damaged.add(name);
          await entry.file.rename(
            '${entry.file.path}$folderBackupDamagedSuffix',
          );
        } catch (_) {
          // Held open by a scanner or a ZIP tool: says nothing about the
          // file, which stays, out of today's pruning.
          unchecked.add(name);
        }
      }
    }

    final previousHold = state['hold'] as Map?;
    Map<String, Object?>? hold = previousHold == null
        ? null
        : Map<String, Object?>.from(previousHold);
    if (drop != null && fresh != null) {
      hold = {
        'since': hold?['since'] ?? _iso(now),
        'captured': _iso(fresh.capturedAt),
        'reason': drop,
      };
    }

    if (hold == null) {
      final rotation = [
        for (final entry in await listBackups(source))
          if (!entry.pinned && !unchecked.contains(p.basename(entry.file.path)))
            entry,
      ];
      final keep = folderBackupsToKeep({
        for (final e in rotation) e.capturedAt,
      }, now);
      for (final entry in rotation) {
        if (keep.contains(entry.capturedAt)) continue;
        try {
          await entry.file.delete();
        } on PathNotFoundException {
          // Deleted or pinned meanwhile.
        }
      }
    }

    // Recorded last, so a failure anywhere above shows as a failed check.
    await _updateState(source.id, (s) {
      s['lastCheckedAt'] = _iso(_now());
      s['lastOutcome'] = fresh == null ? 'unchanged' : 'backedUp';
      s['lastAttemptFailed'] = false;
      s.remove('lastFailureReason');
      s.remove('lastFailureVerification');
      s.remove('firstFailureAt');
      if (recheck) {
        s['lastRecheckDay'] = today;
        s['recheckDamaged'] = damaged;
        s['recheckUnchecked'] = unchecked;
      }
      if (hold == null) {
        s.remove('hold');
      } else {
        s['hold'] = hold;
      }
    });
    // Once per hold, not once per run (§8.3).
    if (previousHold == null && hold != null) {
      await _notify(
        '$notificationKeyPrefix${source.id}',
        '${source.name} shrank',
        '${hold['reason']}. Old backups are kept until you review it.',
      ).then((_) {}, onError: (_) {});
    }
  }

  /// §6.2 step 1. Rechecked every run: junctions can change.
  Future<void> _preflight(FolderBackupSource source) async {
    final folder = Directory(source.sourcePath);
    if (!await folder.exists()) throw FolderBackupFailure('Folder not found');
    final destination = Directory(source.destination);
    if (!await destination.exists()) {
      throw FolderBackupFailure('Destination not found');
    }
    final realFolder = await folder.resolveSymbolicLinks();
    final realSubfolder = p.join(
      await destination.resolveSymbolicLinks(),
      source.subfolderName,
    );
    if (_within(realSubfolder, realFolder)) {
      throw FolderBackupFailure('The destination is inside the folder');
    }
    if (_within(realFolder, realSubfolder)) {
      throw FolderBackupFailure('The folder is inside the destination');
    }
  }

  /// §8: total bytes and file count against the last and the weekly backup,
  /// ignoring anything older than the accepted baseline. The reason, or null.
  Future<String?> _sizeDrop(
    FolderBackupSource source,
    FolderWalk walk,
    List<FolderBackupEntry> backups,
    DateTime? acceptedFrom,
  ) async {
    final now = _now();
    final candidates = [
      for (final b in backups)
        if (acceptedFrom == null || !b.capturedAt.isBefore(acceptedFrom)) b,
    ];
    Future<FolderBackupSummary?> firstReadable(
      Iterable<FolderBackupEntry> entries,
    ) async {
      for (final entry in entries) {
        final summary = await _summaryOrNull(entry.file);
        if (summary != null) return summary;
      }
      return null;
    }

    final references = [
      ('the last backup', await firstReadable(candidates)),
      (
        'the weekly backup',
        await firstReadable(
          candidates.where((b) => backupAgeDays(b.capturedAt, now) >= 7),
        ),
      ),
    ];
    final keep = (100 - source.thresholdPercent) / 100;
    for (final (label, reference) in references) {
      if (reference == null) continue;
      for (final (what, current, before, format) in [
        ('File count', walk.fileCount, reference.fileCount, _count),
        (
          'Size',
          walk.totalBytes,
          reference.totalBytes,
          formatFolderBackupBytes,
        ),
      ]) {
        if (before > 0 && current < before * keep) {
          final percent = ((before - current) * 100 / before).round();
          return '$what fell $percent% since $label '
              '(${format(before)} → ${format(current)})';
        }
      }
    }
    return null;
  }

  /// §6.2 step 5. Old backups are never deleted to make room.
  Future<void> _checkSpace(
    FolderBackupSource source,
    List<FolderBackupEntry> backups,
    FolderWalk walk,
  ) async {
    final needed = backups.isEmpty
        ? (walk.totalBytes * 1.1).ceil()
        : backups.first.bytes * 2;
    final free = await _freeBytes(source.destination);
    if (free != null && free < needed) {
      throw FolderBackupFailure(
        'Not enough free space (needs ${formatFolderBackupBytes(needed)})',
      );
    }
  }

  /// Writes, verifies from disk and renames into place (§6.2 steps 6–8).
  /// Leaves nothing behind on failure.
  Future<FolderBackupEntry> _writeVerified(
    FolderBackupSource source,
    FolderWalk walk,
    DateTime now,
  ) async {
    final dir = Directory(source.subfolderPath);
    await dir.create();
    final name = '${source.slug}_${backupTimestamp(now)}.zip';
    final target = File(p.join(dir.path, name));
    final partial = File('${target.path}$folderBackupPartialSuffix');
    try {
      await _write(source, walk, partial.path, now);
      await _verify(partial.path);
      // A rename replaces whatever it lands on, so a clash must not reach it.
      if (await target.exists()) {
        throw FolderBackupFailure('A backup named $name already exists');
      }
      await partial.rename(target.path);
      return FolderBackupEntry(
        file: target,
        capturedAt: parseBackupTimestamp(
          name,
          folderBackupRotationPattern(source.slug),
        )!,
        pinned: false,
        bytes: await target.length(),
      );
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Backup actions

  /// Pinned backups leave the rotation and are never deleted automatically
  /// (§6.4). The pin is the file's name, so it survives a lost state file.
  Future<void> pin(FolderBackupSource source, FolderBackupEntry entry) =>
      _renameStamped(source, entry, toPinned: true);

  /// Back into the rotation, where the next prune may delete it.
  Future<void> unpin(FolderBackupSource source, FolderBackupEntry entry) =>
      _renameStamped(source, entry, toPinned: false);

  Future<void> _renameStamped(
    FolderBackupSource source,
    FolderBackupEntry entry, {
    required bool toPinned,
  }) => _underMoveLock(() async {
    // Found by name in the source's subfolder as it is now: a move that held
    // the lock has carried the file to a new one.
    final folder =
        (await _source(source.id))?.subfolderPath ?? entry.file.parent.path;
    final file = File(p.join(folder, p.basename(entry.file.path)));
    final name =
        '${source.slug}_${toPinned ? 'pinned_' : ''}'
        '${backupTimestamp(entry.capturedAt)}.zip';
    final target = File(p.join(folder, name));
    if (await target.exists()) {
      throw FolderBackupFailure('A backup named $name already exists');
    }
    await file.rename(target.path);
    await refreshStatus();
  });

  /// Deleting a rotation file is safe: retention fills the gap from what's
  /// left (§7).
  Future<void> deleteBackup(FolderBackupEntry entry) =>
      _underMoveLock(() async {
        await entry.file.delete();
        await refreshStatus();
      });

  /// Delete all… on a retired entry (§9.6): only files with our names, then
  /// the subfolder if it's empty. Once nothing of ours is left, the entry
  /// disappears.
  Future<void> deleteRetired(RetiredFolderBackups retired) async {
    for (final file in await _ourFiles(retired.path, retired.slug)) {
      await file.delete();
    }
    await refreshStatus();
  }

  /// Extract to folder… (§7): verifies the backup, then writes every file
  /// into [targetPath], which must be empty or not exist yet, and must not be
  /// inside a backed-up folder or a backup subfolder.
  Future<void> extract(File backup, String targetPath) async {
    final target = Directory(targetPath);
    final protected = [
      for (final s in await sources()) ...[s.sourcePath, s.subfolderPath],
      for (final r in await retired()) r.path,
    ];
    for (final path in protected) {
      if (_within(targetPath, path)) {
        throw FolderBackupFailure(
          "Can't extract into a backed-up folder or a backup folder",
        );
      }
    }
    if (await target.exists()) {
      if (!await target.list().isEmpty) {
        throw FolderBackupFailure('Pick an empty folder');
      }
    } else {
      await target.create(recursive: true);
    }
    await _extract(backup.path, targetPath);
  }

  /// The size of [path] for the add dialog's estimate (§9.4).
  Future<(int bytes, int files)> estimate(String path) => _estimate(path);

  Future<int?> freeBytesAt(String path) => _freeBytes(path);

  /// The manifest summary for the list's file count, or null if unreadable.
  Future<FolderBackupSummary?> summaryOf(FolderBackupEntry entry) =>
      _summaryOrNull(entry.file);

  // ---------------------------------------------------------------------------
  // Moving the destination (§9.5)

  /// Points [id] at [destination], carrying every file of ours across so the
  /// rotation and size history carry on. Throws
  /// [FolderBackupOldDestinationMissing] when the old drive can't be reached;
  /// [withoutMoving] then retires the old subfolder and starts afresh.
  Future<void> changeDestination(
    String id,
    String destination, {
    bool withoutMoving = false,
  }) => _enqueue(
    () => _underMoveLock(() async {
      final source = await _source(id);
      if (source == null) return;
      destination = p.normalize(destination);
      await checkPlacement(source, destination);
      final from = source.subfolderPath;
      final to = p.join(destination, source.subfolderName);

      if (withoutMoving) {
        await _retire(source, from);
        await _switchDestination(id, destination);
        // The size history restarts: its references stayed behind.
        await _updateState(id, (s) {
          for (final key in [
            'hold',
            'acceptedFrom',
            'lastRecheckDay',
            'recheckDamaged',
            'recheckUnchecked',
            'lastCheckedAt',
          ]) {
            s.remove(key);
          }
        });
        await refreshStatus();
        return;
      }

      if (!await Directory(from).exists()) {
        if (!await Directory(source.destination).exists()) {
          throw FolderBackupOldDestinationMissing(source.destination);
        }
        // Reachable, with nothing to carry.
        await _switchDestination(id, destination);
        await refreshStatus();
        return;
      }

      final files = await _ourFiles(from, source.slug);
      await _updateState(
        id,
        (s) => s['move'] = {'from': from, 'to': to, 'destination': destination},
      );
      _moves[id] = (0, files.length);
      await refreshStatus();
      try {
        if (_sameDrive(from, to)) {
          // One atomic step.
          await Directory(from).rename(to);
        } else {
          var needed = 0;
          for (final file in files) {
            needed += await file.length();
          }
          final free = await _freeBytes(destination);
          if (free != null && free < needed) {
            throw FolderBackupFailure(
              'Not enough free space at the new destination (needs '
              '${formatFolderBackupBytes(needed)})',
            );
          }
          final moving = Directory('$to.moving');
          await moving.create();
          for (final (i, file) in files.indexed) {
            await _copyVerified(
              file.path,
              p.join(moving.path, p.basename(file.path)),
            );
            _moves[id] = (i + 1, files.length);
            notifyListeners();
          }
          // Every copy matches: from here on, the move only goes forward.
          await moving.rename(to);
        }
      } catch (_) {
        await _undoMove(id, '$to.moving', source.slug);
        _moves.remove(id);
        await refreshStatus();
        rethrow;
      }
      await _finishMove(id, from, destination, source.slug);
      _moves.remove(id);
      await refreshStatus();
    }),
  );

  Future<void> _switchDestination(String id, String destination) =>
      _updateRegistry((sources, _) {
        final i = sources.indexWhere((s) => s.id == id);
        if (i >= 0) sources[i] = sources[i].copyWith(destination: destination);
      });

  /// After the new subfolder is complete: point the source at it, then
  /// delete the originals (our names only) and the old subfolder if empty.
  Future<void> _finishMove(
    String id,
    String from,
    String destination,
    String slug,
  ) async {
    await _switchDestination(id, destination);
    for (final file in await _ourFiles(from, slug)) {
      await file.delete();
    }
    await _deleteIfEmpty(from);
    await _updateState(id, (s) => s.remove('move'));
  }

  Future<void> _undoMove(String id, String moving, String slug) async {
    for (final file in await _ourFiles(moving, slug)) {
      await file.delete();
    }
    await _deleteIfEmpty(moving);
    await _updateState(id, (s) => s.remove('move'));
  }

  Future<void> _deleteIfEmpty(String path) async {
    final dir = Directory(path);
    if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
  }

  /// Startup: finishes a move that reached its new subfolder, undoes one
  /// that didn't, and clears leftover `.partial` files. A move whose old
  /// drive is away is left for the next start.
  Future<void> recover() async {
    for (final source in await sources()) {
      final move = (await _readState(source.id))['move'];
      if (move is Map) {
        final from = move['from'] as String;
        final to = move['to'] as String;
        try {
          if (await Directory(to).exists()) {
            if (await Directory(p.dirname(from)).exists()) {
              await _finishMove(
                source.id,
                from,
                move['destination'] as String,
                source.slug,
              );
            } else {
              await _switchDestination(
                source.id,
                move['destination'] as String,
              );
            }
          } else {
            await _undoMove(source.id, '$to.moving', source.slug);
          }
        } catch (_) {
          // Tried again on the next start.
        }
      }
    }
    for (final source in await sources()) {
      try {
        for (final file in await _ourFiles(source.subfolderPath, source.slug)) {
          if (file.path.endsWith(folderBackupPartialSuffix)) {
            await file.delete();
          }
        }
      } catch (_) {
        // Unreachable or locked; tried again on the next start.
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Status

  /// Re-reads the registry, the state files and the destination folders.
  Future<FolderBackupStatus> refreshStatus() async {
    final generation = ++_refreshesStarted;
    final now = _now();
    final statuses = <FolderBackupSourceStatus>[];
    for (final source in await sources()) {
      statuses.add(await _sourceStatus(source, now));
    }

    final retiredStatuses = <RetiredFolderBackupsStatus>[];
    final gone = <String>{};
    final updated = <String, (int, int)>{};
    for (final entry in await retired()) {
      final reachable = await Directory(entry.path).exists();
      if (!reachable) {
        retiredStatuses.add(
          RetiredFolderBackupsStatus(
            entry: entry,
            reachable: false,
            count: entry.lastKnownCount,
            bytes: entry.lastKnownBytes,
          ),
        );
        continue;
      }
      final files = await _ourFiles(entry.path, entry.slug);
      if (files.isEmpty) {
        await _deleteIfEmpty(entry.path).then((_) {}, onError: (_) {});
        gone.add(entry.id);
        continue;
      }
      var bytes = 0;
      for (final file in files) {
        bytes += await file.length();
      }
      final count = (await _listIn(entry.path, entry.slug)).length;
      if (bytes != entry.lastKnownBytes || count != entry.lastKnownCount) {
        updated[entry.id] = (bytes, count);
      }
      retiredStatuses.add(
        RetiredFolderBackupsStatus(
          entry: entry,
          reachable: true,
          count: count,
          bytes: bytes,
        ),
      );
    }
    if (gone.isNotEmpty || updated.isNotEmpty) {
      await _updateRegistry((_, retired) {
        retired.removeWhere((r) => gone.contains(r.id));
        for (final (i, r) in retired.indexed) {
          final usage = updated[r.id];
          if (usage == null) continue;
          retired[i] = RetiredFolderBackups(
            id: r.id,
            name: r.name,
            slug: r.slug,
            path: r.path,
            retiredAt: r.retiredAt,
            lastKnownBytes: usage.$1,
            lastKnownCount: usage.$2,
          );
        }
      });
    }

    final status = FolderBackupStatus(
      sources: statuses,
      retired: retiredStatuses,
    );
    if (generation < _refreshApplied) return _status!;
    _refreshApplied = generation;
    _status = status;
    notifyListeners();
    return status;
  }

  Future<FolderBackupSourceStatus> _sourceStatus(
    FolderBackupSource source,
    DateTime now,
  ) async {
    final state = await _readState(source.id);
    final reachable = await Directory(source.destination).exists();
    final entries = await listBackups(source);
    final pinnedCount = entries.where((e) => e.pinned).length;
    var totalBytes = 0;
    for (final file in await _ourFiles(source.subfolderPath, source.slug)) {
      totalBytes += await file.length();
    }

    String? spaceWarning;
    if (reachable && totalBytes > 0) {
      final free = await _freeBytes(source.destination);
      if (free != null && totalBytes > free / 2) {
        spaceWarning =
            'Backups take ${formatFolderBackupBytes(totalBytes)}, more than '
            "half the destination's free space";
      }
    }

    final hold = state['hold'] as Map?;
    final lastChecked = parseBackupTime(state['lastCheckedAt']);
    final failed = state['lastAttemptFailed'] == true;
    final verificationFailed = state['lastFailureVerification'] == true;
    final damaged = [...?(state['recheckDamaged'] as List?)];
    final unchecked = [...?(state['recheckUnchecked'] as List?)];
    final newest = entries.isEmpty ? null : entries.first.capturedAt;
    final overdue =
        lastChecked != null &&
        now.difference(lastChecked) > source.interval * 2;

    final move = _moves[source.id];
    final (FolderBackupHealth, String) health;
    if (move != null) {
      health = (
        FolderBackupHealth.moving,
        'Moving backups… ${move.$1} of ${move.$2}',
      );
    } else if (_runningId == source.id) {
      final files = _runningFiles;
      health = (
        FolderBackupHealth.backingUp,
        files == null ? 'Backing up…' : 'Backing up ${_count(files)} files',
      );
    } else if (hold != null) {
      health = (FolderBackupHealth.review, hold['reason'] as String);
    } else if (!source.enabled) {
      health = (
        FolderBackupHealth.off,
        'Folder backups are off · '
            '${newest == null ? 'no backups yet' : 'last backup ${backupAgoLabel(newest, now)}'}',
      );
    } else if (failed) {
      health = (
        FolderBackupHealth.attention,
        state['lastFailureReason'] as String? ?? 'The last backup failed',
      );
    } else if (damaged.isNotEmpty) {
      health = (
        FolderBackupHealth.attention,
        '${damaged.length} backup(s) failed re-verification and were set '
            'aside',
      );
    } else if (unchecked.isNotEmpty) {
      health = (
        FolderBackupHealth.attention,
        '${unchecked.length} backup(s) could not be re-checked',
      );
    } else if (overdue) {
      health = (
        FolderBackupHealth.attention,
        'No successful check since ${_when(lastChecked, now)}',
      );
    } else if (lastChecked == null) {
      health = (FolderBackupHealth.notYetBackedUp, 'First backup runs shortly');
    } else if (state['lastOutcome'] == 'unchanged' && newest != null) {
      health = (
        FolderBackupHealth.healthy,
        'Last checked ${_when(lastChecked, now)}, unchanged since '
            '${_when(newest, now)}',
      );
    } else {
      health = (
        FolderBackupHealth.healthy,
        'Last backup ${_when(newest ?? lastChecked, now)}, verified',
      );
    }

    FolderBackupAlert? alert;
    if (hold != null) {
      alert = FolderBackupAlert.review;
    } else if (source.enabled &&
        (failed && verificationFailed || damaged.isNotEmpty)) {
      alert = FolderBackupAlert.failing;
    } else if (source.enabled && failed) {
      // Operational failures are often a drive that's away: they wait out a
      // grace period (§8.4).
      final since = lastChecked ?? parseBackupTime(state['firstFailureAt']);
      final grace = source.interval * 2 > const Duration(hours: 24)
          ? source.interval * 2
          : const Duration(hours: 24);
      if (since != null && now.difference(since) >= grace) {
        alert = FolderBackupAlert.failing;
      }
    }

    return FolderBackupSourceStatus(
      source: source,
      health: health.$1,
      detail: health.$2,
      reachable: reachable,
      backupCount: entries.length - pinnedCount,
      pinnedCount: pinnedCount,
      totalBytes: totalBytes,
      spaceWarning: spaceWarning,
      alert: alert,
    );
  }
}

// -----------------------------------------------------------------------------
// Isolate hops. Top-level, so each closure captures only its arguments and
// never the service.

Future<FolderWalk> _walk(String path) => Isolate.run(() => walkFolder(path));

Future<(int, int)> _estimate(String path) => Isolate.run(() {
  final walk = walkFolder(path);
  return (walk.totalBytes, walk.fileCount);
});

Future<FolderBackupSummary> _write(
  FolderBackupSource source,
  FolderWalk walk,
  String zipPath,
  DateTime capturedAt,
) {
  final sourcePath = source.sourcePath;
  final header = <String, Object?>{
    'sourceId': source.id,
    'sourceName': source.name,
    'sourcePath': source.sourcePath,
  };
  return Isolate.run(
    () => writeFolderArchive(
      sourcePath: sourcePath,
      walk: walk,
      zipPath: zipPath,
      header: header,
      capturedAt: capturedAt,
    ),
  );
}

Future<FolderBackupSummary> _verify(String path) =>
    Isolate.run(() => verifyFolderArchive(path));

Future<void> _extract(String zipPath, String targetPath) =>
    Isolate.run(() => extractFolderArchive(zipPath, targetPath));

Future<void> _copyVerified(String from, String to) =>
    Isolate.run(() => copyVerified(from, to));

Future<FolderBackupSummary?> _summaryOrNull(File file) async {
  final path = file.path;
  try {
    return await Isolate.run(() => readFolderArchiveSummary(path));
  } catch (_) {
    return null;
  }
}

// -----------------------------------------------------------------------------
// Helpers

/// Whether [path] is [parent] or inside it, compared as Windows does:
/// case-insensitively, after normalising.
bool _within(String path, String parent) {
  final a = p.canonicalize(path);
  final b = p.canonicalize(parent);
  return a == b || p.isWithin(b, a);
}

/// Whether [a] and [b] are on the same drive: how a move goes (§9.5), and
/// the dialog's hint (§9.4).
bool folderBackupSameDrive(String a, String b) =>
    p.rootPrefix(p.canonicalize(a)) == p.rootPrefix(p.canonicalize(b));

String _reason(Object error) => switch (error) {
  FolderBackupFailure(:final message) => message,
  FolderBackupDamaged(:final message) =>
    'The new backup failed verification: $message',
  FileSystemException(:final message, :final osError) =>
    'Could not write the backup: ${osError?.message.trim() ?? message}',
  _ => 'Backup failed: $error',
};

String _iso(DateTime time) => time.toUtc().toIso8601String();

final _thousands = NumberFormat.decimalPattern('en_US');

String _count(int n) => _thousands.format(n);

/// "14:02" today, "yesterday 23:00", "3 days ago 08:00".
String _when(DateTime time, DateTime now) {
  final t = time.toLocal();
  final hhmm =
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
  return backupAgeDays(time, now) <= 0
      ? hhmm
      : '${backupAgoLabel(time, now)} $hhmm';
}

/// The list's age label (§9.2): "Yesterday", "Weekly · 9 days ago",
/// "Pinned · 1 Sep".
String folderBackupAgeLabel(FolderBackupEntry entry, DateTime now) {
  if (entry.pinned) {
    return 'Pinned · ${DateFormat('d MMM').format(entry.capturedAt.toLocal())}';
  }
  final age = backupAgeDays(entry.capturedAt, now);
  final ago = backupAgoLabel(entry.capturedAt, now);
  if (age >= retentionTiers[1]) return 'Monthly · $ago';
  if (age >= retentionTiers[0]) return 'Weekly · $ago';
  return '${ago[0].toUpperCase()}${ago.substring(1)}';
}

/// "1,834 files".
String formatFolderBackupFiles(int n) =>
    '${_count(n)} ${n == 1 ? 'file' : 'files'}';

String formatFolderBackupBytes(int bytes) {
  const mb = 1024 * 1024;
  const gb = 1024 * mb;
  if (bytes < mb) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(0)} MB';
  return '${(bytes / gb).toStringAsFixed(1)} GB';
}

/// "1 hour", "12 hours", "1 day", "7 days".
String formatFolderBackupInterval(Duration interval) {
  if (interval.inHours < 24) {
    return '${interval.inHours} ${interval.inHours == 1 ? 'hour' : 'hours'}';
  }
  return '${interval.inDays} ${interval.inDays == 1 ? 'day' : 'days'}';
}
