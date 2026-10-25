import 'dart:async';

import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';

/// `--gaia-dev` only: stands in for the main instance, so the companion runs
/// on its own under `flutter run` and its UI hot reloads. Answers the
/// companion's requests as `GaiaHost` does, from an in-memory database, and
/// sends the main instance's `hotkey` events and `abort` request on cue.
class GaiaDevPipe extends GaiaPipe {
  final _store = GaiaChatStore(
    DriftGaiaRepository(AppDatabase.inMemory()),
    deviceId: 'gaia-dev',
  );
  var _aborted = false;

  @override
  bool get connected => true;

  @override
  Future<bool> connect() async {
    scheduleMicrotask(() => onConnected?.call());
    return true;
  }

  @override
  Future<void> close() async {}

  @override
  void notify(String event, [Map<String, Object?>? params]) {}

  @override
  Future<Object?> request(String method, [Map<String, Object?>? params]) async {
    final p = params ?? const {};
    switch (method) {
      case 'hello':
        return {
          'aborted': _aborted,
          'accent': 0xFF7C9EFF,
          'deviceId': _store.deviceId,
          'settings': GaiaSettings.initial().toJson(),
        };
      case 'chats':
        return [for (final chat in await _store.chats()) chat.toJson()];
      case 'putChat':
        await _store.createChat(GaiaChat.fromJson(_map(p['chat'])));
        return null;
      case 'setSession':
        await _store.setSession(
          p['chatId']! as String,
          p['sessionId']! as String,
          p['lastSeq']! as int,
        );
        return null;
      case 'messages':
        return [
          for (final message in await _store.messages(p['chatId']! as String))
            message.toJson(),
        ];
      case 'putMessage':
        await _store.putMessage(GaiaMessage.fromJson(_map(p['message'])));
        return null;
      case 'rearm':
        _aborted = false;
        return null;
      default:
        throw GaiaPipeException('unknown method $method');
    }
  }

  /// As the main instance's hotkey A (`small`), B (`large`) or G (`window`).
  void hotkey(String key) => onEvent?.call('hotkey', {'key': key});

  /// As the main instance's Abort hotkey.
  Future<void> abort() async {
    _aborted = true;
    await onRequest?.call('abort', const {});
  }

  static Map<String, Object?> _map(Object? value) =>
      (value! as Map).cast<String, Object?>();
}
