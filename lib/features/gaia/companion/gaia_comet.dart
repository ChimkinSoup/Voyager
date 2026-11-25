import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// How a comet on the sky looks, each moving in its own way.
enum GaiaCometLook {
  classic(
    'Classic',
    'A hooded head; a broad dust tail swaying slowly beside a blue ion '
        'tail, ripples running out along it.',
  ),
  streamers(
    'Streamers',
    'Fine blue ion streamers fanning from the head, waves running out '
        'along each.',
  ),
  shedding(
    'Shedding',
    'Dust grains shed from the head, drifting out along the curve of the '
        'tail and fading.',
  ),
  knots(
    'Knots',
    'Bright knots breaking away down the ion tail one after another, as '
        'the head swells and settles.',
  ),
  bands(
    'Bands',
    'A golden dust tail combed into rays, each brightening and dimming on '
        'its own.',
  ),
  jets(
    'Jets',
    'Jets of gas spiralling out of a turning nucleus into a wide hood; the '
        'tails shorter.',
  ),
  great(
    'Great',
    'Bands, Shedding and Streamers at once: a golden dust tail combed into '
        'rays, grains drifting out along it, and blue streamers waving '
        'beside it.',
  ),
  greatV2(
    'Great V2',
    'Great, its grains shed from all over the head and thinning in '
        'gently, with jets spiralling out of the nucleus.',
  ),
  greatV3(
    'Great V3',
    "Great V2's tails with the Shells and starburst head: shells rising "
        'close about the nucleus, faint spikes turning slowly.',
  );

  const GaiaCometLook(this.label, this.description);

  final String label;
  final String description;
}

/// A comet's head, to set on any look's tails, each moving in its own way.
enum GaiaCometHead {
  hood(
    'Hood and jets',
    "Great V2's own: a soft green hood, two jets spiralling out of the "
        'nucleus.',
  ),
  shells(
    'Shells',
    'A tighter hood with a bright core, shells of gas rising off the '
        'sunward side and sweeping back past it.',
  ),
  starburst(
    'Starburst',
    'A small hood about a star-bright nucleus, four fine spikes shimmering '
        'and turning slowly.',
  ),
  shellsStarburst(
    'Shells and starburst',
    "Shells, with Starburst's spikes faint about the nucleus.",
  );

  const GaiaCometHead(this.label, this.description);

  final String label;
  final String description;
}

const _dust = Color(0xFFFFEBD0);
const _gold = Color(0xFFFFD49A);
const _ion = Color(0xFF8FB6FF);
const _coma = Color(0xFFB4FFE4);

