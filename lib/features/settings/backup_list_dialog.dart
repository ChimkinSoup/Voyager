import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/features/settings/services/auto_backup_service.dart';

/// Every automatic backup and pre-restore snapshot on this device —
/// AUTO_BACKUP_HLD.md §7.1.
Future<void> showBackupListDialog(BuildContext context) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => const _BackupListDialog(),
  );
}

/// Confirms, then restores [file] behind a pre-restore snapshot (§7.2), and
/// reports the outcome. Shared by the backup list and Import Backup.
Future<void> confirmAndRestoreBackup(
  BuildContext context,
  WidgetRef ref,
  File file,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final DateTime? capturedAt;
  try {
    final manifest = await readBackupManifest(file);
    capturedAt = DateTime.tryParse(manifest['exportedAt'] as String? ?? '');
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    return;
  }
  if (!context.mounted) return;

  final since = capturedAt == null
      ? 'this backup was taken'
      : DateFormat('d MMM y, HH:mm').format(capturedAt.toLocal());
  final confirmed = await showConfirmDialog(
    context,
    title: 'Restore backup',
    message:
        'Anything changed since $since will be replaced on all your devices. '
        'A snapshot of the current state is saved first, so you can undo '
        'this.',
    confirmLabel: 'Restore',
  );
  if (!confirmed) return;

  messenger.showSnackBar(
    const SnackBar(content: Text('Saving a snapshot, then restoring...')),
  );
  try {
    final summary = await ref.read(autoBackupServiceProvider).restore(file);
    // A restore can rewrite any collection, so nothing on screen can be
    // assumed still current.
    invalidateAllDataProvidersFrom(ref);
    final restored = summary.restoredTotal;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          restored == 0 && !summary.settingsRestored
              ? 'Backup restored — everything in it was already up to date.'
              : 'Backup restored: $restored record(s) restored, '
                    '${summary.skipped} already up to date. Undo it from '
                    'Automatic backups → Before restore.',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Restore failed, nothing was changed: $e')),
    );
  }
}

enum _BackupAction { restore, saveCopy }

class _BackupListDialog extends ConsumerStatefulWidget {
  const _BackupListDialog();

  @override
  ConsumerState<_BackupListDialog> createState() => _BackupListDialogState();
}

class _BackupListDialogState extends ConsumerState<_BackupListDialog> {
  List<BackupFileEntry>? _entries;

  /// Record totals from each manifest, filled in as they are read.
  final _records = <String, int>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final entries = await ref.read(autoBackupServiceProvider).listBackups();
    // Snapshots first: the one just taken is the undo for what just happened.
    entries.sort((a, b) {
      if (a.isSnapshot != b.isSnapshot) return a.isSnapshot ? -1 : 1;
      return b.capturedAt.compareTo(a.capturedAt);
    });
    if (!mounted) return;
    setState(() => _entries = entries);
    for (final entry in entries) {
      try {
        final manifest = await readBackupManifest(entry.file);
        final counts = (manifest['collections'] as Map? ?? const {}).values;
        final total = counts.fold<int>(0, (sum, c) => sum + (c as num).toInt());
        if (!mounted) return;
        setState(() => _records[entry.file.path] = total);
      } catch (_) {
        // The list still shows the file; restoring it will say what is wrong.
      }
    }
  }

  Future<void> _showInFolder() async {
    final dir = await ref.read(autoBackupServiceProvider).backupsDirectory();
    await Process.run('explorer', [dir.path]);
  }

  Future<void> _saveCopy(BackupFileEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await entry.file.readAsBytes();
      // Android writes [bytes] itself; the desktop pickers only return a path.
      final target = await FilePicker.platform.saveFile(
        dialogTitle: 'Save a copy',
        fileName: p.basename(entry.file.path),
        type: FileType.custom,
        allowedExtensions: ['zip'],
        bytes: bytes,
      );
      if (target == null) return;
      if (!isAndroid) await entry.file.copy(target);
      messenger.showSnackBar(SnackBar(content: Text('Saved to: $target')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  Future<void> _restore(BackupFileEntry entry) async {
    await confirmAndRestoreBackup(context, ref, entry.file);
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    final now = DateTime.now();
    final time = DateFormat('d MMM y, HH:mm');

    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Automatic backups')),
          if (isWindows)
            TextButton.icon(
              onPressed: _showInFolder,
              icon: const Icon(PhosphorIconsRegular.folderOpen, size: 18),
              label: const Text('Show in folder'),
            ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 560,
        height: 420,
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
                        entry.isSnapshot
                            ? PhosphorIconsRegular.arrowCounterClockwise
                            : PhosphorIconsRegular.archive,
                      ),
                      title: Text(backupAgeLabel(entry, now)),
                      subtitle: Text(
                        [
                          time.format(entry.capturedAt.toLocal()),
                          formatBackupBytes(entry.bytes),
                          if (_records[entry.file.path] case final records?)
                            '$records records',
                        ].join(' · '),
                      ),
                      trailing: PopupMenuButton<_BackupAction>(
                        icon: const Icon(PhosphorIconsRegular.dotsThree),
                        onSelected: (action) => switch (action) {
                          _BackupAction.restore => _restore(entry),
                          _BackupAction.saveCopy => _saveCopy(entry),
                        },
                        itemBuilder: (_) => voyagerPopupMenuEntries([
                          (
                            value: _BackupAction.restore,
                            child: const Text('Restore…'),
                          ),
                          (
                            value: _BackupAction.saveCopy,
                            child: const Text('Save a copy…'),
                          ),
                        ]),
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
