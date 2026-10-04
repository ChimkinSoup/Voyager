import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/windows_folder_picker.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/features/settings/folder_backup_source_dialog.dart';
import 'package:voyager/features/settings/services/folder_backup_service.dart';

/// One source's backups, or a retired entry's, read-only (§9.2, §9.6).
Future<void> showFolderBackupListDialog(
  BuildContext context, {
  String? sourceId,
  RetiredFolderBackups? retired,
}) {
  assert((sourceId == null) != (retired == null));
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) =>
        _FolderBackupListDialog(sourceId: sourceId, retired: retired),
  );
}

enum _Action { pin, unpin, extract, showInFolder, delete }

class _FolderBackupListDialog extends ConsumerStatefulWidget {
  const _FolderBackupListDialog({this.sourceId, this.retired});

  final String? sourceId;
  final RetiredFolderBackups? retired;

  @override
  ConsumerState<_FolderBackupListDialog> createState() =>
      _FolderBackupListDialogState();
}

class _FolderBackupListDialogState
    extends ConsumerState<_FolderBackupListDialog> {
  List<FolderBackupEntry>? _entries;

  /// File counts from each manifest, by path, filled in as they're read.
  final _files = <String, int>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  FolderBackupSourceStatus? _status(FolderBackupService service) => service
      .status
      ?.sources
      .where((s) => s.source.id == widget.sourceId)
      .firstOrNull;

  Future<void> _reload() async {
    final service = ref.read(folderBackupServiceProvider);
    final retired = widget.retired;
    final source = _status(service)?.source;
    final entries = retired != null
        ? await service.listRetiredBackups(retired)
        : source == null
        ? const <FolderBackupEntry>[]
        : await service.listBackups(source);
    if (!mounted) return;
    setState(() => _entries = entries);
    for (final entry in entries) {
      if (_files.containsKey(entry.file.path)) continue;
      final summary = await service.summaryOf(entry);
      if (!mounted) return;
      if (summary != null) {
        setState(() => _files[entry.file.path] = summary.fileCount);
      }
    }
  }

  void _toast(String message, {bool failed = false}) {
    showVoyagerToastIn(
      Overlay.of(context, rootOverlay: true),
      message: message,
      icon: failed ? PhosphorIconsRegular.warning : PhosphorIconsRegular.check,
      dwell: const Duration(seconds: 5),
    );
  }

  Future<void> _act(_Action action, FolderBackupEntry entry) async {
    final service = ref.read(folderBackupServiceProvider);
    final source = _status(service)?.source;
    try {
      switch (action) {
        case _Action.pin:
          await service.pin(source!, entry);
        case _Action.unpin:
          final confirmed = await showConfirmDialog(
            context,
            title: 'Unpin backup',
            message:
                'It goes back into the rotation, and the next check may '
                'delete it.',
            confirmLabel: 'Unpin',
          );
          if (!confirmed) return;
          await service.unpin(source!, entry);
        case _Action.extract:
          await _extract(entry);
        case _Action.showInFolder:
          // Separate arguments: Dart quotes one with a space whole, which
          // Explorer can't parse, and it opens Documents instead.
          await Process.run('explorer', ['/select,', entry.file.path]);
        case _Action.delete:
          final confirmed = await showConfirmDialog(
            context,
            title: 'Delete backup',
            message: entry.pinned || widget.retired != null
                ? 'This backup is deleted for good.'
                : 'This backup is deleted for good. The rotation fills the '
                      'gap from what is left.',
          );
          if (!confirmed) return;
          await service.deleteBackup(entry);
      }
    } catch (e) {
      _toast('$e', failed: true);
    }
    if (mounted) await _reload();
  }

  /// §7: into an empty folder the user picks, or a new one Voyager makes in
  /// it, then opens it in Explorer.
  Future<void> _extract(FolderBackupEntry entry) async {
    final picked = await pickFolder(title: 'Extract to folder');
    if (picked == null || !mounted) return;
    var target = picked;
    if (!await Directory(picked).list().isEmpty) {
      final service = ref.read(folderBackupServiceProvider);
      final name =
          widget.retired?.name ?? _status(service)?.source.name ?? 'Folder';
      final base = p.join(
        picked,
        '$name restored ${DateFormat('y-MM-dd').format(service.now())}',
      );
      target = base;
      for (var n = 2; await Directory(target).exists(); n++) {
        target = '$base ($n)';
      }
    }
    if (!mounted) return;
    final toast = showVoyagerToastIn(
      Overlay.of(context, rootOverlay: true),
      message: 'Verifying and extracting…',
    );
    try {
      await ref.read(folderBackupServiceProvider).extract(entry.file, target);
    } catch (e) {
      toast.update(
        message: 'Extract failed: $e',
        icon: PhosphorIconsRegular.warning,
        dwell: const Duration(seconds: 8),
      );
      return;
    }
    toast.update(
      message: 'Extracted to $target',
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(seconds: 5),
    );
    await Process.run('explorer', [target]);
  }

  Future<void> _deleteAll(RetiredFolderBackups retired) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete all backups',
      message:
          "Every backup of ${retired.name} in ${retired.path} is deleted for "
          'good. Other files there are left alone.',
      confirmLabel: 'Delete all',
    );
    if (!confirmed) return;
    try {
      await ref.read(folderBackupServiceProvider).deleteRetired(retired);
    } catch (e) {
      _toast('$e', failed: true);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // A run, a prune or a move changes what's on disk.
    ref.listen(folderBackupServiceProvider, (_, _) => _reload());
    final service = ref.watch(folderBackupServiceProvider);
    final status = _status(service);
    final retired = widget.retired;
    if (retired == null && service.status != null && status == null) {
      // Removed from its Edit dialog: there's nothing left to list.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
    final theme = Theme.of(context);
    final entries = _entries;
    final now = service.now();
    final time = DateFormat('d MMM y, HH:mm');
    final busy =
        status?.health == FolderBackupHealth.backingUp ||
        status?.health == FolderBackupHealth.moving;

    return AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(
              retired != null
                  ? '${retired.name} (removed)'
                  : status?.source.name ?? 'Folder backups',
            ),
          ),
          if (status != null) ...[
            GlassButton(
              dense: true,
              onPressed: busy || !status.source.enabled
                  ? null
                  : () => service.backUpNow(status.source.id),
              icon: const Icon(PhosphorIconsRegular.play, size: 16),
              label: 'Back up now',
            ),
            const SizedBox(width: 8),
            GlassButton(
              dense: true,
              onPressed: () =>
                  showFolderBackupSourceDialog(context, source: status.source),
              icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 16),
              label: 'Edit…',
            ),
            Switch(
              value: status.source.enabled,
              onChanged: (v) => service.setEnabled(status.source.id, v),
            ),
          ],
          if (retired != null)
            GlassButton(
              dense: true,
              onPressed: () => _deleteAll(retired),
              icon: const Icon(PhosphorIconsRegular.trash, size: 16),
              label: 'Delete all…',
            ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 600,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (status != null) ...[
              Text(
                status.detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (retired != null) ...[
              Text(
                '${retired.path} · removed '
                '${DateFormat('d MMM y').format(retired.retiredAt.toLocal())}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (status?.health == FolderBackupHealth.review)
              _HoldBanner(status: status!),
            Expanded(
              child: entries == null
                  ? const Center(child: CircularProgressIndicator())
                  : entries.isEmpty
                  ? Center(
                      child: Text(
                        'No backups yet.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final entry in entries)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              entry.pinned
                                  ? PhosphorIconsRegular.pushPin
                                  : PhosphorIconsRegular.archive,
                            ),
                            title: Text(folderBackupAgeLabel(entry, now)),
                            subtitle: Text(
                              [
                                time.format(entry.capturedAt.toLocal()),
                                formatFolderBackupBytes(entry.bytes),
                                if (_files[entry.file.path] case final n?)
                                  formatFolderBackupFiles(n),
                              ].join(' · '),
                            ),
                            trailing: PopupMenuButton<_Action>(
                              icon: const Icon(PhosphorIconsRegular.dotsThree),
                              onSelected: (action) => _act(action, entry),
                              itemBuilder: (_) => voyagerPopupMenuEntries([
                                if (retired == null)
                                  entry.pinned
                                      ? (
                                          value: _Action.unpin,
                                          child: const Text('Unpin'),
                                        )
                                      : (
                                          value: _Action.pin,
                                          child: const Text('Pin'),
                                        ),
                                (
                                  value: _Action.extract,
                                  child: const Text('Extract to folder…'),
                                ),
                                (
                                  value: _Action.showInFolder,
                                  child: const Text('Show in folder'),
                                ),
                                (
                                  value: _Action.delete,
                                  child: const Text('Delete…'),
                                ),
                              ]),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.of(context).pop(),
          label: 'Close',
        ),
      ],
    );
  }
}

/// §8.3: the drop, and the way out of the hold.
class _HoldBanner extends ConsumerWidget {
  const _HoldBanner({required this.status});

  final FolderBackupSourceStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            PhosphorIconsRegular.warningCircle,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'The folder shrank, so no backup is deleted until you review '
              'it. Extract or pin a backup from before the drop, or confirm '
              'it was intentional.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          const SizedBox(width: 12),
          GlassButton(
            dense: true,
            label: 'This was intentional',
            onPressed: () => unawaited(
              ref
                  .read(folderBackupServiceProvider)
                  .acceptDrop(status.source.id),
            ),
          ),
        ],
      ),
    );
  }
}
