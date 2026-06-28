import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/remote_sync_compare_service.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';

class DevSyncCompareSection extends ConsumerStatefulWidget {
  const DevSyncCompareSection({super.key});

  @override
  ConsumerState<DevSyncCompareSection> createState() =>
      _DevSyncCompareSectionState();
}

class _DevSyncCompareSectionState extends ConsumerState<DevSyncCompareSection> {
  String? _selectedTodoListId;
  var _comparing = false;

  Future<void> _flushPendingEdits() async {
    await PendingFlushRegistry.instance.flushAll();
    if (!mounted) return;
    await ref.read(remoteSyncServiceProvider).flushAllPending();
  }

  Future<void> _compareJournalEntries() async {
    if (_comparing) return;
    setState(() => _comparing = true);
    try {
      await _flushPendingEdits();
      if (!mounted) return;
      final report =
          await ref.read(remoteSyncCompareServiceProvider).compareAllJournalEntries();
      if (!mounted) return;
      await _showJournalResultDialog(context, report);
    } finally {
      if (mounted) setState(() => _comparing = false);
    }
  }

  Future<void> _compareAllTodoLists() async {
    if (_comparing) return;
    setState(() => _comparing = true);
    try {
      await _flushPendingEdits();
      if (!mounted) return;
      final report =
          await ref.read(remoteSyncCompareServiceProvider).compareAllTodoLists();
      if (!mounted) return;
      await _showTodoListsResultDialog(context, report);
    } finally {
      if (mounted) setState(() => _comparing = false);
    }
  }

