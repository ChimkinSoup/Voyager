import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

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
    this.morphs = false,
  });

  final int level;
  final Color color;
  final bool lit;

  /// Eases from one [level] into the next, its rings tracing themselves in
  /// or out, rather than switching straight to it.
  final bool morphs;

  @override
  State<GaiaTierGlyph> createState() => _GaiaTierGlyphState();
}

/// How far each level's rings have turned, shared by every glyph of that
/// level, so one handed over to another (the notch's selection moving
/// between its row and its trigger) carries on rather than jumping.
final _turned = <int, ({double phase, Duration at})>{};

/// How far [level]'s rings have turned, for drawing them in step elsewhere.
double gaiaTierGlyphPhase(int level) => _turned[level]?.phase ?? 0;

/// A glyph's side, in logical pixels.
const kGaiaTierGlyphSize = 14.0;

/// The middle dot's radius at [level].
double gaiaTierDotRadius(int level) => level == 0 ? 2.4 : 1.7;

/// The rings, inner first: inner one way, outer the other and slower.
const kGaiaTierRings = [(radius: 4.0, speed: 1.4), (radius: 6.4, speed: -0.8)];

/// How much of its circle a ring covers, the rest its gap.
const kGaiaTierRingSweep = 2 * math.pi * 0.78;

const kGaiaTierRingStroke = 1.1;

/// Where a [ring] starts, after the level has turned by [phase].
double gaiaTierRingStart(({double radius, double speed}) ring, double phase) =>
    phase * ring.speed + (ring.speed < 0 ? math.pi : 0);

/// A ring's opacity [t] of the way along its sweep: it fades towards its tail.
double gaiaTierRingAlpha(({double radius, double speed}) ring, double t) =>
    ring.speed > 0 ? 0.15 + 0.85 * t : 1 - 0.85 * t;

class _GaiaTierGlyphState extends State<GaiaTierGlyph>
    with TickerProviderStateMixin {
  final _phase = ValueNotifier(0.0);
  late final Ticker _ticker;

  late final _lit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: widget.lit ? 1 : 0,
  );

  /// From the glyph as it showed when [GaiaTierGlyph.level] last changed
  /// ([_fromDot], [_fromRings]) into the level's own.
  late final _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
    value: 1,
  );
  var _fromDot = 0.0;
  List<_Ring> _fromRings = const [];

  /// What shows of the glyph at [level], [_morph] of the way in.
  _Shape _shape(int level) {
    final t = Curves.easeInOutCubic.transform(_morph.value);
    return (
      dot: lerpDouble(_fromDot, gaiaTierDotRadius(level), t)!,
      rings: [
        for (var i = 0; i < kGaiaTierRings.length; i++)
          if (i < _fromRings.length ? _fromRings[i] : null case final from?
              when from.shown > 0)
            (
              // Kept rings turn the short way round to where the level's
              // are; leaving ones stay where they were.
              start: i >= level
                  ? from.start
                  : from.start +
                        ((_start(i) - from.start + math.pi) % (2 * math.pi) -
                                math.pi) *
                            t,
              shown: lerpDouble(from.shown, i < level ? 1 : 0, t)!,
            )
          else
            (start: _start(i), shown: i < level ? t : 0),
      ],
    );
  }

  double _start(int ring) =>
      gaiaTierRingStart(kGaiaTierRings[ring], _phase.value);

  @override
  void initState() {
    super.initState();
    _phase.value = _turned[widget.level]?.phase ?? 0;
    _ticker = createTicker(_tick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final run =
        GaiaAmbient.of(context) &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
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
    if (widget.level != old.level) {
      if (widget.morphs && !MediaQuery.disableAnimationsOf(context)) {
        final shown = _shape(old.level);
        _fromDot = shown.dot;
        _fromRings = shown.rings;
        _morph.forward(from: 0);
      }
      // The new level's rings, from where they last turned.
      _phase.value = _turned[widget.level]?.phase ?? 0;
      _resumed = true;
    }
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
    _morph.dispose();
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
      size: const Size.square(kGaiaTierGlyphSize),
      painter: _OrbitPainter(
        level: widget.level,
        color: widget.color,
        shape: () => _shape(widget.level),
        repaint: Listenable.merge([_phase, _morph]),
        lit: _lit,
      ),
    );
  }
}

/// A ring's [start] angle, and how much of its sweep is [shown].
typedef _Ring = ({double start, double shown});

/// A glyph partway between levels: its middle [dot]'s radius, and each of
/// [kGaiaTierRings] in turn.
typedef _Shape = ({double dot, List<_Ring> rings});

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({
    required this.level,
    required this.color,
    required this.shape,
    required Listenable repaint,
    required this.lit,
  }) : super(repaint: Listenable.merge([repaint, lit]));

  final int level;
  final Color color;
  final _Shape Function() shape;
  final Animation<double> lit;

  @override
  void paint(Canvas canvas, Size size) {
    final (:dot, :rings) = shape();
    _paintGlyph(
      canvas,
      size.center(Offset.zero),
      dot: dot,
      rings: rings,
      color: color,
      lit: Curves.easeOut.transform(lit.value),
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter old) =>
      old.level != level || old.color != color;
}

/// The same mark used during an orb's handoff and by the model selector.
void paintGaiaTierGlyph(
  Canvas canvas,
  Offset centre, {
  required int level,
  required Color color,
  required double phase,
  double lit = 0,
  double scale = 1,
}) => _paintGlyph(
  canvas,
  centre,
  dot: gaiaTierDotRadius(level),
  rings: [
    for (final ring in kGaiaTierRings.take(level))
      (start: gaiaTierRingStart(ring, phase), shown: 1),
  ],
  color: color,
  lit: lit,
  scale: scale,
);

void _paintGlyph(
  Canvas canvas,
  Offset centre, {
  required double dot,
  required List<_Ring> rings,
  required Color color,
  required double lit,
  double scale = 1,
}) {
  // The rings spread a little when lit.
  final spread = scale * (1 + 0.1 * lit);
  canvas.drawCircle(
    centre,
    dot * scale * (1 + 0.15 * lit),
    Paint()..color = color,
  );
  for (var i = 0; i < rings.length; i++) {
    final (:start, :shown) = rings[i];
    if (shown <= 0) continue;
    final ring = kGaiaTierRings[i];
    final radius = ring.radius * spread;
    // A ring with a gap, fading towards its tail like the light round
    // Gaia's buttons. Partly shown, it's traced only so far, and faint.
    final sweep = kGaiaTierRingSweep * shown;
    final tint = color.withValues(alpha: color.a * shown);
    final rect = Rect.fromCircle(center: centre, radius: radius);
    final forward = ring.speed > 0;
    // Drawn from halfway into the gap, so the gradient's seam at angle 0
    // sits in the gap and each round cap clamps to its own end's colour.
    final lead = (2 * math.pi - sweep) / 2;
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(start - lead);
    canvas.translate(-centre.dx, -centre.dy);
    canvas.drawArc(
      rect,
      lead,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = kGaiaTierRingStroke * scale
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          center: Alignment.center,
          startAngle: lead,
          endAngle: lead + sweep,
          colors: forward
              ? [tint.withValues(alpha: tint.a * 0.15), tint]
              : [tint, tint.withValues(alpha: tint.a * 0.15)],
        ).createShader(rect),
    );
    canvas.restore();
  }
}
