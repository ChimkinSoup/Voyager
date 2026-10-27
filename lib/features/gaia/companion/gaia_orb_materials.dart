import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter, VertexMode, Vertices;

import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_glyph.dart';

/// Procedural astral material shared by the live orb and its debug previews.
/// Geometry is deterministic and the resting design is independent of state.
enum GaiaOrbMaterial { astral }

/// How the orb shows it's thinking. Focus is the live chat's.
enum GaiaOrbThinking {
  classic(
    'Classic',
    'A breath: the light swells and the orbits speed up.',
    0.4,
  ),
  synapse(
    'Synapse',
    'The orbits slow and dim while sparks spread through a web of motes.',
    -0.2,
  ),
  focus(
    'Focus',
    'Draws its motes and orbits into a tightening core, holds, then '
        'breathes them back out.',
    -0.15,
  ),
  scan(
    'Scan',
    'The core glances about while comets sweep the orbits, searching.',
    0.1,
  );

  const GaiaOrbThinking(this.label, this.description, this.pace);
  final String label, description;

  /// Added to the clock's rate while fully thinking.
  final double pace;

  /// Added to the orbits' clock rate while fully thinking. Focus's orbits
  /// turn at the classic pace while its motes keep their own.
  double get orbitPace => this == focus ? classic.pace : pace;
}

/// How the orb shows its reply streaming in. Outpour is the live chat's.
enum GaiaOrbReplying {
  classic('Classic', 'The rings wobble and spin faster.', 0.9),
  murmur(
    'Murmur',
    "Scan's answer: the orbits relax, its comets soften to glints and the "
        'light murmurs.',
    0.15,
  ),
  ripple(
    'Ripple',
    'Each syllable leaves the core as a wavefront that rocks the orbits.',
    0.15,
  ),
  voice(
    'Voice',
    'The orbits turn to you and ripple like a waveform as it speaks.',
    0.2,
  ),
  outpour(
    'Outpour',
    'The orbits wobble and spin faster as streams of light pour from the '
        'core.',
    0.25,
  );

  const GaiaOrbReplying(this.label, this.description, this.pace);
  final String label, description;

  /// Added to the clock's rate while fully replying.
  final double pace;

  /// How much faster the orbits spin and tumble while fully replying: the
  /// classic reply's, which outpour borrows.
  double get whirl => this == classic || this == outpour ? 1 : 0;

  /// Turns the orbits partway to face the viewer.
  bool get facesViewer => this == voice;
}

/// The orb's clocks. Each advances at a rate set by the orb's state, so
/// easing between states changes how fast things turn, never where they are.
class GaiaOrbClock {
  GaiaOrbClock([this.time = 1.7])
    : orbits = time,
      tumble = time * 0.16,
      turnEven = time * 0.19,
      turnOdd = time * -0.17,
      roll = time * 0.18,
      twinkle = time * 0.7;

  /// The core's, the motes' and the styles' own clock.
  double time;

  /// The orbits' spin.
  double orbits;

  /// The orbits' extra spin while a reply whirls them.
  double whirl = 0;

  /// The orbits' tumble, turn (even and odd orbits) and roll angles. Facing
  /// the viewer scales them toward zero, so they're kept within a turn while
  /// nothing does, and a gather sweeps them back less than a turn.
  double tumble, turnEven, turnOdd, roll;

  /// The motes' twinkle, quicker while replying.
  double twinkle;

  void advance(
    double dt, {
    required double thinking,
    required double replying,
    required GaiaOrbThinking thinkingStyle,
    required GaiaOrbReplying replyingStyle,
    required double gather,
  }) {
    final rate =
        0.55 + thinking * thinkingStyle.pace + replying * replyingStyle.pace;
    final orbitRate =
        0.55 +
        thinking * thinkingStyle.orbitPace +
        replying * replyingStyle.pace;
    time += dt * rate;
    // The spin holds while gathering: each orbit turns the short way round
    // to its place in the glyph, and a spin carrying on could flip which way
    // that is halfway there.
    if (gather == 0) {
      orbits += dt * orbitRate;
      whirl += dt * orbitRate * replying * replyingStyle.whirl;
    }
    tumble += dt * orbitRate * (0.16 + replying * replyingStyle.whirl * 0.2);
    turnEven += dt * orbitRate * 0.19;
    turnOdd -= dt * orbitRate * 0.17;
    roll += dt * orbitRate * 0.18;
    twinkle += dt * rate * (0.7 + replying);
    // A whole turn is invisible while the orbits face their own way, and
    // anything is once they've all gathered flat into the glyph.
    final facing = replyingStyle.facesViewer ? replying : 0.0;
    if ((gather == 0 && facing < 1e-4) || gather == 1) {
      double wrap(double a) => (a + math.pi) % _tau - math.pi;
      tumble = wrap(tumble);
      turnEven = wrap(turnEven);
      turnOdd = wrap(turnOdd);
      roll = wrap(roll);
    }
  }
}

/// An orb's eased state: how far it's thinking, replying, gathered into its
/// glyph and bloomed in. The chat's orb and the studio's share it, so the
/// studio moves as the chat's orb does.
class GaiaOrbMotion extends ChangeNotifier {
  final clock = GaiaOrbClock();
  double thinking = 0, speaking = 0, gather = 0, bloom = 0;

  /// What [thinking] and [speaking] ease toward, themselves easing toward
  /// the targets.
  double thinkingLead = 0, speakingLead = 0;

  /// Straight to the targets, as under reduced motion.
  void snapTo({
    required bool thinks,
    required bool speaks,
    required bool gathers,
  }) {
    thinking = thinkingLead = thinks ? 1 : 0;
    speaking = speakingLead = speaks ? 1 : 0;
    gather = gathers ? 1 : 0;
    bloom = 1;
  }

  /// Eases [dt] seconds toward the targets.
  void advance(
    double dt, {
    required bool thinks,
    required bool speaks,
    required bool gathers,
    required GaiaOrbThinking thinkingStyle,
    required GaiaOrbReplying replyingStyle,
  }) {
    gather = gathers
        ? math.min(1, gather + dt / kGaiaAstralGatherTime)
        : math.max(0, gather - dt / kGaiaAstralUnfurlTime);
    bloom = math.min(1, bloom + dt / kGaiaAstralArrivalTime);
    // Two eases in series: one alone sets off at full speed, jolting the
    // rings' size and tilt as thinking hands over to replying.
    final ease = 1 - math.exp(-5 * dt);
    thinkingLead += ((thinks ? 1 : 0) - thinkingLead) * ease;
    speakingLead += ((speaks ? 1 : 0) - speakingLead) * ease;
    thinking += (thinkingLead - thinking) * ease;
    speaking += (speakingLead - speaking) * ease;
    clock.advance(
      dt,
      thinking: thinking,
      replying: speaking,
      thinkingStyle: thinkingStyle,
      replyingStyle: replyingStyle,
      gather: gather,
    );
  }
}

