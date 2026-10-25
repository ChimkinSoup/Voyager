import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';
import 'package:win32/win32.dart';

/// The utility model's API key (GAIA_HLD.md §5.1): on this device only,
/// encrypted to the Windows account with DPAPI, so no password is needed to
/// use it and no other account or machine can read it. Never synced.
///
/// The Gaia page writes it in the main instance; the companion reads it
/// when a utility job runs, so it never crosses the pipe.
class GaiaSecrets {
  GaiaSecrets({Future<File> Function()? file}) : _file = file ?? _defaultFile;

  final Future<File> Function() _file;

  static Future<File> _defaultFile() async =>
      File(p.join((await appSupportRoot()).path, 'gaia', 'utility_key.bin'));

  /// Null when none is saved, or it can't be decrypted (another account's).
  Future<String?> readUtilityKey() async {
    final file = await _file();
    if (!await file.exists()) return null;
    final plain = _unprotect(await file.readAsBytes());
    return plain == null ? null : utf8.decode(plain);
  }

  /// Null or empty removes it.
  Future<void> writeUtilityKey(String? key) async {
    final file = await _file();
    if (key == null || key.trim().isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsBytes(_protect(utf8.encode(key.trim())));
  }
}

/// `CRYPTPROTECT_UI_FORBIDDEN`: fail rather than show a prompt.
const _uiForbidden = 0x1;

Uint8List _protect(List<int> plain) =>
    _crypt(plain, protect: true) ??
    (throw const FileSystemException('CryptProtectData failed'));

Uint8List? _unprotect(List<int> cipher) => _crypt(cipher, protect: false);

Uint8List? _crypt(List<int> data, {required bool protect}) {
  return using((arena) {
    final input = arena<CRYPT_INTEGER_BLOB>();
    final output = arena<CRYPT_INTEGER_BLOB>();
    final bytes = arena<Uint8>(data.length);
    bytes.asTypedList(data.length).setAll(0, data);
    input.ref
      ..cbData = data.length
      ..pbData = bytes;
    final ok = protect
        ? CryptProtectData(
            input,
            nullptr,
            nullptr,
            nullptr,
            nullptr,
            _uiForbidden,
            output,
          )
        : CryptUnprotectData(
            input,
            nullptr,
            nullptr,
            nullptr,
            nullptr,
            _uiForbidden,
            output,
          );
    if (ok == 0) return null;
    try {
      return Uint8List.fromList(
        output.ref.pbData.asTypedList(output.ref.cbData),
      );
    } finally {
      LocalFree(output.ref.pbData);
    }
  });
}
