import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/utils/key_binding.dart';
Future<String?> showKeyBindingDialog(
  BuildContext context, {
  required String title,
  String? current,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _KeyBindingDialog(title: title, current: current),
  );
}

class _KeyBindingDialog extends StatefulWidget {
  const _KeyBindingDialog({required this.title, this.current});

  final String title;
  final String? current;

  @override
  State<_KeyBindingDialog> createState() => _KeyBindingDialogState();
}

class _KeyBindingDialogState extends State<_KeyBindingDialog> {
  String? _captured;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop<String?>(null);
      return true;
    }

    final binding = keyBindingFromKeyEvent(event);
    if (binding == null) return false;

    final stored = keyBindingToStorage(binding);
    setState(() => _captured = stored);
    Navigator.of(context).pop(stored);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final preview = _captured ?? widget.current;
    return AlertDialog(
      title: Text(widget.title),
      content: Text(
        preview == null
            ? 'Press a letter key to assign this shortcut.\nEsc to cancel.'
            : 'Current: ${formatKeyBinding(preview)}\n\n'
                'Press a new letter key, or Esc to cancel.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop<String?>(null),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
