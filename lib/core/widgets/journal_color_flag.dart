import 'package:flutter/material.dart';

/// Small triangle gradient flag indicating a journal/list color.
class ColorCornerFlag extends StatelessWidget {
  const ColorCornerFlag({super.key, required this.colorValue, this.size = 14});

  final int colorValue;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _CornerFlagPainter(color: Color(colorValue)),
    );
  }
}

class _CornerFlagPainter extends CustomPainter {
  const _CornerFlagPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, 0)
      ..close();

    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [Colors.white.withValues(alpha: 0.95), color],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerFlagPainter oldDelegate) =>
      oldDelegate.color != color;
}
