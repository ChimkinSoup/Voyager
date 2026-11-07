import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// What the `os_*` reads answered (GAIA_HLD.md §15.6), kept on this device
/// alone so the user can see under each call what Gaia read: one file per
/// call, `<chatId>/<callId>.json`. Never synced: another device shows the call
/// without it.
class GaiaToolResultStore {
  GaiaToolResultStore(this.root);

  final Directory root;

  /// The calls each chat listed so far has kept, by their file names.
  final _kept = <String, Set<String>>{};

  /// Ids may come from a backend: only what's safe as a file name.
  static String _safe(String id) =>
      id.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');

  Directory _chat(String chatId) => Directory(p.join(root.path, _safe(chatId)));

  File _file(String chatId, String callId) =>
      File(p.join(_chat(chatId).path, '${_safe(callId)}.json'));

  /// Whether call [callId] of [chatId] is kept here, once [list] has read the
  /// chat's.
  bool has(String chatId, String callId) =>
      _kept[chatId]?.contains(_safe(callId)) ?? false;

  /// Reads which calls [chatId] has kept, for [has].
  Future<void> list(String chatId) async {
    final directory = _chat(chatId);
    final names = <String>{};
    if (await directory.exists()) {
      await for (final entity in directory.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          names.add(p.basenameWithoutExtension(entity.path));
        }
      }
    }
    // Added to, not replaced: a run may save one while this lists.
    (_kept[chatId] ??= {}).addAll(names);
  }

  Future<void> save(String chatId, String callId, GaiaToolResult result) async {
    final file = _file(chatId, callId);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'text': result.text,
        'image': ?result.image,
        'mimeType': ?result.mimeType,
      }),
    );
    (_kept[chatId] ??= {}).add(_safe(callId));
  }

  /// Null when it isn't kept here, or can't be read.
  Future<GaiaToolResult?> read(String chatId, String callId) async {
    try {
      final json =
          (jsonDecode(await _file(chatId, callId).readAsString()) as Map)
              .cast<String, Object?>();
      return GaiaToolResult(
        text: json['text']! as String,
        isError: false,
        image: json['image'] as String?,
        mimeType: json['mimeType'] as String?,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// [callIds]' results of [from] kept for [to] too, as a fork's copies of
  /// their messages show them.
  Future<void> copy(String from, String to, Iterable<String> callIds) async {
    for (final callId in callIds) {
      final file = _file(from, callId);
      if (!await file.exists()) continue;
      final copy = _file(to, callId);
      await copy.parent.create(recursive: true);
      await file.copy(copy.path);
      (_kept[to] ??= {}).add(_safe(callId));
    }
  }

  /// Forgets [callIds] of [chatId].
  Future<void> remove(String chatId, Iterable<String> callIds) async {
    for (final callId in callIds) {
      final file = _file(chatId, callId);
      if (await file.exists()) await file.delete();
      _kept[chatId]?.remove(_safe(callId));
    }
  }

  /// Deletes every chat's results but [chatIds]': those of chats deleted, here
  /// or elsewhere, once they can't be restored.
  Future<void> prune(Set<String> chatIds) async {
    if (!await root.exists()) return;
    final keep = {for (final id in chatIds) _safe(id)};
    await for (final entity in root.list()) {
      if (entity is Directory && !keep.contains(p.basename(entity.path))) {
        await entity.delete(recursive: true);
        _kept.remove(p.basename(entity.path));
      }
    }
  }
}

/// The ids of [messages]' calls whose results may be kept.
Iterable<String> gaiaKeptCallIds(Iterable<GaiaMessage> messages) => [
  for (final message in messages)
    for (final part in message.parts.whereType<GaiaActivityPart>())
      ...part.ids.nonNulls,
];
