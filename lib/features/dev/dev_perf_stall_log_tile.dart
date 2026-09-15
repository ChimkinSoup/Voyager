import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/dev/perf_stall_logger.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

class DevPerfStallLogSection extends StatelessWidget {
  const DevPerfStallLogSection({super.key});

  @override
  Widget build(BuildContext context) {
    final logger = PerfStallLogger.instance;

    return ListenableBuilder(
      listenable: logger,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            title: const Text('Stall log'),
            subtitle: Text(
              'Record every freeze over '
              '${PerfStallLogger.stallThreshold.inMilliseconds}ms with the '
              'page, input and sync activity around it (persists across '
              'restarts)',
            ),
            value: logger.enabled,
            onChanged: (value) => unawaited(logger.setEnabled(value)),
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
                  subtitle: Text(
                    path,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                );
              },
            ),
            ListTile(
              title: const Text('View log'),
              trailing: const Icon(PhosphorIconsRegular.fileText),
              onTap: () => _showLogDialog(context),
            ),
            ListTile(
              title: const Text('Copy log to clipboard'),
              trailing: const Icon(PhosphorIconsRegular.copy),
              onTap: () async {
                final text = await logger.readLog();
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
              trailing: const Icon(PhosphorIconsRegular.trash),
              onTap: () async {
                await logger.clearLog();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Stall log cleared')),
                  );
                }
              },
            ),
          ],
        ],
      ),
    );
  }

  /// Reading the log off disk happens with nothing on screen, so a second
  /// press landing in that gap would stack a second dialog on the first.
  static bool _logDialogOpen = false;

  Future<void> _showLogDialog(BuildContext context) async {
    if (_logDialogOpen) return;
    _logDialogOpen = true;
    final String text;
    try {
      text = await PerfStallLogger.instance.readLog();
    } finally {
      _logDialogOpen = false;
    }
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stall log'),
        content: SizedBox(
          width: 720,
          child: VoyagerScrollView(
            child: SelectableText(
              text.isEmpty ? '(empty)' : text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          GlassButton(
            onPressed: () => Navigator.pop(context),
            label: 'Close',
            dense: true,
          ),
        ],
      ),
    );
  }
}
