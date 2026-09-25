import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/dev/error_logger.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

class DevErrorLogSection extends StatelessWidget {
  const DevErrorLogSection({super.key});

  @override
  Widget build(BuildContext context) {
    final logger = ErrorLogger.instance;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FutureBuilder<String>(
          future: logger.logFilePath(),
          builder: (context, snapshot) => ListTile(
            title: const Text('Error log'),
            subtitle: Text(
              'Every uncaught or reported error, with its stack trace and '
              'build. Always on.\n${snapshot.data ?? ''}',
            ),
          ),
        ),
        ListTile(
          title: const Text('View error log'),
          trailing: const Icon(PhosphorIconsRegular.fileText),
          onTap: () => _showLogDialog(context),
        ),
        ListTile(
          title: const Text('Copy error log to clipboard'),
          trailing: const Icon(PhosphorIconsRegular.copy),
          onTap: () async {
            final text = await logger.readLog();
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    text.isEmpty
                        ? 'Error log is empty'
                        : 'Copied ${text.length} characters',
                  ),
                ),
              );
            }
          },
        ),
        ListTile(
          title: const Text('Clear error log'),
          trailing: const Icon(PhosphorIconsRegular.trash),
          onTap: () async {
            await logger.clearLog();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Error log cleared')),
              );
            }
          },
        ),
      ],
    );
  }

  /// See `DevPerfStallLogSection._logDialogOpen`.
  static bool _logDialogOpen = false;

  Future<void> _showLogDialog(BuildContext context) async {
    if (_logDialogOpen) return;
    _logDialogOpen = true;
    final String text;
    try {
      text = await ErrorLogger.instance.readLog();
    } finally {
      _logDialogOpen = false;
    }
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error log'),
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
