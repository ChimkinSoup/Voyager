import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/secure_vault/secure_vault.dart';

void main() {
  final now = DateTime.utc(2026, 10, 16);

  Future<({SecureVaultHeader header, SecretKey key})> vault() =>
      SecureVault.create('correct horse', vaultId: 'vault-1', now: now);

  test('a note survives the round trip', () async {
    final v = await vault();
    final box = await SecureVault.encrypt(v.key, 'vault-1', 'the pin is 4821');
    expect(await SecureVault.decrypt(v.key, 'vault-1', box), 'the pin is 4821');
  });

  test('the right password unlocks, a wrong one does not', () async {
    final v = await vault();
    final key = await SecureVault.unlock(v.header, 'correct horse');
    expect(key, isNotNull);
    expect(await key!.extractBytes(), await v.key.extractBytes());
    expect(await SecureVault.unlock(v.header, 'correct hose'), isNull);
  });

  test('the header survives its JSON form', () async {
    final v = await vault();
    final header = SecureVaultHeader.fromJson(v.header.toJson());
    expect(await SecureVault.unlock(header, 'correct horse'), isNotNull);
  });

  test('retired vaults survive the JSON form and a password change', () async {
    final v = await SecureVault.create(
      'correct horse',
      vaultId: 'vault-3',
      now: now,
      retiredVaultIds: ['vault-1', 'vault-2'],
    );
    final header = SecureVaultHeader.fromJson(v.header.toJson());
    expect(header.retiredVaultIds, ['vault-1', 'vault-2']);
    final rewrapped = await SecureVault.rewrap(header, v.key, 'new', now: now);
    expect(rewrapped.retiredVaultIds, ['vault-1', 'vault-2']);
  });

  test('a header from before retired vaults reads as retiring none', () async {
    final json = (await vault()).header.toJson()..remove('retiredVaultIds');
    expect(SecureVaultHeader.fromJson(json).retiredVaultIds, isEmpty);
  });

  test('notes still decrypt after a password change', () async {
    final v = await vault();
    final box = await SecureVault.encrypt(v.key, 'vault-1', 'secret');

    final rewrapped = await SecureVault.rewrap(
      v.header,
      v.key,
      'new password',
      now: now,
    );
    expect(rewrapped.headerVersion, v.header.headerVersion + 1);
    expect(rewrapped.vaultId, 'vault-1');
    expect(await SecureVault.unlock(rewrapped, 'correct horse'), isNull);
    final key = await SecureVault.unlock(rewrapped, 'new password');
    expect(await SecureVault.decrypt(key!, 'vault-1', box), 'secret');
  });

  test('nonces never repeat', () async {
    final v = await vault();
    final nonces = <String>{};
    for (var i = 0; i < 200; i++) {
      final box = await SecureVault.encrypt(v.key, 'vault-1', 'same text');
      expect(box.nonce, hasLength(12));
      nonces.add(box.nonce.join(','));
    }
    expect(nonces, hasLength(200));
  });

  test('tampered ciphertext is rejected', () async {
    final v = await vault();
    final box = await SecureVault.encrypt(v.key, 'vault-1', 'secret');
    final flipped = [...box.ciphertext]..[0] ^= 1;
    await expectLater(
      SecureVault.decrypt(
        v.key,
        'vault-1',
        SecureBox(ciphertext: flipped, nonce: box.nonce),
      ),
      throwsA(isA<SecureVaultTamperedException>()),
    );
  });

  test('a note from another vault is rejected', () async {
    final v = await vault();
    final box = await SecureVault.encrypt(v.key, 'vault-1', 'secret');
    await expectLater(
      SecureVault.decrypt(v.key, 'vault-2', box),
      throwsA(isA<SecureVaultTamperedException>()),
    );
  });

  group('bytes', () {
    final photo = Uint8List.fromList(List.generate(5000, (i) => i % 251));

    test('survive the round trip', () async {
      final v = await vault();
      final sealed = await SecureVault.encryptBytes(v.key, 'vault-1', photo);
      // nonce ‖ ciphertext ‖ tag
      expect(sealed.length, 12 + photo.length + 16);
      expect(await SecureVault.decryptBytes(v.key, 'vault-1', sealed), photo);
    });

    test('a flipped byte is refused', () async {
      final v = await vault();
      final sealed = await SecureVault.encryptBytes(v.key, 'vault-1', photo);
      for (final at in [0, 100, sealed.length - 1]) {
        final tampered = Uint8List.fromList(sealed)..[at] ^= 1;
        await expectLater(
          SecureVault.decryptBytes(v.key, 'vault-1', tampered),
          throwsA(isA<SecureVaultTamperedException>()),
        );
      }
      await expectLater(
        SecureVault.decryptBytes(v.key, 'vault-1', sealed.sublist(0, 20)),
        throwsA(isA<SecureVaultTamperedException>()),
      );
    });

    test('each seal takes a fresh nonce', () async {
      final v = await vault();
      final one = await SecureVault.encryptBytes(v.key, 'vault-1', photo);
      final two = await SecureVault.encryptBytes(v.key, 'vault-1', photo);
      expect(one.sublist(0, 12), isNot(two.sublist(0, 12)));
      expect(one, isNot(two));
    });

    test('a blob sealed under another vault is refused', () async {
      final v = await vault();
      final sealed = await SecureVault.encryptBytes(v.key, 'vault-1', photo);
      await expectLater(
        SecureVault.decryptBytes(v.key, 'vault-2', sealed),
        throwsA(isA<SecureVaultTamperedException>()),
      );
      final other = await SecureVault.create('x', vaultId: 'vault-1', now: now);
      await expectLater(
        SecureVault.decryptBytes(other.key, 'vault-1', sealed),
        throwsA(isA<SecureVaultTamperedException>()),
      );
    });
  });
}
