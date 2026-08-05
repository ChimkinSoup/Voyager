import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';

const _paletteAspect = 4 / 3;
const _paletteSpacing = 8.0;

/// Visual swatch size relative to grid pitch radius ([swatchRadius]).
const _swatchVisualScale = 1.15;

double _swatchVisualRadius(double layoutRadius) =>
    layoutRadius * _swatchVisualScale;

/// Height for a palette grid showing [visibleRows] of swatches.
///
/// When [clipPartialNextRow] is true, the height fits exactly [visibleRows]
/// rows in a scrollable grid without revealing any of the next row.
double paletteViewportHeight(
  double swatchRadius, {
  int visibleRows = 3,
  bool clipPartialNextRow = false,
}) {
  if (visibleRows <= 0) return 0;
  final visualDiameter = _swatchVisualRadius(swatchRadius) * 2;
  final cell = visualDiameter + _paletteSpacing;
  var height = visibleRows * cell - _paletteSpacing + 32.0;
  if (clipPartialNextRow) height -= _paletteSpacing;
  return height;
}

/// Sizes a palette grid inside a 4:3 box that grows with color count.
({
  double width,
  double height,
  int columns,
  bool scrollable,
  double contentWidth,
  double contentHeight,
})
computeColorPaletteLayout({
  required int colorCount,
  required double maxWidth,
  required double maxHeight,
  double swatchRadius = 26,
}) {
  if (colorCount == 0) {
    return (
      width: 200,
      height: 150,
      columns: 1,
      scrollable: false,
      contentWidth: 200,
      contentHeight: 150,
    );
  }

  final cell = swatchRadius * 2 + _paletteSpacing;
  final cappedMaxWidth = math.max(cell, maxWidth);
  final cappedMaxHeight = math.max(cell, maxHeight);

  final targetColumns = math.min(
    colorCount,
    math.max(3, (math.sqrt(colorCount * _paletteAspect)).ceil()),
  );
  var columns = math.min(
    colorCount,
    math.max(1, (cappedMaxWidth / cell).floor()),
  );
  columns = math.min(columns, targetColumns);

  var rows = (colorCount / columns).ceil();
  var intrinsicW = columns * cell - _paletteSpacing;
  var intrinsicH = rows * cell - _paletteSpacing;

  double boxW = intrinsicW;
  double boxH = intrinsicH;
  
  var scrollable = false;
  if (boxH > cappedMaxHeight) {
    boxH = cappedMaxHeight;
    scrollable = true;
  }

  return (
    width: boxW,
    height: boxH,
    columns: columns,
    scrollable: scrollable,
    contentWidth: intrinsicW,
    contentHeight: intrinsicH,
  );
}

/// Grid of preset swatches (no custom hex entry).
class ColorPaletteGrid extends StatelessWidget {
  const ColorPaletteGrid({
    super.key,
    required this.palette,
    required this.selected,
    required this.onSelected,
    this.usedColors = const {},
    this.swatchRadius = 18,
    this.maxWidth,
    this.maxHeight,
    this.tightLayout = false,
  });

  final List<int> palette;
  final int? selected;
  final ValueChanged<int> onSelected;
  final Set<int> usedColors;
  final double swatchRadius;
  final double? maxWidth;
  final double? maxHeight;

  /// When true, sizes the grid to its content instead of a fixed 4:3 box.
  final bool tightLayout;

  @override
  Widget build(BuildContext context) {
    if (palette.isEmpty) {
      return Text(
        'Add colors in Settings first.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.sizeOf(context);

        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : (maxWidth ?? media.width * 0.85);

        final visualDiameter = _swatchVisualRadius(swatchRadius) * 2;
        final cell = visualDiameter + _paletteSpacing;
        final columns = math.max(1, ((availableWidth - 32 + _paletteSpacing) / cell).floor());
        final rows = (palette.length / columns).ceil();
        final intrinsicH = rows * visualDiameter + (rows - 1) * _paletteSpacing + 32.0;

        // Cap the visible height. Inside an unbounded context (SingleChildScrollView)
        // constraints.maxHeight is infinity, so we fall back to maxHeight param.
        final capH = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : (maxHeight ?? media.height * 0.45);

        final viewportH = math.min(intrinsicH, capH);
        final needsScroll = intrinsicH > capH;

        final normalizedSelected =
            selected == null ? null : normalizeColorValue(selected!);

        final wrap = Padding(
          padding: const EdgeInsets.all(16.0),
          child: Wrap(
            spacing: _paletteSpacing,
            runSpacing: _paletteSpacing,
            children: palette.map((colorValue) {
              final normalized = normalizeColorValue(colorValue);
              return _ColorSwatch(
                colorValue: colorValue,
                selected: normalized == normalizedSelected,
                used: usedColors.map(normalizeColorValue).contains(normalized),
                radius: _swatchVisualRadius(swatchRadius),
                onTap: () => onSelected(normalized),
              );
            }).toList(),
          ),
        );

        Widget content = wrap;

        if (needsScroll) {
          content = SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: content,
          );
        }

        return SizedBox(
          width: availableWidth,
          height: viewportH,
          child: Material(
            color: Colors.transparent,
            clipBehavior: Clip.hardEdge,
            child: content,
          ),
        );
      },
    );
  }
}

