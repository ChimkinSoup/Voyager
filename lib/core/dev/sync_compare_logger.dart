import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _logFileName = 'sync_compare.log';
const _maxLogBytes = 2 * 1024 * 1024;

/// Persists local-vs-remote sync comparison results.
class SyncCompareLogger extends ChangeNotifier {
  Future<void>? _writeChain = Future<void>.value();

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
  }

  Future<void> log(String text) async {
    await _enqueue(() async {
      final file = File(await logFilePath());
      if (await file.exists()) {
        final length = await file.length();
        if (length > _maxLogBytes) {
          final contents = await file.readAsString();
          await file.writeAsString(
            contents.substring(contents.length - _maxLogBytes ~/ 2),
          );
        }
      }
      await file.writeAsString(text, mode: FileMode.append);
    });
  }

  Future<void> _enqueue(Future<void> Function() action) async {
    _writeChain = _writeChain!.then((_) => action()).catchError((_) {});
    await _writeChain;
  }
}
