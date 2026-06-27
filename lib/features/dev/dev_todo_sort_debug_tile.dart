import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';

class DevTodoSortDebugSection extends ConsumerWidget {
  const DevTodoSortDebugSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logger = ref.watch(todoSortDebugLoggerProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Todo sort debug log'),
          subtitle: const Text(
            'Append full list snapshots when sorting changes (persists across restarts)',
          ),
          value: logger.enabled,
          onChanged: (value) {
            unawaited(ref.read(todoSortDebugLoggerProvider).setEnabled(value));
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
            subtitle: const Text('Show the current todo sort debug log'),
            trailing: const Icon(PhosphorIconsRegular.fileText),
            onTap: () => _showLogDialog(context, ref),
          ),
          ListTile(
            title: const Text('Copy log to clipboard'),
            trailing: const Icon(PhosphorIconsRegular.copy),
            onTap: () async {
              final text = await ref.read(todoSortDebugLoggerProvider).readLog();
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
                  title: const Text('Clear todo sort debug log?'),
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
              await ref.read(todoSortDebugLoggerProvider).clearLog();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Todo sort debug log cleared')),
                );
              }
            },
          ),
        ],
      ],
    );
  }

  Future<void> _showLogDialog(BuildContext context, WidgetRef ref) async {
    final text = await ref.read(todoSortDebugLoggerProvider).readLog();
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Todo sort debug log'),
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