const kGaiaAstralArrivalTime = 1.25;
const kGaiaAstralGatherTime = 1.15;
const kGaiaAstralUnfurlTime = 1.0;

/// The Astral core's white light, tinted a little by [accent]. The spinner
/// and toast marks share it with the orb.
Color gaiaAstralLight(Color accent) => Color.lerp(accent, Colors.white, 0.72)!;

/// The Astral orbits' warm gold.
const kGaiaAstralGold = Color(0xFFFFDF91);

const _tau = math.pi * 2;
const _rayExtension = 1.65;

// Local stages keep the core, solid orbit, crossbars and beads independent.
// A single reversible clock drives them, including interrupted transitions.
double _stage(double value, double start, double end) {
  final t = ((value - start) / (end - start)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

// These samples describe a fixed ray silhouette, independent of the clock,
// colour and size. Keep the later multiply order identical to the live path.
final _raySamples = List.generate(97, (j) {
  final a = j / 96 * _tau;
  final x = math.cos(a), y = math.sin(a);
  final tip = ((math.max(x.abs(), y.abs()) - 0.94) / 0.06).clamp(0.0, 1.0);
  return (
    x: x.sign * math.pow(x.abs(), 7),
    y: y.sign * math.pow(y.abs(), 7),
    stretch: 1 + (_rayExtension - 1) * tip * tip * (3 - 2 * tip),
  );
});

class _V {
  const _V(this.x, this.y, this.z);
  final double x, y, z;
  _V operator +(_V v) => _V(x + v.x, y + v.y, z + v.z);
  _V operator -(_V v) => _V(x - v.x, y - v.y, z - v.z);
  _V operator *(double s) => _V(x * s, y * s, z * s);
  double dot(_V v) => x * v.x + y * v.y + z * v.z;
  _V cross(_V v) => _V(y * v.z - z * v.y, z * v.x - x * v.z, x * v.y - y * v.x);
  _V get unit => this * (1 / math.sqrt(dot(this)).clamp(0.0001, 100));
  _V turn(double pitch, double yaw, [double roll = 0]) {
    final cp = math.cos(pitch), sp = math.sin(pitch);
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final cr = math.cos(roll), sr = math.sin(roll);
    final yy = y * cp - z * sp;
    final zz = y * sp + z * cp;
    final xx = x * cy + zz * sy;
    final zzz = zz * cy - x * sy;
    return _V(xx * cr - yy * sr, xx * sr + yy * cr, zzz);
  }
}

/// Each ring has one orientation per frame. Reuse its trigonometry while
/// retaining the exact original rotation arithmetic (not a new matrix path).
class _Rotation {
  _Rotation(double pitch, double yaw, double roll)
    : cp = math.cos(pitch),
      sp = math.sin(pitch),
      cy = math.cos(yaw),
      sy = math.sin(yaw),
      cr = math.cos(roll),
      sr = math.sin(roll);
  final double cp, sp, cy, sy, cr, sr;
  _V apply(_V v) {
    final yy = v.y * cp - v.z * sp;
    final zz = v.y * sp + v.z * cp;
    final xx = v.x * cy + zz * sy;
    final zzz = zz * cy - v.x * sy;
    return _V(xx * cr - yy * sr, xx * sr + yy * cr, zzz);
  }
}

/// One orbit segment's soft light, blurred later with the rest of its half.
class _Emission {
  _Emission(
    this.from,
    this.to,
    this.width, {
    required this.spill,
    required this.glow,
    this.link = -1,
    this.cap = StrokeCap.round,
  });

  /// A run of neighbouring segments as one stroke along them, carrying the
  /// same light. Once blurred, its seams and the polyline's corners are gone.
  factory _Emission.merge(List<_Emission> run) {
    Offset middle(_Emission e) => (e.from + e.to) / 2;
    double dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;
    final axis = middle(run.last) - middle(run.first);
    if (axis.distance == 0) return run.first;
    final along = axis / axis.distance, across = Offset(-along.dy, along.dx);
    // Half a step past the end middles, so runs abut; further where the
    // segments themselves reach, as when an orbit is seen edge on.
    final step = axis.distance / (run.length - 1);
    var start = dot(middle(run.first), along) - step / 2;
    var end = dot(middle(run.last), along) + step / 2;
    var offset = 0.0, width = 0.0, spill = 0.0, glow = 0.0;
    for (final e in run) {
      for (final point in [e.from, e.to]) {
        start = math.min(start, dot(point, along) - e.width / 2);
        end = math.max(end, dot(point, along) + e.width / 2);
      }
      final segment = e.to - e.from;
      offset += dot(middle(e), across) / run.length;
      width += (dot(segment, across).abs() + e.width) / run.length;
      final area = (segment.distance + e.width) * e.width;
      spill += e.spill.a * area;
      glow += e.glow.a * area;
    }
    final area = (end - start) * width;
    return _Emission(
      along * start + across * offset,
      along * end + across * offset,
      width,
      spill: run.first.spill.withValues(alpha: (spill / area).clamp(0.0, 1.0)),
      glow: run.first.glow.withValues(alpha: (glow / area).clamp(0.0, 1.0)),
      cap: StrokeCap.butt,
    );
  }

  final Offset from, to;
  final double width;
  final Color spill, glow;

  /// Its place along its orbit, so neighbours can merge; -1 for none.
  /// Orbits are numbered apart, so one's end doesn't run into the next.
  final int link;
  final StrokeCap cap;
}

/// A white bead glow, tinted per bead. It's about the size it's drawn at, as
/// sprites are sampled without mipmaps.
final _beadGlow = () {
  const radius = 16.0;
  const box = Rect.fromLTWH(0, 0, radius * 2, radius * 2);
  const white = Colors.white;
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawCircle(
    box.center,
    radius,
    Paint()
      ..shader = RadialGradient(
        colors: [
          white,
          white.withValues(alpha: 1 / 3),
          white.withValues(alpha: 0.02 / 0.22),
          white.withValues(alpha: 0),
        ],
        stops: const [0, 2 / 4.5, 3 / 4.5, 1],
      ).createShader(box),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(box.width.round(), box.height.round());
  picture.dispose();
  return (image: image, box: box);
}();

typedef _BeadGlow = ({Offset centre, double radius, Color color});

int _argb(Color c) =>
    (c.a * 255).round() << 24 |
    (c.r * 255).round() << 16 |
    (c.g * 255).round() << 8 |
    (c.b * 255).round();

/// Small geometry merged into one draw: the orbits' crisp strokes, the
/// interior's motes and the beads. Skia tessellated each stroke and circle on
/// its own, which cost more than the rest of the orb together; as triangles
/// they cost a fraction of that. A feather a pixel wide anti-aliases them.
class _Mesh {
  /// [devicePixelRatio] is the scale above the canvas's own transform, which
  /// a layer's canvas doesn't include.
  _Mesh(this.canvas, double devicePixelRatio) {
    final matrix = canvas.getTransform();
    pixel =
        1 /
        (math.sqrt(matrix[0] * matrix[0] + matrix[1] * matrix[1]) *
            devicePixelRatio);
  }

  final Canvas canvas;
  late final double pixel;
  var _positions = Float32List(2048);
  var _colors = Int32List(1024);
  var _indices = Uint16List(4096);
  var _vertexCount = 0, _indexCount = 0;

  int _vertex(Offset point, int color) {
    if (_vertexCount == _colors.length) {
      _positions = Float32List(_positions.length * 2)..setAll(0, _positions);
      _colors = Int32List(_colors.length * 2)..setAll(0, _colors);
    }
    _positions[_vertexCount * 2] = point.dx;
    _positions[_vertexCount * 2 + 1] = point.dy;
    _colors[_vertexCount] = color;
    return _vertexCount++;
  }

  void _triangle(int a, int b, int c) {
    if (_indexCount + 3 > _indices.length) {
      _indices = Uint16List(_indices.length * 2)..setAll(0, _indices);
    }
    _indices
      ..[_indexCount++] = a
      ..[_indexCount++] = b
      ..[_indexCount++] = c;
  }

  /// A line of [width] from [a] to [b] with round caps.
  void line(Offset a, Offset b, double width, Color color) {
    final argb = _argb(color);
    _round(a, b, width / 2, 3, (a + b) / 2, argb, (_) => argb);
  }

  void disc(Offset centre, double radius, Color color) {
    final argb = _argb(color);
    _round(centre, centre, radius, 4, centre, argb, (_) => argb);
  }

  /// A disc shaded from [light] at its upper left through [body] to [edge],
  /// as a radial gradient twice its radius would.
  void bead(Offset centre, double radius, Color light, Color body, Color edge) {
    final hub = centre + const Offset(-0.4, -0.45) * radius;
    _round(centre, centre, radius, 4, hub, _argb(light), (point) {
      final t = (point - hub).distance / (radius * 2);
      return _argb(
        t < 0.5
            ? Color.lerp(light, body, t * 2)!
            : Color.lerp(body, edge, t * 2 - 1)!,
      );
    });
  }

  /// A fan from [hub] to a rim [half] out from the line [a] to [b], or round
  /// a disc where they meet: each cap in [steps], [shade] colouring the rim.
  void _round(
    Offset a,
    Offset b,
    double half,
    int steps,
    Offset hub,
    int hubColor,
    int Function(Offset point) shade,
  ) {
    if (_vertexCount > 60000) flush();
    final delta = b - a, length = delta.distance;
    final along = length == 0 ? const Offset(1, 0) : delta / length;
    final across = Offset(-along.dy, along.dx);
    // A shape thinner than a pixel covers that fraction of it.
    final coverage = math.min(1.0, half * 2 / pixel);
    int covered(int argb) =>
        ((argb >>> 24) * coverage).round() << 24 | argb & 0xFFFFFF;
    final inner = math.max(half - pixel / 2, 0.0), outer = half + pixel / 2;
    final centre = _vertex(hub, covered(hubColor));
    final first = _vertexCount, rim = 2 * (steps + 1);
    for (var k = 0; k < rim; k++) {
      // Round b's cap from one side to the other, then back round a's.
      final end = k <= steps ? b : a;
      final angle = k <= steps
          ? -math.pi / 2 + k * math.pi / steps
          : math.pi / 2 + (k - steps - 1) * math.pi / steps;
      final direction = along * math.cos(angle) + across * math.sin(angle);
      final point = end + direction * inner;
      final color = shade(point);
      _vertex(point, covered(color));
      _vertex(end + direction * outer, color & 0xFFFFFF);
    }
    for (var k = 0; k < rim; k++) {
      final i = first + 2 * k, j = first + 2 * ((k + 1) % rim);
      _triangle(centre, i, j);
      _triangle(i, i + 1, j + 1);
      _triangle(i, j + 1, j);
    }
  }

  void flush() {
    if (_indexCount == 0) return;
    final vertices = Vertices.raw(
      VertexMode.triangles,
      Float32List.sublistView(_positions, 0, _vertexCount * 2),
      colors: Int32List.sublistView(_colors, 0, _vertexCount),
      indices: Uint16List.sublistView(_indices, 0, _indexCount),
    );
    canvas.drawVertices(vertices, BlendMode.dst, Paint());
    vertices.dispose();
    _vertexCount = _indexCount = 0;
  }
}

class _Mark {
  _Mark(this.depth, this.draw) : mesh = null;
  _Mark.mesh(this.depth, this.mesh) : draw = null;
  final double depth;
  final void Function(Canvas canvas)? draw;

  /// Adds geometry to a [_Mesh] shared with its neighbours in painting order.
  final void Function(_Mesh mesh)? mesh;
  int order = 0;
}

/// Perspective projection and painter's ordering, including translucent rear
/// geometry. The same camera is used for solids, threads, beads and crossbars.
class _Scene {
  _Scene(
    this.centre,
    this.radius,
    this.opacity,
    this.surface,
    this.devicePixelRatio,
  );
  final Offset centre;
  final double radius, opacity, devicePixelRatio;
  final Color surface;
  final marks = <_Mark>[];
  // Canvas snapshots paint properties when recording a draw. Reusing a paint
  // by role is safe and avoids hundreds of native Paint/MaskFilter allocations
  // every frame. Radius-dependent properties belong to this one frame's scene.
  final _glowPaint = Paint();
  final _emissionPaint = Paint()..blendMode = BlendMode.plus;
  // A mask blur per orbit segment cost hundreds of blurs a frame. Their
  // emission is additive and blurring is linear, so it's drawn sharp and
  // blurred once, with the beads' glows.
  final _emission = <_Emission>[];
  final _beadGlows = <_BeadGlow>[];
  late final _hazePaint = Paint()
    ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.12);
  Offset project(_V v) => centre + Offset(v.x, v.y) * (radius * 4 / (4 - v.z));
  Color color(Color c, double alpha) =>
      c.withValues(alpha: (c.a * alpha * opacity).clamp(0.0, 1.0));

  /// Composite the core as one emissive volume. Its centre stays continuous
  /// with the rays: no attenuation mask punches a dim hole into the light.
  void coreLight(void Function(_Scene light) build, {double alpha = 1}) {
    final light = _Scene(
      centre,
      radius,
      opacity * alpha,
      surface,
      devicePixelRatio,
    );
    build(light);
    marks.add(
      _Mark(0, (canvas) {
        final bounds = Rect.fromCircle(center: centre, radius: radius * 1.35);
        canvas.saveLayer(bounds, Paint());
        light.paint(canvas);
        canvas.restore();
      }),
    );
  }

  void line(_V a, _V b, Color c, double width, [double alpha = 1]) {
    final depth = (a.z + b.z) / 2;
    final tint = color(
      c,
      alpha * (0.54 + 0.46 * ((depth + 1) / 2).clamp(0.0, 1.0)),
    );
    final from = project(a), to = project(b);
    marks.add(
      _Mark(
        depth,
        (canvas) => canvas.drawLine(
          from,
          to,
          Paint()
            ..color = tint
            ..strokeWidth = width * (radius / 56).clamp(0.5, 1.3)
            ..strokeCap = StrokeCap.round,
        ),
      ),
    );
  }

  /// A hairline between two points, batched with the orbits' geometry.
  void thread(_V a, _V b, Color c, double width, double alpha) {
    final tint = color(c, alpha);
    final from = project(a), to = project(b);
    final pixels = width * (radius / 56).clamp(0.5, 1.3);
    marks.add(
      _Mark.mesh((a.z + b.z) / 2, (mesh) => mesh.line(from, to, pixels, tint)),
    );
  }

  void dot(_V p, Color c, double size, [double alpha = 1]) {
    final tint = color(
      c,
      alpha * (0.55 + 0.45 * ((p.z + 1) / 2).clamp(0.0, 1.0)),
    );
    final point = project(p);
    final r = size * (radius / 56).clamp(0.52, 1.3) * 4 / (4 - p.z);
    marks.add(_Mark.mesh(p.z, (mesh) => mesh.disc(point, r, tint)));
  }

  void glow(_V p, Color c, double size, [double alpha = 1]) {
    final point = project(p);
    final r = radius * size;
    final tint = color(c, alpha);
    marks.add(
      _Mark(
        p.z,
        (canvas) => canvas.drawCircle(
          point,
          r,
          _glowPaint
            ..shader = RadialGradient(
              colors: [
                tint,
                tint.withValues(alpha: tint.a * 0.35),
                tint.withValues(alpha: 0),
              ],
              stops: const [0, 0.3, 1],
            ).createShader(Rect.fromCircle(center: point, radius: r)),
        ),
      ),
    );
  }

  /// Perspective and luminance indicate depth without any dark under-stroke,
  /// clearance halo or outline. A faint emission pass surrounds crisp geometry.
  void orbitLine(
    _V a,
    _V b,
    Color c,
    double width, {
    double seal = 0,
    double alpha = 1,
    double ringAlpha = 1,
    int link = -1,
  }) {
    if (alpha == 0) return;
    if (alpha != 1) c = c.withValues(alpha: c.a * alpha);
    final z = (a.z + b.z) / 2;
    final near = ((z + 1.05) / 2.1).clamp(0.0, 1.0);
    final shade = 0.17 + 0.83 * math.pow(near, 1.15).toDouble();
    final metal = color(
      Color.lerp(Color.lerp(c, Colors.white, near * 0.12)!, c, seal)!,
      (0.35 + shade * 0.65) * (1 - seal) + ringAlpha * seal,
    );
    final from = project(a), to = project(b);
    final pixels =
        width * (radius / 56).clamp(0.5, 1.3) * 4 / (4 - z) * (1 - seal) +
        kGaiaTierRingStroke * 1.5 * seal;
    if (seal < 1) {
      // Extend only the faint spill; keep the existing close glow and the
      // crisp ring's brightness intact.
      _emission.add(
        _Emission(
          from,
          to,
          pixels + (radius / 56).clamp(0.5, 1.3) * 1.3,
          spill: color(c, (0.065 + near * 0.035) * (1 - seal)),
          glow: color(c, (0.12 + near * 0.1) * (1 - seal)),
          link: link,
        ),
      );
    }
    marks.add(
      _Mark.mesh(z, (mesh) {
        mesh.line(from, to, pixels, metal);
        if (near > 0.6 && seal < 1) {
          mesh.line(
            from + const Offset(-0.15, -0.2),
            to + const Offset(-0.15, -0.2),
            pixels * 0.35,
            color(
              Color.lerp(c, Colors.white, 0.55)!,
              (near - 0.6) * 1.3 * (1 - seal),
            ),
          );
        }
      }),
    );
  }

  void orbitBead(_V p, Color c, double size) {
    final near = ((p.z + 1.05) / 2.1).clamp(0.0, 1.0);
    final point = project(p);
    final r = size * (radius / 56).clamp(0.52, 1.3) * 4 / (4 - p.z);
    final metal = Color.lerp(c, Colors.white, near * 0.2)!;
    final alpha = 0.38 + near * 0.62;
    _beadGlows.add((
      centre: point,
      radius: r * 4.5,
      color: color(c, 0.22 * alpha),
    ));
    marks.add(
      _Mark.mesh(
        p.z,
        (mesh) => mesh.bead(
          point,
          r,
          color(Color.lerp(metal, Colors.white, near * 0.55)!, alpha),
          color(metal, alpha),
          color(metal, alpha * 0.65),
        ),
      ),
    );
  }

  /// Overlapping Gaussian light volumes have neither a hard perimeter nor a
  /// central pin, diamond, disc or identifiable emitter.
  void haze(double t, Color tint, double strength) {
    marks.add(
      _Mark(0, (canvas) {
        for (var layer = 0; layer < 3; layer++) {
          final offset =
              Offset(
                math.sin(t * 0.32 + layer * 2.1) * 0.055,
                math.cos(t * 0.27 + layer * 1.8) * 0.04,
              ) *
              radius;
          final rect = Rect.fromCenter(
            center: centre + offset,
            width: radius * [0.58, 0.38, 0.5][layer],
            height: radius * [0.36, 0.57, 0.44][layer],
          );
          canvas.drawOval(
            rect,
            _hazePaint
              ..color = color(
                layer == 1 ? Colors.white : tint,
                0.32 * strength,
              ),
          );
        }
      }),
    );
  }

  /// A four-point increase in luminance within the haze. Additive, feathered
  /// gradients preserve the reference silhouette without an opaque white
  /// shape, solid centre, stroke or surface that could read as an object.
  void flare(
    _V p,
    Color tint,
    double size, [
    double alpha = 1,
    bool slender = false,
  ]) {
    final centre = project(p), length = radius * size;
    const rayExtension = _rayExtension;
    final rayLength = length * (slender ? rayExtension : 1);
    Path diamond(double scale) {
      final r = length * scale;
      if (slender) {
        // Extend only the tip neighbourhoods. The original astroid scale and
        // its central webbing stay fixed rather than growing with the rays.
        final path = Path();
        for (var j = 0; j < _raySamples.length; j++) {
          final sample = _raySamples[j];
          final px = centre.dx + sample.x * r * sample.stretch;
          final py = centre.dy + sample.y * r * sample.stretch;
          if (j == 0) {
            path.moveTo(px, py);
          } else {
            path.lineTo(px, py);
          }
        }
        return path..close();
      }
      return Path()
        ..moveTo(centre.dx, centre.dy - r)
        ..quadraticBezierTo(
          centre.dx + r * 0.12,
          centre.dy - r * 0.12,
          centre.dx + r,
          centre.dy,
        )
        ..quadraticBezierTo(
          centre.dx + r * 0.12,
          centre.dy + r * 0.12,
          centre.dx,
          centre.dy + r,
        )
        ..quadraticBezierTo(
          centre.dx - r * 0.12,
          centre.dy + r * 0.12,
          centre.dx - r,
          centre.dy,
        )
        ..quadraticBezierTo(
          centre.dx - r * 0.12,
          centre.dy - r * 0.12,
          centre.dx,
          centre.dy - r,
        )
        ..close();
    }

    void draw(Canvas canvas) {
      canvas.drawPath(
        diamond(1.35),
        Paint()
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            (radius * (slender ? 0.06 : 0.035)).clamp(0.6, 3.5),
          )
          ..blendMode = BlendMode.plus
          ..color = color(tint, alpha * (slender ? 0.14 : 0.22)),
      );
      if (slender) {
        // Faint, feathered diffraction rays keep the long corners readable
        // without filling in the area between them.
        for (final axis in [const Offset(1, 0), const Offset(0, 1)]) {
          final extent = axis * rayLength;
          canvas.drawLine(
            centre - extent,
            centre + extent,
            Paint()
              ..blendMode = BlendMode.plus
              ..strokeWidth = (radius * 0.014).clamp(0.4, 0.9)
              ..maskFilter = MaskFilter.blur(
                BlurStyle.normal,
                (radius * 0.018).clamp(0.5, 1.2),
              )
              ..shader =
                  LinearGradient(
                    begin: axis.dx == 1
                        ? Alignment.centerLeft
                        : Alignment.topCenter,
                    end: axis.dx == 1
                        ? Alignment.centerRight
                        : Alignment.bottomCenter,
                    colors: [
                      color(tint, 0),
                      color(tint, alpha * 0.36),
                      color(tint, alpha * 0.85),
                      color(tint, alpha * 0.90),
                      color(tint, alpha * 0.95),
                      color(tint, alpha * 0.95),
                      color(tint, alpha * 0.90),
                      color(tint, alpha * 0.85),
                      color(tint, alpha * 0.36),
                      color(tint, 0),
                    ],
                    stops: const [
                      0,
                      0.12,
                      0.28,
                      0.44,
                      0.48,
                      0.52,
                      0.56,
                      0.72,
                      0.88,
                      1,
                    ],
                  ).createShader(
                    Rect.fromCenter(
                      center: centre,
                      width: rayLength * 2,
                      height: rayLength * 2,
                    ),
                  ),
          );
        }
      }
      canvas.drawPath(
        diamond(1),
        Paint()
          ..blendMode = BlendMode.plus
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            (radius * (slender ? 0.045 : 0.012)).clamp(0.35, 2.8),
          )
          ..shader = RadialGradient(
            colors: [
              color(Colors.white, alpha * (slender ? 0.55 : 0.92)),
              color(Colors.white, alpha * (slender ? 0.26 : 0.78)),
              color(tint, alpha * (slender ? 0.16 : 0.42)),
              color(tint, 0),
            ],
            stops: slender
                ? [0, 0.25 / rayExtension, 0.75 / rayExtension, 1]
                : const [0, 0.25, 0.75, 1],
          ).createShader(Rect.fromCircle(center: centre, radius: rayLength)),
      );
    }

    marks.add(_Mark(p.z, draw));
  }

  /// Paints shares of the orbits' [strokes]' faint wide [spill] and of their
  /// and the beads' close [glow], each blurred once for them all.
  void _emit(
    Canvas canvas,
    List<_Emission> strokes, {
    required double spill,
    required double glow,
  }) {
    final beadGlows = _beadGlows;
    if (beadGlows.isNotEmpty && glow > 0) {
      final sprite = _beadGlow;
      final radius = sprite.box.width / 2;
      canvas.drawAtlas(
        sprite.image,
        [
          for (final beadGlow in beadGlows)
            RSTransform.fromComponents(
              rotation: 0,
              scale: beadGlow.radius / radius,
              anchorX: radius,
              anchorY: radius,
              translateX: beadGlow.centre.dx,
              translateY: beadGlow.centre.dy,
            ),
        ],
        List.filled(beadGlows.length, sprite.box),
        [
          for (final beadGlow in beadGlows)
            beadGlow.color.withValues(alpha: beadGlow.color.a * glow),
        ],
        BlendMode.modulate,
        null,
        Paint()
          ..blendMode = BlendMode.plus
          ..filterQuality = FilterQuality.low,
      );
    }
    if (strokes.isEmpty) return;
    final bounds = Rect.fromCircle(center: centre, radius: radius * 1.6 + 12);
    for (final (sigma, color, share) in [
      ((radius * 0.065).clamp(1.2, 4.0), (_Emission e) => e.spill, spill),
      ((radius * 0.035).clamp(0.75, 2.1), (_Emission e) => e.glow, glow),
    ]) {
      if (share == 0) continue;
      canvas.saveLayer(
        bounds,
        Paint()
          ..blendMode = BlendMode.plus
          ..imageFilter = ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.decal,
          ),
      );
      for (final e in strokes) {
        canvas.drawLine(
          e.from,
          e.to,
          _emissionPaint
            ..color = color(e).withValues(alpha: color(e).a * share)
            ..strokeWidth = e.width
            ..strokeCap = e.cap,
        );
      }
      canvas.restore();
    }
  }

  void paint(Canvas canvas) {
    // Each stroke costs the rasterizer about as much as its blur used to, so
    // runs of four neighbours become one. Blurs are at least a segment's
    // spacing wide, which hides the seams and the polyline's corners.
    final strokes = <_Emission>[];
    for (var i = 0; i < _emission.length;) {
      var n = 1;
      while (n < 4 &&
          i + n < _emission.length &&
          _emission[i + n].link >= 0 &&
          _emission[i + n].link == _emission[i + n - 1].link + 1) {
        n++;
      }
      strokes.add(
        n == 1 ? _emission[i] : _Emission.merge(_emission.sublist(i, i + n)),
      );
      i += n;
    }
    // Each segment's glow went just under it, so where an orbit folds over,
    // seen edge on, the nearest segments' glow lit those behind. One pass
    // can't sit between them all. Most goes under everything, the rest of
    // the close glow over it; a pass part way up would split the geometry
    // at a visible seam.
    marks
      ..add(
        _Mark(
          double.negativeInfinity,
          (c) => _emit(c, strokes, spill: 1, glow: 0.8),
        ),
      )
      ..add(
        _Mark(double.infinity, (c) => _emit(c, strokes, spill: 0, glow: 0.2)),
      );
    // Equal-depth emissive layers must keep their authored order: sorting
    // only by depth can paint a broad blue glow over a white-hot core.
    for (var j = 0; j < marks.length; j++) {
      marks[j].order = j;
    }
    marks.sort((a, b) {
      final depth = a.depth.compareTo(b.depth);
      return depth != 0 ? depth : a.order.compareTo(b.order);
    });
    _Mesh? mesh;
    for (final mark in marks) {
      if (mark.mesh case final add?) {
        add(mesh ??= _Mesh(canvas, devicePixelRatio));
      } else {
        mesh?.flush();
        mark.draw!(canvas);
      }
    }
    mesh?.flush();
  }
}

