import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/scope_switcher.dart';

/// Flag anchored to the top-right corner of a text field.
///
/// Opens the same popover and rows as [ScopeSwitcher], so moving an item
/// looks identical to switching which scope the page shows.
class JournalTitleCornerFlag extends StatelessWidget {
  const JournalTitleCornerFlag({
    super.key,
    required this.colorValue,
    required this.items,
    required this.selectedValue,
    required this.onSelected,
    this.size = 22,
    this.tooltip = 'Move to journal',
  });

  final int colorValue;
  final List<ScopeSwitcherItem<String>> items;
  final String selectedValue;
  final ValueChanged<String> onSelected;
  final double size;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Builder(
        builder: (buttonContext) => MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showContextualPopover<void>(
              context: context,
              buttonContext: buttonContext,
              // ScopeSwitcher's default popover width.
              width: 260,
              builder: (popoverContext) => ScopeMenu<String>(
                items: items,
                selectedValue: selectedValue,
                onSelected: (value) {
                  Navigator.of(popoverContext).pop();
                  onSelected(value);
                },
                appAccent: Theme.of(context).colorScheme.primary,
              ),
            ),
            child: JournalBookmarkFlag(
              colorValue: colorValue,
              size: size,
              snapToTopEdge: true,
            ),
          ),
        ),
      ),
    );
  }
}

/// Filled bookmark marker used to show the journal color.
class JournalBookmarkFlag extends StatelessWidget {
  const JournalBookmarkFlag({
    super.key,
    required this.colorValue,
    this.size = 22,
    this.snapToTopEdge = false,
  });

  final int colorValue;
  final double size;
  final bool snapToTopEdge;

  @override
  Widget build(BuildContext context) {
    final color = paletteColor(colorValue, context);
    final shaded = Icon(
      PhosphorIconsFill.bookmarkSimple,
      size: size,
      color: color,
    );

    if (!snapToTopEdge) {
      return SizedBox(width: size, height: size, child: shaded);
    }

    // Phosphor glyphs sit slightly below the icon box top; nudge up to meet
    // the input border (and fully cover it, not just approach it).
    return SizedBox(
      width: size,
      height: size,
      child: ClipRect(
        child: Transform.translate(
          offset: const Offset(0, -4.5),
          child: Align(alignment: Alignment.topCenter, child: shaded),
        ),
      ),
    );
  }
}

/// Small triangle gradient flag indicating a journal/list color.
class ColorCornerFlag extends StatelessWidget {
  const ColorCornerFlag({
    super.key,
    required this.colorValue,
    this.size = 14,
    this.richColor = false,
  });

  final int colorValue;
  final double size;
  final bool richColor;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _CornerFlagPainter(
        color: paletteColor(colorValue, context),
        richColor: richColor,
      ),
    );
  }
}

class _CornerFlagPainter extends CustomPainter {
  const _CornerFlagPainter({required this.color, this.richColor = false});

  final Color color;
  final bool richColor;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, 0)
      ..close();

    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final paint = Paint()
      ..shader = richColor
          ? LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [Color.lerp(color, Colors.white, 0.5)!, color],
              stops: const [0.0, 0.32],
            ).createShader(rect)
          : LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [Colors.white.withValues(alpha: 0.95), color],
            ).createShader(rect);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerFlagPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.richColor != richColor;
}
