import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';
import 'package:voyager/features/gaia/remote/gaia_remote.dart';

final _ed25519 = Ed25519();

/// This device's signing key (§12.2), made once and kept in the app's own
/// data folder, never synced: a command it signs is one only this device
/// could have sent.
class GaiaDeviceKey {
  GaiaDeviceKey._(this._pair, this.publicKey);

  final SimpleKeyPair _pair;

  /// Base64, as `gaia_devices` holds it.
  final String publicKey;

  static Future<File> _defaultFile() async =>
      File(p.join((await appDataDirectory()).path, 'gaia_device_key.json'));

  /// Throws the key away: a device revoked pairs again with a new one,
  /// which no desktop has refused.
  static Future<void> reset({File? file}) async {
    file ??= await _defaultFile();
    if (await file.exists()) await file.delete();
  }

  /// The key in [file], made and saved there first when there's none.
  static Future<GaiaDeviceKey> load({File? file}) async {
    file ??= await _defaultFile();
    if (await file.exists()) {
      final json = (jsonDecode(await file.readAsString()) as Map)
          .cast<String, Object?>();
      final seed = base64Decode(json['seed']! as String);
      final pair = await _ed25519.newKeyPairFromSeed(seed);
      return GaiaDeviceKey._(pair, await _publicOf(pair));
    }
    final pair = await _ed25519.newKeyPair();
    final seed = await pair.extractPrivateKeyBytes();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'seed': base64Encode(seed)}));
    return GaiaDeviceKey._(pair, await _publicOf(pair));
  }

  static Future<String> _publicOf(SimpleKeyPair pair) async =>
      base64Encode((await pair.extractPublicKey()).bytes);

  Future<GaiaRemoteCommand> sign(GaiaRemoteCommand command) async {
    final signature = await _ed25519.sign(command.signedBytes, keyPair: _pair);
    return command.signed(base64Encode(signature.bytes));
  }
}

/// Whether [command]'s signature is [publicKey]'s.
Future<bool> gaiaVerifyCommand(
  GaiaRemoteCommand command,
  String publicKey,
) async {
  try {
    return await _ed25519.verify(
      command.signedBytes,
      signature: Signature(
        base64Decode(command.signature),
        publicKey: SimplePublicKey(
          base64Decode(publicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    );
  } on FormatException {
    return false;
  } on StateError {
    // A signature of the wrong length.
    return false;
  }
}

/// The keys a desktop trusts commands from (§12.2), pinned when the user
/// confirmed a device's pairing code on it, in a file of its own, never
/// synced. Firestore's `gaia_devices` is where a device asks; what's
/// trusted is only ever what's here, so someone who can write to the
/// user's Firestore can't add a key, or swap one.
///
/// A key revoked anywhere is dropped here for good: [revoked] keeps it, so
/// a device document written back without its `revokedAt` doesn't restore
/// it.
class GaiaTrustStore {
  GaiaTrustStore(this._file);

  static Future<GaiaTrustStore> load({File? file}) async {
    final store = GaiaTrustStore(
      file ??
          File(
            p.join(
              (await appDataDirectory()).path,
              'gaia_trusted_devices.json',
            ),
          ),
    );
    await store._read();
    return store;
  }

  final File _file;

  /// Public key by device id.
  final trusted = <String, String>{};
  final revoked = <String>{};

  Future<void> _read() async {
    if (!await _file.exists()) return;
    try {
      final json = (jsonDecode(await _file.readAsString()) as Map)
          .cast<String, Object?>();
      trusted.addAll(
        ((json['trusted'] as Map?) ?? const {}).cast<String, String>(),
      );
      revoked.addAll(((json['revoked'] as List?) ?? const []).cast<String>());
    } on FormatException {
      // A file cut short: trusting nothing is the safe way to be wrong.
    }
  }

  Future<void> _write() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({'trusted': trusted, 'revoked': revoked.toList()}),
    );
  }

  /// The key [deviceId] signs with, if it's trusted here.
  String? keyOf(String deviceId) {
    final key = trusted[deviceId];
    return key == null || revoked.contains(key) ? null : key;
  }

  Future<void> trust(String deviceId, String publicKey) async {
    if (revoked.contains(publicKey)) return;
    trusted[deviceId] = publicKey;
    await _write();
  }

  /// [publicKey] never trusted again here, whichever device shows it.
  Future<void> revoke(String publicKey) async {
    final had = revoked.length;
    revoked.add(publicKey);
    trusted.removeWhere((_, key) => key == publicKey);
    if (revoked.length != had) await _write();
  }
}

/// The commands a desktop has run (§12.2), on disk so a restart doesn't
/// forget them: a command put back under its own id, signature intact, would
/// otherwise run again for as long as it's fresh. Each line is `createdAt id`,
/// appended, so a crash costs at most the line it was writing. Entries too
/// old to run anyway are dropped when the file is loaded.
class GaiaCommandLog {
  GaiaCommandLog._(this._file, this._ran);

  static Future<GaiaCommandLog> load({
    File? file,
    DateTime Function()? clock,
  }) async {
    file ??= File(
      p.join((await appDataDirectory()).path, 'gaia_commands_run.log'),
    );
    final now = (clock ?? DateTime.now)().millisecondsSinceEpoch;
    final kept = <String, int>{};
    if (await file.exists()) {
      // Latin-1 reads any bytes, so a damaged line is only skipped.
      for (final line in await file.readAsLines(encoding: latin1)) {
        final space = line.indexOf(' ');
        final createdAt = int.tryParse(line.substring(0, max(space, 0)));
        if (createdAt == null) continue;
        if (now - createdAt <= kGaiaCommandMaxAge.inMilliseconds) {
          kept[line.substring(space + 1)] = createdAt;
        }
      }
    } else {
      await file.parent.create(recursive: true);
    }
    // Through a temporary file: a crash here leaves the old log whole.
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      [
        for (final MapEntry(:key, :value) in kept.entries) '$value $key\n',
      ].join(),
      flush: true,
    );
    await temporary.rename(file.path);
    return GaiaCommandLog._(file, kept.keys.toSet());
  }

  final File _file;
  final Set<String> _ran;

  bool hasRun(String id) => _ran.contains(id);

  /// Throws if it can't be saved: the caller must not run the command then.
  Future<void> add(GaiaRemoteCommand command) async {
    await _file.writeAsString(
      '${command.createdAt} ${command.id}\n',
      mode: FileMode.append,
      flush: true,
    );
    _ran.add(command.id);
  }
}
