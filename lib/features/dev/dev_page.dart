import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/dev/dev_weather_api_tile.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';

final devVerboseSyncProvider = StateProvider<bool>((ref) => false);

class DevPage extends ConsumerWidget {
  const DevPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final verboseSync = ref.watch(devVerboseSyncProvider);
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();

    return KeepAliveScrollView(
      storageKey: ShellPageStorageKeys.devList,
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Developer tools',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Local debugging utilities. These affect only this device.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        ListTile(
          title: const Text('Device ID'),
          subtitle: Text(ref.watch(deviceIdProvider)),
        ),
        SwitchListTile(
          title: const Text('Verbose sync logging'),
          subtitle: const Text('Print sync payloads to the debug console'),
          value: verboseSync,
          onChanged: (v) {
            DevFlags.verboseSync = v;
            ref.read(devVerboseSyncProvider.notifier).state = v;
          },
        ),
        const Divider(height: 32),
        DevWeatherApiTile(settings: settings),
        const Divider(height: 32),
        ListTile(
          title: const Text('Force reload local data'),
          subtitle: const Text('Refresh providers from the local database'),
          trailing: const Icon(PhosphorIconsRegular.arrowClockwise),
          onTap: () {
            ref.invalidate(journalsProvider);
            ref.invalidate(journalEntriesProvider);
            ref.invalidate(todoListsProvider);
            ref.invalidate(calendarEventsProvider);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Providers invalidated')),
            );
          },
        ),
        ListTile(
          title: const Text('Purge soft-deleted items'),
          subtitle: const Text(
            'Permanently remove items past the 30-day retention window',
          ),
          trailing: const Icon(PhosphorIconsRegular.broom),
          onTap: () async {
            final now = DateTime.now().toUtc();
            await ref.read(journalRepositoryProvider).purgeExpiredDeleted(now);
            await ref.read(todoRepositoryProvider).purgeExpiredDeleted(now);
            await ref.read(calendarRepositoryProvider).purgeExpiredDeleted(now);
            await ref.read(trackerRepositoryProvider).purgeExpiredDeleted(now);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Soft-deleted items purged')),
              );
            }
          },
        ),
        ListTile(
          title: const Text('Delete all journal entries'),
          subtitle: const Text(
            'Permanently removes every journal entry from the local database',
          ),
          trailing: const Icon(
            PhosphorIconsRegular.trash,
            color: Colors.redAccent,
          ),
          onTap: () => _confirmDeleteAllEntries(context, ref),
        ),
        const Divider(height: 32),
        ListTile(
          title: const Text('Reset all journals'),
          subtitle: const Text(
            'Deletes every journal container. Entries are not removed.',
          ),
          trailing: const Icon(
            PhosphorIconsRegular.warning,
            color: Colors.orange,
          ),
          onTap: () => _confirmResetJournals(context, ref),
        ),
      ],
    );
  }

  Future<void> _confirmDeleteAllEntries(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all journal entries?'),
        content: const Text(
          'This permanently deletes every journal entry on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete entries'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(journalRepositoryProvider).deleteAllEntries();
    ref.invalidate(journalEntriesProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All journal entries deleted')),
      );
    }
  }

  Future<void> _confirmResetJournals(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset all journals?'),
        content: const Text(
          'This permanently deletes all journal containers. Journal entries will remain in the database but may become orphaned.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset journals'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(journalRepositoryProvider).deleteAllJournals();
    ref.invalidate(journalsProvider);
    ref.invalidate(journalEntriesProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('All journals deleted')));
    }
  }
}
