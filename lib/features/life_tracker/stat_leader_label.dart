import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/features/life_tracker/life_tracker_stats.dart';
import 'package:voyager/features/life_tracker/weeping_cherry_canvas.dart';

/// One statistic, as a point in the blossom joined by a leader line to a
/// label parked in a column at the side of the page. Slots are assigned up
/// front (see [lifeStatBlossoms]) rather than derived at layout time, so
/// labels can never collide with each other.
class BlossomSpec {
  const BlossomSpec({
    required this.position,
    required this.labelX,
    required this.labelY,
    required this.onLeft,
    required this.stat,
  });

  /// Where in the blossom the leader line starts, in the weeping cherry's
  /// tree space — see [weepingCanvasPoint].
  final Offset position;

  /// The label's inner edge — its right edge when [onLeft], left edge
  /// otherwise — as a fraction of the page's width. A narrow page pushes it
  /// further out; see [leaderLabelLayout].
  final double labelX;

  /// The label's middle, in the weeping cherry's tree space.
  final double labelY;

  final bool onLeft;
  final LifeStat stat;
}

/// The labels sit over the curtain's outer edges, the tree being drawn full
/// size; each leader runs inward to a point in the thick of the blossom.
/// Tasks and Full Moons sit up top, above the crown.
const lifeStatBlossoms = [
  BlossomSpec(
    position: Offset(-0.35, 0.12),
    labelX: 0.192,
    labelY: 0.065,
    onLeft: true,
    stat: LifeStat.weeksRemaining,
  ),
  BlossomSpec(
    position: Offset(-0.40, 0.30),
    labelX: 0.192,
    labelY: 0.277,
    onLeft: true,
    stat: LifeStat.heartbeats,
  ),
  BlossomSpec(
    position: Offset(-0.45, 0.52),
    labelX: 0.192,
    labelY: 0.488,
    onLeft: true,
    stat: LifeStat.sleepTime,
  ),
  BlossomSpec(
    position: Offset(-0.12, 0.09),
    labelX: 0.192,
    labelY: -0.123,
    onLeft: true,
    stat: LifeStat.tasksConquered,
  ),
  BlossomSpec(
    position: Offset(0.35, 0.12),
    labelX: 0.808,
    labelY: 0.105,
    onLeft: false,
    stat: LifeStat.lifetimeMood,
  ),
  BlossomSpec(
    position: Offset(0.40, 0.36),
    labelX: 0.808,
    labelY: 0.344,
    onLeft: false,
    stat: LifeStat.kmTraveled,
  ),
  BlossomSpec(
    position: Offset(0.15, 0.07),
    labelX: 0.808,
    labelY: -0.123,
    onLeft: false,
    stat: LifeStat.fullMoons,
  ),
];

/// The short level run a leader leaves its label by, as a fraction of the
/// page's width.
const _elbowRun = 0.016;

/// Where each of [blossoms]' labels meets its leader on a page of [size], and
/// whether the leaders are drawn.
///
/// The tree fills the width of a narrow page, so a label kept at its
/// [BlossomSpec.labelX] would end up inside its own point and the leader
/// would double back over it. Each side's labels are pushed out past the
/// furthest point on that side instead. When that leaves too little room for
/// a label, they stay at [BlossomSpec.labelX] over the curtain without
/// leaders.
({List<Offset> anchors, bool leaders}) leaderLabelLayout(
  List<BlossomSpec> blossoms,
  Size size,
) {
  const minRoom = 120.0;
  // Past the elbow's run as well, so the leader still turns in for its point.
  final clearance = size.width * _elbowRun + 16;
  var leftEdge = double.infinity;
  var rightEdge = double.negativeInfinity;
  for (final blossom in blossoms) {
    final target = weepingCanvasPoint(blossom.position, size);
    if (blossom.onLeft) {
      leftEdge = math.min(leftEdge, target.dx - clearance);
    } else {
      rightEdge = math.max(rightEdge, target.dx + clearance);
    }
  }
  double pushed(BlossomSpec blossom) => blossom.onLeft
      ? math.min(blossom.labelX * size.width, leftEdge)
      : math.max(blossom.labelX * size.width, rightEdge);
  final leaders = blossoms.every(
    (blossom) =>
        (blossom.onLeft ? pushed(blossom) : size.width - pushed(blossom)) - 8 >=
        minRoom,
  );
  return (
    anchors: [
      for (final blossom in blossoms)
        Offset(
          leaders ? pushed(blossom) : blossom.labelX * size.width,
          weepingCanvasPoint(Offset(0, blossom.labelY), size).dy,
        ),
    ],
    leaders: leaders,
  );
}

