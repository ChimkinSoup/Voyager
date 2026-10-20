import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';

/// The on-disk half of the vault's images: `<app data>/vault_media/{id}` and
/// `{id}.thumb`, each the sealed bytes exactly as they are in Storage. Nothing
/// here can read them, and nothing plain is ever written here.
class VaultMediaFileStore {
  VaultMediaFileStore({Directory? root}) : _explicitRoot = root;

  /// Set by tests to a temp directory.
  final Directory? _explicitRoot;
  Directory? _resolvedRoot;

  Future<Directory> root() async {
    final cached = _resolvedRoot ?? _explicitRoot;
    if (cached != null) {
      if (!await cached.exists()) await cached.create(recursive: true);
      return cached;
    }
    final data = await appDataDirectory();
    final dir = Directory(p.join(data.path, 'vault_media'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _resolvedRoot = dir;
  }

  /// [id] arrives from synced and restored records, so it is refused unless
  /// it is a bare name.
  Future<File> _file(String id, {required bool thumb}) async {
    if (!_bareName.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'not a bare name');
    }
    final dir = await root();
    return File(p.join(dir.path, thumb ? '$id.thumb' : id));
  }

  Future<Uint8List?> read(String id, {required bool thumb}) async {
    final file = await _file(id, thumb: thumb);
    return await file.exists() ? file.readAsBytes() : null;
  }

  /// [id]'s file, when it is here.
  Future<File?> find(String id, {required bool thumb}) async {
    final file = await _file(id, thumb: thumb);
    return await file.exists() ? file : null;
  }

  Future<void> write(String id, Uint8List sealed, {required bool thumb}) async {
    await (await _file(id, thumb: thumb)).writeAsBytes(sealed, flush: true);
  }

  /// Both of [id]'s files. Missing is success.
  Future<void> delete(String id) async {
    if (!_bareName.hasMatch(id)) return;
    for (final thumb in [false, true]) {
      final file = await _file(id, thumb: thumb);
      if (await file.exists()) await file.delete();
    }
  }

  /// Files no row in [liveIds] claims — see `MediaFileStore.orphanedFiles`.
  Future<List<File>> orphanedFiles(Set<String> liveIds) async {
    final dir = await root();
    final orphans = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final id = p.basenameWithoutExtension(entity.path);
      if (!liveIds.contains(id)) orphans.add(entity);
    }
    return orphans;
  }
}

final _bareName = RegExp(r'^[A-Za-z0-9_-]+$');
