import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_glyph.dart';

/// Debug-menu studies of a layered red and black reticle orb. Asleep, its
/// rings spread apart along a tilted axis; woken, the stack turns to face
/// the viewer and closes into one orb. All styles share one clock, so they
/// can be compared frame for frame, each at a showcase size and at chat and
/// spinner sizes.
class GaiaRedOrbStudies extends StatefulWidget {
  const GaiaRedOrbStudies({super.key});

  @override
  State<GaiaRedOrbStudies> createState() => _GaiaRedOrbStudiesState();
}

class _GaiaRedOrbStudiesState extends State<GaiaRedOrbStudies>
    with SingleTickerProviderStateMixin {
  final _clock = _Clock();
  late final Ticker _ticker = createTicker(_tick);
  var _last = Duration.zero;
  var _awake = false;
  var _cycle = false;
  var _sinceToggle = 0.0;
  var _centre = _Centre.none;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      _clock.wake = _awake ? 1 : 0;
      _clock.notify();
    }
    final run = !reduced && GaiaAmbient.of(context);
    if (run && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!run) {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    final dt = math.min((elapsed - _last).inMicroseconds / 1e6, 0.05);
    _last = elapsed;
    _clock.t += dt;
    _clock.pulse += dt;
    final step = dt / 1.1;
    _clock.wake = (_clock.wake + (_awake ? step : -step)).clamp(0.0, 1.0);
    if (_cycle) {
      _sinceToggle += dt;
      if (_sinceToggle > 3.4) {
        _sinceToggle = 0;
        setState(() => _awake = !_awake);
      }
    }
    _clock.notify();
  }

  void _pulse() => _clock.pulse = 0;

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  Widget _tile(_Style style) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: _pulse,
          child: Container(
            height: 220,
            width: double.infinity,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const RadialGradient(
                center: Alignment(0.25, -0.3),
                radius: 1.1,
                colors: [Color(0xFF0E1A27), _night],
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _OrbPainter(_clock, style, _centre, radius: 58),
                    ),
                  ),
                ),
                Positioned(
                  right: 12,
                  bottom: 10,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final side in const [48.0, 24.0, 16.0])
                        Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: SizedBox.square(
                            dimension: side,
                            child: CustomPaint(
                              painter: _OrbPainter(
                                _clock,
                                style,
                                _centre,
                                radius: side / 2 / 1.15,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(style.label, style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          style.description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Asleep, the rings spread apart and turn on their own. Woken, the '
          'stack swings round to face you and closes into one orb. Tap a '
          'preview to pulse it, as a click would. Bottom right: 48, 24 and '
          '16 px; the two smallest drop the fine layers.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IntrinsicWidth(
              child: GaiaButton(
                label: _awake ? 'Sleep' : 'Wake',
                icon: _awake ? Icons.bedtime_outlined : Icons.flare,
                onPressed: () => setState(() {
                  _awake = !_awake;
                  _sinceToggle = 0;
                  if (MediaQuery.disableAnimationsOf(context)) {
                    _clock.wake = _awake ? 1 : 0;
                    _clock.notify();
                  }
                }),
              ),
            ),
            IntrinsicWidth(
              child: GaiaButton(
                label: 'Pulse',
                icon: Icons.touch_app_outlined,
                onPressed: _pulse,
              ),
            ),
            FilterChip(
              label: const Text('Cycle'),
              selected: _cycle,
              onSelected: (value) => setState(() {
                _cycle = value;
                _sinceToggle = 0;
              }),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Centre when awake', style: theme.textTheme.bodySmall),
            for (final centre in _Centre.values)
              ChoiceChip(
                label: Text(centre.label),
                selected: _centre == centre,
                onSelected: (_) => setState(() => _centre = centre),
              ),
          ],
        ),
        for (final style in _Style.values) ...[
          const SizedBox(height: 12),
          _tile(style),
        ],
      ],
    );
  }
}

class _Clock extends ChangeNotifier {
  double t = 0;

  /// 0 asleep, 1 awake, moving linearly; the painter applies the curves.
  double wake = 0;

  /// Seconds since the last pulse.
  double pulse = 9;

  void notify() => notifyListeners();
}

enum _Centre {
  none('None'),
  core('Red core'),
  mark('Tier mark');

  const _Centre(this.label);
  final String label;
}

