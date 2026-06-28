import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/out_of_sync_journal_entry_purge.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';

class DevOutOfSyncPurgeSection extends ConsumerStatefulWidget {
  const DevOutOfSyncPurgeSection({super.key});

  @override
  ConsumerState<DevOutOfSyncPurgeSection> createState() =>
      _DevOutOfSyncPurgeSectionState();
}

class _DevOutOfSyncPurgeSectionState
    extends ConsumerState<DevOutOfSyncPurgeSection> {
  var _purging = false;
  List<String>? _lastResults;

  Future<void> _purgeAll() async {
    if (_purging) return;

    final summary = OutOfSyncJournalEntryPurge.targets
        .map(
          (target) => '• ${target.title} — ${target.searchHint ?? target.id}',
        )
        .join('\n');

    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete out-of-sync journal entries?',
      message:
          'Permanently deletes ${OutOfSyncJournalEntryPurge.targets.length} '
          'entries from Firestore and this device (no 30-day trash):\n\n'
          '$summary',
      confirmLabel: 'Delete everywhere',
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _purging = true;
      _lastResults = null;
    });

    try {
      final results = await OutOfSyncJournalEntryPurge.purgeAll(
        remoteSync: ref.read(remoteSyncServiceProvider),
        journalRepository: ref.read(journalRepositoryProvider),
      );
      ref.invalidate(syncConflictsProvider);
      ref.invalidate(journalEntriesProvider);
      if (!mounted) return;
      setState(() => _lastResults = results);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Out-of-sync journal entries purged')),
      );
    } finally {
      if (mounted) setState(() => _purging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authUid = ref.watch(authRepositoryProvider).currentUserId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Purge out-of-sync journal entries',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Hard-deletes the entries currently flagged in sync_compare.log '
          'from Firestore and this device.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        for (final target in OutOfSyncJournalEntryPurge.targets)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(target.title),
            subtitle: Text(
              target.searchHint ?? target.id,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: authUid != null && !_purging ? _purgeAll : null,
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          icon: _purging
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(PhosphorIconsRegular.trash, size: 18),
          label: const Text('Delete out-of-sync entries everywhere'),
        ),
        if (authUid == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Sign in to delete from Firestore.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_lastResults != null) ...[
          const SizedBox(height: 12),
          SelectableText(
            _lastResults!.join('\n'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
        ],
      ],
    );
  }
}