/// A comet that looks as [look] about the origin, its tails streaming along
/// +x for about [length], the dust tail curving to [bend]'s side: 1 towards
/// +y, -1 towards -y. With a [head], that head on [look]'s tails in place
/// of its own. [time], in seconds, runs its motion; [alpha] dims the whole
/// of it.
void paintGaiaComet(
  Canvas canvas,
  GaiaCometLook look, {
  required double length,
  required double bend,
  required double time,
  double alpha = 1,
  GaiaCometHead? head,
}) {
  final comet = _Comet(canvas, length, bend, time, alpha);
  // Knots' head swells every 7 s, then settles.
  final swell = pow(0.5 + 0.5 * sin(time * 2 * pi / 7), 4).toDouble();
  switch (look) {
    case GaiaCometLook.classic:
      comet
        ..dust(_dust, 0.44, length * 0.42)
        ..strand(a: 0.32, amp: 2.5);
    case GaiaCometLook.streamers:
      comet
        ..dust(_dust, 0.24, length * 0.3, reach: 0.85)
        ..streamers(0.22);
    case GaiaCometLook.shedding:
      comet
        ..dust(_dust, 0.22, length * 0.4)
        ..strand(a: 0.18, amp: 2)
        ..grains();
    case GaiaCometLook.knots:
      comet
        ..dust(_dust, 0.3, length * 0.36)
        ..strand(a: 0.2, amp: 1.5)
        ..knots();
    case GaiaCometLook.bands:
      comet
        ..dust(_gold, 0.28, length * 0.48)
        ..rays(length * 0.48)
        ..strand(a: 0.15, amp: 1);
    case GaiaCometLook.great:
      // Each a little fainter than on its own, so together they aren't
      // busy.
      comet
        ..dust(_gold, 0.26, length * 0.46)
        ..rays(length * 0.46, a: 0.16)
        ..grains(color: _gold, count: 60)
        ..streamers(0.17);
    case GaiaCometLook.greatV2 || GaiaCometLook.greatV3:
      comet
        ..dust(_gold, 0.26, length * 0.46)
        ..rays(length * 0.46, a: 0.16)
        ..grains(color: _gold, count: 60, from: 15)
        ..streamers(0.17);
    case GaiaCometLook.jets:
      comet
        ..dust(_dust, 0.34, length * 0.34, reach: 0.7)
        ..strand(a: 0.22, reach: 0.9, amp: 2);
  }
  // Great V3's own head is one of the heads.
  switch (head ??
      (look == GaiaCometLook.greatV3 ? GaiaCometHead.shellsStarburst : null)) {
    case GaiaCometHead.hood:
      comet
        ..hood(17, 0.75)
        ..jets();
    case GaiaCometHead.shells:
      comet
        ..hood(14, 0.55)
        ..shells(14)
        ..core(5, 0.7);
    case GaiaCometHead.starburst:
      comet
        ..hood(12, 0.5)
        ..spikes();
    case GaiaCometHead.shellsStarburst:
      comet
        ..hood(14, 0.55)
        ..shells(14, grow: 0.45)
        ..core(5, 0.7)
        ..spikes(a: 0.3, size: 10);
    case null:
      switch (look) {
        case GaiaCometLook.classic ||
            GaiaCometLook.bands ||
            GaiaCometLook.great:
          comet.hood(15, 0.8);
        case GaiaCometLook.streamers:
          comet.hood(14, 0.75);
        case GaiaCometLook.shedding:
          comet.hood(14, 0.8);
        case GaiaCometLook.knots:
          comet.hood(14 + 3 * swell, 0.7 + 0.25 * swell);
        case GaiaCometLook.greatV2:
          comet
            ..hood(17, 0.75)
            ..jets();
        case GaiaCometLook.jets:
          comet
            ..hood(19, 0.7)
            ..jets();
        case GaiaCometLook.greatV3:
          // Given its head above.
          break;
      }
  }
  comet.nucleus();
}

/// A steady pseudo-random number, 0 to 1, for [i] and [salt].
double _hash(int i, int salt) {
  final v = sin(i * 12.9898 + salt * 78.233) * 43758.5453;
  return v - v.floorToDouble();
}

class _Comet {
  _Comet(this.canvas, this.len, this.bend, this.time, this.alpha);

  final Canvas canvas;
  final double len, bend, time, alpha;

  Color tint(Color color, double a) =>
      color.withValues(alpha: (a * alpha).clamp(0.0, 1.0));

  /// Fading from [a] at the head to nothing [length] along.
  Shader fading(Color color, double a, double length) => ui.Gradient.linear(
    Offset.zero,
    Offset(length, 0),
    [tint(color, a), tint(color, 0)],
  );

  /// How far the dust tail's middle has curved off the axis [x] along,
  /// swaying a little.
  double drift(double x) =>
      bend * (1 + 0.12 * sin(time * 0.45)) * 0.22 * len * pow(x / len, 2);

  /// The dust tail's outline, [length] along and [width] across at its end.
  Path fan(double length, double width) {
    final end = drift(length);
    return Path()
      ..moveTo(0, -1.5)
      ..quadraticBezierTo(length * 0.5, -width * 0.35, length, end - width / 2)
      ..lineTo(length, end + width / 2)
      ..quadraticBezierTo(length * 0.5, width * 0.35, 0, 1.5)
      ..close();
  }

