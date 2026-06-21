import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// Flag anchored to the top-right corner of a text field.
class JournalTitleCornerFlag extends StatelessWidget {
  const JournalTitleCornerFlag({
    super.key,
    required this.colorValue,
    required this.onSelected,
    required this.menuEntries,
    this.size = 22,
  });

  final int colorValue;
  final ValueChanged<String> onSelected;
  final List<PopupMenuEntry<String>> Function(BuildContext context) menuEntries;
  final double size;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Move to journal',
      padding: EdgeInsets.zero,
      splashRadius: 0,
      borderRadius: BorderRadius.zero,
      offset: Offset.zero,
      style: const ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: WidgetStatePropertyAll(Size.zero),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        overlayColor: WidgetStatePropertyAll(Colors.transparent),
      ),
      itemBuilder: menuEntries,
      onSelected: onSelected,
      child: JournalBookmarkFlag(
        colorValue: colorValue,
        size: size,
        snapToTopEdge: true,
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
    final color = Color(colorValue);
    final icon = Icon(PhosphorIconsFill.bookmarkSimple, size: size);
    final shaded = ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color, color.withValues(alpha: 0.5)],
      ).createShader(rect),
      child: icon,
    );

    if (!snapToTopEdge) {
      return SizedBox(width: size, height: size, child: shaded);
    }

    // Phosphor glyphs sit slightly below the icon box top; nudge up to meet
    // the input border.
    return SizedBox(
      width: size,
      height: size,
      child: ClipRect(
        child: Transform.translate(
          offset: const Offset(0, -2.5),
          child: Align(
            alignment: Alignment.topCenter,
            child: shaded,
          ),
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
        color: Color(colorValue),
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
