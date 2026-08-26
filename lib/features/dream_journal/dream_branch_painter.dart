import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A low-opacity, procedurally-painted watercolor cherry blossom branch
/// sweeping in from the top-right corner — this page's distinct visual
/// accent on top of the app-wide paper texture and falling petals.
///
/// Painted with plain shapes (no image asset) to match how the rest of the
/// background — [PaperTexture], [PetalField] — is already procedurally drawn
/// rather than sourced from bitmaps.
class DreamBranchOverlay extends StatelessWidget {
  const DreamBranchOverlay({
    super.key,
    required this.color,
    this.minorColors = const [],
  });

  final Color color;
  final List<Color> minorColors;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      // The branch is static once painted, but it sits under the whole page
      // in a Stack — without this boundary it repaints with every autosave
      // setState and every frame of a split-pane drag.
      child: RepaintBoundary(
        child: Opacity(
          opacity: 0.14,
          child: CustomPaint(
            painter: _DreamBranchPainter(
              color: color,
              minorColors: minorColors,
            ),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _DreamBranchPainter extends CustomPainter {
  _DreamBranchPainter({required this.color, required this.minorColors});

  final Color color;
  final List<Color> minorColors;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final branchPaint = Paint()
      ..color = const Color(0xFF6B4A3A).withValues(alpha: 0.55)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path()..moveTo(size.width + 30, -20);
    final p1 = Offset(size.width - 60, size.height * 0.10);
    final p2 = Offset(size.width - 190, size.height * 0.26);
    path
      ..quadraticBezierTo(size.width - 10, size.height * 0.04, p1.dx, p1.dy)
      ..quadraticBezierTo(size.width - 120, size.height * 0.18, p2.dx, p2.dy);
    canvas.drawPath(path, branchPaint);

    final twigPaint = Paint()
      ..color = branchPaint.color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final twigEnd1 = Offset(size.width - 150, size.height * 0.03);
    canvas.drawLine(Offset(size.width - 90, size.height * 0.15), twigEnd1, twigPaint);
    final twigEnd2 = Offset(size.width - 240, size.height * 0.34);
    canvas.drawLine(p2, twigEnd2, twigPaint);

    // Fixed seed so the branch shape is stable across rebuilds instead of
    // reshuffling every repaint.
    final rand = math.Random(7);
    for (final center in [
      Offset(size.width - 40, size.height * 0.03),
      Offset(size.width - 90, size.height * 0.09),
      p1,
      Offset(size.width - 130, size.height * 0.14),
      p2,
      Offset(size.width - 200, size.height * 0.29),
      twigEnd1,
      twigEnd2,
    ]) {
      _paintBlossomCluster(canvas, center, rand);
    }
  }

  void _paintBlossomCluster(Canvas canvas, Offset center, math.Random rand) {
    final petalCount = 4 + rand.nextInt(3);
    for (var i = 0; i < petalCount; i++) {
      final angle = rand.nextDouble() * math.pi * 2;
      final dist = rand.nextDouble() * 14;
      final radius = 6.0 + rand.nextDouble() * 6;
      final useMinor = minorColors.isNotEmpty && rand.nextBool();
      final petalColor = useMinor
          ? minorColors[rand.nextInt(minorColors.length)]
          : color;
      final paint = Paint()..color = petalColor.withValues(alpha: 0.6);
      canvas.drawCircle(
        center + Offset(math.cos(angle) * dist, math.sin(angle) * dist),
        radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DreamBranchPainter oldDelegate) {
    // `minorColors` is rebuilt from settings on every page build, so `!=` on
    // the List — an identity comparison in Dart — was true every time and
    // defeated this guard entirely.
    return oldDelegate.color != color ||
        !listEquals(oldDelegate.minorColors, minorColors);
  }
}