/// Material rendering shares the studio's clock, pause/reduced-motion policy
/// and glyph state. Arrival and burst have their own finite, replayable ages.
/// [devicePixelRatio] is the scale the canvas is drawn at beyond its own
/// transform: the view's, for a layer's canvas.
void paintGaiaMaterialOrb(
  Canvas canvas,
  Size size, {
  required GaiaOrbMaterial material,
  required Offset centre,
  required double radius,
  required GaiaOrbClock clock,
  required double thinking,
  required double replying,
  required double done,
  required double revealAge,
  required double burstAge,
  required Color accent,
  required Color ink,
  required Color surface,
  required int tier,
  double devicePixelRatio = 1,
  GaiaOrbThinking thinkingStyle = GaiaOrbThinking.classic,
  GaiaOrbReplying replyingStyle = GaiaOrbReplying.classic,
}) {
  final time = clock.time;
  final gather = done.clamp(0.0, 1.0);
  final reveal = _stage(revealAge, 0, 0.24);
  final breath = thinkingStyle == GaiaOrbThinking.classic ? thinking : 0.0;
  final scene = _Scene(
    centre,
    radius * (1 - breath * 0.035 * (0.5 + 0.5 * math.sin(time * 3.8))),
    reveal,
    surface,
    devicePixelRatio,
  );
  final burst = burstAge < 2.8 ? math.sin(math.pi * burstAge / 2.8) : 0.0;
  final light = gaiaAstralLight(accent);
  // Fully invisible materials need no geometry, shaders, glow passes or sort.
  // Leave the glyph draw below intact; no nonzero-opacity frame is skipped.
  if (scene.opacity > 0 && gather < 1) {
    switch (material) {
      case GaiaOrbMaterial.astral:
        _astral(
          scene,
          time,
          clock,
          burst,
          accent,
          light,
          gather,
          tier,
          revealAge,
          _Study(time, thinking, thinkingStyle, replying, replyingStyle),
        );
    }
  }
  scene.paint(canvas);
  if (gather > 0.93) {
    final opacity = _stage(gather, 0.93, 1);
    paintGaiaTierGlyph(
      canvas,
      centre,
      level: tier,
      color: accent.withValues(alpha: opacity),
      phase: gaiaTierGlyphPhase(tier),
      scale: 1.5,
    );
  }
}

