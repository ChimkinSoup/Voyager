import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:voyager/core/motion/ambient_clock.dart';
import 'package:voyager/core/motion/window_visibility.dart';
import 'package:voyager/features/life_tracker/weeping_cherry_geometry.dart';

/// The night tone the page's chrome is set in.
const weepingNightColor = Color(0xFF15131C);

/// The painting's pigments. Night is the original moonlit study; day is the
/// same tree on the cream page, its blossom deepened to hold against the
/// paper rather than glow out of the dark.
class _Palette {
  const _Palette({
    required this.skyWash,
    required this.skyPlum,
    required this.skyStrength,
    required this.halo,
    required this.groundColor,
    required this.woodColor,
    required this.woodCrevice,
    required this.woodLight,
    required this.barkStreak,
    required this.blossomFar,
    required this.blossomMid,
    required this.blossomNear,
    required this.petalLight,
    required this.petalHeart,
    required this.blossomLilac,
    required this.petalTones,
    required this.groundTint,
  });

  final Color skyWash;
  final Color skyPlum;

  /// Scales the sky washes' pigment — kept faint by day, where the page
  /// itself is the sky and heavy washes read as grey smudges.
  final double skyStrength;
  final Color halo;
  final Color groundColor;

  final Color woodColor;
  final Color woodCrevice;
  final Color woodLight;
  final Color barkStreak;

  /// Blossom ramp, far to near. Pools layer with plain source-over, which
  /// converges *toward* the pigment however many overlap — so the dense
  /// middle of the curtain settles on these tones instead of blowing out.
  final Color blossomFar;
  final Color blossomMid;
  final Color blossomNear;
  final Color petalLight;
  final Color petalHeart;
  final Color blossomLilac;

  /// The week petals' sprite tones, one row each.
  final List<Color> petalTones;

  /// Multiplied into a petal once it lies on the ground, as 0xRRGGBB.
  final int groundTint;
}

const _nightPalette = _Palette(
  skyWash: Color(0xFF242037),
  skyPlum: Color(0xFF2A1A2C),
  skyStrength: 1.0,
  halo: Color(0xFF3B3452),
  groundColor: Color(0xFF0D0B11),
  woodColor: Color(0xFF1B1520),
  woodCrevice: Color(0xFF060408),
  woodLight: Color(0xFFA79CB6),
  barkStreak: Color(0xFF453B4E),
  blossomFar: Color(0xFF6A3756),
  blossomMid: Color(0xFFC07892),
  blossomNear: Color(0xFFF0B3C6),
  petalLight: Color(0xFFFCDDE6),
  petalHeart: Color(0xFFC94E7C),
  blossomLilac: Color(0xFF9C7FB4),
  petalTones: [
    Color(0xFFF0B3C6),
    Color(0xFFFCDDE6),
    Color(0xFFF5C3D2),
    Color(0xFFE59AB2),
  ],
  groundTint: 0xB9A3B4,
);

const _dayPalette = _Palette(
  skyWash: Color(0xFFB7C6D6),
  skyPlum: Color(0xFFD9C3D3),
  skyStrength: 0.45,
  halo: Color(0xFFFFFFFF),
  groundColor: Color(0xFF7F8C6B),
  woodColor: Color(0xFF2E2226),
  woodCrevice: Color(0xFF120B0D),
  woodLight: Color(0xFFE6CDB4),
  barkStreak: Color(0xFF5C474B),
  blossomFar: Color(0xFF9A3563),
  blossomMid: Color(0xFFD4517D),
  blossomNear: Color(0xFFEE7398),
  petalLight: Color(0xFFFFB0C6),
  petalHeart: Color(0xFFA11D4D),
  blossomLilac: Color(0xFF8B55AC),
  petalTones: [
    Color(0xFFEE7398),
    Color(0xFFFFB0C6),
    Color(0xFFF593B1),
    Color(0xFFD65B83),
  ],
  groundTint: 0xE5899F,
);

/// Whether this app run has already played the weeks falling — per the
/// original Life Tracker design, the fall plays once per restart and every
/// later visit opens on the settled ground.
var _weekFallPlayed = false;

/// The window the weeks lived let go over. Not evenly: they go in waves that
/// follow the breeze — see [_detachCdf].
const _detachSpread = 5.5;

/// How long a petal takes to settle flat once it touches down.
const _settleTime = 0.35;

/// How long a petal takes to reach its falling speed after letting go.
const _launch = 0.25;

/// The breeze during the fall, in tree widths per second: a steady drift to
/// the right, a gust that builds through the middle of the shower, and a
/// quicker flurry over it. Closed-form, with [_windDrift] its integral, so a
/// petal's whole path — and so where it lands — is known the moment it lets
/// go, and the pile is the same on every later visit.
const _breeze = 0.035;

double _wind(double s) =>
    _breeze + 0.040 * math.sin(0.8 * s - 1.2) + 0.012 * math.sin(2.1 * s + 0.5);

/// How hard the idle breeze is gusting at [s], 0 in a lull to about 1.2 at a
/// peak. Periods that never line up, so it doesn't repeat on a beat, and
/// clipped at zero, so gusts come and go between stretches of near calm.
double _idleGust(double s) {
  final raw =
      0.15 +
      0.5 * math.sin(0.29 * s) +
      0.3 * math.sin(0.61 * s + 2.0) +
      0.2 * math.sin(1.13 * s + 4.1);
  return math.pow(math.max(raw, 0), 1.5).toDouble();
}

/// How one band of the curtain answers the wind: how readily it gives, and
/// the swing of its whips — longer ones slower.
class _BandSway {
  _BandSway(math.Random r)
    : give = 0.75 + r.nextDouble() * 0.5,
      rate = 1.3 + r.nextDouble() * 1.1,
      phase = r.nextDouble() * math.pi * 2,
      flutter = 2.8 + r.nextDouble() * 1.4,
      flutterPhase = r.nextDouble() * math.pi * 2;

  final double give;
  final double rate;
  final double phase;
  final double flutter;
  final double flutterPhase;
}

/// By band, back then front layer.
final _bandSways = [
  for (var i = 0; i < weepingBandCount * 2; i++) _BandSway(math.Random(i + 41)),
];

/// How far the breeze carries something between [a] and [b].
double _windDrift(double a, double b) =>
    _breeze * (b - a) -
    0.040 / 0.8 * (math.cos(0.8 * b - 1.2) - math.cos(0.8 * a - 1.2)) -
    0.012 / 2.1 * (math.cos(2.1 * b + 0.5) - math.cos(2.1 * a + 0.5));

/// Share of the weeks lived that have let go by each of 256 steps across
/// [_detachSpread]. Petals tear loose when the wind pulls hardest, so the
/// rate follows the wind's force (its square), eased in and out so the
/// shower starts and ends on a few stragglers.
final _detachCdf = () {
  const steps = 256;
  final cdf = Float64List(steps + 1);
  for (var i = 1; i <= steps; i++) {
    final s = (i - 0.5) / steps * _detachSpread;
    final w = _wind(s);
    cdf[i] =
        cdf[i - 1] +
        w * w * math.pow(math.sin(math.pi * s / _detachSpread), 0.7);
  }
  for (var i = 1; i <= steps; i++) {
    cdf[i] /= cdf[steps];
  }
  return cdf;
}();

/// The share of petals that have let go [s] seconds into the fall.
double _detachedBy(double s) {
  final f = (s / _detachSpread).clamp(0.0, 1.0) * (_detachCdf.length - 1);
  final i = f.floor().clamp(0, _detachCdf.length - 2);
  return _detachCdf[i] + (_detachCdf[i + 1] - _detachCdf[i]) * (f - i);
}

/// When the petal at [share] of the way through the order lets go — the
/// inverse of [_detachedBy].
double _detachTimeFor(double share) {
  var lo = 0;
  var hi = _detachCdf.length - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    _detachCdf[mid] < share ? lo = mid : hi = mid;
  }
  final span = _detachCdf[hi] - _detachCdf[lo];
  final f = span == 0 ? 0.0 : (share - _detachCdf[lo]) / span;
  return (lo + f) / (_detachCdf.length - 1) * _detachSpread;
}

/// One lived week's way down, in tree space.
///
/// A petal is too light to fall like a stone: it reaches a slow terminal
/// speed almost at once and spends the rest of the drop being pushed about.
/// Most flutter — swinging side to side like a pendulum, tilting with each
/// swing, dropping fastest through the bottom of the arc and all but hanging
/// at its ends. The rest tumble end over end, which falls straighter and
/// faster. Either way the breeze carries it, and it lands wherever that
/// takes it.
class _Flight {
  _Flight(int index, WeekPetal petal, this.detach) : start = petal.position {
    final r = math.Random(index * 7919 + 101);
    tumbles = r.nextDouble() < 0.35;
    speed = (0.13 + r.nextDouble() * 0.06) * (tumbles ? 1.35 : 1.0);
    amplitude = (0.010 + r.nextDouble() * 0.018) * (tumbles ? 0.3 : 1.0);
    omega = 2.2 + r.nextDouble() * 1.4;
    phase = r.nextDouble() * math.pi * 2;
    spin = (3 + r.nextDouble() * 4) * (r.nextBool() ? 1 : -1);
    flip = 3 + r.nextDouble() * 3.5;
    catchesWind = tumbles
        ? 0.6 + r.nextDouble() * 0.3
        : 0.9 + r.nextDouble() * 0.4;
    rotation0 = petal.rotation;
    final groundY = weepingGroundY + 0.003 + r.nextDouble() * 0.042;

    // March down to the ground and pin the moment of touchdown. The swing
    // can lift a petal briefly at the end of an arc, so this steps rather
    // than assuming the drop is monotonic.
    const dt = 1 / 60;
    var tau = 0.0;
    while (y(tau + dt) < groundY && tau < 30) {
      tau += dt;
    }
    var lo = tau;
    var hi = tau + dt;
    for (var k = 0; k < 20; k++) {
      final mid = (lo + hi) / 2;
      y(mid) < groundY ? lo = mid : hi = mid;
    }
    landTime = hi;
    landing = Offset(x(landTime), groundY);
    landRotation = rotationAt(landTime);
    landSquash = squashAt(landTime);

    // Lying on the ground, seen from nearly level with it: it settles to
    // point along the ground, so the sprite's narrowing reads as the petal
    // foreshortened flat rather than standing on edge.
    final turns = ((landRotation - math.pi / 2) / math.pi).roundToDouble();
    groundRotation =
        math.pi / 2 + turns * math.pi + (r.nextDouble() - 0.5) * 0.7;
    groundSquash = 2 + r.nextInt(2);
  }