  /// The dust tail, broad and soft, brightest along its middle.
  void dust(Color color, double a, double width, {double reach = 1}) {
    final length = len * reach;
    final paint = Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, len * 0.05)
      ..shader = fading(color, a, length);
    canvas.drawPath(fan(length, width), paint);
    paint.shader = fading(color, a, length * 0.6);
    canvas.drawPath(fan(length * 0.6, width * 0.25), paint);
  }

  /// A fine ion streamer, straight away from the sun but [angle] off it,
  /// rippling: waves [wave] tail lengths long running outwards at [speed]
  /// tail lengths a second, growing as they go.
  void strand({
    required double a,
    double reach = 1.3,
    double angle = 0,
    double amp = 3,
    double wave = 0.45,
    double speed = 0.25,
    double phase = 0,
    double width = 1.3,
  }) {
    final length = len * reach;
    final path = Path()..moveTo(0, 0);
    const steps = 40;
    for (var i = 1; i <= steps; i++) {
      final x = length * i / steps;
      final ripple = sin(2 * pi * (x / len - time * speed) / wave + phase);
      path.lineTo(x, x * angle + amp * x / length * ripple);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8)
        ..shader = fading(_ion, a, length),
    );
  }

  /// The coma: a hood about the nucleus of radius [r], rounded towards the
  /// sun and opening down the tails.
  void hood(double r, double a) {
    final reach = r * 2.2;
    canvas.drawPath(
      parabola(r)..close(),
      Paint()
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.3)
        ..shader = ui.Gradient.radial(
          Offset.zero,
          reach,
          [tint(Colors.white, a), tint(_coma, a * 0.45), tint(_coma, 0)],
          [0, 0.25, 1],
        ),
    );
  }

  /// The nucleus: a bright point in a small glow, flickering faintly.
  void nucleus() {
    final flicker = 1 + 0.1 * sin(time * 2.7);
    canvas
      ..drawCircle(
        Offset.zero,
        6,
        Paint()
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
          ..color = tint(Colors.white, 0.5 * flicker),
      )
      ..drawCircle(Offset.zero, 1.6, Paint()..color = tint(Colors.white, 1));
  }

  /// Five fine ion streamers fanning from the head at [a], each waving on
  /// its own.
  void streamers(double a) {
    for (var k = 0; k < 5; k++) {
      strand(
        a: a,
        reach: 1.15 + 0.2 * _hash(k, 1),
        angle: (k - 2) * 0.035,
        amp: 2 + 2.5 * _hash(k, 2),
        wave: 0.3 + 0.2 * _hash(k, 3),
        speed: 0.18 + 0.12 * _hash(k, 4),
        phase: 2 * pi * _hash(k, 5),
        width: 1,
      );
    }
  }

  /// [count] dust grains in [color] shed from the head, from the nucleus or
  /// anywhere within [from] of it, each drifting out along the tail's curve
  /// at its own pace, spreading and fading as it goes.
  void grains({Color color = _dust, int count = 90, double from = 0}) {
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final p = (time * (0.05 + 0.05 * _hash(i, 1)) + _hash(i, 2)) % 1;
      // Where on the head it left: anywhere within [from] of the nucleus,
      // a little more towards the tails.
      final startX = (_hash(i, 5) - 0.35) * from;
      final startY = (_hash(i, 6) - 0.5) * 1.8 * from;
      final x = startX + len * p;
      final y = drift(x) + startY + (_hash(i, 3) - 0.5) * len * 0.4 * p;
      // Shed from a point, a grain is seen at once; from the whole head,
      // it brightens over the first quarter of its way, so the head isn't
      // crowded with them.
      final fadeIn = from > 0 ? p * 4 : p * 20;
      final a = 0.7 * pow(1 - p, 1.4) * min(1, fadeIn);
      paint.color = tint(color, a.toDouble());
      canvas.drawCircle(Offset(x, y), 0.6 + 0.8 * _hash(i, 4), paint);
    }
  }

  /// Knots of the ion tail breaking away, one after another, stretching
  /// and fading as they go.
  void knots() {
    final paint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
    for (var k = 0; k < 3; k++) {
      final p = (time * 0.07 + k / 3) % 1;
      final x = len * 1.3 * p;
      paint.color = tint(_ion, 0.5 * pow(sin(pi * p), 1.5).toDouble());
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(x, 1.5 * sin(time * 1.3 + k)),
          width: 8 + 30 * p,
          height: 3 + 4 * p,
        ),
        paint,
      );
    }
  }

  /// Rays combed along the dust tail [width] across, each waxing and
  /// waning on its own, at most [a].
  void rays(double width, {double a = 0.2}) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    for (var k = 0; k < 7; k++) {
      final across = (k / 6 - 0.5) * width * 0.8;
      final wax = 0.5 + 0.5 * sin(time * 0.5 + k * 1.7);
      paint.shader = fading(_gold, a * wax, len);
      canvas.drawPath(
        Path()
          ..moveTo(0, 0)
          ..quadraticBezierTo(
            len * 0.5,
            across * 0.3,
            len,
            drift(len) + across,
          ),
        paint,
      );
    }
  }

  /// The hood's outline at radius [r], open down the tails.
  Path parabola(double r) {
    final reach = r * 2.2;
    return Path()
      ..moveTo(reach, -r * 1.1)
      ..quadraticBezierTo(-r * 1.4 - reach, 0, reach, r * 1.1);
  }

  /// A bright core of radius [r] about the nucleus, sharper than the hood.
  void core(double r, double a) => canvas.drawCircle(
    Offset.zero,
    r,
    Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.25)
      ..shader = ui.Gradient.radial(
        Offset.zero,
        r,
        [tint(Colors.white, a), tint(_coma, a * 0.5), tint(_coma, 0)],
        [0, 0.5, 1],
      ),
  );

  /// Shells of gas rising off the nucleus and out through a hood of radius
  /// [r], each widening by [grow] of it and fading as it goes.
  void shells(double r, {double grow = 0.9}) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1);
    for (var k = 0; k < 3; k++) {
      final p = (time * 0.25 + k / 3) % 1;
      paint.color = tint(
        Color.lerp(Colors.white, _coma, p)!,
        0.55 * (1 - p) * min(1, p * 5),
      );
      canvas.drawPath(parabola(r * (0.3 + grow * p)), paint);
    }
  }

  /// Four fine spikes about the nucleus, as a bright star's, at most [a]
  /// and about [size] long, shimmering and turning slowly.
  void spikes({double a = 0.75, double size = 16}) {
    final paint = Paint()
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.6);
    for (var k = 0; k < 4; k++) {
      final angle = pi / 4 + k * pi / 2 + time * 0.05;
      final reach = size * (1 + 0.3 * sin(time * 1.3 + k * 2.1));
      final end = Offset(cos(angle), sin(angle)) * reach;
      paint.shader = ui.Gradient.linear(Offset.zero, end, [
        tint(Colors.white, a),
        tint(Colors.white, 0),
      ]);
      canvas.drawLine(Offset.zero, end, paint);
    }
  }

  /// Two jets spiralling out of the turning nucleus, swept back down the
  /// tails as they leave it.
  void jets() {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
      ..shader = ui.Gradient.radial(Offset.zero, 18, [
        tint(Colors.white, 0.55),
        tint(_coma, 0),
      ]);
    for (var j = 0; j < 2; j++) {
      final path = Path()..moveTo(0, 0);
      for (var s = 1; s <= 24; s++) {
        final r = s * 0.7;
        final theta = time * 0.6 + j * pi + s * 0.2;
        path.lineTo(r * cos(theta) + r * r * 0.03, r * sin(theta));
      }
      canvas.drawPath(path, paint);
    }
  }
}
