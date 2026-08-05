import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';

/// Typeface for the annotations. The reference sets its callouts in a plain
/// monospace against the painting, and the contrast between the drafted label
/// and the wet brushwork is most of why they read as annotations on a study
/// rather than as chrome bolted onto a picture.
const _monoFamily = 'Consolas';
const _monoFallback = <String>['Menlo', 'DejaVu Sans Mono', 'Courier New', 'monospace'];

/// One statistic, annotated in the margin: a bracketed name, its value under
/// it, and a dashed leader running back to the point in the canopy it
/// describes. Clicking anywhere in the label opens the stat popup.
class StatLeaderLabel extends StatefulWidget {
  const StatLeaderLabel({
    super.key,
    required this.name,
    required this.value,
    required this.onLeft,
    required this.inkColor,
    required this.accentColor,
    required this.haloColor,
    required this.onTap,
    required this.onHoverChanged,
  });

  final String name;
  final String value;
  final bool onLeft;
  final Color inkColor;
  final Color accentColor;

  /// The paper. Bled out behind the glyphs so the label stays readable where
  /// it crosses the canopy, which the two outer columns always do.
  final Color haloColor;
  final VoidCallback onTap;
  final ValueChanged<bool> onHoverChanged;

  @override
  State<StatLeaderLabel> createState() => _StatLeaderLabelState();
}

class _StatLeaderLabelState extends State<StatLeaderLabel> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
    widget.onHoverChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final tone = _hovered ? widget.accentColor : widget.inkColor;
    final halo = <Shadow>[
      Shadow(color: widget.haloColor, blurRadius: 5),
      Shadow(color: widget.haloColor, blurRadius: 10),
    ];

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment:
              widget.onLeft ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '[ ${widget.name.toUpperCase()} ]',
              textAlign: widget.onLeft ? TextAlign.right : TextAlign.left,
              style: TextStyle(
                fontFamily: _monoFamily,
                fontFamilyFallback: _monoFallback,
                fontSize: 10.5,
                height: 1.35,
                letterSpacing: 1.1,
                color: tone.withValues(alpha: _hovered ? 0.95 : 0.62),
                shadows: halo,
              ),
            ),
            Text(
              widget.value,
              textAlign: widget.onLeft ? TextAlign.right : TextAlign.left,
              style: TextStyle(
                fontFamily: _monoFamily,
                fontFamilyFallback: _monoFallback,
                fontSize: 12.5,
                height: 1.3,
                letterSpacing: 0.2,
                color: tone.withValues(alpha: _hovered ? 1.0 : 0.82),
                shadows: halo,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The dashed leaders joining every label to its point in the canopy, plus the
/// small dot each one lands on. Drawn as one painter under the labels rather
/// than one per label, since each line spans an arbitrary slice of the canvas
/// and a per-label widget would need a box big enough to contain it.
class LeaderLinePainter extends CustomPainter {
  LeaderLinePainter({
    required this.blossoms,
    required this.inkColor,
    required this.accentColor,
    required this.highlighted,
  });

  final List<BlossomSpec> blossoms;
  final Color inkColor;
  final Color accentColor;

  /// Index of the label currently hovered, or -1.
  final int highlighted;

  static const _dashOn = 2.6;
  static const _dashOff = 3.4;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < blossoms.length; i++) {
      final blossom = blossoms[i];
      final active = i == highlighted;
      final tone = active ? accentColor : inkColor;

      final label = Offset(
        blossom.labelAnchor.dx * size.width,
        blossom.labelAnchor.dy * size.height,
      );
      final target = Offset(
        blossom.position.dx * size.width,
        blossom.position.dy * size.height,
      );
      // A short horizontal run out of the label before the line turns for the
      // canopy, so it leaves the text squarely instead of at a random angle.
      final elbow = Offset(
        label.dx + (blossom.onLeft ? 1 : -1) * size.width * 0.016,
        label.dy,
      );

      final paint = Paint()
        ..color = tone.withValues(alpha: active ? 0.75 : 0.38)
        ..strokeWidth = active ? 1.2 : 1.0
        ..style = PaintingStyle.stroke;

      _dashed(canvas, label, elbow, paint);
      _dashed(canvas, elbow, target, paint);

      canvas.drawCircle(
        target,
        active ? 3.4 : 2.4,
        Paint()..color = tone.withValues(alpha: active ? 0.9 : 0.55),
      );
    }
  }

  void _dashed(Canvas canvas, Offset from, Offset to, Paint paint) {
    final delta = to - from;
    final length = delta.distance;
    if (length <= 0) return;
    final step = Offset(delta.dx / length, delta.dy / length);
    var travelled = 0.0;
    while (travelled < length) {
      final end = math.min(travelled + _dashOn, length);
      canvas.drawLine(from + step * travelled, from + step * end, paint);
      travelled = end + _dashOff;
    }
  }

  @override
  bool shouldRepaint(covariant LeaderLinePainter oldDelegate) {
    return oldDelegate.highlighted != highlighted ||
        oldDelegate.inkColor != inkColor ||
        oldDelegate.accentColor != accentColor ||
        !identical(oldDelegate.blossoms, blossoms);
  }
}
