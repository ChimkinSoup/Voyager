import 'package:flutter/material.dart';
import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/features/rankings/rankings_icons.dart';

/// Name, colour and icon — everything a category needs to exist. Every other
/// setting has a sensible default and is changed in the manage sheet.
Future<({String name, int color, String iconKey})?> showRankingCategoryDialog(
  BuildContext context, {
  String title = 'New category',
  String submitLabel = 'Create',
  String initialName = '',
  int? initialColor,
  String initialIconKey = 'star',
}) {
  return showVoyagerDialog<({String name, int color, String iconKey})>(
    context: context,
    builder: (context) => _CategoryDialog(
      title: title,
      submitLabel: submitLabel,
      initialName: initialName,
      initialColor: initialColor ?? defaultColorPalette.first,
      initialIconKey: initialIconKey,
    ),
  );
}

class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog({
    required this.title,
    required this.submitLabel,
    required this.initialName,
    required this.initialColor,
    required this.initialIconKey,
  });

  final String title;
  final String submitLabel;
  final String initialName;
  final int initialColor;
  final String initialIconKey;

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  late final TextEditingController _nameController;
  late int _color;
  late String _iconKey;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _color = widget.initialColor;
    _iconKey = widget.initialIconKey;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (name: name, color: _color, iconKey: _iconKey));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dialog = EnterToSubmitScope(
      onSubmit: _submit,
      child: AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 380,
          // Scrolls in a window too short for the palette and the icons.
          child: VoyagerScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LabeledTextField(
                label: 'Name',
                controller: _nameController,
                autofocus: true,
                accentColor: Color(_color),
                // The scope above only sees Enter while no field is focused.
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              Text('Color', style: theme.textTheme.labelMedium),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: paletteViewportHeight(28, visibleRows: 2),
                ),
                child: ColorPaletteGrid(
                  palette: defaultColorPalette,
                  selected: _color,
                  onSelected: (color) => setState(() => _color = color),
                  swatchRadius: 28,
                  maxWidth: 380,
                  maxHeight: paletteViewportHeight(28, visibleRows: 2),
                  tightLayout: true,
                ),
              ),
              const SizedBox(height: 16),
              Text('Icon', style: theme.textTheme.labelMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final entry in rankingCategoryIcons.entries)
                    _IconChoice(
                      icon: entry.value,
                      selected: entry.key == _iconKey,
                      accent: Color(_color),
                      onTap: () => setState(() => _iconKey = entry.key),
                    ),
                ],
              ),
            ],
            ),
          ),
        ),
        actions: [
          GlassButton(
            onPressed: () => Navigator.pop(context),
            label: 'Cancel',
            dense: true,
          ),
          GlassButton(
            onPressed: _submit,
            label: widget.submitLabel,
            color: Color(_color),
            dense: true,
          ),
        ],
      ),
    );
    return CtrlEnterToSubmitScope(onSubmit: _submit, child: dialog);
  }
}

class _IconChoice extends StatelessWidget {
  const _IconChoice({
    required this.icon,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected ? accent.withValues(alpha: 0.16) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: selected
            ? BorderSide(color: accent)
            : BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.3),
              ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(
            icon,
            size: 18,
            color: selected ? accent : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