  final double detach;
  final Offset start;
  late final bool tumbles;
  late final double speed;
  late final double amplitude;
  late final double omega;
  late final double phase;
  late final double spin;
  late final double flip;
  late final double catchesWind;
  late final double rotation0;

  late final double landTime;
  late final Offset landing;
  late final double landRotation;
  late final double landSquash;
  late final double groundRotation;
  late final int groundSquash;

  double get end => detach + landTime + _settleTime;

  /// 0 as it lets go, 1 once it's up to speed and swinging fully.
  double _ramp(double tau, double over) => 1 - math.exp(-tau / over);

  double y(double tau) {
    final drop = speed * (tau - _launch * _ramp(tau, _launch));
    if (tumbles) return start.dy + drop;
    final theta = omega * tau + phase;
    return start.dy +
        drop +
        _ramp(tau, 0.6) *
            0.55 *
            speed /
            (2 * omega) *
            (math.sin(2 * theta) - math.sin(2 * phase));
  }

  double x(double tau) =>
      start.dx +
      catchesWind * _windDrift(detach, detach + tau) +
      _ramp(tau, 0.6) * amplitude * math.sin(omega * tau + phase);

  double rotationAt(double tau) {
    if (tumbles) return rotation0 + spin * tau;
    // Leans into each swing, and slowly comes round as it goes.
    return rotation0 +
        _ramp(tau, 0.6) * 0.75 * math.cos(omega * tau + phase) +
        0.25 * tau * spin.sign;
  }

  /// Sprite squash, fractional: face-on at 0 through edge-on at the last
  /// level.
  double squashAt(double tau) {
    if (tumbles) {
      return (1 - math.cos(flip * tau).abs()) * (petalSquashLevels - 1);
    }
    // Tilted furthest, and so most edge-on, at the ends of each swing.
    return _ramp(tau, 0.6) *
        math.sin(omega * tau + phase).abs() *
        (petalSquashLevels - 2);
  }
}

/// Weeping cherry painted as watercolour — a night study, or by day the same
/// tree in deeper pigment for the cream page. Everything except the sway and
/// the petals is baked to images once per size; see [_Scene].
///
/// One petal per week of an 80-year life hangs on the curtain. The weeks
/// already lived ([weeksLived]) lie on the ground, and the first time the tree
/// is shown in an app run they fall there, the canopy thinning as they go.
class WeepingCherryCanvas extends StatefulWidget {
  const WeepingCherryCanvas({
    super.key,
    required this.weeksLived,
    this.replayCount = 0,
    this.brightness = Brightness.dark,
    this.pointer,
  });

  /// Null while it isn't known yet — the tree waits to fall until it is.
  final int? weeksLived;

  /// Bumped to play the fall again.
  final int replayCount;

  /// Picks the night or day palette.
  final Brightness brightness;

  /// Where the pointer is over the canvas, null while it's elsewhere. The
  /// curtain and the drifting petals give way where it moves through them.
  final ValueListenable<Offset?>? pointer;

  @override
  State<WeepingCherryCanvas> createState() => _WeepingCherryCanvasState();
}

class _WeepingCherryCanvasState extends State<WeepingCherryCanvas>
    with WindowVisibility<WeepingCherryCanvas> {
  static final _geometry = generateWeepingCherryGeometry();

  /// Advanced by the shared [AmbientClock] at about 60fps rather than by a
  /// [Ticker], which would ask for a frame on every vsync — and every frame
  /// re-rasterizes the whole window, so on a 120Hz display that doubles the
  /// page's GPU load for a sway nobody can tell apart from 60. The pause a
  /// Ticker would give for free with its tab or a hidden window is done by
  /// hand.
  var _subscribed = false;
  var _tickerModeEnabled = true;
  final _time = ValueNotifier<double>(0);

  /// The vsync time of the last frame; null until the first since starting.
  double? _lastTick;

  _Scene? _scene;
  Timer? _resizeSettle;

  /// Whether [_scene] was baked for the other brightness. Re-baking is a few
  /// hundred milliseconds on the UI thread, so a theme change made while the
  /// tree is out of sight waits until it's next in sight.
  var _sceneStale = false;
  _Palette get _palette =>
      widget.brightness == Brightness.light ? _dayPalette : _nightPalette;

  late var _petals = _FallingPetal.generate(_palette);
  late var _sprites = _petalSprites(_palette);
  late final _wake = _PointerWake(_petals.length);

  static final Future<ui.FragmentProgram?> _crossfadeProgram =
      ui.FragmentProgram.fromAsset(
        'shaders/weeping_crossfade.frag',
      ).then<ui.FragmentProgram?>((p) => p, onError: (Object _) => null);

  /// Null until loaded — or if it never does, when the crossfade falls back
  /// to offscreen layers.
  ui.FragmentProgram? _program;

  int _weeks = 0;
  List<int> _lived = const [];

  /// Each lived petal's way down, by petal index; null for the rest.
  List<_Flight?> _flights = List.filled(_geometry.weekPetals.length, null);

  /// When the last of [_flights] has landed and settled, from the fall's
  /// start.
  double _fallEnd = 0;

  /// On [_time]'s clock. Null when nothing is falling. The clock only runs
  /// while the ticker does, so a page warmed up or mounted out of sight
  /// doesn't spend the fall before anyone sees it.
  double? _fallStart;

  @override
  void initState() {
    super.initState();
    _syncAnimation();
    _applyWeeks();
    _crossfadeProgram.then((program) {
      if (mounted && program != null) setState(() => _program = program);
    });
  }

  @override
  void didUpdateWidget(WeepingCherryCanvas old) {
    super.didUpdateWidget(old);
    if (old.weeksLived != widget.weeksLived) _applyWeeks();
    if (old.brightness != widget.brightness) {
      _sprites.dispose();
      _sprites = _petalSprites(_palette);
      _petals = _FallingPetal.generate(_palette);
      _sceneStale = true;
      _resizeSettle?.cancel();
    }
    if (old.replayCount != widget.replayCount && _weeks > 0) {
      _fallStart = _time.value;
    }
  }

  @override
  void dispose() {
    AmbientClock.instance.unsubscribe(_tick);
    _resizeSettle?.cancel();
    _scene?.dispose();
    _sprites.dispose();
    _time.dispose();
    super.dispose();
  }

  void _applyWeeks() {
    final weeks = widget.weeksLived;
    if (weeks == null) return;
    _weeks = weeks;
    _lived = _geometry.livedPetals(weeks);
    // Shuffled, so neighbours on the tree don't let go in sequence around
    // the crown.
    final order = [..._lived]..shuffle(math.Random(17));
    final flights = List<_Flight?>.filled(_geometry.weekPetals.length, null);
    var fallEnd = 0.0;
    for (var rank = 0; rank < order.length; rank++) {
      final i = order[rank];
      final flight = _Flight(
        i,
        _geometry.weekPetals[i],
        _detachTimeFor((rank + 0.5) / order.length),
      );
      flights[i] = flight;
      fallEnd = math.max(fallEnd, flight.end);
    }
    _flights = flights;
    _fallEnd = fallEnd;
    if (!_weekFallPlayed && weeks > 0) {
      _weekFallPlayed = true;
      _fallStart = _time.value;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled == _tickerModeEnabled) return;
    _tickerModeEnabled = enabled;
    _syncAnimation();
  }

  @override
  void onWindowVisibilityChanged() {
    _syncAnimation();
    if (_sceneStale && _subscribed) setState(() {});
  }

  void _syncAnimation() {
    final run = _tickerModeEnabled && windowVisible;
    if (run == _subscribed) return;
    _subscribed = run;
    if (run) {
      _lastTick = null;
      AmbientClock.instance.subscribe(_tick);
    } else {
      AmbientClock.instance.unsubscribe(_tick);
    }
  }

  void _tick(Duration timeStamp) {
    final now = timeStamp.inMicroseconds / 1e6;
    final last = _lastTick;
    // Accumulated, so resuming after a pause doesn't jump the cycle.
    if (last != null) _time.value += math.min(math.max(now - last, 0), 0.1);
    _lastTick = now;
    final start = _fallStart;
    if (start != null && _time.value - start > _fallEnd) {
      setState(() {
        _fallStart = null;
        _scene?.dropFull();
      });
    }
  }

  /// How much of its pigment each pool keeps: a pool fades with the share of
  /// its petals that have fallen, down to a quarter so the wood never stands
  /// fully bare.
  List<double> _clusterFade() {
    final total = List<int>.filled(_geometry.clusters.length, 0);
    final lost = List<int>.filled(_geometry.clusters.length, 0);
    for (final petal in _geometry.weekPetals) {
      total[petal.cluster]++;
    }
    for (final i in _lived) {
      lost[_geometry.weekPetals[i].cluster]++;
    }
    return [
      for (var c = 0; c < total.length; c++)
        total[c] == 0 ? 1.0 : 1 - 0.75 * lost[c] / total[c],
    ];
  }

  _Scene _bake(Size size, double dpr) {
    _sceneStale = false;
    return _Scene.bake(
      _geometry,
      size,
      dpr,
      weeks: _weeks,
      fade: _clusterFade(),
      withFull: _fallStart != null,
      palette: _palette,
    );
  }

  _Scene _sceneFor(Size size, double dpr) {
    final scene = _scene;
    if (scene == null ||
        scene.weeks != _weeks ||
        (_sceneStale && _subscribed)) {
      scene?.dispose();
      return _scene = _bake(size, dpr);
    }
    if (_fallStart != null && !scene.hasFull) scene.bakeFull(_geometry);
    if (scene.size != size || scene.dpr != dpr) {
      // Baking is a few hundred milliseconds of blur and path work, so a
      // window drag keeps the old bake (stretched) and re-bakes once it stops.
      _resizeSettle?.cancel();
      _resizeSettle = Timer(const Duration(milliseconds: 250), () {
        if (!mounted) return;
        setState(() {
          _scene?.dispose();
          _scene = _bake(size, dpr);
        });
      });
    }
    return scene;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size.isEmpty) return const SizedBox.shrink();
        final scene = _sceneFor(size, MediaQuery.devicePixelRatioOf(context));
        final program = _program;
        if (program != null) scene.prepareCrossfade(program);
        return RepaintBoundary(
          child: CustomPaint(
            size: size,
            isComplex: true,
            willChange: true,
            painter: _WeepingCherryPainter(
              scene: scene,
              geometry: _geometry,
              petals: _petals,
              sprites: _sprites,
              palette: _palette,
              flights: _flights,
              fallStart: _fallStart,
              fallEnd: _fallEnd,
              time: _time,
              wake: _wake,
              pointer: widget.pointer,
            ),
          ),
        );
      },
    );
  }
}

