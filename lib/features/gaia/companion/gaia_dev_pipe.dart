import 'dart:async';
import 'dart:io';

import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_image_render.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/host/gaia_capture.dart';
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
      case 'forkChat':
        await _store.forkChat(GaiaChat.fromJson(_map(p['chat'])), [
          for (final message in p['messages']! as List)
            GaiaMessage.fromJson(_map(message)),
        ]);
        return null;
      case 'rewindChat':
        await _store.rewindChat(
          p['chatId']! as String,
          fork: GaiaChat.fromJson(_map(p['fork'])),
          copies: [
            for (final message in p['copies']! as List)
              GaiaMessage.fromJson(_map(message)),
          ],
          dropped: [
            for (final message in p['dropped']! as List)
              GaiaMessage.fromJson(_map(message)),
          ],
          record: GaiaForkRecord.fromJson(p['record']),
          rewind: gaiaRewindsFromJson([p['rewind']]).single,
        );
        return null;
      case 'moveLate':
        await _store.moveLate(
          GaiaMessage.fromJson(_map(p['late'])),
          GaiaMessage.fromJson(_map(p['copy'])),
        );
        return null;
      case 'dropFork':
        await _store.dropFork(p['chatId']! as String);
        return null;
      case 'setSession':
        await _store.setSession(
          p['chatId']! as String,
          p['sessionId'] as String?,
          p['lastSeq']! as int,
          adapter: p['adapter'] as String? ?? kGaiaClaudeCodeAdapter,
        );
        return null;
      case 'setPinned':
        await _store.setPinned(p['chatId']! as String, p['pinned']! as bool);
        return null;
      case 'deleteChat':
        await _store.deleteChat(p['chatId']! as String);
        await _store.deleteDraft(p['chatId']! as String);
        return {'mediaDeletedAt': null};
      case 'restoreChat':
        await _store.restoreChat(p['chatId']! as String);
        await _store.restoreDraft(p['chatId']! as String);
        return null;
      case 'restorableChats':
        return await _store.restorableChatIds();
      case 'messages':
        return [
          for (final message in await _store.messages(p['chatId']! as String))
            message.toJson(),
        ];
      case 'searchMessages':
        return [
          for (final hit in await _store.searchMessages(p['query']! as String))
            hit.toJson(),
        ];
      case 'putMessage':
        final written = await _store.putMessage(
          GaiaMessage.fromJson(_map(p['message'])),
        );
        // The ticks as stored, which may be the Gaia page's.
        return written == null
            ? null
            : gaiaChecksToJson(gaiaChecksOf(written.parts));
      case 'toggleCheck':
        final written = await _store.toggleCheck(
          p['messageId']! as String,
          p['part']! as int,
          p['task']! as int,
          p['flipped']! as bool,
        );
        return written == null
            ? null
            : gaiaChecksToJson(gaiaChecksOf(written.parts));
      case 'rearm':
        _aborted = false;
        return null;
      case 'attachImage':
        // No media module: a copy stands in for the stored image, and its
        // path for its ids.
        final copy = await File(
          p['path']! as String,
        ).copy('${p['path']}.stored');
        final image = await gaiaDecodeImage(copy.path);
        final size = (image.width, image.height);
        image.dispose();
        return {
          'mediaId': copy.path,
          'referenceId': copy.path,
          'path': copy.path,
          'mimeType': 'image/png',
          'width': size.$1,
          'height': size.$2,
        };
      case 'detachImage':
        return null;
      case 'mediaFile':
        return p['mediaId'];
      case 'drafts':
        return [for (final draft in await _store.drafts()) draft.toJson()];
      case 'putDraft':
        await _store.putDraft(GaiaDraft.fromJson(_map(p['draft'])));
        return null;
      case 'ingestImage':
        // As attachImage: a copy, its path for its id. Its own, so an
        // image attached from the same file doesn't overwrite it.
        return (await File(
          p['path']! as String,
        ).copy('${p['path']}.draft')).path;
      case 'draftImageFile':
        final path = p['mediaId']! as String;
        return await File(path).exists() ? path : null;
      default:
        throw GaiaPipeException('unknown method $method');
    }
  }

  /// As the main instance's hotkey A (`small`), B (`large`) or G (`window`).
  void hotkey(String key) => onEvent?.call('hotkey', {'key': key});

  /// As the main instance's hotkey C (`region`) or D (`screen`).
  Future<void> capture(String kind) async {
    final capture = await gaiaCaptureScreen(
      '${Directory.systemTemp.path}\\gaia-dev-${DateTime.now().microsecondsSinceEpoch}.bmp',
    );
    if (capture == null) return;
    onEvent?.call('capture', {
      'kind': kind,
      'path': capture.path,
      'left': capture.left,
      'top': capture.top,
      'width': capture.width,
      'height': capture.height,
    });
  }

  /// As the main instance's Abort hotkey.
  Future<void> abort() async {
    _aborted = true;
    await onRequest?.call('abort', const {});
  }

  static Map<String, Object?> _map(Object? value) =>
      (value! as Map).cast<String, Object?>();
}
