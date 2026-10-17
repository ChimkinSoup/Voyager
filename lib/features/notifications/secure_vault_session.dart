import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/secure_vault/secure_vault.dart';
import 'package:voyager/core/vim/vim_session.dart';
import 'package:voyager/domain/models/notification_models.dart';

/// An unlocked vault: its data key, in memory only.
class SecureVaultSession {
  const SecureVaultSession({required this.key, required this.vaultId});

  final SecretKey key;
  final String vaultId;
}

/// Whether the Secure Notes vault is unlocked, and with what key. Null while
/// locked, which is how every launch starts.
class SecureVaultSessionNotifier extends StateNotifier<SecureVaultSession?> {
  SecureVaultSessionNotifier() : super(null);

  /// How long the inbox can sit with no pointer or key activity before the
  /// vault locks itself.
  static const idleTimeout = Duration(minutes: 5);

  Timer? _idle;

  void unlock(SecretKey key, String vaultId) {
    state = SecureVaultSession(key: key, vaultId: vaultId);
    touch();
  }

  /// Restarts the idle clock — any activity in the inbox while unlocked.
  void touch() {
    if (!mounted || state == null) return;
    _idle?.cancel();
    _idle = Timer(idleTimeout, lock);
  }

  /// Forgets the key. The decrypted notes go with it (see
  /// [secureNoteTextsProvider]), and the rows, their controllers and undo
  /// history with the section that is no longer built. Vim's registers are
  /// global, so they are emptied here in case they hold a yank from a note.
  void lock() {
    _idle?.cancel();
    _idle = null;
    // Already locked by its own disposal.
    if (!mounted) return;
    final session = state;
    if (session == null) return;
    state = null;
    final key = session.key;
    if (key is SecretKeyData) key.destroy();
    VimRegister.text = '';
    VimRegister.linewise = false;
    VimSearchMemory.pattern = '';
  }

  /// Locks if the vault now on this device is not the one unlocked.
  void lockUnlessVault(String? vaultId) {
    if (state != null && state!.vaultId != vaultId) lock();
  }

  @override
  void dispose() {
    lock();
    super.dispose();
  }
}

/// Rebuilt — and so locked — whenever the signed-in account changes,
/// sign-out included: the sync repository is rebuilt for each one. Also locks
/// when the vault's header is replaced by a reset, from this device or
/// another.
final secureVaultSessionProvider =
    StateNotifierProvider<SecureVaultSessionNotifier, SecureVaultSession?>((
      ref,
    ) {
      ref.watch(syncRepositoryProvider);
      final notifier = SecureVaultSessionNotifier();
      ref.listen(secureVaultHeaderProvider, (_, next) {
        if (next.isLoading) return;
        notifier.lockUnlessVault(next.valueOrNull?.vaultId);
      });
      return notifier;
    });

/// A Secure Note with its text, as the unlocked vault reads it.
typedef SecureNoteText = ({SecureNote note, String text});

/// The current vault's notes, decrypted — empty while locked. Notes sealed
/// under any other vault are never shown, and one that fails to decrypt is
/// left out rather than shown broken.
final secureNoteTextsProvider =
    FutureProvider.autoDispose<List<SecureNoteText>>((ref) async {
      final session = ref.watch(secureVaultSessionProvider);
      if (session == null) return const [];
      final notes = await ref.watch(secureNotesProvider.future);
      final texts = <SecureNoteText>[];
      for (final note in notes) {
        if (note.vaultId != session.vaultId) continue;
        try {
          final text = await SecureVault.decrypt(
            session.key,
            session.vaultId,
            SecureBox(
              ciphertext: base64Decode(note.ciphertext),
              nonce: base64Decode(note.nonce),
            ),
          );
          texts.add((note: note, text: text));
        } on SecureVaultTamperedException {
          continue;
        } on FormatException {
          continue;
        } on ArgumentError {
          // A nonce or ciphertext too short to split.
          continue;
        }
      }
      return texts;
    });

/// Seals [text] into [note]'s fields under the unlocked vault.
Future<({String ciphertext, String nonce})> sealSecureText(
  SecureVaultSession session,
  String text,
) async {
  final box = await SecureVault.encrypt(session.key, session.vaultId, text);
  return (
    ciphertext: base64Encode(box.ciphertext),
    nonce: base64Encode(box.nonce),
  );
}
