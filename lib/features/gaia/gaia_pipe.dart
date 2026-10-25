import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// The main instance <-> companion named pipe (GAIA_HLD.md §3.2), and the
/// request/response protocol on it. Both processes use it: the main instance
/// with [startCompanion], the companion with [connect].
///
/// The pipe itself is native (`windows/runner/gaia_pipe.cpp`): created for the
/// current user only, and each end checks the other's PID. Frames are JSON:
/// `{id, method, params}` for a request, `{id, result}` or `{id, error}` for
/// its response, `{event, params}` for a one-way event.
class GaiaPipe {
  GaiaPipe() {
    _channel.setMethodCallHandler(_onNative);
  }

  static const _channel = MethodChannel('voyager/gaia_pipe');

  /// Answers the other side's requests: returns the result, or throws.
  Future<Object?> Function(String method, Map<String, Object?> params)?
  onRequest;

  void Function(String event, Map<String, Object?> params)? onEvent;

  void Function()? onConnected;

  /// Also when a connection never came about: the companion exited first, or
  /// the main instance never answered.
  void Function()? onDisconnected;

  bool get connected => _connected;
  var _connected = false;

  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;

  /// Main instance: launches the companion and listens for it. Returns its
  /// PID, or 0 when it could not be launched.
  Future<int> startCompanion() async =>
      await _channel.invokeMethod<int>('startCompanion') ?? 0;

  /// Companion: connects to the main instance that launched it.
  Future<bool> connect() async =>
      await _channel.invokeMethod<bool>('connect') ?? false;

  Future<void> close() => _channel.invokeMethod('close');

  /// Sends a request and waits for its response. Throws [GaiaPipeException]
  /// when the other side answers with an error or goes away first.
  Future<Object?> request(String method, [Map<String, Object?>? params]) {
    if (!_connected) {
      return Future.error(GaiaPipeException('not connected'));
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _send({'id': id, 'method': method, 'params': params ?? const {}});
    return completer.future;
  }

  void notify(String event, [Map<String, Object?>? params]) {
    if (!_connected) return;
    _send({'event': event, 'params': params ?? const {}});
  }

  void _send(Map<String, Object?> frame) =>
      unawaited(_channel.invokeMethod('send', jsonEncode(frame)));

  Future<void> _onNative(MethodCall call) async {
    switch (call.method) {
      case 'connected':
        _connected = true;
        onConnected?.call();
      case 'disconnected':
        _connected = false;
        final pending = [..._pending.values];
        _pending.clear();
        for (final completer in pending) {
          completer.completeError(GaiaPipeException('disconnected'));
        }
        onDisconnected?.call();
      case 'message':
        _onFrame(
          (jsonDecode(call.arguments as String) as Map).cast<String, Object?>(),
        );
    }
  }

  void _onFrame(Map<String, Object?> frame) {
    final id = frame['id'] as int?;
    final method = frame['method'] as String?;
    final params = (frame['params'] as Map?)?.cast<String, Object?>() ?? {};
    if (method != null && id != null) {
      unawaited(_answer(id, method, params));
    } else if (id != null) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (frame.containsKey('error')) {
        completer.completeError(GaiaPipeException(frame['error'].toString()));
      } else {
        completer.complete(frame['result']);
      }
    } else if (frame['event'] case final String event) {
      onEvent?.call(event, params);
    }
  }

  Future<void> _answer(
    int id,
    String method,
    Map<String, Object?> params,
  ) async {
    try {
      final handler = onRequest;
      if (handler == null) throw GaiaPipeException('no handler');
      _send({'id': id, 'result': await handler(method, params)});
    } catch (error) {
      _send({'id': id, 'error': '$error'});
    }
  }
}

class GaiaPipeException implements Exception {
  GaiaPipeException(this.message);

  final String message;

  @override
  String toString() => 'GaiaPipeException: $message';
}
