import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/features/settings/folder_backup_list_dialog.dart';
import 'package:voyager/features/settings/folder_backup_source_dialog.dart';
import 'package:voyager/features/settings/settings_reveal.dart';
import 'package:voyager/features/settings/services/folder_backup_service.dart';
import 'package:voyager/features/shell/reveal_request.dart';

/// Settings → Backup & Restore → Folder backups (FOLDER_BACKUP_HLD.md §9).
/// Windows only.
class FolderBackupSection extends ConsumerStatefulWidget {
  const FolderBackupSection({super.key});

  @override
  ConsumerState<FolderBackupSection> createState() =>
      _FolderBackupSectionState();
}

class _FolderBackupSectionState extends ConsumerState<FolderBackupSection> {
  @override
  void initState() {
    super.initState();
    // Fresh each time Settings opens.
    ref.read(folderBackupServiceProvider).refreshStatus();
    if (ref.read(revealFolderBackupsRequestProvider)) _reveal();
  }

  /// Answers the inbox's rows and the OS notification, as the automatic
  /// backup tiles do theirs.
  void _reveal() => revealSettingsSection(
    context,
    clearRequest: () =>
        ref.read(revealFolderBackupsRequestProvider.notifier).state = false,
  );

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(revealFolderBackupsRequestProvider, (_, next) {
      if (next) _reveal();
    });
    final status = ref.watch(folderBackupServiceProvider).status;
    final theme = Theme.of(context);
    final total = status?.totalBytes ?? 0;

    return Column(
      children: [
        ListTile(
          leading: const Icon(PhosphorIconsRegular.folders),
          title: const Text('Folder backups'),
          subtitle: Text(
            [
              'Back up any folder, such as an Obsidian vault, on a schedule',
              if (total > 0) '${formatFolderBackupBytes(total)} in all',
            ].join(' · '),
          ),
          trailing: GlassButton(
            dense: true,
            onPressed: () => showFolderBackupSourceDialog(context),
            icon: const Icon(PhosphorIconsRegular.plus, size: 16),
            label: 'Add folder…',
          ),
        ),
        for (final source in status?.sources ?? const [])
          _SourceRow(status: source),
        for (final retired in status?.retired ?? const [])
          ListTile(
            leading: Icon(
              PhosphorIconsRegular.archive,
              color: theme.colorScheme.outline,
            ),
            title: Text(
              '${retired.entry.name} (removed) · '
              '${retired.count} ${retired.count == 1 ? 'backup' : 'backups'} · '
              '${formatFolderBackupBytes(retired.bytes)}',
            ),
            subtitle: Text(
              [
                retired.entry.path,
                'removed '
                    '${DateFormat('d MMM y').format(retired.entry.retiredAt.toLocal())}',
                if (!retired.reachable) 'drive not connected',
              ].join(' · '),
            ),
            trailing: const Icon(PhosphorIconsRegular.caretRight),
            onTap: () =>
                showFolderBackupListDialog(context, retired: retired.entry),
          ),
      ],
    );
  }
}

/// §9.2: one source.
class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.status});

  final FolderBackupSourceStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Color? dot, String word) = switch (status.health) {
      FolderBackupHealth.moving => (null, 'Moving…'),
      FolderBackupHealth.backingUp => (null, 'Backing up…'),
      FolderBackupHealth.review => (theme.colorScheme.error, 'Review'),
      FolderBackupHealth.off => (theme.colorScheme.outline, 'Off'),
      FolderBackupHealth.attention => (Colors.amber, 'Attention'),
      FolderBackupHealth.notYetBackedUp => (
        theme.colorScheme.outline,
        'Not yet backed up',
      ),
      FolderBackupHealth.healthy => (Colors.green, 'Healthy'),
    };
    final busy =
        status.health == FolderBackupHealth.moving ||
        status.health == FolderBackupHealth.backingUp;
    final count = status.backupCount;
    final title = [
      status.source.name,
      if (!status.reachable)
        'destination not connected'
      else ...[
        [
          '$count ${count == 1 ? 'backup' : 'backups'}',
          if (status.pinnedCount > 0) '+ ${status.pinnedCount} pinned',
        ].join(' '),
        formatFolderBackupBytes(status.totalBytes),
      ],
    ].join(' · ');

    return ListTile(
      leading: const Icon(PhosphorIconsRegular.folderSimple),
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status.detail),
          if (status.spaceWarning case final warning?)
            Text(
              warning,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.amber.shade800,
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox.square(
              dimension: 10,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (dot != null)
            Icon(Icons.circle, size: 10, color: dot),
          const SizedBox(width: 6),
          Text(word, style: theme.textTheme.labelMedium),
          const SizedBox(width: 4),
          const Icon(PhosphorIconsRegular.caretRight),
        ],
      ),
      onTap: () =>
          showFolderBackupListDialog(context, sourceId: status.source.id),
    );
  }
}
