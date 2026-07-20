import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A progress ring drawn as discrete arc segments rather than one continuous
/// stroke, matching the app's geometric visual language. Segments fill
/// clockwise from the top; the segment straddling the progress boundary is
/// blended proportionally so movement still reads smoothly.
class GeometricProgressRing extends StatelessWidget {
  const GeometricProgressRing({
    super.key,
    required this.progress,
    required this.color,
    this.size = 120,
    this.segments = 28,
    this.strokeWidth = 8,
    this.child,
  });

  /// 0..1. Values outside the range are clamped by the painter.
  final double progress;
  final Color color;
  final double size;
  final int segments;
  final double strokeWidth;

  /// Centered content (typically the percentage label).
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          progress: progress,
          color: color,
          trackColor: theme.colorScheme.onSurface.withValues(alpha: 0.10),
          segments: segments,
          strokeWidth: strokeWidth,
        ),
        child: child == null ? null : Center(child: child),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
    required this.segments,
    required this.strokeWidth,
  });

  final double progress;
  final Color color;
  final Color trackColor;
  final int segments;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (segments <= 0) return;

    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    if (radius <= 0) return;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: radius,
    );

    final clamped = progress.isNaN ? 0.0 : progress.clamp(0.0, 1.0);
    final segmentAngle = (2 * math.pi) / segments;
    // Gap scales with segment count so dense rings don't close up.
    final gap = segmentAngle * 0.22;
    final sweep = segmentAngle - gap;
    const start = -math.pi / 2;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;

    for (var i = 0; i < segments; i++) {
      final fill = (clamped * segments - i).clamp(0.0, 1.0);
      paint.color =
          fill <= 0 ? trackColor : Color.lerp(trackColor, color, fill)!;
      canvas.drawArc(
        rect,
        start + i * segmentAngle + gap / 2,
        sweep,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.segments != segments ||
      old.strokeWidth != strokeWidth;
}
