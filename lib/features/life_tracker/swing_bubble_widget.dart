import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The rope swing hanging off the tree's lower-right branch, with an
/// ethereal bubble resting on its seat. The whole assembly swings gently as
/// a pendulum from the branch attachment point; the bubble underneath opens
/// the bucket list popup.
class SwingAndBubble extends StatefulWidget {
  const SwingAndBubble({
    super.key,
    this.ropeLength = 130,
    this.plankWidth = 74,
    this.accentColor = const Color(0xFF9FD8FF),
    required this.onBubbleTap,
  });

  final double ropeLength;
  final double plankWidth;
  final Color accentColor;
  final Future<void> Function() onBubbleTap;

  @override
  State<SwingAndBubble> createState() => _SwingAndBubbleState();
}

class _SwingAndBubbleState extends State<SwingAndBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const plankHeight = 14.0;
    final totalHeight = widget.ropeLength + plankHeight + 20;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final angle = math.sin(_controller.value * 2 * math.pi) * 0.09;
        return Transform.rotate(
          angle: angle,
          alignment: Alignment.topCenter,
          child: child,
        );
      },
      child: SizedBox(
        width: widget.plankWidth + 30,
        height: totalHeight,
        child: Stack(
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          children: [
            CustomPaint(
              size: Size(widget.plankWidth + 30, totalHeight),
              painter: _SwingPainter(
                ropeLength: widget.ropeLength,
                plankWidth: widget.plankWidth,
                plankHeight: plankHeight,
              ),
            ),
            Positioned(
              top: widget.ropeLength - 20,
              child: _Bubble(color: widget.accentColor, onTap: widget.onBubbleTap),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwingPainter extends CustomPainter {
  _SwingPainter({
    required this.ropeLength,
    required this.plankWidth,
    required this.plankHeight,
  });

  final double ropeLength;
  final double plankWidth;
  final double plankHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;
    const ropeGap = 20.0;
    final leftX = center - ropeGap / 2;
    final rightX = center + ropeGap / 2;
    final plankTop = ropeLength;
    final plankRect = Rect.fromLTWH(
      center - plankWidth / 2,
      plankTop,
      plankWidth,
      plankHeight,
    );

    final ropePaint = Paint()
      ..color = const Color(0xFFC9B08A)
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;

    // Ropes from the branch down through the plank's two holes.
    canvas.drawLine(Offset(center, 0), Offset(leftX, plankTop + 4), ropePaint);
    canvas.drawLine(Offset(center, 0), Offset(rightX, plankTop + 4), ropePaint);

    // Wood plank.
    final plankPaint = Paint()
      ..shader = ui.Gradient.linear(
        plankRect.topLeft,
        plankRect.bottomRight,
        [const Color(0xFF9C6B3E), const Color(0xFF7A4F2B)],
      );
    canvas.drawRRect(
      RRect.fromRectAndRadius(plankRect, const Radius.circular(3)),
      plankPaint,
    );

    // Holes the rope passes through.
    final holePaint = Paint()..color = const Color(0xFF3E2A17);
    canvas.drawCircle(Offset(leftX, plankTop + 4), 2.2, holePaint);
    canvas.drawCircle(Offset(rightX, plankTop + 4), 2.2, holePaint);

    // Rope continues below the plank and ends in a knot.
    final knotY = plankTop + plankHeight + 8;
    canvas.drawLine(Offset(leftX, plankTop + plankHeight - 2), Offset(leftX, knotY), ropePaint);
    canvas.drawLine(Offset(rightX, plankTop + plankHeight - 2), Offset(rightX, knotY), ropePaint);
    final knotPaint = Paint()..color = const Color(0xFFC9B08A);
    canvas.drawCircle(Offset(leftX, knotY), 3.2, knotPaint);
    canvas.drawCircle(Offset(rightX, knotY), 3.2, knotPaint);
  }

  @override
  bool shouldRepaint(covariant _SwingPainter oldDelegate) => false;
}

class _Bubble extends StatefulWidget {
  const _Bubble({required this.color, required this.onTap});

  final Color color;
  final Future<void> Function() onTap;

  @override
  State<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends State<_Bubble> {
  bool _hovered = false;
  bool _active = false;

  Future<void> _handleTap() async {
    setState(() => _active = true);
    await widget.onTap();
    if (mounted) setState(() => _active = false);
  }

  @override
  Widget build(BuildContext context) {
    final expanded = _hovered || _active;
    const baseSize = 30.0;
    final size = expanded ? baseSize * 1.25 : baseSize;
    final glow = expanded ? 22.0 : 10.0;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _handleTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                Colors.white.withValues(alpha: 0.85),
                widget.color.withValues(alpha: 0.55),
                widget.color.withValues(alpha: 0.15),
              ],
              stops: const [0.0, 0.6, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.55),
                blurRadius: glow,
                spreadRadius: expanded ? 3 : 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
