import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';

class SettingsColorPaletteSection extends ConsumerStatefulWidget {
  const SettingsColorPaletteSection({
    super.key,
    required this.settings,
    required this.onSave,
  });

  final AppSettings settings;
  final Future<void> Function(AppSettings settings) onSave;

  @override
  ConsumerState<SettingsColorPaletteSection> createState() =>
      _SettingsColorPaletteSectionState();
}

class _SettingsColorPaletteSectionState
    extends ConsumerState<SettingsColorPaletteSection> {
  final _hexController = TextEditingController();
  String? _hexError;

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  Future<void> _updatePalette(List<int> palette) async {
    await widget.onSave(widget.settings.copyWith(colorPalette: palette));
  }

  Future<void> _addColor() async {
    final parsed = parseHexColor(_hexController.text);
    if (parsed == null) {
      setState(() => _hexError = 'Enter 6 hex digits (e.g. 7C9EFF)');
      return;
    }
    final palette = List<int>.from(widget.settings.colorPalette);
    if (palette.contains(parsed)) {
      setState(() => _hexError = 'Color already in palette');
      return;
    }
    palette.add(parsed);
    _hexController.clear();
    setState(() => _hexError = null);
    await _updatePalette(palette);
  }

  Future<void> _removeColor(int color) async {
    if (widget.settings.colorPalette.length <= 1) return;
    final palette = List<int>.from(widget.settings.colorPalette)
      ..remove(normalizeColorValue(color));
    await _updatePalette(palette);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = widget.settings.colorPalette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Color palette', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Preset colors used across the app. Add custom colors with hex here; '
          'everywhere else you pick from this list only.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final color in palette)
              InputChip(
                avatar: CircleAvatar(backgroundColor: Color(color)),
                label: Text(formatColorHex(color)),
                onDeleted: palette.length > 1
                    ? () => _removeColor(color)
                    : null,
                deleteIcon: palette.length > 1
                    ? const Icon(PhosphorIconsRegular.x, size: 18)
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _hexController,
                maxLength: 6,
                buildCounter: (
                  _,
                  {
                  required currentLength,
                  required isFocused,
                  maxLength,
                }) =>
                    null,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(6),
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Fa-f]')),
                ],
                decoration: InputDecoration(
                  labelText: 'Add custom color',
                  hintText: '7C9EFF',
                  errorText: _hexError,
                ),
                onSubmitted: (_) => _addColor(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _addColor,
              child: const Text('Add'),
            ),
          ],
        ),
      ],
    );
  }
}

Future<void> pickAccentColor(
  BuildContext context,
  WidgetRef ref,
  AppSettings settings,
  Future<void> Function(AppSettings settings) onSave,
) async {
  var selected = normalizeColorValue(settings.accentColor);
  final palette = ref.read(colorPaletteProvider);
  if (!paletteContains(palette, selected)) {
    selected = normalizeColorValue(palette.first);
  }

  final picked = await pickColorFromPalette(
    context,
    palette: palette,
    current: selected,
    title: 'Accent color',
  );
  if (picked != null) {
    await onSave(settings.copyWith(accentColor: picked));
  }
}