/// Typeface for the annotations. The reference sets its callouts in a plain
/// monospace against the painting, and the contrast between the drafted label
/// and the wet brushwork is most of why they read as annotations on a study
/// rather than as chrome bolted onto a picture.
const _monoFamily = 'Consolas';
const _monoFallback = <String>[
  'Menlo',
  'DejaVu Sans Mono',
  'Courier New',
  'monospace',
];

/// One statistic, annotated in the margin: a bracketed name, its value under
/// it, and a dashed leader running back to the point in the canopy it
/// describes. Clicking anywhere in the label opens the stat popup.
class StatLeaderLabel extends StatefulWidget {
  const StatLeaderLabel({
    super.key,
    required this.name,
    required this.value,
    this.valueIsProse = false,
    required this.onLeft,
    required this.inkColor,
    required this.accentColor,
    required this.haloColor,
    required this.onTap,
    required this.onHoverChanged,
  });

  final String name;
  final String value;

  /// A sentence in place of a figure ("Set your birth date in Settings"),
  /// which wraps; a figure is kept on one line and shrunk to fit instead.
  final bool valueIsProse;
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
    // Tight layers first, so the glyph edges sit on solid paper rather than
    // a faint bloom the blossom shows through.
    final halo = <Shadow>[
      Shadow(color: widget.haloColor, blurRadius: 1.5),
      Shadow(color: widget.haloColor, blurRadius: 3),
      Shadow(color: widget.haloColor, blurRadius: 6),
      Shadow(color: widget.haloColor, blurRadius: 12),
    ];

    final value = Text(
      widget.value,
      textAlign: widget.onLeft ? TextAlign.right : TextAlign.left,
      style: TextStyle(
        fontFamily: _monoFamily,
        fontFamilyFallback: _monoFallback,
        fontSize: 13,
        height: 1.3,
        letterSpacing: 0.2,
        fontWeight: FontWeight.w600,
        color: tone,
        shadows: halo,
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: widget.onLeft
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '[ ${widget.name.toUpperCase()} ]',
              textAlign: widget.onLeft ? TextAlign.right : TextAlign.left,
              style: TextStyle(
                fontFamily: _monoFamily,
                fontFamilyFallback: _monoFallback,
                fontSize: 11,
                height: 1.35,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w600,
                color: tone.withValues(alpha: _hovered ? 1.0 : 0.88),
                shadows: halo,
              ),
            ),
            if (widget.valueIsProse)
              value
            else
              // Kept on one line and shrunk if the label is too narrow for
              // it: a number broken across lines (or cut at the edge)
              // misreads.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: widget.onLeft
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: value,
              ),
          ],
        ),
      ),
    );
  }
}

/// The dashed leaders joining every label to its point in the blossom, plus the
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
    final layout = leaderLabelLayout(blossoms, size);
    if (!layout.leaders) return;
    for (var i = 0; i < blossoms.length; i++) {
      final blossom = blossoms[i];
      final active = i == highlighted;
      final tone = active ? accentColor : inkColor;

      final label = layout.anchors[i];
      final target = weepingCanvasPoint(blossom.position, size);
      // A short horizontal run out of the label before the line turns for the
      // blossom, so it leaves the text squarely instead of at a random angle.
      final elbow = Offset(
        label.dx + (blossom.onLeft ? 1 : -1) * size.width * _elbowRun,
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
