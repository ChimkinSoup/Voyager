import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';

class DevJournalDebugSection extends ConsumerWidget {
  const DevJournalDebugSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logger = ref.watch(journalDebugLoggerProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Journal page debug log'),
          subtitle: const Text(
            'Append UI state and DB snapshots for journal save actions (persists across restarts)',
          ),
          value: logger.enabled,
          onChanged: (value) {
            unawaited(ref.read(journalDebugLoggerProvider).setEnabled(value));
          },
        ),
        if (logger.enabled) ...[
          FutureBuilder<String>(
            future: logger.logFilePath(),
            builder: (context, snapshot) {
              final path = snapshot.data;
              if (path == null) return const SizedBox.shrink();
              return ListTile(
                dense: true,
                title: const Text('Log file'),
                subtitle: Text(path, style: Theme.of(context).textTheme.bodySmall),
              );
            },
          ),
          ListTile(
            title: const Text('View log'),
            subtitle: const Text('Show the current journal debug log'),
            trailing: const Icon(PhosphorIconsRegular.fileText),
            onTap: () => _showLogDialog(context, ref),
          ),
          ListTile(
            title: const Text('Copy log to clipboard'),
            trailing: const Icon(PhosphorIconsRegular.copy),
            onTap: () async {
              final text = await ref.read(journalDebugLoggerProvider).readLog();
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      text.isEmpty
                          ? 'Log is empty'
                          : 'Copied ${text.length} characters',
                    ),
                  ),
                );
              }
            },
          ),
          ListTile(
            title: const Text('Clear log'),
            subtitle: const Text('Remove all log entries from disk'),
            trailing: const Icon(PhosphorIconsRegular.trash),
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Clear journal debug log?'),
                  content: const Text(
                    'This permanently deletes the log file contents.',
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
              await ref.read(journalDebugLoggerProvider).clearLog();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Journal debug log cleared')),
                );
              }
            },
          ),
        ],
      ],
    );
  }

  Future<void> _showLogDialog(BuildContext context, WidgetRef ref) async {
    final text = await ref.read(journalDebugLoggerProvider).readLog();
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Journal debug log'),
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
}