_V _circle(double a, double radius, _Rotation rotation) =>
    rotation.apply(_V(math.cos(a) * radius, math.sin(a) * radius, 0));

/// A steady pseudo-random value in [0, 1) for [n].
double _hash(int n) {
  final x = math.sin(n * 12.9898 + 78.233) * 43758.5453;
  return x - x.floorToDouble();
}

/// The non-classic thinking and replying studies' strengths this frame, each
/// eased in and out with its state. All zero for the classic styles.
class _Study {
  _Study(
    double t,
    double thinking,
    GaiaOrbThinking thinkingStyle,
    double replying,
    GaiaOrbReplying replyingStyle,
  ) : synapse = thinkingStyle == GaiaOrbThinking.synapse ? thinking : 0,
      focus = thinkingStyle == GaiaOrbThinking.focus ? thinking : 0,
      scan = thinkingStyle == GaiaOrbThinking.scan ? thinking : 0,
      murmur = replyingStyle == GaiaOrbReplying.murmur ? replying : 0,
      ripple = replyingStyle == GaiaOrbReplying.ripple ? replying : 0,
      voice = replyingStyle == GaiaOrbReplying.voice ? replying : 0,
      outpour = replyingStyle == GaiaOrbReplying.outpour ? replying : 0,
      classicReply = replyingStyle == GaiaOrbReplying.classic ? replying : 0 {
    if (focus > 0) {
      // A slow draw in, a hold, then a quicker release.
      final u = t / 1.3 % 1;
      final release = _stage(u, 0.74, 1);
      inhale = focus * _stage(u, 0, 0.62) * (1 - release);
      exhale = focus * math.sin(math.pi * release);
    }
    if (scan > 0) {
      // Glances: a quick turn to somewhere new, then a long look.
      final glance = t * 0.9, n = glance.floor();
      Offset look(int n) => Offset(_hash(n) * 2 - 1, _hash(n + 101) * 2 - 1);
      gaze =
          Offset.lerp(look(n), look(n + 1), _stage(glance - n, 0, 0.4))! * scan;
    }
    if (voice > 0 || murmur > 0) {
      // Syllables, grouped into words by a slower phrase and its pauses.
      final syllable = 0.5 + 0.5 * math.sin(t * 22);
      final phrase = 0.5 + 0.5 * math.sin(t * 5.1 + math.sin(t * 2.3) * 1.7);
      final words = ((math.sin(t * 1.9) + 0.7) * 3).clamp(0.0, 1.0);
      final level = 0.3 + 0.7 * syllable * (0.35 + 0.65 * phrase) * words;
      speech = voice * level;
      hum = murmur * level;
    }
    if (ripple > 0) {
      // Up to three wavefronts in flight; some beats are quiet, like speech.
      final beat = t * 3.2, n = beat.floor();
      for (var m = 0; m < 3; m++) {
        final u = (beat - n + m) / 3;
        final loud = _hash(n - m) < 0.2 ? 0.0 : 0.5 + 0.5 * _hash(n - m + 7);
        final fade = math.pow(1 - u, 1.5) * _stage(u, 0, 0.06);
        waves.add((radius: 0.12 + u * 1.15, strength: ripple * loud * fade));
      }
      final fresh = beat - n;
      final loud = _hash(n) < 0.2 ? 0.0 : 0.5 + 0.5 * _hash(n + 7);
      flash = ripple * loud * math.pow(1 - fresh, 3);
    }
  }