const _tau = 2 * math.pi;
const _red = Color(0xFFFF2D55);
const _redDim = Color(0xFFA3203A);
const _redDeep = Color(0xFF5A0718);
const _white = Color(0xFFEAF1FF);
const _blush = Color(0xFFFF9AAE);
const _slate = Color(0xFF7D8FA6);
const _night = Color(0xFF05060A);

enum _Look { ring, dashes, ticks }

/// One ring of the stack, in units of the orb's radius.
class _Layer {
  const _Layer(
    this.radius, {
    this.depth = 0,
    this.look = _Look.ring,
    this.color = _white,
    this.accent,
    this.width = 1.2,
    this.count = 0,
    this.sweep = 1,
    this.spin = 0,
    this.glow = false,
    this.fine = false,
  });

  final double radius;

  /// Where it sits along the axis while asleep.
  final double depth;
  final _Look look;
  final Color color;

  /// Every fifth tick, longer, in this colour.
  final Color? accent;
  final double width;

  /// Dashes or ticks round the ring.
  final int count;

  /// The share of the circle drawn: an arc, or each dash's share of its slot.
  final double sweep;

  /// Turning in its own plane, radians a second.
  final double spin;
  final bool glow;

  /// Dropped at small sizes.
  final bool fine;
}

const _reticleLayers = [
  _Layer(
    1.25,
    depth: 1.5,
    look: _Look.ticks,
    color: _slate,
    count: 60,
    spin: 0.15,
    fine: true,
  ),
  _Layer(
    1.32,
    depth: 1.5,
    color: _slate,
    width: 0.8,
    sweep: 0.7,
    spin: -0.1,
    fine: true,
  ),
  _Layer(
    1.05,
    depth: 0.8,
    look: _Look.dashes,
    count: 5,
    sweep: 0.55,
    width: 1.0,
    spin: -0.35,
    fine: true,
  ),
  _Layer(0.8, color: _red, width: 2.6, glow: true),
  _Layer(0.72, depth: -0.25, width: 1.3, sweep: 0.85, spin: 0.9),
  _Layer(
    0.94,
    depth: -0.8,
    look: _Look.dashes,
    count: 3,
    sweep: 0.7,
    width: 1.6,
    spin: 0.5,
  ),
  _Layer(
    0.66,
    depth: -1.4,
    look: _Look.dashes,
    count: 4,
    sweep: 0.4,
    color: _slate,
    width: 1.0,
    spin: -0.6,
    fine: true,
  ),
];

