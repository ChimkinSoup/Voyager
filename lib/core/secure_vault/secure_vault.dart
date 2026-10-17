import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';

/// How a password is stretched into the key that wraps the vault's data key.
///
/// Stored in the header, so the settings can change later without breaking a
/// vault made under the old ones: unlocking uses what the header says, and a
/// password change re-wraps under [SecureVaultKdf.current].
class SecureVaultKdf {
  const SecureVaultKdf({
    required this.name,
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
  });

  /// OWASP's Argon2id minimum: 19 MiB, 2 passes, 1 lane. About 60 ms on a
  /// desktop in release mode.
  static const current = SecureVaultKdf(
    name: 'argon2id',
    memoryKiB: 19 * 1024,
    iterations: 2,
    parallelism: 1,
  );

  final String name;
  final int memoryKiB;
  final int iterations;
  final int parallelism;

  Map<String, dynamic> toJson() => {
    'name': name,
    'memoryKiB': memoryKiB,
    'iterations': iterations,
    'parallelism': parallelism,
  };

  factory SecureVaultKdf.fromJson(Map<String, dynamic> json) => SecureVaultKdf(
    name: json['name'] as String,
    memoryKiB: (json['memoryKiB'] as num).toInt(),
    iterations: (json['iterations'] as num).toInt(),
    parallelism: (json['parallelism'] as num).toInt(),
  );
}

/// The vault's one shared document (`users/{uid}/secure_vault/header`): what
/// a password needs to recover the data key, and nothing that reveals it.
class SecureVaultHeader {
  const SecureVaultHeader({
    required this.vaultId,
    required this.kdf,
    required this.salt,
    required this.wrappedKey,
    required this.wrapNonce,
    required this.headerVersion,
    required this.updatedAt,
    this.retiredVaultIds = const [],
  });

  /// Names this vault. Every note is bound to it, so a note from a vault that
  /// has since been reset can never be read with the new one's key.
  final String vaultId;
  final SecureVaultKdf kdf;
  final List<int> salt;

  /// The data key, encrypted with the password key (AES-GCM, tag included).
  final List<int> wrappedKey;
  final List<int> wrapNonce;

  /// Bumped by every password change and reset, so two devices can't each
  /// write their own over the other's.
  final int headerVersion;
  final DateTime updatedAt;

  /// Every vault this one replaced, through resets. A note sealed under one of
  /// them can never be read again, so every device deletes it. A vault id this
  /// list doesn't name may be a newer vault this device hasn't heard of yet.
  final List<String> retiredVaultIds;

  Map<String, dynamic> toJson() => {
    'vaultId': vaultId,
    'kdf': kdf.toJson(),
    'salt': base64Encode(salt),
    'wrappedKey': base64Encode(wrappedKey),
    'wrapNonce': base64Encode(wrapNonce),
    'headerVersion': headerVersion,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'retiredVaultIds': retiredVaultIds,
  };

  factory SecureVaultHeader.fromJson(Map<String, dynamic> json) =>
      SecureVaultHeader(
        vaultId: json['vaultId'] as String,
        kdf: SecureVaultKdf.fromJson(
          Map<String, dynamic>.from(json['kdf'] as Map),
        ),
        salt: base64Decode(json['salt'] as String),
        wrappedKey: base64Decode(json['wrappedKey'] as String),
        wrapNonce: base64Decode(json['wrapNonce'] as String),
        headerVersion: (json['headerVersion'] as num).toInt(),
        updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
        retiredVaultIds: [
          for (final id in json['retiredVaultIds'] as List? ?? const [])
            id as String,
        ],
      );
}

/// One encrypted note body. [ciphertext] carries the GCM tag at its end.
class SecureBox {
  const SecureBox({required this.ciphertext, required this.nonce});

  final List<int> ciphertext;
  final List<int> nonce;
}

/// Thrown by [SecureVault.decrypt] for a box that fails authentication —
/// tampered with, or sealed under another vault or key.
class SecureVaultTamperedException implements Exception {
  const SecureVaultTamperedException();

  @override
  String toString() => 'SecureVaultTamperedException';
}

/// The Secure Notes vault's cryptography: a random data key encrypts the
/// notes, and the password only wraps that key — so a password change
/// re-wraps one key instead of re-encrypting every note.
///
/// Notes use AES-256-GCM under a fresh 12-byte nonce on every save. The
/// authenticated data is the [SecureVaultHeader.vaultId] alone, not the note
/// id, so a conflict fork can carry ciphertext to a new note id while the
/// vault is locked.
abstract final class SecureVault {
  static final _aes = AesGcm.with256bits();