  final double synapse, focus, scan, murmur, ripple, voice, outpour;
  final double classicReply;
  double inhale = 0, exhale = 0, speech = 0, hum = 0, flash = 0;
  Offset gaze = Offset.zero;
  final waves = <({double radius, double strength})>[];

  /// How hard the ripple's wavefronts push at [radius] right now.
  double swell(double radius) {
    var push = 0.0;
    for (final wave in waves) {
      final d = (radius - wave.radius) / 0.09;
      push += wave.strength * math.exp(-d * d);
    }
    return push;
  }
}

void _astral(
  _Scene s,
  double t,
  GaiaOrbClock clock,
  double burst,
  Color accent,
  Color light,
  double gather,
  int tier,
  double revealAge,
  _Study study,
) {
  const gold = kGaiaAstralGold;
  final pulse =
      1 +
      study.classicReply * 0.1 * math.sin(t * 5) +
      burst * 0.3 +
      study.inhale * 0.2 +
      study.exhale * 0.35 +
      study.flash * 0.3 +
      study.hum * 0.12 +
      study.speech * 0.25 -
      study.synapse * 0.35;
  final handoff = _stage(gather, 0.93, 1);
  final coreGather = _stage(gather, 0.18, 0.94);
  final coreBorn = _stage(revealAge, 0, 0.3);
  final coreSize =
      (0.22 + coreBorn * 0.78) *
      (1 - coreGather * 0.92) *
      (1 - study.inhale * 0.3 + study.speech * 0.25 + study.hum * 0.1);
  // While scanning, the bright centre glances about inside its haze.
  final look = _V(study.gaze.dx * 0.14, study.gaze.dy * 0.14, 0);
  s.glow(const _V(0, 0, -0.2), accent, 0.8 * pulse, 0.28 * (1 - coreGather));
  s.coreLight((emission) {
    emission.haze(t, light, pulse * 1.4);
    emission.glow(
      look + const _V(0, 0, -0.04),
      light,
      0.48 * pulse * coreSize,
      0.32,
    );
    emission.flare(
      look + const _V(0, 0, 0.01),
      light,
      0.48 * coreSize,
      0.98,
      true,
    );
  }, alpha: 1 - coreGather);

  for (final wave in study.waves) {
    if (wave.strength < 0.005) continue;
    final r = wave.radius * s.radius;
    s.marks.add(
      _Mark(0, (canvas) {
        final soft = r + s.radius * 0.1;
        canvas.drawCircle(
          s.centre,
          soft,
          Paint()
            ..blendMode = BlendMode.plus
            ..shader = RadialGradient(
              colors: [
                s.color(light, 0),
                s.color(light, 0.16 * wave.strength),
                s.color(light, 0),
              ],
              stops: [(r - s.radius * 0.1) / soft, r / soft, 1],
            ).createShader(Rect.fromCircle(center: s.centre, radius: soft)),
        );
        canvas.drawCircle(
          s.centre,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..blendMode = BlendMode.plus
            ..strokeWidth = (s.radius / 56).clamp(0.5, 1.3) * 1.1
            ..color = s.color(light, 0.7 * wave.strength),
        );
      }),
    );
  }

  // The diffuse star condenses into the model's central dot. The orbits have
  // their own choreography; neither the whole scene nor its bounds shrink.
  final dot = _stage(gather, 0.32, 0.9);
  if (dot > 0) {
    s.marks.add(
      _Mark(
        0.1,
        (canvas) => canvas.drawCircle(
          s.centre,
          gaiaTierDotRadius(tier) * 1.5,
          Paint()..color = accent.withValues(alpha: dot * (1 - handoff)),
        ),
      ),
    );
  }

  for (var hoop = 0; hoop < 4; hoop++) {
    // Core first, then separate orbits trace themselves into existence.
    final assembled = _stage(revealAge, 0.22 + hoop * 0.1, 0.88 + hoop * 0.1);
    if (assembled == 0) continue;
    final primary = tier > 0 && (hoop == 2 || (tier == 2 && hoop == 0));
    final ring = kGaiaTierRings[hoop == 0 && tier == 2 ? 1 : 0];
    final align = _stage(gather, hoop == 2 ? 0.02 : 0.09, 0.62);
    final collect = _stage(gather, 0.17 + hoop * 0.025, 0.92);
    final contract = _stage(gather, 0.4, 0.98);
    final seal = primary ? _stage(gather, 0.35, 0.96) : 0.0;
    final classic = study.classicReply;
    final pitch =
        hoop * 0.7 +
        clock.tumble +
        // Outpour borrows the classic reply's wobble and faster spin.
        (classic + study.outpour) * 0.4 * math.sin(t + hoop) +
        study.gaze.dy * 0.35;
    final yaw =
        hoop * 0.9 +
        (hoop.isEven ? clock.turnEven : clock.turnOdd) +
        study.gaze.dx * 0.45;
    final roll = clock.roll;
    // Speaking turns the orbits to face the viewer, as gathering does.
    final face = (1 - align) * (1 - study.voice * 0.5);
    final (tipped, turned, rolled) = (pitch * face, yaw * face, roll * face);
    final rotation = _Rotation(tipped + (1 - assembled) * 0.7, turned, rolled);
    final baseRadius = 0.72 + hoop * 0.065;
    final nativeRadius =
        baseRadius +
        burst * 0.12 -
        study.inhale * 0.14 +
        // Focus rests a little out, so the rings breathe in step with motes.
        study.focus * 0.06 +
        study.outpour * (hoop - 1.5) * 0.045 +
        study.swell(baseRadius) * 0.07;
    final spin = (clock.orbits + clock.whirl) * (hoop.isEven ? 0.4 : -0.35);
    // A comet's head, as a fraction of the way round its orbit.
    final head = (t * (0.55 + hoop * 0.12)) % 1;
    final targetStart = gaiaTierRingStart(ring, gaiaTierGlyphPhase(tier));
    final turn = (targetStart - spin + math.pi) % _tau - math.pi;
    final arrivalTurn = (1 - assembled) * (hoop.isEven ? -1.1 : 1.1);

    _V point(double along, double radial, {bool end = false}) {
      // Crossbars tip sideways and join end to end as the notched model arc.
      final at = along + (end ? seal / 96 : 0);
      final a =
          at * (_tau + (kGaiaTierRingSweep - _tau) * align) +
          spin +
          turn * align +
          arrivalTurn;
      final targetRadius = primary ? ring.radius * 1.5 / s.radius : 0.0;
      final contraction = primary ? contract : collect;
      var r =
          ((nativeRadius + radial * (1 - seal)) * (1 - contraction) +
              targetRadius * contraction) *
          (0.22 + assembled * 0.78);
      if (study.voice > 0) {
        // Lobes run round the orbit, as tall as the syllable is loud.
        r *=
            1 +
            study.speech *
                0.11 *
                math.sin(a * (3 + hoop % 2) - t * 7 + hoop * 1.7);
      }
      final spiral = primary
          ? 0.0
          : collect * _tau * (hoop.isEven ? 0.85 : -0.85);
      return _circle(a + spiral, r, rotation);
    }

    final tint = Color.lerp(
      hoop == 0 || hoop == 2 ? light : gold,
      accent,
      seal,
    )!;
    final alpha =
        (primary ? 1.0 : 1 - _stage(collect, 0.78, 1)) *
        (1 - handoff) *
        (1 - study.synapse * 0.4);
    for (var j = 0; j < 96; j++) {
      final along = j / 96;
      if (assembled < 1 && along > assembled * 1.14) continue;
      // A short feather behind the growing head, rather than a ring-wide fade.
      final born = assembled == 1
          ? 1.0
          : _stage(assembled * 1.14 - along, 0, 0.12);
      if (born == 0) continue;
      var visibility = alpha * born;
      var lit = tint;
      var comet = 0.0;
      if (study.scan > 0 || study.murmur > 0) {
        // Bright at the head, trailing off behind it; the rest dims. When
        // the murmur takes over, the same heads carry on as short glints
        // over undimmed orbits.
        final behind = (hoop.isEven ? head - along : along - head) % 1;
        comet =
            study.scan * math.exp(-behind * 9) +
            study.murmur * 0.6 * math.exp(-behind * 24);
        visibility *= 1 - study.scan * 0.5 + comet * 0.5;
        lit = Color.lerp(tint, Colors.white, comet * 0.7)!;
        if (behind < 1 / 96) s.glow(point(along, 0), light, 0.13, 0.5 * comet);
      }
      final ringAlpha = gaiaTierRingAlpha(ring, (j + 0.5) / 96);
      if (hoop == 0 || hoop == 3) {
        final halfLength = hoop == 0 ? 0.041 : 0.045;
        s.orbitLine(
          point(along, -halfLength),
          point(along, halfLength, end: true),
          lit,
          1.45 * (1 + comet * 0.6),
          seal: seal,
          alpha: visibility,
          ringAlpha: ringAlpha,
          link: hoop * 100 + j,
        );
      } else if (hoop == 1) {
        if (j % 3 == 0) {
          s.orbitBead(
            point(along, 0),
            lit.withValues(alpha: visibility),
            1.95 * (1 - collect * 0.65) * (1 + comet * 0.6),
          );
        }
      } else {
        s.orbitLine(
          point(along, 0),
          point((j + 1) / 96, 0),
          lit,
          1.1 * (1 + comet * 0.6),
          seal: seal,
          alpha: visibility,
          ringAlpha: ringAlpha,
          link: hoop * 100 + j,
        );
      }
    }
  }
  _floatingInterior(
    s,
    t,
    clock.twinkle,
    burst,
    accent,
    light,
    gather,
    revealAge,
    study,
  );
}