enum _Style {
  reticle(
    'Reticle',
    'The first one: a neon ring, white arcs and a tick dial threaded on a '
        'red axis, closing into a framed HUD.',
    layers: _reticleLayers,
  ),
  cascade(
    'Cascade',
    'Reticle\'s parts, but it twists a full turn as it wakes and the rings '
        'lock in one after another, front to back, each with a small '
        'overshoot.',
    layers: _reticleLayers,
    twist: _tau,
    stagger: 0.45,
    closeCurve: Curves.easeOutBack,
  ),
  instrument(
    'Instrument',
    'Denser and more technical: a fine and a coarse dial with red marks, a '
        'segmented outer track and red inner arcs. Crosshairs frame it awake.',
    layers: [
      _Layer(
        1.3,
        depth: 1.6,
        look: _Look.ticks,
        color: _slate,
        count: 90,
        spin: 0.08,
        fine: true,
      ),
      _Layer(
        1.2,
        depth: 1.6,
        look: _Look.ticks,
        color: _slate,
        accent: _red,
        count: 40,
        spin: -0.12,
        fine: true,
      ),
      _Layer(
        1.05,
        depth: 0.8,
        look: _Look.dashes,
        count: 12,
        sweep: 0.7,
        width: 1.0,
        spin: -0.3,
      ),
      _Layer(0.8, color: _red, width: 2.6, glow: true),
      _Layer(0.72, depth: -0.3, width: 1.3, sweep: 0.85, spin: 0.9),
      _Layer(
        0.58,
        depth: -0.9,
        look: _Look.dashes,
        count: 3,
        sweep: 0.35,
        color: _red,
        width: 1.6,
        spin: -1.1,
      ),
      _Layer(
        0.92,
        depth: -1.3,
        look: _Look.dashes,
        count: 3,
        sweep: 0.7,
        width: 1.6,
        spin: 0.5,
      ),
    ],
    crosshair: true,
  ),
  twin(
    'Twin dial',
    'Seen side on, with a tick dial at each end of the axis and the arcs '
        'mirrored about the neon ring. Awake, the two dials counter-rotate.',
    pose: (pitch: -0.12, yaw: 1.32, roll: -0.12),
    spread: 0.85,
    brackets: false,
    layers: [
      _Layer(
        1.22,
        depth: 1.6,
        look: _Look.ticks,
        color: _slate,
        accent: _red,
        count: 48,
        spin: 0.2,
        fine: true,
      ),
      _Layer(
        1.32,
        depth: -1.6,
        look: _Look.ticks,
        color: _slate,
        count: 72,
        spin: -0.15,
        fine: true,
      ),
      _Layer(
        1.0,
        depth: 1.0,
        look: _Look.dashes,
        count: 4,
        sweep: 0.6,
        width: 1.4,
        spin: 0.4,
      ),
      _Layer(
        1.08,
        depth: -1.0,
        look: _Look.dashes,
        count: 4,
        sweep: 0.6,
        width: 1.4,
        spin: -0.4,
        fine: true,
      ),
      _Layer(0.7, depth: 0.55, width: 1.2, sweep: 0.8, spin: 0.9),
      _Layer(0.7, depth: -0.55, width: 1.2, sweep: 0.8, spin: -0.9),
      _Layer(0.8, color: _red, width: 2.6, glow: true),
    ],
  ),
  thread(
    'Thread',
    'Pared back: one thin neon ring, one white arc and a dial, strung far '
        'apart on a long axis. Quiet, and the cleanest at small sizes.',
    pose: (pitch: -0.25, yaw: 1.15, roll: -0.55),
    spread: 1.0,
    axisLength: 2.7,
    layers: [
      _Layer(
        1.25,
        depth: 1.9,
        look: _Look.ticks,
        color: _slate,
        count: 40,
        spin: 0.15,
        fine: true,
      ),
      _Layer(0.8, color: _red, width: 1.8, glow: true),
      _Layer(0.9, depth: -1.0, width: 0.9, sweep: 0.6, spin: 0.7),
    ],
  ),
  crimson(
    'Crimson',
    'Reticle\'s shape in reds only: dim red dials and arcs round the one '
        'bright neon ring, with pink in place of white.',
    ink: _blush,
    layers: [
      _Layer(
        1.25,
        depth: 1.5,
        look: _Look.ticks,
        color: _redDim,
        accent: _red,
        count: 60,
        spin: 0.15,
        fine: true,
      ),
      _Layer(
        1.32,
        depth: 1.5,
        color: _redDim,
        width: 0.8,
        sweep: 0.7,
        spin: -0.1,
        fine: true,
      ),
      _Layer(
        1.05,
        depth: 0.8,
        look: _Look.dashes,
        count: 5,
        sweep: 0.55,
        color: _red,
        width: 1.0,
        spin: -0.35,
        fine: true,
      ),
      _Layer(0.8, color: _red, width: 2.8, glow: true),
      _Layer(
        0.72,
        depth: -0.25,
        color: _blush,
        width: 1.2,
        sweep: 0.85,
        spin: 0.9,
      ),
      _Layer(
        0.94,
        depth: -0.8,
        look: _Look.dashes,
        count: 3,
        sweep: 0.7,
        color: _redDim,
        width: 1.6,
        spin: 0.5,
      ),
      _Layer(
        0.66,
        depth: -1.4,
        look: _Look.dashes,
        count: 4,
        sweep: 0.4,
        color: _redDim,
        width: 1.0,
        spin: -0.6,
        fine: true,
      ),
    ],
  );

  const _Style(
    this.label,
    this.description, {
    required this.layers,
    this.pose = (pitch: -0.2, yaw: 1.0, roll: -0.5),
    this.spread = 0.9,
    this.axisLength = 2.1,
    this.twist = 0,
    this.stagger = 0,
    this.closeCurve = Curves.easeInCubic,
    this.brackets = true,
    this.crosshair = false,
    this.ink = _white,
  });

  final String label, description;
  final List<_Layer> layers;

  /// The stack's turn while asleep; awake it faces the viewer.
  final ({double pitch, double yaw, double roll}) pose;

  /// How far apart the layers sit while asleep.
  final double spread;

  /// The red axis's reach either side, in radii.
  final double axisLength;

  /// An extra roll taken while waking.
  final double twist;

  /// How much later the farthest layer closes than the nearest, as a share
  /// of the wake.
  final double stagger;
  final Curve closeCurve;
  final bool brackets, crosshair;

  /// The light colour: white, or a tint of the red.
  final Color ink;
}