  /// A new vault under [password], and its data key.
  static Future<({SecureVaultHeader header, SecretKey key})> create(
    String password, {
    required String vaultId,
    required DateTime now,
    int headerVersion = 1,
    List<String> retiredVaultIds = const [],
  }) async {
    final key = await _aes.newSecretKey();
    final header = await _wrap(
      key,
      password,
      vaultId: vaultId,
      headerVersion: headerVersion,
      now: now,
      retiredVaultIds: retiredVaultIds,
    );
    return (header: header, key: key);
  }

  /// The data key, or null when [password] is wrong.
  static Future<SecretKey?> unlock(
    SecureVaultHeader header,
    String password,
  ) async {
    final passwordKey = await _derive(password, header.salt, header.kdf);
    try {
      final bytes = await _aes.decrypt(
        _split(header.wrappedKey, header.wrapNonce),
        secretKey: SecretKey(passwordKey),
        aad: utf8.encode(header.vaultId),
      );
      return SecretKeyData(bytes);
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  /// [header] re-wrapped under [newPassword] — the notes are untouched.
  static Future<SecureVaultHeader> rewrap(
    SecureVaultHeader header,
    SecretKey key,
    String newPassword, {
    required DateTime now,
  }) => _wrap(
    key,
    newPassword,
    vaultId: header.vaultId,
    headerVersion: header.headerVersion + 1,
    now: now,
    retiredVaultIds: header.retiredVaultIds,
  );

  static Future<SecureBox> encrypt(
    SecretKey key,
    String vaultId,
    String text,
  ) async {
    final box = await _aes.encrypt(
      utf8.encode(text),
      secretKey: key,
      nonce: _aes.newNonce(),
      aad: utf8.encode(vaultId),
    );
    return SecureBox(
      ciphertext: [...box.cipherText, ...box.mac.bytes],
      nonce: box.nonce,
    );
  }

  /// Throws [SecureVaultTamperedException] for a box that fails
  /// authentication.
  static Future<String> decrypt(
    SecretKey key,
    String vaultId,
    SecureBox box,
  ) async {
    try {
      final bytes = await _aes.decrypt(
        _split(box.ciphertext, box.nonce),
        secretKey: key,
        aad: utf8.encode(vaultId),
      );
      return utf8.decode(bytes);
    } on SecretBoxAuthenticationError {
      throw const SecureVaultTamperedException();
    }
  }

  /// Always wraps under [SecureVaultKdf.current], never a header's own KDF
  /// params: a synced or restored header is untrusted, so weakened params in
  /// one must never end up protecting a key this device writes.
  static Future<SecureVaultHeader> _wrap(
    SecretKey key,
    String password, {
    required String vaultId,
    required int headerVersion,
    required DateTime now,
    required List<String> retiredVaultIds,
  }) async {
    const kdf = SecureVaultKdf.current;
    final salt = SecretKeyData.random(length: 16).bytes;
    final passwordKey = await _derive(password, salt, kdf);
    final box = await _aes.encrypt(
      await key.extractBytes(),
      secretKey: SecretKey(passwordKey),
      nonce: _aes.newNonce(),
      aad: utf8.encode(vaultId),
    );
    return SecureVaultHeader(
      vaultId: vaultId,
      kdf: kdf,
      salt: salt,
      wrappedKey: [...box.cipherText, ...box.mac.bytes],
      wrapNonce: box.nonce,
      headerVersion: headerVersion,
      updatedAt: now,
      retiredVaultIds: retiredVaultIds,
    );
  }

  static SecretBox _split(List<int> sealed, List<int> nonce) {
    final macStart = sealed.length - 16;
    if (macStart < 0) throw const SecureVaultTamperedException();
    return SecretBox(
      sealed.sublist(0, macStart),
      nonce: nonce,
      mac: Mac(sealed.sublist(macStart)),
    );
  }

  /// Runs off the UI isolate: even at tens of milliseconds on a desktop, a
  /// phone can take several frames.
  static Future<List<int>> _derive(
    String password,
    List<int> salt,
    SecureVaultKdf kdf,
  ) {
    if (kdf.name != 'argon2id') {
      throw UnsupportedError('Unknown key derivation: ${kdf.name}');
    }
    return Isolate.run(() async {
      final argon = Argon2id(
        parallelism: kdf.parallelism,
        memory: kdf.memoryKiB,
        iterations: kdf.iterations,
        hashLength: 32,
      );
      final key = await argon.deriveKeyFromPassword(
        password: password,
        nonce: salt,
      );
      return key.extractBytes();
    });
  }
}
