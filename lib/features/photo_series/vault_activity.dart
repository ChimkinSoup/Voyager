import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';

/// Pointer and key activity inside [child] holds off the vault's idle lock,
/// as it does in the inbox (PHOTO_SERIES_HLD.md §6.4).
class VaultActivity extends ConsumerWidget {
  const VaultActivity({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void touch() => ref.read(secureVaultSessionProvider.notifier).touch();
    return Listener(
      onPointerDown: (_) => touch(),
      onPointerMove: (_) => touch(),
      onPointerHover: (_) => touch(),
      onPointerSignal: (_) => touch(),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, _) {
          touch();
          return KeyEventResult.ignored;
        },
        child: child,
      ),
    );
  }
}
