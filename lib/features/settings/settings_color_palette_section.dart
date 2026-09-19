import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
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
  final _hexFocusNode = FocusNode();
  String? _hexError;

  @override
  void dispose() {
    _hexController.dispose();
    _hexFocusNode.dispose();
    super.dispose();
  }

  Future<void> _updatePalette(List<int> palette) async {
    await widget.onSave(widget.settings.copyWith(colorPalette: palette));
  }

  Future<void> _addColor() async {
    final parsed = parseHexColor(_hexController.text);
    if (parsed == null) {
      setState(() => _hexError = 'Enter 6 hex digits (e.g. 7C9EFF)');
      _hexFocusNode.requestFocus();
      return;
    }
    final palette = List<int>.from(widget.settings.colorPalette);
    if (palette.contains(parsed)) {
      setState(() => _hexError = 'Color already in palette');
      _hexFocusNode.requestFocus();
      return;
    }
    palette.add(parsed);
    _hexController.clear();
    setState(() => _hexError = null);
    await _updatePalette(palette);
    if (mounted) _hexFocusNode.requestFocus();
  }

  Future<void> _removeColor(int color) async {
    if (widget.settings.colorPalette.length <= 1) return;
    final palette = List<int>.from(widget.settings.colorPalette)
      ..remove(normalizeColorValue(color));
    await _updatePalette(palette);
  }

  /// Moves [dragged] into [target]'s slot.
  ///
  /// Dropping onto a chip to the right lands after it, to the left lands
  /// before it — `removeAt` has already shifted the later indices down by one
  /// when the move is rightward, so the single `insert` covers both.
  Future<void> _moveColor(int dragged, int target) async {
    final palette = List<int>.from(widget.settings.colorPalette);
    final from = palette.indexOf(normalizeColorValue(dragged));
    final to = palette.indexOf(normalizeColorValue(target));
    if (from < 0 || to < 0 || from == to) return;
    palette.insert(to, palette.removeAt(from));
    await _updatePalette(palette);
  }

  Widget _colorChip(int color, {required bool deletable, BorderSide? side}) {
    return InputChip(
      avatar: CircleAvatar(backgroundColor: Color(color)),
      label: Text(formatColorHex(color)),
      side: side,
      onDeleted: deletable ? () => _removeColor(color) : null,
      deleteIcon: deletable
          ? const Icon(PhosphorIconsRegular.x, size: 18)
          : null,
    );
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
          'everywhere else you pick from this list only. Drag a swatch to '
          'reorder the palette.',
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
              DragTarget<int>(
                onWillAcceptWithDetails: (details) =>
                    normalizeColorValue(details.data) !=
                    normalizeColorValue(color),
                onAcceptWithDetails: (details) =>
                    _moveColor(details.data, color),
                builder: (context, candidates, _) => Draggable<int>(
                  data: color,
                  feedback: Material(
                    type: MaterialType.transparency,
                    child: _colorChip(color, deletable: false),
                  ),
                  childWhenDragging: Opacity(
                    opacity: 0.3,
                    child: _colorChip(color, deletable: false),
                  ),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: _colorChip(
                      color,
                      deletable: palette.length > 1,
                      side: candidates.isEmpty
                          ? null
                          : BorderSide(
                              color: theme.colorScheme.primary,
                              width: 2,
                            ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: VoyagerTextField(
                controller: _hexController,
                focusNode: _hexFocusNode,
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
                  // Filter before limiting, so a pasted "#f2d5cf" loses its
                  // "#" rather than its last digit.
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Fa-f]')),
                  LengthLimitingTextInputFormatter(6),
                ],
                decoration: const InputDecoration(
                  hintText: 'Add custom color (e.g. 7C9EFF)',
                  // Without these the field takes Flutter's outlined default of
                  // 20px above and below a single line of text, which left the
                  // row looming over the swatches it belongs to.
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                onSubmitted: (_) => _addColor(),
              ),
            ),
            const SizedBox(width: 8),
            GlassButton(
              onPressed: _addColor,
              label: 'Add',
              dense: true,
            ),
          ],
        ),
        if (_hexError != null) ...[
          const SizedBox(height: 8),
          Text(
            _hexError!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
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
