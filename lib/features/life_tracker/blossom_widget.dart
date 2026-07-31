import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/leaf_shapes.dart';

/// One interactive blossom overlaid on the tree canvas: enlarges and shows a
/// brief label on hover, subtly scales up and stays enlarged while its stat
/// popup is open.
class BlossomWidget extends StatefulWidget {
  const BlossomWidget({
    super.key,
    required this.size,
    required this.color,
    required this.shortLabel,
    required this.onTap,
  });

  final double size;
  final Color color;
  final String shortLabel;

  /// Opens the blossom's stat popup; the returned future should complete
  /// when the popup closes, so the blossom can stop showing as "active".
  final Future<void> Function() onTap;

  @override
  State<BlossomWidget> createState() => _BlossomWidgetState();
}

class _BlossomWidgetState extends State<BlossomWidget> {
  bool _hovered = false;
  bool _active = false;

  Future<void> _handleTap() async {
    setState(() => _active = true);
    await widget.onTap();
    if (mounted) setState(() => _active = false);
  }

  @override
  Widget build(BuildContext context) {
    final scale = _active ? 1.28 : (_hovered ? 1.16 : 1.0);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _handleTap,
        child: SizedBox(
          width: widget.size * 2.2,
          height: widget.size * 2.8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: scale,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: SizedBox(
                  width: widget.size * 2,
                  height: widget.size * 2,
                  child: CustomPaint(
                    painter: _BlossomPainter(color: widget.color),
                  ),
                ),
              ),
              AnimatedOpacity(
                opacity: _hovered || _active ? 1 : 0,
                duration: const Duration(milliseconds: 140),
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    widget.shortLabel,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BlossomPainter extends CustomPainter {
  _BlossomPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    paintLeaf(canvas, LeafDesign.sakuraBlossom, Offset.zero & size, color);
  }

  @override
  bool shouldRepaint(covariant _BlossomPainter oldDelegate) => oldDelegate.color != color;
}