/// Where [treePoint] (in tree space) lands on a [WeepingCherryCanvas] of
/// [size] — for laying things over the painting.
Offset weepingCanvasPoint(Offset treePoint, Size size) =>
    _Frame(size).map(treePoint);

/// The trunk's outline on a [WeepingCherryCanvas] of [size], up to the fork.
Path weepingTrunkPath(Size size) =>
    _limbPath(_WeepingCherryCanvasState._geometry.limbs.first, _Frame(size));

/// Maps tree space onto a canvas: scaled by height, centred, ground near the
/// bottom.
class _Frame {
  _Frame(Size size)
    : scale = math.min(size.height * 0.86, size.width / 1.5),
      origin = Offset(size.width / 2, 0) {
    top = size.height - weepingGroundY * scale - size.height * 0.06;
  }

  final double scale;
  final Offset origin;
  late final double top;

  Offset map(Offset p) => Offset(origin.dx + p.dx * scale, top + p.dy * scale);
}

class _BandImage {
  _BandImage(this.band, this.image, this.rect, this.pivotY);

  final int band;
  final ui.Image image;

  /// Where the image goes, in logical canvas pixels.
  final Rect rect;
  final double pivotY;
}

/// The baked painting: night stock and ground in [background], the wood in
/// [wood], and the blossom split into swaying vertical bands, behind and in
/// front of the trunk — thinned for the weeks lived, plus, while the weeks
/// are falling, the unthinned canopy it crossfades from.
class _Scene {
  _Scene._(
    this.palette,
    this.size,
    this.dpr,
    this.weeks,
    this.background,
    this.wood,
    this.woodRect,
    this.back,
    this.front,
    this.fullBack,
    this.fullFront,
  );

  factory _Scene.bake(
    WeepingCherryGeometry g,
    Size size,
    double dpr, {
    required int weeks,
    required List<double> fade,
    required bool withFull,
    required _Palette palette,
  }) {
    final scale = math.min(dpr, 2.0);
    final frame = _Frame(size);
    return _withGrain((grainShader) {
      final background = _rasterize(
        Offset.zero & size,
        scale,
        (canvas) => _paintNight(canvas, size, frame, grainShader, palette),
      );

      var woodBounds = Rect.zero;
      for (final limb in g.limbs) {
        for (final p in limb.points) {
          woodBounds = woodBounds.isEmpty
              ? Rect.fromCircle(center: frame.map(p), radius: 1)
              : woodBounds.expandToInclude(
                  Rect.fromCircle(center: frame.map(p), radius: 1),
                );
        }
      }
      woodBounds = woodBounds.inflate(frame.scale * 0.06);
      final wood = _rasterize(
        woodBounds,
        scale,
        (canvas) => _paintWood(canvas, g, frame, grainShader, palette),
      );

      final full = withFull && weeks > 0;

      return _Scene._(
        palette,
        size,
        dpr,
        weeks,
        background,
        wood,
        woodBounds,
        _bakeBands(g, frame, scale, false, grainShader, fade, palette),
        _bakeBands(g, frame, scale, true, grainShader, fade, palette),
        full
            ? _bakeBands(g, frame, scale, false, grainShader, null, palette)
            : null,
        full
            ? _bakeBands(g, frame, scale, true, grainShader, null, palette)
            : null,
      );
    });
  }

  final _Palette palette;
  final Size size;
  final double dpr;
  final int weeks;
  final ui.Image background;
  final ui.Image wood;
  final Rect woodRect;
  final List<_BandImage> back;
  final List<_BandImage> front;
  List<_BandImage>? fullBack;
  List<_BandImage>? fullFront;

  /// Whether the unthinned canopy is here to crossfade from. With no weeks
  /// lived there is nothing to thin, so the thinned one stands in for it.
  bool get hasFull => weeks == 0 || fullBack != null;

  /// The settled petals on the ground, baked once nothing is falling — they
  /// never move again, so there's no call to lay out a sprite for every one
  /// of them each frame.
  ui.Image? groundPile;
  Rect groundPileRect = Rect.zero;

  /// One crossfade shader per band of [back] and [front], holding its
  /// thinned and unthinned bakes. Null while there's nothing to crossfade or
  /// the shader hasn't loaded.
  List<ui.FragmentShader>? backFades;
  List<ui.FragmentShader>? frontFades;

  /// Bakes just the unthinned canopy for a replay — the rest of the bake
  /// still holds, and redoing it is a few hundred milliseconds of blur work.
  void bakeFull(WeepingCherryGeometry g) {
    final frame = _Frame(size);
    final scale = math.min(dpr, 2.0);
    _withGrain((grainShader) {
      fullBack = _bakeBands(g, frame, scale, false, grainShader, null, palette);
      fullFront = _bakeBands(g, frame, scale, true, grainShader, null, palette);
    });
  }

  void prepareCrossfade(ui.FragmentProgram program) {
    final fullBack = this.fullBack;
    final fullFront = this.fullFront;
    if (fullBack == null || fullFront == null || backFades != null) return;
    // A shader each, since every band needs its own rect and images at once.
    List<ui.FragmentShader> fades(
      List<_BandImage> thin,
      List<_BandImage> full,
    ) => [
      for (var i = 0; i < thin.length; i++)
        program.fragmentShader()
          ..setFloat(0, thin[i].rect.left)
          ..setFloat(1, thin[i].rect.top)
          ..setFloat(2, thin[i].rect.width)
          ..setFloat(3, thin[i].rect.height)
          ..setImageSampler(0, full[i].image, filterQuality: FilterQuality.low)
          ..setImageSampler(1, thin[i].image, filterQuality: FilterQuality.low),
    ];
    backFades = fades(back, fullBack);
    frontFades = fades(front, fullFront);
  }

  /// Releases the unthinned canopy once the fall has settled — it's only
  /// needed for the crossfade.
  void dropFull() {
    for (final fade in [...?backFades, ...?frontFades]) {
      fade.dispose();
    }
    for (final band in [...?fullBack, ...?fullFront]) {
      band.image.dispose();
    }
    backFades = null;
    frontFades = null;
    fullBack = null;
    fullFront = null;
  }

  void dispose() {
    background.dispose();
    wood.dispose();
    groundPile?.dispose();
    for (final band in [...back, ...front]) {
      band.image.dispose();
    }
    dropFull();
  }
}

/// Runs [bake] with the paper grain as a tiling shader, freed afterwards.
T _withGrain<T>(T Function(Shader grain) bake) {
  final grain = _grainImage();
  final grainShader = ui.ImageShader(
    grain,
    TileMode.repeated,
    TileMode.repeated,
    Matrix4.identity().storage,
  );
  final result = bake(grainShader);
  grainShader.dispose();
  grain.dispose();
  return result;
}

List<_BandImage> _bakeBands(
  WeepingCherryGeometry g,
  _Frame frame,
  double scale,
  bool front,
  Shader grain,
  List<double>? fade,
  _Palette p,
) => [
  for (var b = 0; b < weepingBandCount; b++)
    ?_bakeBand(g, frame, scale, b, front, grain, fade, p),
];

ui.Image _rasterize(Rect rect, double scale, void Function(Canvas) paint) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);
  canvas.translate(-rect.left, -rect.top);
  paint(canvas);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(
    math.max(1, (rect.width * scale).ceil()),
    math.max(1, (rect.height * scale).ceil()),
  );
  picture.dispose();
  return image;
}