  Future<void> _compareTodoList() async {
    final listId = _selectedTodoListId;
    if (_comparing || listId == null) return;
    setState(() => _comparing = true);
    try {
      await _flushPendingEdits();
      if (!mounted) return;
      final result =
          await ref.read(remoteSyncCompareServiceProvider).compareTodoList(listId);
      if (!mounted) return;
      await _showTodoResultDialog(context, result);
    } finally {
      if (mounted) setState(() => _comparing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final listsAsync = ref.watch(todoListsProvider);
    final logger = ref.watch(syncCompareLoggerProvider);

    final lists = listsAsync.valueOrNull ?? const [];
    _selectedTodoListId ??= lists.isNotEmpty ? lists.first.id : null;
    if (_selectedTodoListId != null &&
        lists.isNotEmpty &&
        !lists.any((list) => list.id == _selectedTodoListId)) {
      _selectedTodoListId = lists.first.id;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Remote sync compare',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Compares saved local SQLite data with CRDT-resolved Firestore '
          'payloads. Timestamps compare at second precision. Differences are '
          'appended to sync_compare.log.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Compare all journal entries'),
          subtitle: const Text(
            'Field-level diff for every local entry vs remote',
          ),
          trailing: _comparing
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(PhosphorIconsRegular.arrowsLeftRight),
          onTap: _comparing ? null : () => unawaited(_compareJournalEntries()),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Compare all todo lists'),
          subtitle: const Text(
            'List metadata and tasks for every local list vs remote',
          ),
          trailing: _comparing
              ? null
              : const Icon(PhosphorIconsRegular.listChecks),
          onTap: _comparing ? null : () => unawaited(_compareAllTodoLists()),
        ),
        listsAsync.when(
          data: (lists) {
            if (lists.isEmpty) {
              return const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('No todo lists available'),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  value: _selectedTodoListId,
                  decoration: const InputDecoration(
                    labelText: 'Todo list',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final list in lists)
                      DropdownMenuItem(
                        value: list.id,
                        child: Text(list.name),
                      ),
                  ],
                  onChanged: _comparing
                      ? null
                      : (value) => setState(() => _selectedTodoListId = value),
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Compare todo list with remote'),
                  subtitle: const Text(
                    'Reports task mismatch if any task differs',
                  ),
                  trailing: const Icon(PhosphorIconsRegular.listChecks),
                  onTap: _comparing ? null : () => unawaited(_compareTodoList()),
                ),
              ],
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
          error: (error, _) => ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Failed to load todo lists: $error'),
          ),
        ),
        const SizedBox(height: 8),
        FutureBuilder<String>(
          future: logger.logFilePath(),
          builder: (context, snapshot) {
            final path = snapshot.data;
            if (path == null) return const SizedBox.shrink();
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Compare log file'),
              subtitle: Text(path, style: Theme.of(context).textTheme.bodySmall),
            );
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('View compare log'),
          trailing: const Icon(PhosphorIconsRegular.fileText),
          onTap: () => _showLogDialog(context, ref),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Copy compare log'),
          trailing: const Icon(PhosphorIconsRegular.copy),
          onTap: () async {
            final text = await ref.read(syncCompareLoggerProvider).readLog();
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    text.isEmpty
                        ? 'Compare log is empty'
                        : 'Copied ${text.length} characters',
                  ),
                ),
              );
            }
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Clear compare log'),
          trailing: const Icon(PhosphorIconsRegular.trash),
          onTap: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Clear sync compare log?'),
                content: const Text(
                  'This permanently deletes sync_compare.log contents.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Clear'),
                  ),
                ],
              ),
            );
            if (confirmed != true) return;
            await ref.read(syncCompareLoggerProvider).clearLog();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Sync compare log cleared')),
              );
            }
          },
        ),
      ],
    );
  }

  Future<void> _showLogDialog(BuildContext context, WidgetRef ref) async {
    final text = await ref.read(syncCompareLoggerProvider).readLog();
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sync compare log'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: SelectableText(
              text.isEmpty ? '(empty)' : text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showJournalResultDialog(
    BuildContext context,
    JournalCompareReport report,
  ) async {
    final mismatches =
        report.results.where((result) => !result.matched).toList();

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          report.allMatched
              ? 'Journal entries in sync'
              : 'Journal entry mismatches',
        ),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${report.matchedCount}/${report.results.length} entries in sync. '
                  '${report.mismatchCount} field mismatches, '
                  '${report.missingOnRemoteCount} missing on remote, '
                  '${report.missingOnLocalCount} missing locally.',
                ),
                if (mismatches.isEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('All compared fields match Firestore.'),
                ] else ...[
                  const SizedBox(height: 12),
                  for (final result in mismatches) ...[
                    Text(
                      result.entryId,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(_journalStatusLabel(result)),
                    if (result.detail != null) Text(result.detail!),
                    for (final diff in result.diffs)
                      Text(
                        '${diff.field}: local="${diff.local}" remote="${diff.remote}"',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (result.remoteCharOpCount != null)
                      Text(
                        'Remote char ops: ${result.remoteCharOpCount} '
                        '(chain valid: ${result.remoteOpChainValid})',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    const SizedBox(height: 8),
                  ],
                  const Text(
                    'Details saved to sync_compare.log.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showTodoListsResultDialog(
    BuildContext context,
    TodoListsCompareReport report,
  ) async {
    final mismatches =
        report.results.where((result) => !result.matched).toList();

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          report.allMatched
              ? 'Todo lists in sync'
              : 'Todo list mismatches',
        ),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${report.matchedCount}/${report.results.length} lists in sync. '
                  '${report.mismatchCount} with mismatches, '
                  '${report.missingOnRemoteCount} missing on remote, '
                  '${report.missingOnLocalCount} missing locally.',
                ),
                if (mismatches.isEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'All compared list fields and tasks match Firestore.',
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  for (final result in mismatches) ...[
                    Text(
                      result.listName,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(_todoStatusLabel(result)),
                    if (result.detail != null) Text(result.detail!),
                    for (final diff in result.listDiffs)
                      Text(
                        'list.${diff.field}: local="${diff.local}" '
                        'remote="${diff.remote}"',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (!result.matched &&
                        (result.mismatchedTaskCount > 0 ||
                            result.localOnlyTaskCount > 0 ||
                            result.remoteOnlyTaskCount > 0))
                      Text(
                        '${result.mismatchedTaskCount} task(s) differ, '
                        '${result.localOnlyTaskCount} local-only, '
                        '${result.remoteOnlyTaskCount} remote-only.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    const SizedBox(height: 8),
                  ],
                  const Text(
                    'Details saved to sync_compare.log.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showTodoResultDialog(
    BuildContext context,
    TodoListCompareResult result,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          result.matched
              ? 'Todo list in sync'
              : 'Task mismatch',
        ),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('List: ${result.listName}'),
                if (result.matched) ...[
                  const SizedBox(height: 8),
                  const Text('All list fields and tasks match remote.'),
                ] else ...[
                  const SizedBox(height: 8),
                  for (final diff in result.listDiffs)
                    Text(
                      'list.${diff.field}: local="${diff.local}" '
                      'remote="${diff.remote}"',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  Text(
                    '${result.mismatchedTaskCount} task(s) differ, '
                    '${result.localOnlyTaskCount} local-only, '
                    '${result.remoteOnlyTaskCount} remote-only.',
                  ),
                  if (result.detail != null) ...[
                    const SizedBox(height: 8),
                    Text(result.detail!),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    'Details saved to sync_compare.log.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _todoStatusLabel(TodoListCompareResult result) {
    return switch (result.status) {
      SyncCompareSyncStatus.inSync => 'In sync',
      SyncCompareSyncStatus.mismatch => 'Mismatch',
      SyncCompareSyncStatus.missingOnRemote => 'Missing on remote',
      SyncCompareSyncStatus.missingOnLocal => 'Missing locally',
      SyncCompareSyncStatus.remoteFetchFailed => 'Remote fetch failed',
    };
  }

  String _journalStatusLabel(JournalEntryCompareResult result) {
    return switch (result.status) {
      SyncCompareSyncStatus.inSync => 'In sync',
      SyncCompareSyncStatus.mismatch => 'Mismatch',
      SyncCompareSyncStatus.missingOnRemote => 'Missing on remote',
      SyncCompareSyncStatus.missingOnLocal => 'Missing locally',
      SyncCompareSyncStatus.remoteFetchFailed => 'Remote fetch failed',
    };
  }
}
