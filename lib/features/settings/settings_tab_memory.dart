import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';

const _fileName = 'settings_tab.txt';

/// The Settings tab last open on this device, kept across restarts.
///
/// Device-local on purpose, like `FinanceUiPrefs`: which tab is open is where
/// the user is on this screen, not a preference, so it stays out of
/// AppSettings and never syncs. Read once in `main`, before anything can build
/// Settings, because the tab controller wants its first tab synchronously.
class SettingsTabMemory {
  SettingsTabMemory._();

  /// The tab's label rather than its index, so a tab added or reordered later
  /// does not reopen Settings on the wrong one.
  static String? lastTab;

  /// Only `main` loads, so a test switching tabs writes nothing to disk.
  static var _persisted = false;

  static Future<void> _writeChain = Future<void>.value();

  static Future<void> load() async {
    _persisted = true;
    try {
      final file = await _file();
      if (await file.exists()) {
        final label = (await file.readAsString()).trim();
        if (label.isNotEmpty) lastTab = label;
      }
    } catch (_) {
      // Settings opens on its first tab.
    }
  }

  static void remember(String label) {
    if (label == lastTab) return;
    lastTab = label;
    if (!_persisted) return;
    // A failed write costs one tab position on the next launch.
    _writeChain = _writeChain
        .then((_) async {
          await (await _file()).writeAsString(label, flush: true);
        })
        .catchError((Object _) {});
  }

  static Future<File> _file() async =>
      File(p.join((await appDataDirectory()).path, _fileName));
}