/// A tile of paper tooth: specks of varying strength, used both to lift the
/// night stock and, knocked out of the pigment, as granulation.
ui.Image _grainImage() {
  const extent = 160;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rand = math.Random(4411);
  final paint = Paint();
  for (var i = 0; i < 2600; i++) {
    paint.color = Color.fromRGBO(255, 255, 255, 0.05 + rand.nextDouble() * 0.5);
    canvas.drawCircle(
      Offset(rand.nextDouble() * extent, rand.nextDouble() * extent),
      0.3 + rand.nextDouble() * 0.9,
      paint,
    );
  }
  final picture = recorder.endRecording();
  final image = picture.toImageSync(extent, extent);
  picture.dispose();
  return image;
}

/// An irregular, lobed outline — the hard, cauliflowered edge watercolour
/// dries to.
Path _blob(Offset c, double r, math.Random rand, {double wobble = 0.22}) {
  const steps = 22;
  final phases = [for (var i = 0; i < 3; i++) rand.nextDouble() * math.pi * 2];
  final squash = 0.75 + rand.nextDouble() * 0.4;
  final turn = rand.nextDouble() * math.pi;
  final points = <Offset>[];
  for (var i = 0; i < steps; i++) {
    final a = i / steps * math.pi * 2;
    final k =
        1 +
        wobble *
            (0.5 * math.sin(2 * a + phases[0]) +
                0.3 * math.sin(5 * a + phases[1]) +
                0.2 * math.sin(9 * a + phases[2]));
    final local = Offset(math.cos(a) * r * k, math.sin(a) * r * k * squash);
    points.add(
      c +
          Offset(
            local.dx * math.cos(turn) - local.dy * math.sin(turn),
            local.dx * math.sin(turn) + local.dy * math.cos(turn),
          ),
    );
  }
  final start = Offset.lerp(points.last, points.first, 0.5)!;
  final path = Path()..moveTo(start.dx, start.dy);
  for (var i = 0; i < steps; i++) {
    final m = Offset.lerp(points[i], points[(i + 1) % steps], 0.5)!;
    path.quadraticBezierTo(points[i].dx, points[i].dy, m.dx, m.dy);
  }
  return path..close();
}

/// The sky and ground the tree stands in. No opaque stock: the washes lie
/// straight over the app's own background.
void _paintNight(
  Canvas canvas,
  Size size,
  _Frame frame,
  Shader grain,
  _Palette p,
) {
  final rect = Offset.zero & size;

  // Moonlit haze behind the crown, so the dark wood has something to stand
  // against.
  final crown = frame.map(const Offset(-0.05, 0.30));
  canvas.drawCircle(
    crown,
    frame.scale * 0.75,
    Paint()
      ..shader = ui.Gradient.radial(crown, frame.scale * 0.75, [
        p.halo.withValues(alpha: 0.55),
        p.halo.withValues(alpha: 0.0),
      ]),
  );

  // Loose sky washes with dried edges: big, faint, overlapping.
  final rand = math.Random(77);
  for (var i = 0; i < 16; i++) {
    final c = Offset(
      rand.nextDouble() * size.width,
      rand.nextDouble() * size.height * 0.75,
    );
    final r = size.shortestSide * (0.18 + rand.nextDouble() * 0.25);
    final color = rand.nextBool() ? p.skyWash : p.skyPlum;
    final path = _blob(c, r, rand, wobble: 0.16);
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(
          alpha: (0.16 + rand.nextDouble() * 0.12) * p.skyStrength,
        )
        ..maskFilter = rand.nextDouble() < 0.5
            ? ui.MaskFilter.blur(ui.BlurStyle.normal, r * 0.12)
            : null,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.22 * p.skyStrength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  // Ground: a dark wash with a ragged top edge running the full width.
  final groundY = frame.map(const Offset(0, weepingGroundY)).dy;
  final ground = Path()..moveTo(-10, groundY);
  for (var x = -10.0; x <= size.width + 20; x += 18) {
    ground.lineTo(
      x,
      groundY -
          frame.scale * 0.012 +
          math.sin(x * 0.013) * frame.scale * 0.006 +
          rand.nextDouble() * frame.scale * 0.006,
    );
  }
  ground
    ..lineTo(size.width + 20, size.height + 10)
    ..lineTo(-10, size.height + 10)
    ..close();
  canvas.drawPath(
    ground,
    Paint()
      ..color = p.groundColor.withValues(alpha: 0.85)
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 2),
  );

  // Blossom glow pooled on the ground under the curtain.
  final pool = frame.map(const Offset(0, weepingGroundY + 0.015));
  canvas.drawOval(
    Rect.fromCenter(
      center: pool,
      width: frame.scale * 1.5,
      height: frame.scale * 0.07,
    ),
    Paint()
      ..color = p.blossomFar.withValues(alpha: 0.35)
      ..maskFilter = ui.MaskFilter.blur(
        ui.BlurStyle.normal,
        frame.scale * 0.02,
      ),
  );

  canvas.drawRect(
    rect,
    Paint()
      ..shader = grain
      ..color = const Color(0x0FFFFFFF)
      ..blendMode = BlendMode.plus,
  );
}

/// A tapered ribbon along a limb's centre line, with a rounded tip.
Path _limbPath(CherryLimb limb, _Frame frame) {
  final pts = [for (final p in limb.points) frame.map(p)];
  final left = <Offset>[];
  final right = <Offset>[];
  for (var i = 0; i < pts.length; i++) {
    final a = pts[math.max(0, i - 1)];
    final b = pts[math.min(pts.length - 1, i + 1)];
    final d = b - a;
    final n = Offset(-d.dy, d.dx) / d.distance;
    // Knuckles and swellings, so the wood isn't a clean extruded tube.
    final half =
        limb.widths[i] *
        frame.scale /
        2 *
        (1 +
            // The trunk only swells faintly; at its width a full knuckle
            // reads as a lumpy outline rather than wood.
            (limb.widths.first > 0.06 ? 0.02 : 0.07) *
                math.sin(i * 0.9 + limb.points.first.dx * 40));
    left.add(pts[i] + n * half);
    right.add(pts[i] - n * half);
  }
  final path = Path()..moveTo(left.first.dx, left.first.dy);
  for (final p in left.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  final tip = pts.last;
  path.quadraticBezierTo(
    tip.dx + (tip - pts[pts.length - 2]).dx,
    tip.dy + (tip - pts[pts.length - 2]).dy,
    right.last.dx,
    right.last.dy,
  );
  for (final p in right.reversed.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  path.close();
  // A round base, so every fork closes over without a notch. Not at the
  // ground, where the trunk and roots start buried and a cap would bulge out
  // under them.
  if (limb.points.first.dy > weepingGroundY - 0.05) return path;
  path.addOval(
    Rect.fromCircle(
      center: pts.first,
      radius: limb.widths.first * frame.scale / 2,
    ),
  );
  return path;
}

/// The wood: one opaque silhouette composited once (so overlaps at forks
/// don't double up), with moonlight along its upper-left edge, bark streaks
/// and granulation painted only where wood already is.
void _paintWood(
  Canvas canvas,
  WeepingCherryGeometry g,
  _Frame frame,
  Shader grain,
  _Palette p,
) {
  final paths = [for (final limb in g.limbs) _limbPath(limb, frame)];
  final bounds = paths
      .map((p) => p.getBounds())
      .reduce((a, b) => a.expandToInclude(b))
      .inflate(frame.scale * 0.02);

  // Damp halo where the ink crept into the paper.
  canvas.saveLayer(bounds, Paint()..color = const Color(0x55000000));
  final bleed = Paint()
    ..color = p.woodColor
    ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, frame.scale * 0.004);
  for (final path in paths) {
    canvas.drawPath(path, bleed);
  }
  canvas.restore();

  canvas.saveLayer(bounds, Paint()..color = const Color(0xF0FFFFFF));
  final body = Paint()..color = p.woodColor;
  for (final path in paths) {
    canvas.drawPath(path, body);
  }

  final rand = math.Random(31);
  final mark = Paint()
    ..strokeCap = StrokeCap.round
    ..blendMode = BlendMode.srcATop;
  for (final limb in g.limbs) {
    final pts = [for (final p in limb.points) frame.map(p)];
    Offset normalAt(int i) {
      final d = pts[math.min(i + 1, pts.length - 1)] - pts[math.max(i - 1, 0)];
      return Offset(-d.dy, d.dx) / d.distance;
    }

    for (var i = 0; i < pts.length; i++) {
      final half = limb.widths[i] * frame.scale / 2;
      if (half < 3) break;
      final n = normalAt(i);

      // Mottled pigment: the wash pooled darker and lighter as it dried.
      if (rand.nextDouble() < 0.5) {
        mark
          ..style = PaintingStyle.fill
          ..color = (rand.nextBool() ? p.barkStreak : p.woodCrevice).withValues(
            alpha: 0.18 + rand.nextDouble() * 0.2,
          )
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, half * 0.25);
        canvas.drawPath(
          _blob(
            pts[i] + n * (rand.nextDouble() - 0.5) * half,
            half * (0.4 + rand.nextDouble() * 0.5),
            rand,
          ),
          mark,
        );
      }

      // Lenticels — the horizontal bands that make cherry bark read as
      // cherry. Short dashes across the grain rather than along it.
      final dashes = (half / 6).ceil();
      for (var k = 0; k < dashes; k++) {
        if (rand.nextDouble() < 0.45) continue;
        final across = (rand.nextDouble() - 0.5) * 1.5 * half;
        final length = half * (0.15 + rand.nextDouble() * 0.35);
        final at = pts[i] + n * across;
        mark
          ..style = PaintingStyle.stroke
          ..maskFilter = null
          ..strokeWidth = math.max(
            0.7,
            half * (0.03 + rand.nextDouble() * 0.04),
          )
          ..color = (rand.nextDouble() < 0.6 ? p.barkStreak : p.woodCrevice)
              .withValues(alpha: 0.35 + rand.nextDouble() * 0.35);
        canvas.drawLine(at - n * length / 2, at + n * length / 2, mark);
      }
    }
  }

  // Moonlight from the upper left. Painted as the whole silhouette minus a
  // copy of itself nudged away from the light, so only the outer lit edge of
  // the union survives — a per-limb rim would also light every edge that
  // runs across the trunk where a branch overlaps it.
  final shift = Offset(0.6, 0.8) * frame.scale * 0.007;
  canvas.saveLayer(
    bounds,
    Paint()
      ..blendMode = BlendMode.srcATop
      ..color = const Color(0x8CFFFFFF),
  );
  final lit = Paint()..color = p.woodLight;
  for (final path in paths) {
    canvas.drawPath(path, lit);
  }
  final cut = Paint()
    ..blendMode = BlendMode.dstOut
    ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, frame.scale * 0.002);
  for (final path in paths) {
    canvas.drawPath(path.shift(shift), cut);
  }
  canvas.restore();

  // Lose the foot of the trunk into the ground instead of ending on a cut.
  final ground = frame.map(const Offset(0, weepingGroundY)).dy;
  canvas.drawRect(
    Rect.fromLTRB(
      bounds.left,
      ground - frame.scale * 0.004,
      bounds.right,
      bounds.bottom,
    ),
    Paint()
      ..blendMode = BlendMode.dstOut
      ..shader = ui.Gradient.linear(
        Offset(0, ground - frame.scale * 0.004),
        Offset(0, ground + frame.scale * 0.010),
        const [Color(0x00000000), Color(0xFF000000)],
      ),
  );

  canvas.drawRect(
    bounds,
    Paint()
      ..shader = grain
      ..color = const Color(0x40FFFFFF)
      ..blendMode = BlendMode.dstOut,
  );
  canvas.restore();
}