final _motes = List.generate(96, (i) {
  final random = math.Random(9301 + i * 43);
  final y = random.nextDouble() * 2 - 1;
  final a = random.nextDouble() * _tau;
  final radial = math.sqrt(1 - y * y);
  return (
    position:
        _V(math.cos(a) * radial, y, math.sin(a) * radial) *
        (0.12 + math.pow(random.nextDouble(), 1 / 3) * 0.6),
    speed: 0.09 + random.nextDouble() * 0.25,
    phase: random.nextDouble() * _tau,
    size: 0.65 + random.nextDouble() * 0.65,
  );
});

void _floatingInterior(
  _Scene s,
  double t,
  double twinkle,
  double burst,
  Color accent,
  Color light,
  double gather,
  double revealAge,
  _Study study,
) {
  // Kept for the synapse's web, which needs every mote placed first.
  final web = <({_V p, Color color, double size, double alpha})>[];
  for (var i = 0; i < _motes.length; i++) {
    final mote = _motes[i];
    // Independent tilted paths, radial travel and gentle 3D wandering fill
    // more of the volume. Bound only the outermost excursion, not each orbit.
    final breathing = 0.94 + 0.14 * math.sin(t * 0.7 + mote.phase);
    final wander = _V(
      math.sin(t * 0.41 + mote.phase) * 0.055,
      math.cos(t * 0.33 + mote.phase * 1.3) * 0.055,
      math.sin(t * 0.29 + mote.phase * 1.7) * 0.055,
    );
    var p =
        mote.position.turn(
              t * mote.speed + mote.phase,
              t * mote.speed * 0.73,
              math.sin(t * 0.3 + mote.phase) * 0.3,
            ) *
            breathing +
        wander;
    final distance = math.sqrt(p.dot(p));
    if (distance > 0.84) p = p * (0.84 / distance);
    final born = _stage(
      revealAge,
      0.48 + (i % 12) * 0.025,
      0.94 + (i % 12) * 0.025,
    );
    if (born == 0) continue;
    var shine = 1.0;
    if (study.focus > 0) {
      // Drawn in, turning, towards the core.
      p = p.turn(0, study.inhale * 0.8) * (1 - study.inhale * 0.55);
    }
    if (study.ripple > 0) {
      p = p * (1 + study.swell(math.sqrt(p.dot(p))) * 0.12);
    }
    if (study.voice > 0) shine += study.voice * (study.speech - 0.5) * 0.6;
    if (study.outpour > 0) {
      // Out from the core along its own direction, and toward the viewer.
      _V stream(double flow) =>
          mote.position.unit * (0.1 + flow * 0.92) + _V(0, 0, flow * 0.45);
      final flow = (t * 0.9 * (0.7 + mote.speed) + mote.phase / _tau) % 1;
      p = p + (stream(flow) - p) * study.outpour;
      final fade = math.sin(math.pi * flow);
      shine *= 1 - study.outpour * (1 - fade);
      if (flow > 0.08 && born == 1 && gather == 0) {
        s.thread(
          stream(flow - 0.08),
          p,
          light,
          0.6,
          0.35 * study.outpour * fade,
        );
      }
    }
    final inward = _stage(gather, 0.06 + (i % 8) * 0.018, 0.84);
    if (born < 1 || inward > 0) {
      p =
          p.turn(0, inward * _tau * 0.85 + (1 - born) * 1.1) *
          born *
          (1 - inward);
    }
    final color = Color.lerp(
      i % 7 == 0 ? kGaiaAstralGold : light,
      accent,
      gather,
    )!;
    final alpha =
        (0.65 + 0.25 * math.sin(twinkle + mote.phase)) *
        born *
        (1 - _stage(inward, 0.65, 1)) *
        shine;
    if (study.synapse > 0) {
      web.add((p: p, color: color, size: mote.size, alpha: alpha));
    } else {
      s.dot(p, color, mote.size, alpha);
    }
  }
  if (web.isNotEmpty) _synapse(s, t, study.synapse, light, web);
}

