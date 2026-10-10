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
    final uid = ref.read(authRepositoryProvider).currentUserId;
    if (uid == null) return;

    setState(() {
      _purging = true;
      _lastResults = null;
    });

    try {
      // Compared again first: the list on screen can be hours old, and an
      // entry that has synced since must not be deleted.
      final report = await ref
          .read(remoteSyncCompareServiceProvider)
          .compareAllJournalEntries();
      if (!mounted) return;
      ref.read(lastJournalCompareProvider.notifier).state = (
        uid: uid,
        report: report,
      );
      final targets = OutOfSyncJournalEntryPurge.targetsFrom(report);
      if (targets.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing is out of sync any more')),
        );
        return;
      }

      final summary = targets
          .map((target) => '• ${target.id} — ${target.reason}')
          .join('\n');
      final confirmed = await showConfirmDialog(
        context,
        title: 'Delete out-of-sync journal entries?',
        message:
            'Permanently deletes ${targets.length} '
            'entries from Firestore and this device (no 30-day trash):\n\n'
            '$summary',
        confirmLabel: 'Delete everywhere',
      );
      if (!confirmed || !mounted) return;

      final results = await OutOfSyncJournalEntryPurge.purgeAll(
        targets: targets,
        remoteSync: ref.read(remoteSyncServiceProvider),
        journalRepository: ref.read(journalRepositoryProvider),
      );
      // Purged: the compare no longer describes what is here.
      ref.read(lastJournalCompareProvider.notifier).state = null;
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
    // Only a compare this account ran: another account's flagged ids mean
    // nothing here (BUG-219).
    final compare = ref.watch(lastJournalCompareProvider);
    final targets = compare == null || compare.uid != authUid
        ? const <OutOfSyncJournalEntryTarget>[]
        : OutOfSyncJournalEntryPurge.targetsFrom(compare.report);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Purge out-of-sync journal entries',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Hard-deletes the entries "Compare all journal entries" finds '
          'different here and in the cloud, from Firestore and this device. '
          'Compares again before asking.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (compare == null || compare.uid != authUid)
          Text(
            'Run "Compare all journal entries" first.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else if (targets.isEmpty)
          Text(
            'The last compare flagged nothing.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        for (final target in targets)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(target.id),
            subtitle: Text(
              target.reason,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: authUid != null && targets.isNotEmpty && !_purging
              ? _purgeAll
              : null,
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
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ],
    );
  }
}