double _ease(double value, double from, double to) =>
    Curves.easeOutCubic.transform(((value - from) / (to - from)).clamp(0, 1));

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.clock, this.style, this.centre, {required this.radius})
    : super(repaint: clock);

  final _Clock clock;
  final _Style style;
  final _Centre centre;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.t;
    final wake = clock.wake;
    final turn = Curves.easeInOutCubic.transform(wake);
    final open = 1 - turn;
    final fade = (1 - clock.pulse / 0.7).clamp(0.0, 1.0);
    final pulse = fade * fade;
    final detail = radius >= 20;
    final c = size.center(Offset.zero);
    final r = radius * (1 + 0.07 * pulse + 0.015 * turn * math.sin(t * 1.6));
    final unit = math.max(radius / 64, 0.5);
    final focal = r * 5;
    final pose = style.pose;
    final rotation = Matrix4.rotationZ(pose.roll * open + style.twist * turn)
      ..multiply(
        Matrix4.rotationY((pose.yaw + 0.12 * math.sin(t * 0.5)) * open),
      )
      ..multiply(
        Matrix4.rotationX((pose.pitch + 0.07 * math.sin(t * 0.37)) * open),
      );

    Offset project(Float64List m, double x, double y, double z) {
      final px = m[0] * x + m[4] * y + m[8] * z + m[12];
      final py = m[1] * x + m[5] * y + m[9] * z + m[13];
      final pz = m[2] * x + m[6] * y + m[10] * z + m[14];
      final s = focal / (focal + pz);
      return c + Offset(px * s, py * s);
    }

    // The layers hold apart while the stack turns, then close: all at once,
    // or nearest first when staggered.
    final depths = style.layers.map((layer) => layer.depth);
    final near = depths.reduce(math.min);
    final far = depths.reduce(math.max);
    double gap(_Layer layer) {
      final delay = style.stagger * (layer.depth - near) / (far - near);
      final close = style.closeCurve.transform(
        ((wake - delay) / (0.85 - style.stagger)).clamp(0.0, 1.0),
      );
      return layer.depth * style.spread * (1 - close) * r;
    }

    final placed = [
      for (final layer in style.layers)
        if (detail || !layer.fine)
          (
            layer: layer,
            m:
                (rotation.clone()
                      ..multiply(Matrix4.translationValues(0, 0, gap(layer))))
                    .storage,
          ),
    ];
    // Farthest first; when they meet, the larger beneath.
    placed.sort((a, b) {
      final byDepth = b.m[14].compareTo(a.m[14]);
      return byDepth != 0 ? byDepth : b.layer.radius.compareTo(a.layer.radius);
    });

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final (:layer, :m) in placed) {
      final rad = layer.radius * r;
      final start = layer.spin * t;
      final steps = detail ? 96 : 40;
      final path = Path();
      final accents = Path();
      void arc(double from, double sweep) {
        final n = math.max(4, (steps * sweep / _tau).ceil());
        for (var i = 0; i <= n; i++) {
          final a = from + sweep * i / n;
          final p = project(m, rad * math.cos(a), rad * math.sin(a), 0);
          if (i == 0) {
            path.moveTo(p.dx, p.dy);
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
      }

      switch (layer.look) {
        case _Look.ring:
          arc(start, layer.sweep * _tau);
        case _Look.dashes:
          for (var k = 0; k < layer.count; k++) {
            arc(
              start + k * _tau / layer.count,
              layer.sweep * _tau / layer.count,
            );
          }
        case _Look.ticks:
          for (var k = 0; k < layer.count; k++) {
            final a = start + k * _tau / layer.count;
            final major = k % 5 == 0;
            final inner = rad * (major ? 0.88 : 0.94);
            final p0 = project(m, rad * math.cos(a), rad * math.sin(a), 0);
            final p1 = project(m, inner * math.cos(a), inner * math.sin(a), 0);
            (major && layer.accent != null ? accents : path)
              ..moveTo(p0.dx, p0.dy)
              ..lineTo(p1.dx, p1.dy);
          }
      }
      final color = Color.lerp(layer.color, style.ink, pulse * 0.7)!;
      final width = layer.width * unit;
      if (layer.glow) {
        canvas.drawPath(
          path,
          paint
            ..color = color.withValues(alpha: 0.4)
            ..strokeWidth = width * (detail ? 3.5 : 2.4)
            ..maskFilter = detail
                ? MaskFilter.blur(BlurStyle.normal, 3.5 * unit)
                : null,
        );
        paint.maskFilter = null;
      }
      canvas.drawPath(
        path,
        paint
          ..color = color
          ..strokeWidth = width,
      );
      if (layer.accent case final accent?) {
        canvas.drawPath(
          accents,
          paint
            ..color = Color.lerp(accent, style.ink, pulse * 0.7)!
            ..strokeWidth = width * 1.4,
        );
      }
      if (layer.glow) {
        canvas.drawPath(
          path,
          paint
            ..color = style.ink.withValues(alpha: 0.55)
            ..strokeWidth = width * 0.35,
        );
      }
    }

    // The red spine through the stack, gone end on once it faces you.
    if (detail && open > 0.02) {
      final m = rotation.storage;
      final reach = style.axisLength * r;
      final a = project(m, 0, 0, -reach);
      final b = project(m, 0, 0, reach);
      canvas.drawLine(
        a,
        b,
        Paint()
          ..strokeWidth = 1.1 * unit
          ..shader = ui.Gradient.linear(
            a,
            b,
            [
              _red.withValues(alpha: 0),
              _red.withValues(alpha: 0.9 * open),
              _red.withValues(alpha: 0.9 * open),
              _red.withValues(alpha: 0),
            ],
            const [0, 0.3, 0.7, 1],
          ),
      );
    }

    // A streak of light across the middle while it turns.
    final streak = math.sin(math.pi * wake);
    if (detail && streak > 0.02) {
      final a = c - Offset(2.6 * r * streak, 0);
      final b = c + Offset(2.6 * r * streak, 0);
      for (final (color, width, alpha) in [
        (_red, 3.0, 0.35),
        (style.ink, 1.0, 0.9),
      ]) {
        canvas.drawLine(
          a,
          b,
          Paint()
            ..strokeWidth = width * unit
            ..shader = ui.Gradient.linear(
              a,
              b,
              [
                color.withValues(alpha: 0),
                color.withValues(alpha: alpha * streak),
                color.withValues(alpha: 0),
              ],
              const [0, 0.5, 1],
            ),
        );
      }
    }

    final framed = _ease(wake, 0.7, 1);
    if (detail && framed > 0) {
      if (style.brackets) {
        canvas.drawCircle(
          c,
          r * 1.42,
          paint
            ..color = _slate.withValues(alpha: 0.35 * framed)
            ..strokeWidth = unit,
        );
        final rect = Rect.fromCircle(center: c, radius: r * 1.36);
        for (var k = 0; k < 4; k++) {
          final a = math.pi / 4 + k * math.pi / 2 + 0.15 * t;
          canvas.drawArc(
            rect,
            a - 0.12,
            0.24,
            false,
            paint
              ..color = (k.isEven ? _red : style.ink).withValues(alpha: framed)
              ..strokeWidth = 1.6 * unit,
          );
        }
      }
      if (style.crosshair) {
        for (var k = 0; k < 4; k++) {
          final d = Offset(
            math.cos(k * math.pi / 2),
            math.sin(k * math.pi / 2),
          );
          canvas.drawLine(
            c + d * r * 1.48,
            c + d * r * (1.48 + 0.16 * framed),
            paint
              ..color = style.ink.withValues(alpha: 0.8 * framed)
              ..strokeWidth = 1.2 * unit,
          );
        }
      }
    }

    final shown = _ease(wake, 0.75, 1);
    if (shown > 0) {
      switch (centre) {
        case _Centre.none:
          break;
        case _Centre.core:
          final radius = r * 0.16 * (0.6 + 0.4 * shown) * (1 + 0.2 * pulse);
          canvas.drawCircle(
            c,
            radius,
            Paint()
              ..shader = RadialGradient(
                colors: [
                  Color.lerp(_red, _white, 0.75)!.withValues(alpha: shown),
                  _red.withValues(alpha: shown),
                  _redDeep.withValues(alpha: 0.5 * shown),
                  _redDeep.withValues(alpha: 0),
                ],
                stops: const [0, 0.3, 0.65, 1],
              ).createShader(Rect.fromCircle(center: c, radius: radius)),
          );
        case _Centre.mark when detail:
          paintGaiaTierGlyph(
            canvas,
            c,
            level: 2,
            color: style.ink.withValues(alpha: shown),
            phase: t,
            lit: pulse,
            scale: r * 0.4 / 6.4 * (0.7 + 0.3 * shown),
          );
        case _Centre.mark:
          break;
      }
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.clock != clock ||
      old.style != style ||
      old.centre != centre ||
      old.radius != radius;
}
