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
    this.gradientColors,
  });

  /// 0..1. Values outside the range are clamped by the painter.
  final double progress;
  final Color color;
  final double size;
  final int segments;
  final double strokeWidth;

  /// Centered content (typically the percentage label).
  final Widget? child;

  /// When set, each filled segment's color is sampled from a sweep gradient
  /// at that segment's angular position instead of the flat [color]. Leaves
  /// every other call site (which passes `null`) byte-for-byte unchanged.
  final List<Color>? gradientColors;

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
          gradientColors: gradientColors,
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
    this.gradientColors,
  });

  final double progress;
  final Color color;
  final Color trackColor;
  final int segments;
  final double strokeWidth;
  final List<Color>? gradientColors;

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

    final gradient = gradientColors;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;

    for (var i = 0; i < segments; i++) {
      final fill = (clamped * segments - i).clamp(0.0, 1.0);
      final segmentColor = gradient == null
          ? color
          : _sampleGradient(gradient, i / segments);
      paint.color =
          fill <= 0 ? trackColor : Color.lerp(trackColor, segmentColor, fill)!;
      canvas.drawArc(
        rect,
        start + i * segmentAngle + gap / 2,
        sweep,
        false,
        paint,
      );
    }
  }

  /// Linearly interpolates through [colors] at position [t] (0..1).
  Color _sampleGradient(List<Color> colors, double t) {
    if (colors.length == 1) return colors.first;
    final scaled = t.clamp(0.0, 1.0) * (colors.length - 1);
    final index = scaled.floor();
    if (index >= colors.length - 1) return colors.last;
    return Color.lerp(colors[index], colors[index + 1], scaled - index)!;
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.segments != segments ||
      old.strokeWidth != strokeWidth ||
      old.gradientColors != gradientColors;
}