_BandImage? _bakeBand(
  WeepingCherryGeometry g,
  _Frame frame,
  double scale,
  int band,
  bool front,
  Shader grain,
  List<double>? fade,
  _Palette p,
) {
  final strands = [
    for (final s in g.strands)
      if (s.band == band && s.front == front) s,
  ];
  final clusters = [
    for (var i = 0; i < g.clusters.length; i++)
      if (g.clusters[i].band == band && g.clusters[i].front == front) i,
  ];
  if (strands.isEmpty && clusters.isEmpty) return null;

  Rect? bounds;
  void include(Offset p, double r) {
    final rect = Rect.fromCircle(center: frame.map(p), radius: r * frame.scale);
    bounds = bounds?.expandToInclude(rect) ?? rect;
  }

  for (final s in strands) {
    for (final p in s.points) {
      include(p, 0.03);
    }
  }
  for (final i in clusters) {
    include(g.clusters[i].center, g.clusters[i].radius * 2.2);
  }
  final rect = bounds!;

  final image = _rasterize(rect, scale, (canvas) {
    canvas.saveLayer(rect, Paint());

    // A wet-in-wet veil along each strand, so the curtain glows as one mass
    // before any individual blossom is laid on it.
    for (final s in strands) {
      final path = Path();
      for (var i = 0; i < s.points.length; i++) {
        final p = frame.map(s.points[i]);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = frame.scale * 0.022
          ..color = (front ? p.blossomMid : p.blossomFar).withValues(
            alpha: 0.06,
          )
          ..maskFilter = ui.MaskFilter.blur(
            ui.BlurStyle.normal,
            frame.scale * 0.010,
          ),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s.width * frame.scale
          // Fading to nothing, so the bare tips below the bloom don't hang
          // like rain.
          ..shader = ui.Gradient.linear(
            frame.map(s.points.first),
            frame.map(s.points.last),
            const [Color(0x8C3A2A3A), Color(0x003A2A3A)],
          ),
      );
    }

    for (final i in clusters) {
      _paintCluster(canvas, g.clusters[i], frame, fade?[i] ?? 1.0, p);
    }

    // Granulation: pigment knocked out where the paper's tooth stood proud.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = grain
        ..color = const Color(0x38FFFFFF)
        ..blendMode = BlendMode.dstOut,
    );
    canvas.restore();
  });

  return _BandImage(
    band,
    image,
    rect,
    frame.map(Offset(0, g.bandPivots[band])).dy,
  );
}

void _paintCluster(
  Canvas canvas,
  BlossomCluster c,
  _Frame frame,
  double fade,
  _Palette p,
) {
  final rand = math.Random(c.seed);
  final center = frame.map(c.center);
  final r = c.radius * frame.scale;

  // Moonlight from the upper left: the crown's top and left catch it, the
  // underside and the far right of the curtain fall into shade.
  final lit = (0.55 - c.center.dx * 0.55 - (c.center.dy - 0.40) * 1.1).clamp(
    0.0,
    1.0,
  );
  final depth = c.depth * (0.55 + 0.45 * lit);
  var tone = depth < 0.5
      ? Color.lerp(p.blossomFar, p.blossomMid, depth * 2)!
      : Color.lerp(p.blossomMid, p.blossomNear, (depth - 0.5) * 2)!;
  tone = Color.lerp(tone, p.blossomLilac, rand.nextDouble() * 0.3)!;

  if (c.wet) {
    canvas.drawPath(
      _blob(center, r * 1.3, rand),
      Paint()
        ..color = tone.withValues(alpha: 0.15 * fade)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, r * 0.35),
    );
  } else {
    final path = _blob(center, r, rand);
    canvas.drawPath(
      path,
      Paint()
        ..color = tone.withValues(
          alpha: (0.18 + rand.nextDouble() * 0.14) * fade,
        ),
    );
    // Dried edge on some pools only — pigment pulled to the rim as the pool
    // evaporated. On every pool it reads as a cluster of soap bubbles.
    if (rand.nextDouble() < 0.35) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.7, r * 0.06)
          ..color = Color.lerp(
            tone,
            p.petalHeart,
            0.25,
          )!.withValues(alpha: 0.22 * fade),
      );
    }
  }

  // Individual flowers only where the near side catches the light; the rest
  // stays a wash.
  final flowers = depth < 0.45 ? 0 : (depth * lit * 4.5).round();
  for (var i = 0; i < flowers; i++) {
    final at =
        center +
        Offset(
          (rand.nextDouble() - 0.5) * r * 1.4,
          (rand.nextDouble() - 0.5) * r * 1.1,
        );
    final fr = r * (0.16 + rand.nextDouble() * 0.14);
    final color = Color.lerp(tone, p.petalLight, 0.3 + depth * 0.5)!;
    canvas.drawPath(
      _blob(at, fr, rand, wobble: 0.35),
      Paint()
        ..color = color.withValues(alpha: (0.25 + depth * lit * 0.5) * fade),
    );
    if (rand.nextDouble() < 0.3) {
      canvas.drawCircle(
        at,
        math.max(0.5, fr * 0.22),
        Paint()..color = p.petalHeart.withValues(alpha: 0.45 * depth * fade),
      );
    }
  }
}

class _FallingPetal {
  const _FallingPetal({
    required this.startX,
    required this.startY,
    required this.drift,
    required this.period,
    required this.phase,
    required this.size,
    required this.spin,
    required this.tumble,
    required this.color,
  });

  final double startX;
  final double startY;
  final double drift;
  final double period;
  final double phase;
  final double size;
  final double spin;
  final double tumble;
  final Color color;

  static List<_FallingPetal> generate(_Palette p) {
    final rand = math.Random(909);
    return [
      for (var i = 0; i < 34; i++)
        _FallingPetal(
          startX: (rand.nextDouble() - 0.5) * 1.2,
          startY: 0.20 + rand.nextDouble() * 0.40,
          drift: 0.05 + rand.nextDouble() * 0.20,
          period: 11 + rand.nextDouble() * 9,
          phase: rand.nextDouble(),
          size: 0.0055 + rand.nextDouble() * 0.0045,
          spin: (rand.nextDouble() - 0.5) * 2.4,
          tumble: 0.8 + rand.nextDouble() * 1.6,
          color: Color.lerp(p.blossomNear, p.petalLight, rand.nextDouble())!,
        ),
    ];
  }
}

/// One cherry petal, base at the origin and notched tip at (0, -1).
final _petalPath = Path()
  ..moveTo(0, 0)
  ..cubicTo(-0.62, -0.22, -0.55, -0.88, -0.14, -1.0)
  ..lineTo(0, -0.86)
  ..lineTo(0.14, -1.0)
  ..cubicTo(0.55, -0.88, 0.62, -0.22, 0, 0)
  ..close();

/// Sprite sheet for the week petals: a row per tone, a column per squash
/// level, from face-on through to nearly edge-on. Thousands of them move
/// every frame, so they go out through one atlas draw rather than a path each.
const _spriteCell = 48.0;

/// A petal's length within its cell.
const _spritePetal = 40.0;

ui.Image _petalSprites(_Palette p) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var tone = 0; tone < petalToneCount; tone++) {
    final color = p.petalTones[tone];
    for (var q = 0; q < petalSquashLevels; q++) {
      canvas.save();
      canvas.translate(
        q * _spriteCell + _spriteCell / 2,
        tone * _spriteCell + (_spriteCell + _spritePetal) / 2,
      );
      canvas.scale(
        _spritePetal * (1 - 0.8 * q / petalSquashLevels),
        _spritePetal,
      );
      // Deeper at the base, where the petal meets the flower's heart.
      canvas.drawPath(
        _petalPath,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset.zero,
            const Offset(0, -1),
            [Color.lerp(color, p.petalHeart, 0.45)!, color, color],
            const [0, 0.45, 1],
          ),
      );
      canvas.restore();
    }
  }
  final picture = recorder.endRecording();
  final image = picture.toImageSync(
    (_spriteCell * petalSquashLevels).toInt(),
    (_spriteCell * petalToneCount).toInt(),
  );
  picture.dispose();
  return image;
}

