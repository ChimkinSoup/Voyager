import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// The companion's end of the pipe Gaia's MCP shims connect to (GAIA_HLD.md
/// §5.3). A CLI that can't host Gaia's tools itself, Codex, launches
/// `voyager.exe --gaia-mcp`, which relays its stdio here
/// (`windows/runner/gaia_tool_pipe.cpp`).
///
/// A run [bind]s the process it launched; a shim is accepted only when that
/// process is among its ancestors, and its calls go to that run's tools.
/// Every other shim is dropped, so nothing but Gaia's own agents can call
/// them.
class GaiaToolPipe {
  GaiaToolPipe() {
    _channel.setMethodCallHandler(_onNative);
  }

  static const _channel = MethodChannel('voyager/gaia_tools');

  final _runs = <int, GaiaTurnTools>{};
  final _connections = <int, GaiaTurnTools>{};
  Future<bool>? _listening;

  /// Starts accepting shims, once; false when the pipe couldn't be created.
  Future<bool> listen() => _listening ??= _channel
      .invokeMethod<bool>('listen')
      .then((ok) => ok ?? false);

  /// Shims started under [pid] get [tools] until the returned function
  /// unbinds them, and drops their connections.
  void Function() bind(int pid, GaiaTurnTools tools) {
    _runs[pid] = tools;
    return () {
      if (_runs[pid] == tools) _runs.remove(pid);
      for (final MapEntry(key: id, :value) in [..._connections.entries]) {
        if (value != tools) continue;
        _connections.remove(id);
        unawaited(_channel.invokeMethod('drop', {'id': id}));
      }
    };
  }

  Future<void> _onNative(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, Object?>();
    final id = args['id']! as int;
    switch (call.method) {
      case 'connected':
        final ancestry = [
          for (final pid in (args['ancestry']! as String).split(','))
            int.parse(pid),
        ];
        final tools = ancestry.map((pid) => _runs[pid]).nonNulls.firstOrNull;
        if (tools == null) {
          debugPrint('[gaia] dropped a tool shim no run started: $ancestry');
          await _channel.invokeMethod('drop', {'id': id});
        } else {
          _connections[id] = tools;
        }
      case 'message':
        final tools = _connections[id];
        if (tools == null) return;
        final Object? message;
        try {
          message = jsonDecode(args['line']! as String);
        } on FormatException {
          return;
        }
        if (message is! Map) return;
        final answer = await gaiaMcpAnswer(message.cast(), tools);
        if (answer != null && _connections[id] == tools) {
          await _channel.invokeMethod('send', {
            'id': id,
            'line': jsonEncode(answer),
          });
        }
      case 'disconnected':
        if (_connections.remove(id) != null) {
          await _channel.invokeMethod('drop', {'id': id});
        }
    }
  }
}
