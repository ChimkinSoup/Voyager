import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';

/// Prompts for a name and palette color when creating journals/lists.
Future<({String name, int color})?> showCreateNameColorDialog(
  BuildContext context, {
  required String title,
  required List<int> palette,
  required int initialColor,
}) {
  return showDialog<({String name, int color})>(
    context: context,
    builder: (context) => _CreateNameColorDialog(
      title: title,
      palette: palette,
      initialColor: initialColor,
    ),
  );
}

class _CreateNameColorDialog extends StatefulWidget {
  const _CreateNameColorDialog({
    required this.title,
    required this.palette,
    required this.initialColor,
  });

  final String title;
  final List<int> palette;
  final int initialColor;

  @override
  State<_CreateNameColorDialog> createState() => _CreateNameColorDialogState();
}

class _CreateNameColorDialogState extends State<_CreateNameColorDialog> {
  late final TextEditingController _nameController;
  late int _selectedColor;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _selectedColor = widget.initialColor;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (name: name, color: _selectedColor));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            Text('Color', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            ColorPaletteGrid(
              palette: widget.palette,
              selected: _selectedColor,
              onSelected: (color) => setState(() => _selectedColor = color),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
