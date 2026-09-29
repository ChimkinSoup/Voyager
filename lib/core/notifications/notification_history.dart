import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';

const _fileName = 'notification_history.json';

/// Where a notification came from. Stored by name, so the icon the history
/// shows is picked from this rather than persisted: an icon rebuilt from a
/// saved code point is a non-constant [IconData], which release builds'
/// icon tree-shaking refuses to compile.
enum NotificationSource {
  /// A toast or snackbar raised inside the app.
  app,

  /// A scheduled reminder falling due.
  reminder,
}

/// One notification the app showed on this device.
@immutable
class NotificationRecord {
  const NotificationRecord({
    required this.at,
    required this.message,
    required this.source,
    this.origin,
    this.detail,
    this.dedupeKey,
  });

  final DateTime at;
  final String message;
  final NotificationSource source;

  /// Where in the app it came from — "Settings", "LeetCode", "Sync". Null
  /// when nothing could say, such as a toast on the login screen.
  final String? origin;

  /// A second line, such as a reminder's "Starts in 10 min".
  final String? detail;

  /// Identifies a notification that can be raised again for the same event —
  /// a reminder still due when the app restarts — so it is recorded once.
  final String? dedupeKey;

  NotificationRecord _withMessage(String message) => NotificationRecord(
    at: at,
    message: message,
    source: source,
    origin: origin,
    detail: detail,
    dedupeKey: dedupeKey,
  );

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'message': message,
    'source': source.name,
    if (origin != null) 'origin': origin,
    if (detail != null) 'detail': detail,
    if (dedupeKey != null) 'dedupeKey': dedupeKey,
  };

  static NotificationRecord fromJson(Map<String, Object?> json) =>
      NotificationRecord(
        at: DateTime.parse(json['at']! as String).toLocal(),
        message: json['message']! as String,
        source:
            NotificationSource.values.asNameMap()[json['source']] ??
            NotificationSource.app,
        origin: json['origin'] as String?,
        detail: json['detail'] as String?,
        dedupeKey: json['dedupeKey'] as String?,
      );
}

/// Every notification shown on this device in the last [retention], newest
/// first — for Settings' notification history.
///
/// Local to the device rather than synced: it records what *this* screen
/// showed, and syncing it would also have it recording its own sync toasts
/// from every other device.
class NotificationHistory extends ChangeNotifier {
  NotificationHistory._();

  @visibleForTesting
  NotificationHistory.forTesting();

  static final instance = NotificationHistory._();

  static const retention = Duration(days: 30);

  var _records = <NotificationRecord>[];

  /// Only `main` loads, so a test that raises a toast keeps its history in
  /// memory rather than writing into the real app-data folder.
  var _persisted = false;

  Future<void> _writeChain = Future<void>.value();

  /// A save held back so a toast rewriting itself on every sync tick writes
  /// the file at most once per [_reviseSaveDelay], not once per tick.
  Timer? _pendingSave;

  static const _reviseSaveDelay = Duration(seconds: 1);

  List<NotificationRecord> get records => List.unmodifiable(_records);

  /// Names the part of the app the user is on, for a notification whose
  /// raiser did not say where it came from. Set by the app, which knows its
  /// pages; core does not.
  String? Function()? currentOrigin;

  /// Reads what earlier runs recorded and turns on saving. Called once from
  /// `main`. A missing or unreadable file starts an empty history.
  ///
  /// Saves only if the history no longer matches the file: records aged out,
  /// or some were recorded before the file was read.
  Future<void> load() async {
    _persisted = true;
    final recordedBefore = _records.isNotEmpty;
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString()) as List<Object?>;
        _records = [
          for (final entry in decoded)
            NotificationRecord.fromJson(entry! as Map<String, Object?>),
          // Anything recorded while the file was being read is newer.
          ..._records,
        ];
        _records.sort((a, b) => b.at.compareTo(a.at));
      }
    } catch (_) {
      // A corrupt file is replaced by the next save.
    }
    final agedOut = _prune();
    notifyListeners();
    if (recordedBefore || agedOut) _save();
  }

  /// Adds a notification shown just now, and returns it so a toast that
  /// rewrites itself can [revise] it. Returns null when [dedupeKey] was
  /// already recorded.
  ///
  /// [origin] defaults to [currentOrigin]: most notifications answer
  /// something the user just did on the page they are looking at.
  NotificationRecord? record(
    String message, {
    NotificationSource source = NotificationSource.app,
    String? origin,
    String? detail,
    String? dedupeKey,
  }) {
    if (dedupeKey != null && _records.any((r) => r.dedupeKey == dedupeKey)) {
      return null;
    }
    final entry = NotificationRecord(
      at: DateTime.now(),
      message: message,
      source: source,
      origin: origin ?? currentOrigin?.call(),
      detail: detail,
      dedupeKey: dedupeKey,
    );
    _records.insert(0, entry);
    _changed();
    return entry;
  }

  /// Rewrites [entry]'s message in place, for a toast that changed what it
  /// says. Returns the replacement, or [entry] itself if it has aged out.
  NotificationRecord revise(NotificationRecord entry, String message) {
    final index = _records.indexOf(entry);
    if (index < 0 || entry.message == message) return entry;
    final revised = entry._withMessage(message);
    _records[index] = revised;
    _changed(deferSave: true);
    return revised;
  }

  void clear() {
    _records = [];
    _changed();
  }

  void _changed({bool deferSave = false}) {
    _prune();
    notifyListeners();
    if (!_persisted) return;
    if (deferSave) {
      _pendingSave ??= Timer(_reviseSaveDelay, _save);
    } else {
      _save();
    }
  }

  /// Drops records older than [retention]; returns whether any went.
  bool _prune() {
    final cutoff = DateTime.now().subtract(retention);
    final before = _records.length;
    _records.removeWhere((r) => r.at.isBefore(cutoff));
    return _records.length < before;
  }

  void _save() {
    _pendingSave?.cancel();
    _pendingSave = null;
    final json = jsonEncode([for (final r in _records) r.toJson()]);
    // A failed write is dropped; the next change writes the whole list again.
    _writeChain = _writeChain
        .then((_) async {
          // Written beside the file and renamed over it, so an exit
          // mid-write leaves the previous history rather than a truncated one.
          final file = await _file();
          final temp = File('${file.path}.tmp');
          await temp.writeAsString(json, flush: true);
          await temp.rename(file.path);
        })
        .catchError((Object _) {});
  }

  /// Settles once every save asked for so far has reached the disk.
  @visibleForTesting
  Future<void> get saved {
    if (_pendingSave != null) _save();
    return _writeChain;
  }

  Future<File> _file() async =>
      File(p.join((await appDataDirectory()).path, _fileName));
}