/// Preset-only color picker backed by the user palette in settings.
class ColorPickerField extends ConsumerStatefulWidget {
  const ColorPickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.usedColors = const {},
    this.maxWidth,
    this.maxHeight,
    this.swatchRadius = 18,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final Set<int> usedColors;
  final double? maxWidth;
  final double? maxHeight;
  final double swatchRadius;

  @override
  ConsumerState<ColorPickerField> createState() => _ColorPickerFieldState();
}

class _ColorPickerFieldState extends ConsumerState<ColorPickerField> {
  late int _selected;

  @override
  void initState() {
    super.initState();
    _selected = normalizeColorValue(widget.value);
  }

  @override
  void didUpdateWidget(ColorPickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = normalizeColorValue(widget.value);
    if (next != _selected) {
      _selected = next;
    }
  }

  void _select(int color) {
    setState(() => _selected = color);
    widget.onChanged(color);
  }

  @override
  Widget build(BuildContext context) {
    final palette = ref.watch(colorPaletteProvider);
    final media = MediaQuery.sizeOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        ColorPaletteGrid(
          palette: palette,
          selected: _selected,
          onSelected: _select,
          usedColors: widget.usedColors,
          swatchRadius: widget.swatchRadius,
          maxWidth: widget.maxWidth ?? media.width,
          maxHeight: widget.maxHeight,
        ),
      ],
    );
  }
}



Future<int?> pickColorFromPalette(
  BuildContext context, {
  required List<int> palette,
  int? current,
  Set<int> usedColors = const {},
  String title = 'Choose color',
}) async {
  if (palette.isEmpty) return current;

  return showVoyagerDialog<int>(
    context: context,
    builder: (context) => _PalettePickDialog(
      palette: palette,
      initial: current,
      usedColors: usedColors,
      title: title,
    ),
  );
}

class _PalettePickDialog extends StatefulWidget {
  const _PalettePickDialog({
    required this.palette,
    required this.initial,
    required this.usedColors,
    required this.title,
  });

  final List<int> palette;
  final int? initial;
  final Set<int> usedColors;
  final String title;

  @override
  State<_PalettePickDialog> createState() => _PalettePickDialogState();
}

class _SubmitIntent extends Intent {
  const _SubmitIntent();
}

class _PalettePickDialogState extends State<_PalettePickDialog> {
  late int _picked;

  @override
  void initState() {
    super.initState();
    _picked = widget.initial == null
        ? normalizeColorValue(widget.palette.first)
        : normalizeColorValue(widget.initial!);
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): _SubmitIntent(),
      },
      child: Actions(
        actions: {
          _SubmitIntent: CallbackAction<_SubmitIntent>(
            onInvoke: (_) {
              Navigator.pop(context, _picked);
              return null;
            },
          ),
        },
        child: AlertDialog(
          title: Text(widget.title),
          titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          content: SizedBox(
            width: 520,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: paletteViewportHeight(32, visibleRows: 3),
              ),
              child: ColorPaletteGrid(
                palette: widget.palette,
                selected: _picked,
                usedColors: widget.usedColors,
                onSelected: (color) => setState(() => _picked = color),
                swatchRadius: 32,
                maxWidth: 520,
                maxHeight: paletteViewportHeight(32, visibleRows: 3),
                tightLayout: true,
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
              onPressed: () => Navigator.pop(context, _picked),
              label: 'Save',
              dense: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.colorValue,
    required this.selected,
    required this.used,
    required this.radius,
    required this.onTap,
  });

  final int colorValue;
  final bool selected;
  final bool used;
  final double radius;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usedRingColor = theme.colorScheme.onSurface.withValues(alpha: 0.88);
    final diameter = radius * 2;
    
    final swatchColor = Color(colorValue);
    final isDark = swatchColor.computeLuminance() < 0.5;
    final checkColor = isDark ? Colors.white : Colors.black;

    return InkWell(
      onTap: onTap,
      onFocusChange: (focused) {
        if (focused) onTap();
      },
      customBorder: const CircleBorder(),
      child: Ink(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: swatchColor,
          border: selected
              ? Border.all(color: theme.colorScheme.primary, width: 3)
              : used
              ? Border.all(color: usedRingColor, width: 3)
              : null,
        ),
        child: selected ? Icon(
          PhosphorIconsFill.checkFat,
          color: checkColor,
          size: radius * 1.2,
        ) : null,
      ),
    );
  }
}
