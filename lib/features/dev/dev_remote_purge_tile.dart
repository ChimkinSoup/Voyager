import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';

class DevRemotePurgeSection extends ConsumerStatefulWidget {
  const DevRemotePurgeSection({super.key});

  @override
  ConsumerState<DevRemotePurgeSection> createState() =>
      _DevRemotePurgeSectionState();
}

class _DevRemotePurgeSectionState extends ConsumerState<DevRemotePurgeSection> {
  final _entryIdController = TextEditingController();
  var _purging = false;

  @override
  void dispose() {
    _entryIdController.dispose();
    super.dispose();
  }

  Future<void> _purgeEntry() async {
    final entryId = _entryIdController.text.trim();
    if (entryId.isEmpty || _purging) return;

    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete from Firestore permanently?',
      message:
          'This permanently deletes journal_entries/$entryId and all '
          'sync_operations where documentId equals that ID. It bypasses the '
          '30-day trash. Your local copy on this device is kept.',
      confirmLabel: 'Delete from Firestore',
    );
    if (!confirmed || !mounted) return;

    setState(() => _purging = true);
    try {
      final operationsDeleted = await ref
          .read(remoteSyncServiceProvider)
          .permanentlyDeleteFromRemote(
            collection: FirestoreCollections.journalEntries,
            documentId: entryId,
          );
      ref.invalidate(syncConflictsProvider);
      ref.invalidate(journalEntriesProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            operationsDeleted == 0
                ? 'Remote document deleted (no sync_operations found)'
                : 'Remote document deleted ($operationsDeleted sync_operations removed)',
          ),
        ),
      );
    } catch (error) {
      // The operation-log wipe forces a server read and throws when it can't
      // reach one, so an offline purge now fails instead of reporting the
      // cache's "no sync_operations found" as a completed delete.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Remote purge failed: $error')),
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
          'Remote purge',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Hard-delete a journal entry from Firestore without the 30-day recycle bin.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (authUid != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Firebase Auth UID'),
            subtitle: SelectableText(
              authUid,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            trailing: IconButton(
              tooltip: 'Copy Auth UID',
              icon: const Icon(PhosphorIconsRegular.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: authUid));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Auth UID copied')),
                  );
                }
              },
            ),
          )
        else
          Text(
            'Sign in to purge remote documents.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 8),
        LabeledTextField(
          label: 'Journal entry ID',
          hintText: 'ecbb36e5-9c33-49ef-8501-ebd08ae772bc',
          controller: _entryIdController,
          enabled: authUid != null && !_purging,
        ),
        const SizedBox(height: 12),
        GlassButton(
          onPressed: authUid != null && !_purging ? _purgeEntry : null,
          color: Theme.of(context).colorScheme.error,
          icon: _purging
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(PhosphorIconsRegular.cloudSlash),
          label: 'Delete from Firestore permanently',
        ),
      ],
    );
  }
}