/// Motes as a web of faint links. Waves of firing spread out from a mote
/// at a time, lighting the motes and links they pass through.
void _synapse(
  _Scene s,
  double t,
  double strength,
  Color light,
  List<({_V p, Color color, double size, double alpha})> motes,
) {
  final firing = List.filled(motes.length, 0.0);
  for (var k = 0; k < 3; k++) {
    final cycle = t * 1.8 + k / 3, n = cycle.floor(), u = cycle - n;
    final seed = motes[(_hash(n * 3 + k) * motes.length).floor()].p;
    final front = u * 0.9, fade = math.pow(1 - u, 1.5);
    for (var i = 0; i < motes.length; i++) {
      final away = motes[i].p - seed;
      final d = (math.sqrt(away.dot(away)) - front) / 0.1;
      firing[i] = math.max(firing[i], math.exp(-d * d) * fade);
    }
  }
  const reach = 0.3;
  for (var i = 0; i < motes.length; i++) {
    final a = motes[i];
    for (var j = i + 1; j < motes.length; j++) {
      final b = motes[j];
      final gap = b.p - a.p;
      final d = math.sqrt(gap.dot(gap));
      if (d >= reach) continue;
      final alpha =
          strength *
          (1 - d / reach) *
          (0.16 + 1.2 * (firing[i] + firing[j]) / 2) *
          math.min(a.alpha, b.alpha);
      if (alpha > 0.012) s.thread(a.p, b.p, light, 0.8, alpha);
    }
  }
  for (var i = 0; i < motes.length; i++) {
    final m = motes[i], lit = strength * firing[i];
    s.dot(
      m.p,
      Color.lerp(m.color, Colors.white, lit)!,
      m.size * (1 + lit * 0.7),
      m.alpha + lit * 0.9,
    );
  }
}
