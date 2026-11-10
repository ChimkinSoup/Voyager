import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// The `/` palette's commands by when they were last used, most recent
/// first, so the palette puts them first among equal matches.
/// Local to this desktop and never synced, like `GaiaSidebar`: kept in a
/// JSON [file] beside Gaia's other files. Null in tests, which keep nothing.
class GaiaCommandUses {
  GaiaCommandUses({this.file});

  final File? file;

  /// Command names, without the slash.
  var recent = <String>[];

  /// Enough for every command a user could have in mind.
  static const _kept = 50;

  Future<void> load() async {
    final file = this.file;
    if (file == null || !await file.exists()) return;
    try {
      recent = [
        for (final name in jsonDecode(await file.readAsString()) as List)
          name as String,
      ];
    } catch (error) {
      debugPrint('[gaia] command uses unreadable, starting over: $error');
    }
  }

  void use(String name) {
    recent = [name, ...recent.where((n) => n != name)].take(_kept).toList();
    // In turn, so an older write never lands after a newer one.
    _saved = _saved.then((_) => _save());
  }

  var _saved = Future<void>.value();

  Future<void> _save() async {
    final file = this.file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(recent));
    } catch (error) {
      debugPrint('[gaia] command uses not saved: $error');
    }
  }
}
