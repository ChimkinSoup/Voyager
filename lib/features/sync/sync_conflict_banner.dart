import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/domain/models/sync_conflict.dart';

/// Persistent banner shown when quarantined sync conflicts exist.
class SyncConflictBanner extends ConsumerWidget {
  const SyncConflictBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflictsAsync = ref.watch(syncConflictsProvider);
    return conflictsAsync.when(
      data: (conflicts) {
        if (conflicts.isEmpty) return const SizedBox.shrink();
        return Material(
          color: Theme.of(context).colorScheme.errorContainer,
          child: SafeArea(
            bottom: false,
            child: ListTile(
              dense: true,
              title: Text(
                'Conflicting edits detected.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                '${conflicts.length} document(s) need resolution',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
              trailing: FilledButton(
                onPressed: () => _openResolutionDialog(context, ref),
                child: const Text('Resolve'),
              ),
            ),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Future<void> _openResolutionDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => const SyncConflictResolutionDialog(),
    );
    ref.invalidate(syncConflictsProvider);
  }
}

class SyncConflictResolutionDialog extends ConsumerStatefulWidget {
  const SyncConflictResolutionDialog({super.key});

  @override
  ConsumerState<SyncConflictResolutionDialog> createState() =>
      _SyncConflictResolutionDialogState();
}

class _SyncConflictResolutionDialogState
    extends ConsumerState<SyncConflictResolutionDialog> {
  TextEditingController? _mergeController;
  String? _loadedConflictId;
  var _resolving = false;

  @override
  void dispose() {
    _mergeController?.dispose();
    super.dispose();
  }

  void _syncMergeController(SyncConflict conflict) {
    if (_loadedConflictId == conflict.id) return;
    _mergeController?.dispose();
    _mergeController = TextEditingController(text: conflict.localText ?? '');
    _loadedConflictId = conflict.id;
  }

  Future<void> _refreshAfterResolve() async {
    ref.invalidate(syncConflictsProvider);
    ref.invalidate(journalEntriesProvider);
    ref.invalidate(journalListEntriesProvider);
    ref.invalidate(journalEntryCountsProvider);
    ref.invalidate(todoTasksProvider);
    ref.invalidate(allTodoTasksProvider);

    final conflicts = await ref.read(syncConflictsProvider.future);
    if (!mounted) return;
    if (conflicts.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() => _loadedConflictId = null);
  }

  Future<void> _resolveConflict(Future<void> Function() resolve) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      await resolve();
      await _refreshAfterResolve();
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _resolveAllConflicts(Future<void> Function() resolveAll) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      await resolveAll();
      await _refreshAfterResolve();
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _confirmPermanentRemoteDelete(SyncConflict conflict) async {
    final isJournal =
        conflict.collection == FirestoreCollections.journalEntries;
    final label = isJournal ? 'journal entry' : 'todo task';
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete from Firestore permanently?',
      message:
          'This permanently deletes the remote $label document and all '
          'sync_operations for this entry from Firestore. It bypasses the '
          '30-day trash. Your local copy on this device is kept.',
      confirmLabel: 'Delete from Firestore',
    );
    if (!confirmed || !mounted) return;

    await _resolveConflict(() async {
      final operationsDeleted = await ref
          .read(remoteSyncServiceProvider)
          .permanentlyDeleteFromRemote(
            collection: conflict.collection,
            documentId: conflict.documentId,
          );
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final conflictsAsync = ref.watch(syncConflictsProvider);
    final showDocumentIds =
        ref.watch(devSettingsProvider).showConflictDocumentIds;

    return conflictsAsync.when(
      data: (conflicts) {
        if (conflicts.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          });
          return AlertDialog(
            title: const Text('Resolve sync conflict'),
            content: const SizedBox(
              width: 720,
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final conflict = conflicts.first;
        _syncMergeController(conflict);
        final mergeController = _mergeController!;

        final localTitle = conflict.localTitle ?? '(untitled)';
        final remoteTitle = conflict.remoteTitle ?? '(untitled)';
        final localText = conflict.localText ?? '';
        final remoteText = conflict.remoteText ?? '';
        final isJournal =
            conflict.collection == FirestoreCollections.journalEntries;
        final textLabel = isJournal ? 'Body' : 'Notes';
        final remainingLabel = conflicts.length == 1
            ? '1 conflict remaining'
            : '${conflicts.length} conflicts remaining';

        return AlertDialog(
          title: const Text('Resolve sync conflict'),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    remainingLabel,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  if (conflicts.length > 1) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _resolving
                                ? null
                                : () => _resolveAllConflicts(
                                      () => ref
                                          .read(remoteSyncServiceProvider)
                                          .resolveAllConflictsKeepLocal(),
                                    ),
                            child: const Text('Keep local for all'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _resolving
                                ? null
                                : () => _resolveAllConflicts(
                                      () => ref
                                          .read(remoteSyncServiceProvider)
                                          .resolveAllConflictsKeepRemote(),
                                    ),
                            child: const Text('Keep remote for all'),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    isJournal ? 'Journal entry' : 'Todo task',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  if (showDocumentIds) ...[
                    const SizedBox(height: 8),
                    _ConflictDocumentIds(conflict: conflict),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _DiffColumn(
                          heading: 'Local',
                          title: localTitle,
                          textLabel: textLabel,
                          text: localText,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _DiffColumn(
                          heading: 'Remote',
                          title: remoteTitle,
                          textLabel: textLabel,
                          text: remoteText,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: mergeController,
                    maxLines: 8,
                    enabled: !_resolving,
                    decoration: InputDecoration(
                      labelText: 'Manual merge ($textLabel)',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _resolving
                        ? null
                        : () => _confirmPermanentRemoteDelete(conflict),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    icon: const Icon(Icons.cloud_off_outlined, size: 18),
                    label: const Text('Delete from Firestore permanently'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: _resolving ? null : () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            TextButton(
              onPressed: _resolving
                  ? null
                  : () => _resolveConflict(
                        () => ref
                            .read(remoteSyncServiceProvider)
                            .resolveConflictKeepLocal(conflict),
                      ),
              child: const Text('Keep Local'),
            ),
            TextButton(
              onPressed: _resolving
                  ? null
                  : () => _resolveConflict(
                        () => ref
                            .read(remoteSyncServiceProvider)
                            .resolveConflictKeepRemote(conflict),
                      ),
              child: const Text('Keep Remote'),
            ),
            FilledButton(
              onPressed: _resolving
                  ? null
                  : () => _resolveConflict(
                        () => ref
                            .read(remoteSyncServiceProvider)
                            .resolveConflictManualMerge(
                              conflict,
                              mergedText: mergeController.text,
                            ),
                      ),
              child: _resolving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Use merged text'),
            ),
          ],
        );
      },
      loading: () => AlertDialog(
        title: const Text('Resolve sync conflict'),
        content: const SizedBox(
          width: 720,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (error, _) => AlertDialog(
        title: const Text('Resolve sync conflict'),
        content: Text('$error'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _ConflictDocumentIds extends StatelessWidget {
  const _ConflictDocumentIds({required this.conflict});

  final SyncConflict conflict;

  @override
  Widget build(BuildContext context) {
    final entryId = conflict.documentId;
    final firestoreCollectionId = firestoreDocumentIdForLocal(
      conflict.collection,
      entryId,
    );
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
    );
    final hintStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          'Entry ID: $entryId',
          style: style,
        ),
        SelectableText(
          'Document path: ${conflict.collection}/$firestoreCollectionId',
          style: style,
        ),
        if (firestoreCollectionId != entryId)
          SelectableText(
            'Firestore collection id: $firestoreCollectionId',
            style: style,
          ),
        const SizedBox(height: 6),
        Text(
          'To clear corrupted sync history in Firebase Console, delete rows in '
          'sync_operations where the documentId field equals the entry ID above '
          '(not the sync_operations document name — those look like '
          'deviceId_entryId_sequence).',
          style: hintStyle,
        ),
        const SizedBox(height: 4),
        SelectableText(
          'sync_operations filter: documentId == $entryId',
          style: style,
        ),
      ],
    );
  }
}

class _DiffColumn extends StatelessWidget {
  const _DiffColumn({
    required this.heading,
    required this.title,
    required this.textLabel,
    required this.text,
  });

  final String heading;
  final String title;
  final String textLabel;
  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              heading,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text('Title: $title'),
            const SizedBox(height: 8),
            Text('$textLabel:', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            SelectableText(
              text.isEmpty ? '(empty)' : text,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