/// One layer of week petals for a single atlas draw.
class _PetalBatch {
  _PetalBatch(int capacity)
    : _transforms = Float32List(capacity * 4),
      _rects = Float32List(capacity * 4),
      _colors = Int32List(capacity),
      _restX = Float32List(capacity),
      _below = Float32List(capacity),
      _bands = Int32List(capacity);

  final Float32List _transforms;
  final Float32List _rects;
  final Int32List _colors;

  /// For [sway]: each petal's translation before any lean, how far below its
  /// band's pivot it hangs (negative above, in the crown), and which of the lean slots it follows.
  final Float32List _restX;
  final Float32List _below;
  final Int32List _bands;
  int _count = 0;

  void clear() => _count = 0;

  void add({
    required Offset at,
    required double length,
    required double rotation,
    required int tone,
    required int squash,
    required double alpha,
    int tint = 0xFFFFFF,
    int band = 0,
    double below = 0,
  }) {
    final scale = length / _spritePetal;
    final scos = math.cos(rotation) * scale;
    final ssin = math.sin(rotation) * scale;
    const anchor = _spriteCell / 2;
    final i = _count * 4;
    final x = at.dx - scos * anchor + ssin * anchor;
    _restX[_count] = x;
    _below[_count] = below;
    _bands[_count] = band;
    _transforms
      ..[i] = scos
      ..[i + 1] = ssin
      ..[i + 2] = x
      ..[i + 3] = at.dy - ssin * anchor - scos * anchor;
    _rects
      ..[i] = squash * _spriteCell
      ..[i + 1] = tone * _spriteCell
      ..[i + 2] = (squash + 1) * _spriteCell
      ..[i + 3] = (tone + 1) * _spriteCell;
    _colors[_count] = ((alpha.clamp(0.0, 1.0) * 255).round() << 24) | tint;
    _count++;
  }

  /// Leans every petal with its band, so a frame where only the breeze moves
  /// patches one number per petal instead of laying the batch out again.
  void sway(Float64List leans, _PointerWake wake) {
    // Most chains hang straight, and their petals need no wake lookup.
    final strandsBent = [
      for (var s = 0; s < leans.length; s++) wake.strands.bent(s),
    ];
    final crownBent = [
      for (var s = 0; s < leans.length; s++) wake.crown.bent(s),
    ];
    for (var k = 0; k < _count; k++) {
      final band = _bands[k];
      final below = _below[k];
      final bent = below >= 0 ? strandsBent[band] : crownBent[band];
      _transforms[k * 4 + 2] =
          _restX[k] +
          leans[band] * math.max(below, 0) +
          (bent ? wake.shiftAt(band, below) : 0);
    }
  }

  void draw(Canvas canvas, ui.Image sprites, Paint paint) {
    if (_count == 0) return;
    canvas.drawRawAtlas(
      sprites,
      Float32List.sublistView(_transforms, 0, _count * 4),
      Float32List.sublistView(_rects, 0, _count * 4),
      Int32List.sublistView(_colors, 0, _count),
      BlendMode.modulate,
      null,
      paint,
    );
  }
}

/// White lerped [t] of the way to [tint], as 0xRRGGBB — without the [Color]
/// a lerp allocates, since every flying petal needs one a frame.
int _tintToward(int tint, double t) {
  int channel(int shift) {
    final c = (tint >> shift) & 0xFF;
    return (255 + (c - 255) * t).round() << shift;
  }

  return channel(16) | channel(8) | channel(0);
}

