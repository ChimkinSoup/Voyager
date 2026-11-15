import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// One draft sent from the composer, as it stood when Enter was pressed.
typedef GaiaHistoryEntry = ({String text, DateTime at});

/// What the composer sent, for Up and Down to bring back
/// (GAIA_HISTORY_HLD.md). One history for every chat, local to this desktop
/// and never synced, like `GaiaCommandUses`: kept in a JSON [file] beside
/// Gaia's other files. Null in tests, which keep nothing.
class GaiaCommandHistory {
  GaiaCommandHistory({this.file});

  final File? file;

  /// Oldest first.
  var entries = <GaiaHistoryEntry>[];

  static const _kept = 100;

  Future<void> load() async {
    final file = this.file;
    if (file == null || !await file.exists()) return;
    try {
      entries = [
        for (final entry in jsonDecode(await file.readAsString()) as List)
          (
            text: entry['text'] as String,
            at: DateTime.parse(entry['at'] as String),
          ),
      ];
    } catch (error) {
      debugPrint('[gaia] history unreadable, starting over: $error');
    }
  }

  /// [text] as the newest entry, unless it's blank or the newest already.
  void add(String text) {
    if (text.trim().isEmpty) return;
    if (entries.isNotEmpty && entries.last.text == text) return;
    entries = [...entries, (text: text, at: DateTime.now().toUtc())];
    if (entries.length > _kept) entries.removeRange(0, entries.length - _kept);
    // In turn, so an older write never lands after a newer one.
    _saved = _saved.then((_) => _save());
  }

  var _saved = Future<void>.value();

  /// Done once every write so far has landed.
  @visibleForTesting
  Future<void> get saved => _saved;

  Future<void> _save() async {
    final file = this.file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final entries = this.entries;
      // Off the UI isolate: long pastes can make it megabytes.
      final json = await Isolate.run(
        () => jsonEncode([
          for (final entry in entries)
            {'text': entry.text, 'at': entry.at.toIso8601String()},
        ]),
      );
      await file.writeAsString(json);
    } catch (error) {
      debugPrint('[gaia] history not saved: $error');
    }
  }
}
