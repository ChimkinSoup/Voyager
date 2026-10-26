import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';

/// A small mark for one of Gaia's tiers, [level] 0 (quick) to 2 (deep), told
/// apart by its shape rather than its colour: a dot in no, one or two rings,
/// their gaps turning. [lit] (hovered or selected) spreads the rings and
/// spins them faster.
class GaiaTierGlyph extends StatefulWidget {
  const GaiaTierGlyph({
    super.key,
    required this.level,
    required this.color,
    this.lit = false,
  });

  final int level;
  final Color color;
  final bool lit;

  @override
  State<GaiaTierGlyph> createState() => _GaiaTierGlyphState();
}

/// How far each level's rings have turned, shared by every glyph of that
/// level, so one handed over to another (the notch's selection moving
/// between its row and its trigger) carries on rather than jumping.
final _turned = <int, ({double phase, Duration at})>{};

class _GaiaTierGlyphState extends State<GaiaTierGlyph>
    with TickerProviderStateMixin {
  final _phase = ValueNotifier(0.0);
  late final Ticker _ticker;

  late final _lit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: widget.lit ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    _phase.value = _turned[widget.level]?.phase ?? 0;
    _ticker = createTicker(_tick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final run = GaiaAmbient.of(context);
    if (run == _ticker.isActive) return;
    if (run) {
      _resumed = true;
      _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  /// Set by a start: the level's last turn may be from before a pause, and
  /// turning it on by the whole pause would jump.
  var _resumed = false;

  @override
  void didUpdateWidget(GaiaTierGlyph old) {
    super.didUpdateWidget(old);
    if (widget.lit == old.lit) return;
    if (widget.lit) {
      _lit.forward();
    } else {
      _lit.reverse();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _lit.dispose();
    _phase.dispose();
    super.dispose();
  }

  void _tick(Duration _) {
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    final turned = _turned[widget.level];
    // The first glyph of the level to tick this frame turns it.
    if (turned == null || turned.at != now) {
      final dt = turned == null || _resumed
          ? 0
          : (now - turned.at).inMicroseconds / 1e6;
      final speed = 1 + 2 * Curves.easeOut.transform(_lit.value);
      _turned[widget.level] = (
        phase: (turned?.phase ?? 0) + dt * speed,
        at: now,
      );
    }
    _resumed = false;
    _phase.value = _turned[widget.level]!.phase;
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(14),
      painter: _OrbitPainter(
        level: widget.level,
        color: widget.color,
        phase: _phase,
        lit: _lit,
      ),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({
    required this.level,
    required this.color,
    required this.phase,
    required this.lit,
  }) : super(repaint: Listenable.merge([phase, lit]));

  final int level;
  final Color color;
  final ValueListenable<double> phase;
  final Animation<double> lit;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final lit = Curves.easeOut.transform(this.lit.value);
    // The rings spread a little when lit.
    final spread = 1 + 0.1 * lit;
    canvas.drawCircle(
      centre,
      (level == 0 ? 2.4 : 1.7) * (1 + 0.15 * lit),
      Paint()..color = color,
    );
    // Inner one way, outer the other and slower.
    const rings = [(radius: 4.0, speed: 1.4), (radius: 6.4, speed: -0.8)];
    for (final ring in rings.take(level)) {
      final radius = ring.radius * spread;
      final start = phase.value * ring.speed + (ring.speed < 0 ? math.pi : 0);
      // A ring with a gap, fading towards its tail like the light round
      // Gaia's buttons.
      const sweep = 2 * math.pi * 0.78;
      final rect = Rect.fromCircle(center: centre, radius: radius);
      final forward = ring.speed > 0;
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate(start);
      canvas.translate(-centre.dx, -centre.dy);
      canvas.drawArc(
        rect,
        0,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(
            center: Alignment.center,
            endAngle: sweep,
            colors: forward
                ? [color.withValues(alpha: 0.15), color]
                : [color, color.withValues(alpha: 0.15)],
          ).createShader(rect),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_OrbitPainter old) =>
      old.level != level || old.color != color;
}