double _smoothstep(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// One side of every band's pivot as a chain of joints out from it: the
/// pointer drags the joints it moves past, and the chain carries the bend
/// along before it settles back to where the breeze has it. The pivot never
/// moves; the far end is free.
///
/// Neighbouring joints damp each other's motion as well as pull on each
/// other, so the quick ripples a chain of springs would otherwise wobble
/// with die out almost at once, and what's left is the slow swing of the
/// whole strand.
class _Chain {
  _Chain({
    required this.joints,
    required this.give,
    required this.tension,
    required this.hanging,
    required this.stiffness,
    required this.drag,
    required this.internalDrag,
    required this.reach,
  }) : _shifts = Float64List(weepingBandCount * 2 * joints),
       _velocities = Float64List(weepingBandCount * 2 * joints),
       _forces = Float64List(joints);

  final int joints;

  /// The share of the pointer's speed the joints are dragged toward.
  final double give;

  /// How hard each joint pulls its neighbours along.
  final double tension;

  /// Whether the chain hangs: each link then carries the weight of those
  /// below it, so it's taut at the pivot and loose at the tip, and swings
  /// like a strand rather than a ruler.
  final bool hanging;

  /// How hard each joint is held toward rest on its own, as the wood holds
  /// the crown.
  final double stiffness;

  /// The air's drag on each joint.
  final double drag;

  /// How hard neighbouring joints damp the motion between them.
  final double internalDrag;

  /// The furthest a joint goes, in tree widths.
  final double reach;

  /// Each joint's sideways shift in logical pixels, by lean slot then joint
  /// out from the pivot (exclusive).
  final Float64List _shifts;
  final Float64List _velocities;
  final Float64List _forces;

  /// Each slot's length from the pivot to the chain's end, as of the last
  /// step.
  final _spans = Float64List(weepingBandCount * 2);

  /// The shift of joint [j] of [slot]; joint 0 is the pivot.
  double joint(int slot, int j) => j == 0 ? 0 : _shifts[slot * joints + j - 1];

  bool bent(int slot) {
    for (var j = 1; j <= joints; j++) {
      if (joint(slot, j).abs() > 0.05) return true;
    }
    return false;
  }

  /// The shift [out] from the pivot of [slot], between its joints.
  double shiftAt(int slot, double out) {
    final span = _spans[slot];
    if (span <= 0) return 0;
    final u = (out / span * joints).clamp(0.0, joints * 1.0);
    final j = math.min(u.floor(), joints - 1);
    final a = joint(slot, j);
    return a + (joint(slot, j + 1) - a) * (u - j);
  }

  /// How taut the link from joint [s] to [s] + 1 is.
  double _link(int s) => hanging ? (joints - s) / joints : 1;

  /// Steps [slot]'s chain on by [dt]: [span] long from [pivotY], running
  /// down when [down], else up. [across] is how near the pointer is to the
  /// band's middle, 0 to 1.
  void step(
    int slot,
    double pivotY,
    double span,
    bool down,
    double across,
    Offset? pointer,
    double pointerSpeed,
    double dt,
    double scale,
  ) {
    _spans[slot] = span;
    final o = slot * joints;
    final limit = scale * reach;
    if (pointer != null && across > 0.01) {
      for (var j = 0; j < joints; j++) {
        final out = span * (j + 1) / joints;
        final d =
            (pointer.dy - (down ? pivotY + out : pivotY - out)) /
            (scale * 0.05);
        final near = across * math.exp(-d * d);
        _velocities[o + j] +=
            math.min(4 * near * dt, 1) *
            (give * pointerSpeed - _velocities[o + j]);
      }
    }
    // In short substeps: the taut links near the pivot are too stiff to
    // take a whole frame in one.
    final substeps = (dt * 240).ceil();
    final h = dt / substeps;
    for (var n = 0; n < substeps; n++) {
      for (var j = 0; j < joints; j++) {
        final x = _shifts[o + j];
        final v = _velocities[o + j];
        // The link in toward the pivot, and out toward the free end.
        final inner = _link(j);
        final xIn = j == 0 ? 0.0 : _shifts[o + j - 1];
        final vIn = j == 0 ? 0.0 : _velocities[o + j - 1];
        var f =
            inner * (tension * (xIn - x) + internalDrag * (vIn - v)) -
            stiffness * x -
            drag * v;
        if (j < joints - 1) {
          final outer = _link(j + 1);
          f +=
              outer *
              (tension * (_shifts[o + j + 1] - x) +
                  internalDrag * (_velocities[o + j + 1] - v));
        }
        _forces[j] = f;
      }
      for (var j = 0; j < joints; j++) {
        final v = _velocities[o + j] + _forces[j] * h;
        _velocities[o + j] = v;
        _shifts[o + j] = (_shifts[o + j] + v * h).clamp(-limit, limit);
      }
    }
  }
}

/// The pointer stirring the tree as it passes: each band's hanging strands,
/// and more stiffly its crown above them, bend in segments where it moves
/// through ([_Chain]). Each drifting petal hangs on a damped spring of its
/// own.
class _PointerWake {
  _PointerWake(int petalCount)
    : _petalOffsets = Float64List(petalCount * 2),
      _petalVelocities = Float64List(petalCount * 2);

  /// Below each band's pivot, where the strands hang free: a swing of about
  /// two seconds that overshoots once, softly.
  final strands = _Chain(
    joints: 6,
    give: 0.6,
    tension: 250,
    hanging: true,
    stiffness: 0,
    drag: 1,
    internalDrag: 30,
    reach: 0.035,
  );

  /// Above it, where the blossom is held on the wood: it gives less, and
  /// eases back without swinging past.
  final crown = _Chain(
    joints: 4,
    give: 0.3,
    tension: 15,
    hanging: false,
    stiffness: 20,
    drag: 7,
    internalDrag: 2,
    reach: 0.02,
  );

  final Float64List _petalOffsets;
  final Float64List _petalVelocities;

  double? _time;
  Offset? _pointer;
  Offset _pointerVelocity = Offset.zero;
  double _dt = 0;

  /// Moves on to time [t], with the pointer at [pointer] — null while it's
  /// off the canvas.
  void advance(double t, Offset? pointer) {
    final last = _time;
    _time = t;
    _dt = last == null ? 0 : (t - last).clamp(0.0, 0.1);
    // A repaint without the clock moving changes nothing.
    if (last != null && _dt == 0) return;
    final from = _pointer;
    _pointer = pointer;
    _pointerVelocity = from == null || pointer == null || _dt == 0
        ? Offset.zero
        : (pointer - from) / _dt;
  }

  /// The shift [below] the pivot of [slot] — above it where negative.
  double shiftAt(int slot, double below) =>
      below >= 0 ? strands.shiftAt(slot, below) : crown.shiftAt(slot, -below);

  /// Steps [bands]' chains on. The pointer drags the joints nearest it, in
  /// the bands it's among; the far layer is behind the near one, so it takes
  /// less of the push.
  void swayBands(List<_BandImage> bands, bool front, double scale) {
    if (_dt == 0) return;
    final p = _pointer;
    for (final band in bands) {
      final slot = band.band * 2 + (front ? 1 : 0);
      var across = 0.0;
      if (p != null) {
        final d = (p.dx - band.rect.center.dx) / (scale * 0.07);
        across = (front ? 1.0 : 0.6) * math.exp(-d * d);
      }
      final pivot = band.pivotY;
      final speed = _pointerVelocity.dx;
      strands.step(
        slot,
        pivot,
        math.max(band.rect.bottom - pivot, 0.0),
        true,
        across,
        p,
        speed,
        _dt,
        scale,
      );
      crown.step(
        slot,
        pivot,
        math.max(pivot - band.rect.top, 0.0),
        false,
        across,
        p,
        speed,
        _dt,
        scale,
      );
    }
  }

  /// Where drifting petal [i], which the breeze has at [at], is once the
  /// pointer has had its way with it. Lighter than the whips, it's batted
  /// further and wanders back slowly, the air's drag soon stopping it.
  Offset petal(int i, Offset at, double scale) {
    var x = _petalOffsets[i * 2];
    var y = _petalOffsets[i * 2 + 1];
    if (_dt == 0) return at.translate(x, y);
    var vx = _petalVelocities[i * 2];
    var vy = _petalVelocities[i * 2 + 1];
    final p = _pointer;
    if (p != null) {
      final d = (at.translate(x, y) - p).distance / (scale * 0.035);
      final drag = math.min(6 * math.exp(-d * d) * _dt, 1);
      vx += drag * (_pointerVelocity.dx - vx);
      vy += drag * (_pointerVelocity.dy - vy);
    }
    vx += (-2 * x - 4 * vx) * _dt;
    vy += (-2 * y - 4 * vy) * _dt;
    x += vx * _dt;
    y += vy * _dt;
    _petalOffsets
      ..[i * 2] = x
      ..[i * 2 + 1] = y;
    _petalVelocities
      ..[i * 2] = vx
      ..[i * 2 + 1] = vy;
    return at.translate(x, y);
  }
}

class _WeepingCherryPainter extends CustomPainter {
  _WeepingCherryPainter({
    required this.scene,
    required this.geometry,
    required this.petals,
    required this.sprites,
    required this.palette,
    required this.flights,
    required this.fallStart,
    required this.fallEnd,
    required this.time,
    required this.wake,
    required this.pointer,
  }) : super(repaint: time);

  final _Scene scene;
  final WeepingCherryGeometry geometry;
  final List<_FallingPetal> petals;
  final ui.Image sprites;
  final _Palette palette;
  final List<_Flight?> flights;
  final double? fallStart;
  final double fallEnd;
  final ValueNotifier<double> time;
  final _PointerWake wake;
  final ValueListenable<Offset?>? pointer;

  late final _treeBack = _PetalBatch(geometry.weekPetals.length);
  late final _treeFront = _PetalBatch(geometry.weekPetals.length);
  late final _ground = _PetalBatch(geometry.weekPetals.length);
  late final _flyingBack = _PetalBatch(geometry.weekPetals.length);
  late final _flyingFront = _PetalBatch(geometry.weekPetals.length);

  /// The fall's gust leaning the curtain, on top of its idle sway. Faded in
  /// as the fall starts and out before it ends, so the curtain never jumps.
  double _gust = 0;

  /// Each band's lean this frame, by band * 2 + layer (front 1). Every petal
  /// on the curtain sways with one of these, so they're worked out once a
  /// frame rather than once a petal.
  final _leans = Float64List(weepingBandCount * 2);

  /// The lean each flying petal let go with, by petal; NaN until it's needed.
  /// It's fixed from the moment the petal leaves, so it's worked out once.
  late final _launchLeans = Float64List(geometry.weekPetals.length)
    ..fillRange(0, geometry.weekPetals.length, double.nan);

  /// The pointer wake's shift each flying petal let go with, by petal; set
  /// alongside [_launchLeans].
  late final _launchShifts = Float64List(geometry.weekPetals.length);

  /// Whether the batches hold the settled layout. With nothing falling the
  /// petals only sway, so later frames just lean the curtain's batches.
  var _settled = false;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final start = fallStart;
    final fall = start == null ? null : t - start;
    // The canopy thins a beat behind the petals leaving it, at the rate they
    // go.
    final thinned = fall == null ? 1.0 : _detachedBy(fall - 0.4);
    _gust = fall == null
        ? 0
        : (_wind(fall) - _breeze) *
              0.3 *
              _smoothstep(fall) *
              _smoothstep((fallEnd - fall) / 1.5);
    // Into the bake's space, which a stale bake is stretched from.
    final p = pointer?.value;
    wake.advance(
      t,
      p?.scale(scene.size.width / size.width, scene.size.height / size.height),
    );
    final scale = _Frame(scene.size).scale;
    wake.swayBands(scene.back, false, scale);
    wake.swayBands(scene.front, true, scale);
    for (final band in scene.back) {
      _leans[band.band * 2] = _shear(band, t, false);
    }
    for (final band in scene.front) {
      _leans[band.band * 2 + 1] = _shear(band, t, true);
    }

    // A stale bake (mid-resize) is stretched to fit until the re-bake lands.
    canvas.save();
    canvas.scale(
      size.width / scene.size.width,
      size.height / scene.size.height,
    );
    if (fall != null || !_settled) _layoutPetals(fall);
    _settled = fall == null;
    _treeBack.sway(_leans, wake);
    _treeFront.sway(_leans, wake);
    final imagePaint = Paint()..filterQuality = FilterQuality.medium;
    final spritePaint = Paint()..filterQuality = FilterQuality.medium;
    _drawImage(canvas, scene.background, Offset.zero & scene.size, imagePaint);
    _drawBands(canvas, scene.back, scene.fullBack, thinned, false);
    _treeBack.draw(canvas, sprites, spritePaint);
    // Petals from the far side of the crown fall behind the trunk and the
    // near curtain.
    _flyingBack.draw(canvas, sprites, spritePaint);
    _drawImage(canvas, scene.wood, scene.woodRect, imagePaint);
    if (fall == null) {
      scene.groundPile ??= _bakeGroundPile(spritePaint);
      _drawImage(canvas, scene.groundPile!, scene.groundPileRect, imagePaint);
    } else {
      _ground.draw(canvas, sprites, spritePaint);
    }
    _drawBands(canvas, scene.front, scene.fullFront, thinned, true);
    _treeFront.draw(canvas, sprites, spritePaint);
    _flyingFront.draw(canvas, sprites, spritePaint);
    _drawPetals(canvas, scene.size, t);
    canvas.restore();
  }

  /// Rasterizes the settled [_ground] batch: a strip across the ground line,
  /// deep enough for the furthest a petal lands below it. On whole pixels,
  /// so the bake lands back on the grid it was drawn on.
  ui.Image _bakeGroundPile(Paint spritePaint) {
    final frame = _Frame(scene.size);
    final rect = Rect.fromLTRB(
      0,
      frame.map(const Offset(0, weepingGroundY - 0.01)).dy.floorToDouble(),
      scene.size.width,
      frame.map(const Offset(0, weepingGroundY + 0.06)).dy.ceilToDouble(),
    );
    scene.groundPileRect = rect;
    return _rasterize(
      rect,
      math.min(scene.dpr, 2.0),
      (canvas) => _ground.draw(canvas, sprites, spritePaint),
    );
  }

  void _drawImage(Canvas canvas, ui.Image image, Rect dst, Paint paint) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      paint,
    );
  }

  /// How far a band leans at time [t]. The idle breeze comes from the left,
  /// so the curtain leans downwind with each gust and settles back in the
  /// lulls rather than swinging evenly both ways. Each gust reaches a band
  /// as it sweeps across the tree — the far layer a beat behind the near —
  /// and every band gives and flutters in its own way, so the whips move as
  /// separate strands instead of one breathing sheet.
  double _shear(_BandImage band, double t, bool front) {
    final sway = _bandSways[band.band * 2 + (front ? 1 : 0)];
    final across = band.rect.center.dx / scene.size.width;
    final gust = _idleGust(t - across * 1.6 - (front ? 0 : 0.35));
    return (front ? 1.0 : 0.7) *
        (sway.give * (0.003 + 0.017 * gust) +
            (0.002 + 0.006 * gust) * math.sin(t * sway.rate + sway.phase) +
            0.0015 * math.sin(t * sway.flutter + sway.flutterPhase) +
            _gust);
  }

  /// While the weeks fall, the unthinned canopy crossfades into the thinned
  /// one, linearly rather than dipping through translucent. Normally in one
  /// pass per band, through the crossfade shader; until that has loaded, each
  /// set is composited in a layer of its own and the two mixed additively.
  void _drawBands(
    Canvas canvas,
    List<_BandImage> bands,
    List<_BandImage>? full,
    double thinned,
    bool front,
  ) {
    final paint = Paint()..filterQuality = FilterQuality.medium;
    if (full == null || thinned >= 1) {
      _drawBandSet(
        canvas,
        bands,
        front,
        (i) => _drawImage(canvas, bands[i].image, bands[i].rect, paint),
      );
      return;
    }
    final fades = front ? scene.frontFades : scene.backFades;
    if (fades != null) {
      for (final fade in fades) {
        fade.setFloat(4, thinned);
      }
      _drawBandSet(
        canvas,
        bands,
        front,
        (i) => canvas.drawRect(bands[i].rect, paint..shader = fades[i]),
      );
      return;
    }
    // Room for the tips at their furthest lean, so the layer doesn't crop
    // them.
    Rect? bounds;
    for (final band in bands) {
      final slot = band.band * 2 + (front ? 1 : 0);
      var bend = 0.0;
      for (final chain in [wake.strands, wake.crown]) {
        for (var j = 1; j <= chain.joints; j++) {
          bend = math.max(bend, chain.joint(slot, j).abs());
        }
      }
      final lean =
          (_leans[slot] * (band.rect.bottom - band.pivotY)).abs() + bend;
      final rect = band.rect.inflate(lean);
      bounds = bounds?.expandToInclude(rect) ?? rect;
    }
    canvas.saveLayer(bounds, Paint());
    canvas.saveLayer(
      bounds,
      Paint()..color = Color.fromRGBO(0, 0, 0, 1 - thinned),
    );
    _drawBandSet(
      canvas,
      full,
      front,
      (i) => _drawImage(canvas, full[i].image, full[i].rect, paint),
    );
    canvas.restore();
    canvas.saveLayer(
      bounds,
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, thinned)
        ..blendMode = BlendMode.plus,
    );
    _drawBandSet(
      canvas,
      bands,
      front,
      (i) => _drawImage(canvas, bands[i].image, bands[i].rect, paint),
    );
    canvas.restore();
    canvas.restore();
  }

  /// Each band is sheared below the height its strands leave the wood: the
  /// attachment stays put and the tips swing, while the crown above holds
  /// still rather than tilting the other way about the same point. Both
  /// halves meet at zero offset, so the join doesn't show. Where the pointer
  /// has bent a half, it goes in a slice per segment of its [_Chain], each
  /// sheared to run from one joint's shift to the next's. [draw] paints band
  /// [i] in place, once per piece.
  void _drawBandSet(
    Canvas canvas,
    List<_BandImage> bands,
    bool front,
    void Function(int i) draw,
  ) {
    for (var i = 0; i < bands.length; i++) {
      final band = bands[i];
      final slot = band.band * 2 + (front ? 1 : 0);
      if (band.rect.top < band.pivotY) {
        _drawHalf(canvas, band, slot, wake.crown, 0, () => draw(i));
      }
      if (band.rect.bottom > band.pivotY) {
        _drawHalf(
          canvas,
          band,
          slot,
          wake.strands,
          _leans[slot],
          () => draw(i),
        );
      }
    }
  }

  /// Paints [band]'s half on [chain]'s side of the pivot, leaning by [lean]
  /// as well as bent by the chain.
  void _drawHalf(
    Canvas canvas,
    _BandImage band,
    int slot,
    _Chain chain,
    double lean,
    void Function() draw,
  ) {
    final w = scene.size.width;
    final pivot = band.pivotY;
    final end = chain == wake.strands ? band.rect.bottom : band.rect.top;
    final bent = chain.bent(slot);
    // At rest, one piece: a slice each would only multiply the draws.
    final pieces = bent ? chain.joints : 1;
    for (var j = 0; j < pieces; j++) {
      final from = pivot + (end - pivot) * j / pieces;
      // Hard clips on shared edges, so the pieces neither gap nor double up
      // along the joins.
      final to = j == pieces - 1
          ? end
          : pivot + (end - pivot) * (j + 1) / pieces;
      final a = bent ? chain.joint(slot, j) : 0.0;
      final b = bent ? chain.joint(slot, j + 1) : 0.0;
      canvas.save();
      canvas.clipRect(
        Rect.fromLTRB(-w, math.min(from, to), 2 * w, math.max(from, to)),
        doAntiAlias: false,
      );
      canvas.translate(a + lean * (from - pivot), from);
      canvas.transform(
        (Matrix4.identity()..setEntry(0, 1, lean + (b - a) / (to - from)))
            .storage,
      );
      canvas.translate(0, -from);
      draw();
      canvas.restore();
    }
  }

  /// Sorts every week petal into the tree, the air or the ground for this
  /// frame, and works out where it is. Petals on the tree are laid out at
  /// rest; [_PetalBatch.sway] leans them afterwards.
  void _layoutPetals(double? fall) {
    final frame = _Frame(scene.size);
    _treeBack.clear();
    _treeFront.clear();
    _ground.clear();
    _flyingBack.clear();
    _flyingFront.clear();

    // The band image a petal sways with, by lean slot.
    final bands = List<_BandImage?>.filled(weepingBandCount * 2, null);
    for (final b in scene.back) {
      bands[b.band * 2] = b;
    }
    for (final b in scene.front) {
      bands[b.band * 2 + 1] = b;
    }

    for (var i = 0; i < geometry.weekPetals.length; i++) {
      final petal = geometry.weekPetals[i];
      final flight = flights[i];
      final cluster = geometry.clusters[petal.cluster];
      final front = cluster.front;
      final slot = cluster.band * 2 + (front ? 1 : 0);
      final band = bands[slot];
      final home = frame.map(petal.position);
      // How far below its band's pivot it hangs (above it where negative) —
      // the lever the lean acts on. Nothing for a band with no image, which
      // never sways.
      final below = band == null ? 0.0 : home.dy - band.pivotY;

      if (flight == null || (fall != null && fall < flight.detach)) {
        (front ? _treeFront : _treeBack).add(
          at: home,
          length: petal.size * frame.scale,
          rotation: petal.rotation,
          tone: petal.tone,
          squash: petal.squash,
          alpha: front ? 0.7 : 0.4,
          band: slot,
          below: below,
        );
        continue;
      }

      // In the shade of the canopy and half-sunk in the grass: dimmer and
      // duskier than the petals still catching the moon.
      final groundAlpha = 0.45 + petal.phase * 0.25;
      final tau = fall == null ? double.infinity : fall - flight.detach;

      if (tau >= flight.landTime) {
        // Touched down: settles flat into the grass over a moment.
        final left =
            1 - ((tau - flight.landTime) / _settleTime).clamp(0.0, 1.0);
        final s = 1 - left * left;
        _ground.add(
          at: frame.map(flight.landing),
          length: petal.groundSize * frame.scale,
          rotation:
              flight.landRotation +
              (flight.groundRotation - flight.landRotation) * s,
          tone: petal.tone,
          squash:
              (flight.landSquash +
                      (flight.groundSquash - flight.landSquash) * s)
                  .round(),
          alpha: groundAlpha,
          tint: palette.groundTint,
        );
        continue;
      }

      // In the air. It leaves from wherever the curtain had swayed it to,
      // and that offset eases out over the first moments of the drop, so the
      // path still ends exactly where the settled pile has it.
      var launchLean = _launchLeans[i];
      if (launchLean.isNaN) {
        launchLean = _launchLeans[i] = band == null
            ? 0.0
            : _shear(band, fallStart! + flight.detach, front);
        // Where the pointer had bent its strand as it let go.
        _launchShifts[i] = band == null ? 0.0 : wake.shiftAt(slot, below);
      }
      final swayed = launchLean * math.max(below, 0) + _launchShifts[i];
      final progress = tau / flight.landTime;
      final air = frame.map(Offset(flight.x(tau), flight.y(tau)));
      (front ? _flyingFront : _flyingBack).add(
        at: Offset(air.dx + swayed * (1 - _smoothstep(tau / 0.8)), air.dy),
        // Grows from the speck it was on the tree to its full size as it
        // comes away from the mass of bloom.
        length:
            (petal.size +
                (petal.groundSize - petal.size) * _smoothstep(tau / 0.5)) *
            frame.scale,
        rotation: flight.rotationAt(tau),
        tone: petal.tone,
        squash: flight.squashAt(tau).round(),
        alpha: 0.9 - (0.9 - groundAlpha) * progress,
        tint: _tintToward(palette.groundTint, progress),
      );
    }
  }

  /// The ambient petals that drift across the scene on a loop.
  void _drawPetals(Canvas canvas, Size size, double t) {
    final frame = _Frame(size);
    final paint = Paint();
    for (var i = 0; i < petals.length; i++) {
      final petal = petals[i];
      final u = (t / petal.period + petal.phase) % 1.0;
      final y = petal.startY + u * (weepingGroundY - petal.startY);
      final x =
          petal.startX +
          petal.drift * u +
          0.025 * math.sin(t * 0.9 + petal.phase * 12);
      final fade = math.min(1.0, math.min(u / 0.08, (1 - u) / 0.10));
      final at = wake.petal(i, frame.map(Offset(x, y)), frame.scale);
      final s = petal.size * frame.scale;
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(t * petal.spin + petal.phase * 6);
      // Tumbling: the petal turns edge-on and back as it falls.
      canvas.scale(
        s * (0.25 + 0.75 * math.cos(t * petal.tumble + petal.phase * 9).abs()),
        s,
      );
      paint.color = petal.color.withValues(alpha: 0.85 * fade);
      canvas.drawPath(_petalPath, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_WeepingCherryPainter old) =>
      old.scene != scene ||
      old.sprites != sprites ||
      old.fallStart != fallStart ||
      old.flights != flights;
}
