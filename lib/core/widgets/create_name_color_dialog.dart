import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';

/// Prompts for a name and palette color when creating journals/lists.
Future<({String name, int color})?> showCreateNameColorDialog(
  BuildContext context, {
  required String title,
  required List<int> palette,
  required int initialColor,
  Set<int> usedColors = const {},
  String submitLabel = 'Create',
}) {
  return showDialog<({String name, int color})>(
    context: context,
    builder: (context) => _CreateNameColorDialog(
      title: title,
      palette: palette,
      initialColor: initialColor,
      usedColors: usedColors,
      submitLabel: submitLabel,
    ),
  );
}

class _CreateNameColorDialog extends StatefulWidget {
  const _CreateNameColorDialog({
    required this.title,
    required this.palette,
    required this.initialColor,
    required this.usedColors,
    required this.submitLabel,
  });

  final String title;
  final List<int> palette;
  final int initialColor;
  final Set<int> usedColors;
  final String submitLabel;

  @override
  State<_CreateNameColorDialog> createState() => _CreateNameColorDialogState();
}

class _CreateNameColorDialogState extends State<_CreateNameColorDialog> {
  late final TextEditingController _nameController;
  late int _selectedColor;
  var _showEmptyNameError = false;

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
    if (name.isEmpty) {
      setState(() => _showEmptyNameError = true);
      return;
    }
    Navigator.pop(context, (name: name, color: _selectedColor));
  }

  @override
  Widget build(BuildContext context) {
    return EnterToSubmitScope(
      onSubmit: _submit,
      child: AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledTextField(
              label: 'Name',
              controller: _nameController,
              autofocus: true,
              onChanged: (_) {
                if (_showEmptyNameError) {
                  setState(() => _showEmptyNameError = false);
                }
              },
            ),
            if (_showEmptyNameError) ...[
              const SizedBox(height: 6),
              Text(
                'Title cannot be empty',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text('Color', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            ColorPaletteGrid(
              palette: widget.palette,
              selected: _selectedColor,
              usedColors: widget.usedColors,
              onSelected: (color) => setState(() => _selectedColor = color),
              maxWidth: 520,
              maxHeight: paletteViewportHeight(18, visibleRows: 3),
              tightLayout: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.submitLabel)),
      ],
      ),
    );
  }
}
