import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voyager/core/constants/build_info.dart';

const _logFileName = 'voyager_errors.log';
const _maxLogBytes = 1024 * 1024;
const _recordRule = '--------------------------------------------------------';

/// Writes every uncaught error, and every one reported through
/// [FlutterError.reportError], to a file with its stack trace and build.
///
/// Always on: a release build has no console, so without this an error leaves
/// nothing behind but its symptom. Chains onto whatever handlers are already
/// installed rather than replacing them, so debug output is unchanged.
class ErrorLogger {
  ErrorLogger._();

  @visibleForTesting
  ErrorLogger.forTesting();

  static final instance = ErrorLogger._();

  /// An error identical to the last one within this window is counted rather
  /// than written, so a widget that throws on every frame can't flood the log.
  static const _repeatWindow = Duration(seconds: 10);

  String? _lastKey;
  DateTime? _lastAt;
  var _repeats = 0;

  /// Only `main` installs, so a test that reaches a failure path which calls
  /// [record] writes nothing, rather than into the real Documents folder.
  var _installed = false;

  Future<void> _writeChain = Future<void>.value();

  /// Hooks both error channels. Called once from `main`, before anything that
  /// wraps [FlutterError.onError] to filter known noise.
  void install() {
    _installed = true;
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      record(
        details.exception,
        details.stack,
        context: [
          if (details.library != null) details.library!,
          if (details.context != null) details.context!.toDescription(),
        ].join(' '),
      );
      if (previousFlutter != null) {
        previousFlutter(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    final previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, context: 'uncaught');
      // False leaves the engine's own reporting in place.
      return previousPlatform?.call(error, stack) ?? false;
    };

    _enqueue(
      (file) => file.writeAsString(
        '\n=== APP START ${_stamp(DateTime.now())}  build $buildLabel '
        '(${_buildMode()}) ===\n',
        mode: FileMode.append,
        flush: true,
      ),
    );
  }

  /// Also called directly from `catch` blocks that handle a failure but
  /// should still leave a record of it. Does nothing until [install].
  void record(Object error, StackTrace? stack, {String context = ''}) {
    if (!_installed) return;
    final now = DateTime.now();
    final key = '$context|$error';
    final lastAt = _lastAt;
    if (key == _lastKey &&
        lastAt != null &&
        now.difference(lastAt) < _repeatWindow) {
      _repeats++;
      _lastAt = now;
      return;
    }

    final text = StringBuffer();
    if (_repeats > 0) {
      text.writeln('  (previous error repeated $_repeats more times)');
    }
    _lastKey = key;
    _lastAt = now;
    _repeats = 0;

    text
      ..writeln(_recordRule)
      ..writeln('${_stamp(now)}  ERROR  build $buildLabel (${_buildMode()})')
      ..writeln(context.isEmpty ? '  $error' : '  $context: $error')
      ..writeln(stack?.toString().trimRight() ?? '  (no stack trace)');
    final entry = text.toString();
    _enqueue((file) async {
      await _trimIfNeeded(file);
      await file.writeAsString(entry, mode: FileMode.append, flush: true);
    });
  }

  Future<String> logFilePath() async => p.join(await directory(), _logFileName);

  Future<String> readLog() async {
    await _writeChain;
    final file = File(await logFilePath());
    if (!await file.exists()) return '';
    return file.readAsString();
  }

  Future<void> clearLog() async {
    await _writeChain;
    final file = File(await logFilePath());
    if (await file.exists()) await file.writeAsString('');
  }

  Future<void> _trimIfNeeded(File file) async {
    if (!await file.exists()) return;
    if (await file.length() <= _maxLogBytes) return;
    final content = await file.readAsString();
    final tail = content.substring(content.length - _maxLogBytes ~/ 2);
    final nextRecord = tail.indexOf(_recordRule);
    await file.writeAsString(
      '... log truncated ...\n'
      '${nextRecord >= 0 ? tail.substring(nextRecord) : tail}',
      flush: true,
    );
  }

  /// A failed write is dropped: reporting it would come straight back here.
  void _enqueue(Future<void> Function(File file) write) {
    _writeChain = _writeChain
        .then((_) async => write(File(await logFilePath())))
        .catchError((Object _) {});
  }

  /// Where the log lives. Replaced in tests: on a Windows host
  /// `path_provider` resolves the real Documents folder even under
  /// `flutter test`.
  @visibleForTesting
  static Future<String> Function() directory = () async =>
      (await getApplicationDocumentsDirectory()).path;

  static String _buildMode() =>
      kDebugMode ? 'debug' : (kProfileMode ? 'profile' : 'release');

  static String _stamp(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}:${two(at.second)}'
        '.${at.millisecond.toString().padLeft(3, '0')}';
  }
}
