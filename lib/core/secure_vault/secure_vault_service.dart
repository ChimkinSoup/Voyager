import 'package:cryptography/cryptography.dart';
import 'package:voyager/core/secure_vault/secure_vault.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/note_sync.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart'
    show NoOpSyncRepository;
import 'package:voyager/domain/repositories/repositories.dart';

/// Why a vault change was refused. [message] is shown to the user as is.
class SecureVaultException implements Exception {
  const SecureVaultException(this.message);

  final String message;

  @override
  String toString() => 'SecureVaultException: $message';
}

/// The Secure Notes vault's header lifecycle: creating it, unlocking it,
/// changing its password and resetting it.
///
/// Every change to the header is a transaction against the server's copy,
/// which fails offline rather than queueing: two devices can never each make
/// a vault of their own, or each write a password change over the other's.
/// Unlocking needs no server, and uses this device's copy of the header.
class SecureVaultService {
  SecureVaultService({
    required NotificationRepository repository,
    required SyncRepository sync,
    DateTime Function() now = utcNow,
  }) : _repository = repository,
       _sync = sync,
       _now = now;

  final NotificationRepository _repository;
  final SyncRepository _sync;
  final DateTime Function() _now;

  static const minPasswordLength = 8;

  Future<SecureVaultHeader?> localHeader() async {
    final json = await _repository.getSecureVaultHeader();
    return json == null ? null : SecureVaultHeader.fromJson(json);
  }

  /// This device's header, after taking the server's if it is newer. Offline,
  /// just this device's.
  Future<SecureVaultHeader?> refreshHeader() async {
    try {
      // Bounded: offline, a read can wait on the server for some seconds
      // before settling for the cache, and the user is holding a button.
      final remote = await _sync
          .getDocument(
            FirestoreCollections.secureVault,
            FirestoreCollections.secureVaultHeaderId,
          )
          .timeout(const Duration(seconds: 3));
      if (remote != null) await _adoptIfNewer(remote);
    } catch (_) {
      // Offline: the local copy is what an unlock uses anyway.
    }
    return localHeader();
  }

  /// Makes the account's vault. Throws if one already exists — its header is
  /// taken here, so the caller can offer to unlock it instead.
  Future<SecretKey> create(String password) async {
    _requireSignedIn();
    final made = await SecureVault.create(
      password,
      vaultId: newId(),
      now: _now(),
    );
    final remote = await _write(
      (remote) => remote == null ? made.header.toJson() : null,
    );
    if (remote != null) {
      await _adoptIfNewer(remote);
      throw const SecureVaultException(
        'This account already has a vault. Unlock it instead.',
      );
    }
    await _saveLocal(made.header);
    return made.key;
  }

  /// The data key, or null for a wrong password.
  Future<SecretKey?> unlock(String password) async {
    final header = await localHeader();
    if (header == null) return null;
    return SecureVault.unlock(header, password);
  }

  /// Re-wraps the data key under [newPassword]. Returns false for a wrong
  /// [currentPassword].
  Future<bool> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    _requireSignedIn();
    final header = await localHeader();
    if (header == null) return false;
    final key = await SecureVault.unlock(header, currentPassword);
    if (key == null) return false;
    final rewrapped = await SecureVault.rewrap(
      header,
      key,
      newPassword,
      now: _now(),
    );
    await _replace(header, rewrapped);
    return true;
  }

  /// Starts a new, empty vault under [password], deleting every Secure Note.
  /// The old vault's notes can't be read with the new key in any case.
  Future<SecretKey> reset(String password) async {
    _requireSignedIn();
    final header = await localHeader();
    final made = await SecureVault.create(
      password,
      vaultId: newId(),
      now: _now(),
      headerVersion: (header?.headerVersion ?? 0) + 1,
      retiredVaultIds: [...?header?.retiredVaultIds, ?header?.vaultId],
    );
    await _replace(header, made.header);
    for (final note in await _repository.listSecureNotes()) {
      await _repository.deleteSecureNote(note.id);
    }
    return made.key;
  }

  /// Writes [next] over the server's header only if it is still [current].
  Future<void> _replace(
    SecureVaultHeader? current,
    SecureVaultHeader next,
  ) async {
    var wrote = false;
    final remote = await _write((remote) {
      wrote = current == null
          ? remote == null
          : remote != null &&
                remote['vaultId'] == current.vaultId &&
                remote['headerVersion'] == current.headerVersion;
      return wrote ? next.toJson() : null;
    });
    if (!wrote) {
      if (remote != null) await _adoptIfNewer(remote);
      throw const SecureVaultException(
        'The vault was changed on another device. Try again.',
      );
    }
    await _saveLocal(next);
  }

  Future<Map<String, dynamic>?> _write(
    Map<String, dynamic>? Function(Map<String, dynamic>? remote) decide,
  ) async {
    try {
      return await _sync.writeAfterReading(
        FirestoreCollections.secureVault,
        FirestoreCollections.secureVaultHeaderId,
        decide,
      );
    } catch (_) {
      throw const SecureVaultException(
        "Couldn't reach the server. Changing the vault needs a connection.",
      );
    }
  }

  void _requireSignedIn() {
    if (_sync is NoOpSyncRepository) {
      throw const SecureVaultException('Sign in to use Secure Notes.');
    }
  }

  Future<void> _adoptIfNewer(Map<String, dynamic> remote) =>
      adoptSecureVaultHeader(_repository, remote);

  Future<void> _saveLocal(SecureVaultHeader header) =>
      _repository.saveSecureVaultHeader(
        header.toJson(),
        vaultId: header.vaultId,
        headerVersion: header.headerVersion,
      );
}
