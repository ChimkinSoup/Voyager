import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';

const _paletteAspect = 4 / 3;
const _paletteSpacing = 8.0;

/// Visual swatch size relative to grid pitch radius ([swatchRadius]).
const _swatchVisualScale = 1.15;

double _swatchVisualRadius(double layoutRadius) =>
    layoutRadius * _swatchVisualScale;

/// Height for a palette grid showing [visibleRows] of swatches.
double paletteViewportHeight(double swatchRadius, {int visibleRows = 3}) {
  if (visibleRows <= 0) return 0;
  final cell = swatchRadius * 2 + _paletteSpacing;
  return visibleRows * cell - _paletteSpacing;
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
  final cappedMaxWidth = math.max(160, maxWidth);
  final cappedMaxHeight = math.max(120, maxHeight);

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

  double boxW;
  double boxH;
  if (intrinsicW / intrinsicH >= _paletteAspect) {
    boxW = intrinsicW;
    boxH = intrinsicW / _paletteAspect;
  } else {
    boxH = intrinsicH;
    boxW = intrinsicH * _paletteAspect;
  }

  const minW = 160.0;
  const minH = 120.0;
  if (boxW < minW) {
    boxW = minW;
    boxH = boxW / _paletteAspect;
  }
  if (boxH < minH) {
    boxH = minH;
    boxW = boxH * _paletteAspect;
  }

  var scrollable = false;
  if (boxW > cappedMaxWidth || boxH > cappedMaxHeight) {
    boxW = math
        .min(cappedMaxWidth, cappedMaxHeight * _paletteAspect)
        .toDouble();
    boxH = boxW / _paletteAspect;
    scrollable = intrinsicH > boxH;
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

bool _paletteContains(List<int> palette, int color) =>
    paletteContains(palette, color);

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

    final media = MediaQuery.sizeOf(context);
    final layout = computeColorPaletteLayout(
      colorCount: palette.length,
      maxWidth: maxWidth ?? media.width * 0.85,
      maxHeight: maxHeight ?? media.height * 0.45,
      swatchRadius: swatchRadius,
    );

    final normalizedSelected = selected == null
        ? null
        : normalizeColorValue(selected!);

    final maxViewportHeight = maxHeight ?? media.height * 0.45;
    final scrollable =
        layout.scrollable || layout.contentHeight > maxViewportHeight;

    final width = tightLayout
        ? math.min(
            layout.contentWidth,
            maxWidth ?? layout.contentWidth,
          )
        : layout.width;
    final height = scrollable
        ? (tightLayout
            ? maxViewportHeight
            : layout.height)
        : (tightLayout ? layout.contentHeight : layout.height);

    final grid = GridView.builder(
      padding: EdgeInsets.zero,
      shrinkWrap: !scrollable,
      physics: scrollable
          ? const ClampingScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: layout.columns,
        mainAxisSpacing: _paletteSpacing,
        crossAxisSpacing: _paletteSpacing,
        childAspectRatio: 1,
      ),
      itemCount: palette.length,
      itemBuilder: (context, index) {
        final colorValue = palette[index];
        final normalized = normalizeColorValue(colorValue);
        return Center(
          child: _ColorSwatch(
            colorValue: colorValue,
            selected: normalized == normalizedSelected,
            used: usedColors.map(normalizeColorValue).contains(normalized),
            radius: _swatchVisualRadius(swatchRadius),
            onTap: () => onSelected(normalized),
          ),
        );
      },
    );

    return SizedBox(
      width: width,
      height: height,
      child: ClipRect(child: grid),
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
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final Set<int> usedColors;
  final double? maxWidth;
  final double? maxHeight;

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        ColorPaletteGrid(
          palette: palette,
          selected: _selected,
          onSelected: _select,
          usedColors: widget.usedColors,
          maxWidth: widget.maxWidth,
          maxHeight: widget.maxHeight,
        ),
      ],
    );
  }
}

const _palettePickDialogHeightScale = 1.17;

Future<int?> pickColorFromPalette(
  BuildContext context, {
  required List<int> palette,
  int? current,
  Set<int> usedColors = const {},
  String title = 'Choose color',
}) async {
  if (palette.isEmpty) return current;

  return showDialog<int>(
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

class _PalettePickDialogState extends State<_PalettePickDialog> {
  late int _picked;

  @override
  void initState() {
    super.initState();
    _picked = widget.initial == null
        ? normalizeColorValue(widget.palette.first)
        : normalizeColorValue(widget.initial!);
    if (!_paletteContains(widget.palette, _picked)) {
      _picked = normalizeColorValue(widget.palette.first);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      },
      child: Actions(
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
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
            child: ColorPaletteGrid(
              palette: widget.palette,
              selected: _picked,
              usedColors: widget.usedColors,
              onSelected: (color) => setState(() => _picked = color),
              swatchRadius: 22,
              maxWidth: 520,
              maxHeight:
                  paletteViewportHeight(22, visibleRows: 3) *
                  _palettePickDialogHeightScale,
              tightLayout: true,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, _picked),
              child: const Text('Save'),
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
    final ringColor = theme.colorScheme.onSurface.withValues(alpha: 0.28);
    final usedRingColor = theme.colorScheme.onSurface.withValues(alpha: 0.65);
    final diameter = radius * 2;

    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Color(colorValue),
          border: selected
              ? Border.all(color: ringColor, width: 2.5)
              : used
              ? Border.all(color: usedRingColor, width: 2.5)
              : null,
        ),
      ),
    );
  }
}
