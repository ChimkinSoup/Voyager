import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';
import 'package:voyager/features/gaia/companion/gaia_starfield.dart';

/// How the sky leaves once a prompt is sent from it.
enum GaiaSkyExit {
  /// The stars streak out from the middle, faster and faster.
  warp,

  /// The sky spins up, each star drawing an arc as in a long exposure.
  trails,

  /// The stars pour into the composer, the prompt taking the sky with it.
  converge,

  /// A sunrise glow climbs from the bottom as the stars go out, the
  /// faintest first.
  dawn,

  /// Everything simply fades.
  fade,

  /// The stars rise a little as they fade.
  drift,

  /// The stars go out one by one, each with a last glint.
  blinkOut,
}

/// How the aurora goes as the sky leaves.
enum GaiaAuroraExit {
  /// Its curtains rise off the top, thinning.
  rise,

  /// Each curtain rolls up into its own top edge, like a blind, where it
  /// hangs.
  retract,

  /// The curtains break into vertical rays, which wink out one by one.
  rays,

  /// A last surge: brighter, rippling fast and swelling, then gone.
  flare,

  /// Its green drains to a deep violet-red as it dims, as at dawn.
  ebb,

  /// The curtains flatten into a thin, still arc, which then fades.
  arc,

  /// Ebb and arc at once: flattening into a still arc as its green drains
  /// to violet-red, then fading.
  dusk,
}

/// How a satellite crossing the sky looks.
enum GaiaSatellite {
  /// A steady point.
  dot,

  /// A tiny body with solar panels either side, slowly tumbling.
  panels,

  /// A point leaving a faint fading trail, as in a long exposure.
  trail,

  /// A dim point that flashes now and then, as a tumbling rocket body does.
  tumbler,

  /// A big bright station: warm, with a soft halo and a faint glint.
  station,

  /// A train of points, one after another along the same path.
  train,
}

/// The rare aurora's colours, each with its share of the rare skies.
enum GaiaRareAurora {
  crimson(0.4),
  mauve(0.25),
  twilight(0.25),
  gold(0.1);

  const GaiaRareAurora(this.share);

  final double share;
}

/// A meteor shower on the sky: as the real calendar has one tonight, or
/// held at a strength.
enum GaiaSkyShower { calendar, off, light, medium, peak }

/// A yearly meteor shower: its peak, the days it's active either side of
/// it, and how strong it is at its peak against the strongest, 0 to 1.
typedef _Shower = ({
  String name,
  int month,
  int day,
  int before,
  int after,
  double strength,
});

/// The major yearly showers, as the IMO's calendar has them.
const _showers = <_Shower>[
  (name: 'Quadrantids', month: 1, day: 3, before: 6, after: 9, strength: 1),
  (name: 'Lyrids', month: 4, day: 22, before: 8, after: 8, strength: 0.4),
  (
    name: 'Eta Aquariids',
    month: 5,
    day: 6,
    before: 17,
    after: 22,
    strength: 0.6,
  ),
  (name: 'Perseids', month: 8, day: 12, before: 26, after: 12, strength: 1),
  (name: 'Orionids', month: 10, day: 21, before: 19, after: 17, strength: 0.4),
  (name: 'Leonids', month: 11, day: 17, before: 11, after: 13, strength: 0.4),
  (name: 'Geminids', month: 12, day: 14, before: 10, after: 6, strength: 1),
];

/// The meteor shower on [date], and its strength, 0 to 1: strongest at its
/// peak, falling away to a trace at either end of the days it's active. Of
/// two at once, the stronger; null when none is.
({String name, double strength})? gaiaMeteorShower(DateTime date) {
  ({String name, double strength})? best;
  for (final s in _showers) {
    // The year either side too, for a shower active over the new year.
    for (final year in [date.year - 1, date.year, date.year + 1]) {
      final days =
          date.difference(DateTime(year, s.month, s.day)).inMinutes / 1440;
      final off = days.abs() / (days < 0 ? s.before : s.after);
      if (off > 1) continue;
      final strength = s.strength * (0.05 + 0.95 * pow(1 - off, 3));
      if (strength > (best?.strength ?? 0)) {
        best = (name: s.name, strength: strength);
      }
    }
  }
  return best;
}

/// Bursts a minute from a shower at full strength.
const _burstPeak = 8.0 / 3;

/// A night sky behind a new chat: stars turning slowly about a pole above
/// the window, constellations that trace themselves one at a time, a meteor
/// or satellite now and then, and a faint aurora along the top. Behind the
/// chat, and over the [GaiaStarfield], which turns with it.
///
/// It fades in with an empty chat and goes with it: by [exit] when a prompt
/// was just [sent] from it, else by simply fading. The starfield carries on
/// turning as it did. It ticks only while
/// [active] and [shown], or while it's leaving; under reduced motion it's
/// still, and simply goes.
class GaiaSky extends StatefulWidget {
  const GaiaSky({
    super.key,
    required this.active,
    required this.shown,
    required this.sent,
    required this.rotation,
    this.restRate = 0,
    required this.stars,
    required this.twinkle,
    required this.sparkles,
    required this.traceSpeed,
    required this.figures,
    required this.eventInterval,
    required this.aurora,
    this.auroraExit = GaiaAuroraExit.rise,
    this.auroraDrift = 1,
    this.rareAurora = false,
    this.rareColours,
    this.shower = GaiaSkyShower.off,
    this.satellite = GaiaSatellite.dot,
    required this.exit,
    this.plainBlink = false,
    required this.exitTime,
    this.exitTest = 0,
    this.burstTest = 0,
    this.top = 0,
    this.left,
    required this.child,
  });

  final ValueListenable<bool> active;

  /// The chat is empty. Otherwise, once it has left, nothing is drawn and
  /// nothing ticks.
  final bool shown;

  /// Were [shown] to turn false now, the sky would leave by [exit] rather
  /// than simply fade: a prompt was just sent from it.
  final bool sent;

  /// Degrees a minute the sky turns.
  final double rotation;

  /// Frames a second while nothing on the sky moves quickly; 0, every
  /// frame. Twinkling, sparkles, the aurora, satellites and the turning
  /// look the same at a lower rate, and the window is still between.
  final int restRate;

  /// Stars per million square logical pixels.
  final double stars;

  /// How deeply the stars shimmer, 0 to 1: at 1, each dims to 30% of its
  /// brightness at the bottom of its slow pulse.
  final double twinkle;

  /// Sparkles a second: a star swelling into a four-pointed glint, then
  /// settling.
  final double sparkles;

  /// Logical pixels a second the pen tracing a constellation moves.
  final double traceSpeed;

  /// Once traced, a constellation's figure is sketched over its lines,
  /// fading with them. Experimental.
  final bool figures;

  /// The average seconds from one meteor or satellite to the next.
  final double eventInterval;

  /// The aurora's strength, 0 to 1.
  final double aurora;

  final GaiaAuroraExit auroraExit;

  /// How fast the aurora's curtains wax and wane against one another, as a
  /// share of their own pace; 0, each holds steady.
  final double auroraDrift;

  /// The rare aurora every time, rather than one sky in [kGaiaRareAurora].
  final bool rareAurora;

  /// The rare aurora's colours; null, rolled by their shares.
  final GaiaRareAurora? rareColours;

  final GaiaSkyShower shower;

  /// A change sends one across at once, to see it by, if fewer than three
  /// are up.
  final GaiaSatellite satellite;

  final GaiaSkyExit exit;

  /// Blinking out, each star simply fades, without a last glint, and the
  /// starfield behind without brightening.
  final bool plainBlink;

  /// Seconds the [exit] lasts.
  final double exitTime;

  /// A change plays the [exit] in place, the sky coming back after.
  final int exitTest;

  /// A change sends a burst of a shower's meteors across at once.
  final int burstTest;

  /// As [GaiaStarfield]'s: the sky keeps below this.
  final double top;

  /// As [GaiaStarfield]'s: an opaque sidebar's edge, which it stops at.
  final ValueListenable<double>? left;

  final Widget child;

  @override
  State<GaiaSky> createState() => _GaiaSkyState();
}

/// Enough stars for the largest window at the densest setting; smaller
/// skies draw the first few.
const _pool = 6000;

/// Room, in logical pixels, for a constellation to turn out of sight before
/// it comes round again.
const _reach = 200.0;

const _fadeIn = 0.8;
const _fadeOut = 0.35;

/// Seconds a traced constellation holds, then takes to fade, and then the
/// sky rests before tracing the next.
const _hold = 4.0;
const _unwrite = 2.0;
const _rest = 1.5;

/// Seconds before a constellation can be traced again.
const _repeat = 90.0;

/// Seconds a star's sparkle lasts.
const _sparkleLife = 1.6;

/// The square logical pixels of sky in view that sparkle at the set rate:
/// a full 1440 by 900 window's, beside a 200-wide sidebar. A smaller sky
/// sparkles less often.
const _sparkleArea = 1199.0 * 807;

/// A satellite train's points behind the first, and their spacing.
const _trainCars = 7;
const _trainGap = 14.0;

/// Seconds the sky's turning takes to ease up, or to coast down, by about
/// two thirds: as a heavy wheel's would, never starting or stopping dead.
const _coast = 0.5;

/// Seconds a clear takes to fade once what it kept clear has gone.
const _clearFade = 0.4;

/// Taken off the wait for a resting step, so the frame it asks for lands
/// on the vsync at the step, not the one after.
const _restSlack = Duration(milliseconds: 4);

/// Logical pixels the lean may move in one step and still count as
/// resting.
const _leanRest = 0.01;

class _GaiaSkyState extends State<GaiaSky> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _sky = _Sky(Random());

  /// The frame of the last step, so the next knows how long it's been,
  /// frames or not between them; null when stopped.
  Duration? _lastTick;

  /// Set while waiting for a resting step, at [GaiaSky.restRate].
  Timer? _wake;

  /// The starfield's lean at the last step, to tell if it's moving.
  Offset? _lastLean;
  var _reduced = false;

  bool get _running => _ticker.isActive || _wake != null;

  @override
  void initState() {
    super.initState();
    _apply();
    if (widget.shown) {
      _sky.begin();
      _blinkIn();
    }
    widget.active.addListener(_sync);
  }

  @override
  void didUpdateWidget(GaiaSky oldWidget) {
    super.didUpdateWidget(oldWidget);
    _apply();
    if (oldWidget.satellite != widget.satellite) _sky.sendSatellite();
    if (oldWidget.burstTest != widget.burstTest) _sky.sendShowerBurst();
    final test = oldWidget.exitTest != widget.exitTest && widget.shown;
    if ((oldWidget.shown && !widget.shown) || test) {
      if (_sky.exiting != null) {
        _sky.returning = false;
      } else if (widget.sent || test) {
        _sky.exit = widget.exit;
        _sky.exiting = 0;
      }
      // Else another chat opened, rather than a prompt sent: no exit under
      // the chat coming in, the whole sky just fades, quickly, with the
      // greeting.
    } else if (!oldWidget.shown && widget.shown && _sky.exiting != null) {
      _sky.returning = true;
    } else if (!oldWidget.shown && widget.shown) {
      // Back before it had faded: the same sky, not a new one.
      if (_sky.opacity == 0) _sky.begin();
      _blinkIn();
    }
    if (oldWidget.active != widget.active) {
      oldWidget.active.removeListener(_sync);
      widget.active.addListener(_sync);
    }
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    _starfield = GaiaStarfield.of(context);
    _glow = GaiaStarfield.glowOf(context);
    _lean = GaiaStarfield.leanOf(context);
    _sync();
  }

  /// The starfield behind, which turns with the sky, so as it goes its
  /// stars are left as they are.
  void Function(double radians)? _starfield;
  void Function(double glow)? _glow;

  /// The starfield's lean towards the cursor, which the sky leans by too.
  Offset Function()? _lean;

  @override
  void dispose() {
    widget.active.removeListener(_sync);
    _wake?.cancel();
    _ticker.dispose();
    // Gone mid-exit, the starfield's left as bright as it was.
    _glow?.call(0);
    _sky.dispose();
    super.dispose();
  }

  void _apply() {
    _sky
      ..shown = widget.shown
      ..rotation = widget.rotation * pi / 180 / 60
      ..density = widget.stars
      ..twinkle = widget.twinkle
      ..sparkleRate = widget.sparkles
      ..traceSpeed = widget.traceSpeed
      ..figures = widget.figures
      ..eventInterval = widget.eventInterval
      ..aurora = widget.aurora
      ..satellite = widget.satellite
      ..auroraExit = widget.auroraExit
      ..auroraDrift = widget.auroraDrift
      ..forceRare = widget.rareAurora
      ..rareColours = widget.rareColours
      ..shower = switch (widget.shower) {
        GaiaSkyShower.calendar =>
          gaiaMeteorShower(DateTime.now())?.strength ?? 0,
        GaiaSkyShower.off => 0,
        GaiaSkyShower.light => 0.15,
        GaiaSkyShower.medium => 0.4,
        GaiaSkyShower.peak => 1,
      }
      ..plainBlink = widget.plainBlink
      ..exitTime = widget.exitTime;
    // Not mid-exit: the exit under way keeps the way it's going.
    if (_sky.exiting == null) _sky.exit = widget.exit;
  }

  /// Coming with a blink-out to leave by, the stars light up as they would
  /// blink out: the exit played back from its end. Back before it had
  /// faded, it fades in from where it is instead.
  void _blinkIn() {
    if (widget.exit != GaiaSkyExit.blinkOut || _sky.opacity > 0) return;
    _sky
      ..exiting = 1
      ..returning = true
      ..opacity = 1;
  }

  void _sync() {
    final run =
        !_reduced && (_sky.leaving || (widget.shown && widget.active.value));
    if (!run) {
      _wake?.cancel();
      _wake = null;
      _ticker.stop();
      _lastTick = null;
      _sky.settle();
      _glow?.call(0);
    } else if (_wake == null || _sky.quick) {
      // Waiting for a resting step, unless something quick has started.
      _wake?.cancel();
      _wake = null;
      if (!_ticker.isActive) _ticker.start();
    }
  }

  void _tick(Duration _) {
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    // Capped, so a stall doesn't jump the sky.
    final dt = switch (_lastTick) {
      final last? => min((now - last).inMicroseconds / 1e6, 0.1),
      null => 0.0,
    };
    _lastTick = now;
    final spin = _sky.spin;
    _sky.step(dt);
    _starfield?.call(spin - _sky.spin);
    // Brightest halfway through an exit, as the sky's own stars go; not at
    // all in a plain blink-out, which only fades.
    final plain = _sky.plainBlink && _sky.exit == GaiaSkyExit.blinkOut;
    _glow?.call(switch (_sky.exiting) {
      final p? when !plain => 0.8 * sin(pi * p),
      _ => 0.0,
    });
    // Stops once it has left.
    _sync();
    // The starfield's lean is drawn by both, so the sky keeps up with it.
    final lean = _lean?.call();
    final leaning =
        lean != null && (lean - (_lastLean ?? lean)).distance > _leanRest;
    _lastLean = lean;
    final rate = widget.restRate;
    if (rate <= 0 || !_ticker.isActive || _sky.quick || leaning) return;
    _ticker.stop();
    _wake = Timer(
      Duration(microseconds: (1e6 / rate).round()) - _restSlack,
      () {
        _wake = null;
        _sync();
      },
    );
  }

  /// The sky's own box, which [_clears] are measured from.
  final _canvas = GlobalKey();

  /// The [GaiaSkyClear]s over the sky.
  final _clears = <GlobalKey>{};

  /// Each clear's box and opacity as last painted, for it to fade from once
  /// it's gone: by then it can't be measured.
  final _lastRects = <GlobalKey, (Rect, double)>{};

  /// [_clears]' boxes, in the sky's, each with its [GaiaSkyClear.opacity].
  List<(Rect, double)> _clearRects() {
    final sky = _canvas.currentContext?.findRenderObject();
    if (sky is! RenderBox || !sky.hasSize) return const [];
    return [
      for (final key in _clears)
        if (key.currentContext?.findRenderObject() case final RenderBox box
            when box.attached && box.hasSize)
          _lastRects[key] = (
            MatrixUtils.transformRect(
              box.getTransformTo(sky),
              Offset.zero & box.size,
            ),
            (key.currentWidget! as _ClearBox).opacity,
          ),
    ];
  }

  void _clear(GlobalKey key, {required bool add}) {
    if (add) {
      _clears.add(key);
    } else {
      _clears.remove(key);
      final last = _lastRects.remove(key);
      // Fading only while the sky ticks; otherwise it's simply gone.
      if (last != null && _running) {
        _sky.cleared.add(last);
        _sync();
      }
    }
    _sky.repaint();
  }

  @override
  Widget build(BuildContext context) {
    // Boundaries on both sides, so a frame repaints only the sky.
    return RepaintBoundary(
      child: CustomPaint(
        key: _canvas,
        painter: _SkyPainter(
          _sky,
          widget.top,
          widget.left,
          Theme.of(context).scaffoldBackgroundColor,
          _clearRects,
          _lean,
        ),
        child: RepaintBoundary(
          child: _SkyScope(clear: _clear, child: widget.child),
        ),
      ),
    );
  }
}

class _SkyScope extends InheritedWidget {
  const _SkyScope({required this.clear, required super.child});

  final void Function(GlobalKey key, {required bool add}) clear;

  @override
  bool updateShouldNotify(_SkyScope oldWidget) => oldWidget.clear != clear;
}

/// Keeps the [GaiaSky] behind [child] clear: the stars fade out around it,
/// so text over the sky is always legible.
class GaiaSkyClear extends StatefulWidget {
  const GaiaSkyClear({super.key, this.opacity = 1, required this.child});

  /// How much of the clear is kept, 0 to 1: fading with [child], so the
  /// stars come back behind it as it goes.
  final double opacity;

  final Widget child;

  @override
  State<GaiaSkyClear> createState() => _GaiaSkyClearState();
}

class _GaiaSkyClearState extends State<GaiaSkyClear> {
  final _key = GlobalKey();
  _SkyScope? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = context.dependOnInheritedWidgetOfExactType<_SkyScope>();
    if (scope?.clear == _scope?.clear) return;
    _scope?.clear(_key, add: false);
    scope?.clear(_key, add: true);
    _scope = scope;
  }

  @override
  void didUpdateWidget(GaiaSkyClear oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Repainted by the sky, which may be still.
    if (oldWidget.opacity != widget.opacity) _scope?.clear(_key, add: true);
  }

  // Out of the tree for the frame's paint as soon as it's taken out, not
  // only once it's gone for good: an inactive box can't be measured.
  @override
  void deactivate() {
    _scope?.clear(_key, add: false);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _scope?.clear(_key, add: true);
  }

  @override
  Widget build(BuildContext context) => _ClearBox(
    key: _key,
    opacity: widget.opacity,
    // Re-measured by the sky, which otherwise does so only as it paints:
    // still, it would keep the clear where the child was.
    onMoved: () => _scope?.clear(_key, add: true),
    child: widget.child,
  );
}

/// Tells [onMoved] once the frame it painted in is done, whenever its box
/// paints somewhere new or at a new size.
class _ClearBox extends SingleChildRenderObjectWidget {
  const _ClearBox({
    super.key,
    required this.opacity,
    required this.onMoved,
    super.child,
  });

  /// Read by the sky as it measures the box.
  final double opacity;

  final VoidCallback onMoved;

  @override
  _RenderClearBox createRenderObject(BuildContext context) =>
      _RenderClearBox(onMoved);

  @override
  void updateRenderObject(BuildContext context, _RenderClearBox box) =>
      box.onMoved = onMoved;
}

class _RenderClearBox extends RenderProxyBox {
  _RenderClearBox(this.onMoved);

  VoidCallback onMoved;
  Rect? _painted;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final rect = localToGlobal(Offset.zero) & size;
    if (rect == _painted) return;
    final first = _painted == null;
    _painted = rect;
    // Not mid-paint, and not for its first: the sky measures that one.
    if (!first) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (attached) onMoved();
      });
    }
  }
}

/// A constellation's figure: its stars, and the lines between them in the
/// order they're traced, all within a unit circle about its centre.
class _Shape {
  _Shape(
    List<Offset> stars,
    this.edges,
    this.size, [
    List<_Stroke> art = const [],
  ]) : points = _normalised(stars, stars),
       art = [
         for (final stroke in art)
           (points: _normalised(stroke.points, stars), smooth: stroke.smooth),
       ] {
    final lengths = [
      for (final (a, b) in edges) (points[a] - points[b]).distance,
    ];
    total = lengths.fold(0.0, (sum, length) => sum + length);
    var at = 0.0;
    for (final length in lengths) {
      starts.add(at / total);
      at += length;
      ends.add(at / total);
    }
    reached = List.filled(points.length, 1.0);
    for (final (k, (a, b)) in edges.indexed) {
      reached[a] = min(reached[a], starts[k]);
      reached[b] = min(reached[b], ends[k]);
    }
  }

  final List<Offset> points;
  final List<(int, int)> edges;

  /// A sketch of the figure it's named for, in the same terms as [points].
  final List<_Stroke> art;

  /// Its radius in logical pixels, in a mid-sized window.
  final double size;

  /// The length of all its lines, in radii.
  late final double total;

  /// Each line's start and end, as shares of the tracing: the pen keeps a
  /// steady speed.
  final starts = <double>[], ends = <double>[];

  /// When the pen first reaches each star, as a share of the tracing.
  late final List<double> reached;

  /// [points] about the centre of [stars]' bounds, in units of the farthest
  /// star from it.
  static List<Offset> _normalised(List<Offset> points, List<Offset> stars) {
    final bounds = stars.fold(
      Rect.fromPoints(stars.first, stars.first),
      (rect, p) => rect.expandToInclude(Rect.fromPoints(p, p)),
    );
    final centre = bounds.center;
    final extent = stars.map((p) => (p - centre).distance).reduce(max);
    return [for (final p in points) (p - centre) / extent];
  }
}

/// One line of a figure's sketch: a smooth curve through its points, or
/// straight from one to the next.
typedef _Stroke = ({List<Offset> points, bool smooth});

_Stroke _curve(List<Offset> points) => (points: points, smooth: true);

_Stroke _straight(List<Offset> points) => (points: points, smooth: false);

/// A head, an eye, a jewel.
_Stroke _ring(Offset centre, double r) => _curve([
  for (var i = 0; i <= 10; i++)
    centre + Offset(cos(i * pi / 5), sin(i * pi / 5)) * r,
]);

/// Rough figures of a few constellations, x rightwards and y down, with
/// sketches of what each is named for.
final _shapes = [
  // The Big Dipper, the Great Bear's back and tail.
  _Shape(
    const [
      Offset(0, 0.1),
      Offset(0.28, 0),
      Offset(0.5, 0.05),
      Offset(0.72, 0.12),
      Offset(0.78, 0.38),
      Offset(1.08, 0.42),
      Offset(1.05, 0.12),
    ],
    const [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 3)],
    110,
    [
      _curve(const [
        Offset(0, 0.1),
        Offset(0.3, 0.02),
        Offset(0.72, 0.1),
        Offset(1.05, 0.02),
        Offset(1.4, -0.05),
        Offset(1.7, 0),
        Offset(1.9, 0.12),
        Offset(1.85, 0.25),
        Offset(1.65, 0.3),
        Offset(1.55, 0.5),
        Offset(1.2, 0.55),
        Offset(0.85, 0.5),
        Offset(0.76, 0.38),
        Offset(0.72, 0.1),
      ]),
      _curve(const [Offset(1.68, 0), Offset(1.72, -0.1), Offset(1.8, -0.02)]),
      _curve(const [Offset(1.5, 0.5), Offset(1.55, 0.8), Offset(1.62, 0.95)]),
      _curve(const [Offset(1.4, 0.52), Offset(1.4, 0.85), Offset(1.45, 0.95)]),
      _curve(const [
        Offset(0.95, 0.52),
        Offset(0.92, 0.85),
        Offset(0.98, 0.95),
      ]),
      _curve(const [
        Offset(0.83, 0.48),
        Offset(0.78, 0.85),
        Offset(0.82, 0.95),
      ]),
    ],
  ),
  // Cassiopeia, the queen on her throne.
  _Shape(
    const [
      Offset(0, 0.1),
      Offset(0.25, 0.45),
      Offset(0.5, 0.2),
      Offset(0.75, 0.5),
      Offset(1, 0.15),
    ],
    const [(0, 1), (1, 2), (2, 3), (3, 4)],
    85,
    [
      _straight(const [
        Offset(0.95, -0.3),
        Offset(1, 0.15),
        Offset(0.95, 0.58),
        Offset(0.3, 0.58),
        Offset(0.28, 0.95),
      ]),
      _straight(const [Offset(0.95, 0.58), Offset(0.97, 0.95)]),
      _ring(const Offset(0.75, -0.25), 0.08),
      _curve(const [Offset(0.75, -0.16), Offset(0.7, 0.2), Offset(0.6, 0.5)]),
      _curve(const [Offset(0.72, 0), Offset(0.45, 0.15), Offset(0.2, 0.05)]),
      _curve(const [Offset(0.6, 0.5), Offset(0.25, 0.55), Offset(0.15, 0.9)]),
    ],
  ),
  // Orion, the hunter, club raised and shield out.
  _Shape(
    const [
      Offset(0.45, -0.15),
      Offset(0.15, 0),
      Offset(0.75, 0.08),
      Offset(0.35, 0.5),
      Offset(0.47, 0.47),
      Offset(0.58, 0.43),
      Offset(0.25, 1),
      Offset(0.85, 0.95),
    ],
    const [(1, 0), (0, 2), (2, 5), (5, 4), (4, 3), (3, 1), (3, 6), (5, 7)],
    105,
    [
      _ring(const Offset(0.45, -0.17), 0.08),
      _curve(const [Offset(0.15, 0), Offset(0.3, 0.25), Offset(0.35, 0.5)]),
      _curve(const [
        Offset(0.75, 0.08),
        Offset(0.62, 0.25),
        Offset(0.58, 0.43),
      ]),
      _curve(const [
        Offset(0.33, 0.52),
        Offset(0.25, 0.75),
        Offset(0.4, 0.78),
        Offset(0.6, 0.72),
        Offset(0.62, 0.46),
      ]),
      _curve(const [Offset(0.3, 0.77), Offset(0.25, 1)]),
      _curve(const [Offset(0.55, 0.74), Offset(0.85, 0.95)]),
      _curve(const [
        Offset(0.15, 0),
        Offset(0, -0.2),
        Offset(0.05, -0.45),
        Offset(0.2, -0.7),
      ]),
      _curve(const [Offset(0.75, 0.08), Offset(0.95, 0.05)]),
      _curve(const [
        Offset(1, -0.25),
        Offset(1.08, -0.05),
        Offset(1.1, 0.15),
        Offset(1.05, 0.35),
      ]),
      _straight(const [Offset(0.47, 0.5), Offset(0.48, 0.72)]),
    ],
  ),
  // Cygnus, the swan in flight.
  _Shape(
    const [
      Offset(0.5, 0),
      Offset(0.5, 0.33),
      Offset(0.52, 0.62),
      Offset(0.55, 1),
      Offset(0.15, 0.22),
      Offset(0.88, 0.48),
    ],
    const [(0, 1), (1, 2), (2, 3), (4, 1), (1, 5)],
    100,
    [
      _curve(const [
        Offset(0.5, 0.33),
        Offset(0.3, 0.2),
        Offset(0.15, 0.22),
        Offset(-0.1, 0.1),
        Offset(-0.25, -0.05),
        Offset(0, 0.25),
        Offset(0.3, 0.35),
      ]),
      _curve(const [
        Offset(0.5, 0.33),
        Offset(0.7, 0.42),
        Offset(0.88, 0.48),
        Offset(1.1, 0.5),
        Offset(1.25, 0.45),
        Offset(1, 0.62),
        Offset(0.65, 0.45),
      ]),
      _curve(const [
        Offset(0.5, 0.33),
        Offset(0.45, 0.1),
        Offset(0.5, -0.08),
        Offset(0.58, 0.08),
        Offset(0.55, 0.33),
      ]),
      _curve(const [
        Offset(0.5, 0.4),
        Offset(0.52, 0.62),
        Offset(0.53, 0.85),
        Offset(0.55, 1),
        Offset(0.62, 1.06),
      ]),
    ],
  ),
  // Lyra, the lyre.
  _Shape(
    const [
      Offset(0.15, 0),
      Offset(0.4, 0.3),
      Offset(0.72, 0.36),
      Offset(0.8, 0.82),
      Offset(0.5, 0.76),
    ],
    const [(0, 1), (1, 2), (2, 3), (3, 4), (4, 1)],
    50,
    [
      _curve(const [
        Offset(0.5, 0.78),
        Offset(0.35, 0.4),
        Offset(0.3, 0),
        Offset(0.42, -0.1),
      ]),
      _curve(const [
        Offset(0.8, 0.84),
        Offset(0.85, 0.4),
        Offset(0.75, 0),
        Offset(0.62, -0.08),
      ]),
      _straight(const [Offset(0.3, 0.05), Offset(0.78, 0.05)]),
      _straight(const [Offset(0.5, 0.78), Offset(0.8, 0.84)]),
      _straight(const [Offset(0.45, 0.06), Offset(0.6, 0.79)]),
      _straight(const [Offset(0.55, 0.06), Offset(0.68, 0.81)]),
      _straight(const [Offset(0.65, 0.06), Offset(0.74, 0.82)]),
    ],
  ),
  // Leo.
  _Shape(
    const [
      Offset(0, 0.2),
      Offset(0.08, 0.04),
      Offset(0.22, 0.1),
      Offset(0.25, 0.35),
      Offset(0.15, 0.55),
      Offset(0.17, 0.85),
      Offset(0.68, 0.72),
      Offset(1, 0.62),
      Offset(0.7, 0.38),
    ],
    const [
      (0, 1),
      (1, 2),
      (2, 3),
      (3, 4),
      (4, 5),
      (5, 6),
      (6, 7),
      (7, 8),
      (8, 3),
    ],
    110,
    [
      // The sickle is his mane.
      _curve(const [
        Offset(0.25, 0.35),
        Offset(0.3, 0.15),
        Offset(0.15, -0.05),
        Offset(-0.05, 0.05),
        Offset(-0.12, 0.25),
        Offset(0, 0.4),
        Offset(0.15, 0.5),
      ]),
      _curve(const [
        Offset(0.28, 0.25),
        Offset(0.55, 0.32),
        Offset(0.7, 0.38),
        Offset(0.95, 0.5),
        Offset(1, 0.62),
        Offset(1.15, 0.55),
        Offset(1.25, 0.7),
        Offset(1.22, 0.85),
      ]),
      _curve(const [
        Offset(0.17, 0.6),
        Offset(0.4, 0.75),
        Offset(0.68, 0.75),
        Offset(0.95, 0.72),
      ]),
      _curve(const [Offset(0.17, 0.6), Offset(0.17, 0.85), Offset(0.12, 1.05)]),
      _curve(const [Offset(0.3, 0.7), Offset(0.32, 1.05)]),
      _curve(const [Offset(0.82, 0.74), Offset(0.85, 1.05)]),
      _curve(const [Offset(0.95, 0.7), Offset(1, 1.05)]),
    ],
  ),
  // Scorpius.
  _Shape(
    const [
      Offset(0.08, 0),
      Offset(0.05, 0.15),
      Offset(0.02, 0.3),
      Offset(0.22, 0.22),
      Offset(0.3, 0.3),
      Offset(0.38, 0.38),
      Offset(0.45, 0.55),
      Offset(0.48, 0.72),
      Offset(0.5, 0.88),
      Offset(0.62, 0.98),
      Offset(0.8, 0.95),
      Offset(0.92, 0.85),
      Offset(0.88, 0.72),
      Offset(1, 0.68),
    ],
    const [
      (0, 1),
      (1, 2),
      (1, 3),
      (3, 4),
      (4, 5),
      (5, 6),
      (6, 7),
      (7, 8),
      (8, 9),
      (9, 10),
      (10, 11),
      (11, 12),
      (12, 13),
    ],
    115,
    [
      // Claws, body and legs, its tail the stars' own hook.
      _curve(const [
        Offset(0.08, 0),
        Offset(-0.05, -0.15),
        Offset(-0.15, -0.1),
      ]),
      _curve(const [Offset(-0.05, -0.15), Offset(0, -0.25)]),
      _curve(const [
        Offset(0.02, 0.3),
        Offset(-0.12, 0.35),
        Offset(-0.2, 0.25),
      ]),
      _curve(const [Offset(-0.12, 0.35), Offset(-0.22, 0.45)]),
      _curve(const [
        Offset(0.15, 0.12),
        Offset(0.3, 0.22),
        Offset(0.42, 0.38),
        Offset(0.52, 0.55),
      ]),
      _curve(const [
        Offset(0.1, 0.28),
        Offset(0.26, 0.38),
        Offset(0.36, 0.5),
        Offset(0.44, 0.6),
      ]),
      _straight(const [Offset(0.25, 0.32), Offset(0.15, 0.45)]),
      _straight(const [Offset(0.33, 0.4), Offset(0.25, 0.55)]),
      _straight(const [Offset(0.3, 0.25), Offset(0.42, 0.15)]),
      _straight(const [Offset(0.38, 0.32), Offset(0.5, 0.25)]),
      _curve(const [Offset(1, 0.68), Offset(1.05, 0.55), Offset(0.98, 0.5)]),
    ],
  ),
  // The Southern Cross.
  _Shape(
    const [
      Offset(0.5, 0),
      Offset(0.5, 1),
      Offset(0.1, 0.45),
      Offset(0.85, 0.4),
    ],
    const [(0, 1), (2, 3)],
    45,
    [
      _straight(const [
        Offset(0.45, -0.05),
        Offset(0.55, -0.05),
        Offset(0.55, 0.37),
        Offset(0.9, 0.35),
        Offset(0.9, 0.45),
        Offset(0.55, 0.47),
        Offset(0.55, 1.05),
        Offset(0.45, 1.05),
        Offset(0.45, 0.48),
        Offset(0.05, 0.5),
        Offset(0.05, 0.4),
        Offset(0.45, 0.38),
        Offset(0.45, -0.05),
      ]),
    ],
  ),
  // The Little Dipper, the Little Bear, Polaris at its tail's tip.
  _Shape(
    const [
      Offset(0, 0),
      Offset(0.18, 0.08),
      Offset(0.33, 0.2),
      Offset(0.5, 0.3),
      Offset(0.75, 0.25),
      Offset(0.8, 0.5),
      Offset(0.55, 0.55),
    ],
    const [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 3)],
    85,
    [
      _curve(const [
        Offset(0, 0),
        Offset(0.33, 0.15),
        Offset(0.5, 0.26),
        Offset(0.75, 0.2),
        Offset(1, 0.28),
        Offset(1.08, 0.4),
        Offset(0.95, 0.48),
        Offset(0.8, 0.56),
        Offset(0.55, 0.6),
        Offset(0.5, 0.3),
      ]),
      _curve(const [Offset(0.82, 0.56), Offset(0.85, 0.78)]),
      _curve(const [Offset(0.6, 0.6), Offset(0.58, 0.8)]),
    ],
  ),
  // Gemini, the twins, arm in arm.
  _Shape(
    const [
      Offset(0.1, 0),
      Offset(0.35, 0.05),
      Offset(0.15, 0.35),
      Offset(0.25, 0.7),
      Offset(0.3, 1),
      Offset(0.45, 0.35),
      Offset(0.6, 0.65),
      Offset(0.7, 0.95),
    ],
    const [(0, 2), (2, 3), (3, 4), (0, 1), (1, 5), (5, 6), (6, 7)],
    95,
    [
      _ring(const Offset(0.1, -0.06), 0.07),
      _ring(const Offset(0.35, -0.01), 0.07),
      _curve(const [Offset(0.1, 0.02), Offset(0.15, 0.35), Offset(0.22, 0.65)]),
      _curve(const [Offset(0.22, 0.65), Offset(0.18, 1)]),
      _curve(const [Offset(0.22, 0.65), Offset(0.32, 1)]),
      _curve(const [
        Offset(0.36, 0.07),
        Offset(0.45, 0.35),
        Offset(0.55, 0.62),
      ]),
      _curve(const [Offset(0.55, 0.62), Offset(0.55, 0.95)]),
      _curve(const [Offset(0.55, 0.62), Offset(0.7, 0.95)]),
      _curve(const [Offset(0.13, 0.2), Offset(0.28, 0.18), Offset(0.42, 0.22)]),
    ],
  ),
  // Taurus, the bull's head, the V its face and the long horns.
  _Shape(
    const [
      Offset(0.55, 0.65),
      Offset(0.4, 0.5),
      Offset(0, 0.1),
      Offset(0.65, 0.48),
      Offset(1, 0.05),
      Offset(0.75, 0.9),
    ],
    const [(5, 0), (0, 1), (1, 2), (0, 3), (3, 4)],
    100,
    [
      _curve(const [
        Offset(0.35, 0.42),
        Offset(0.4, 0.65),
        Offset(0.55, 0.85),
        Offset(0.7, 0.65),
        Offset(0.72, 0.42),
      ]),
      _curve(const [Offset(0.38, 0.4), Offset(0.15, 0.25), Offset(0, 0.1)]),
      _curve(const [Offset(0.7, 0.4), Offset(0.85, 0.2), Offset(1, 0.05)]),
      _curve(const [Offset(0.35, 0.42), Offset(0.2, 0.47)]),
      _curve(const [Offset(0.72, 0.42), Offset(0.88, 0.44)]),
    ],
  ),
  // Corona Borealis, the northern crown.
  _Shape(
    const [
      Offset(0, 0.3),
      Offset(0.15, 0.65),
      Offset(0.35, 0.85),
      Offset(0.6, 0.88),
      Offset(0.82, 0.7),
      Offset(1, 0.4),
    ],
    const [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5)],
    50,
    [
      _curve(const [
        Offset(-0.05, 0.28),
        Offset(0.1, 0.7),
        Offset(0.35, 0.93),
        Offset(0.62, 0.96),
        Offset(0.88, 0.75),
        Offset(1.06, 0.38),
      ]),
      _curve(const [
        Offset(0.08, 0.3),
        Offset(0.2, 0.6),
        Offset(0.37, 0.77),
        Offset(0.58, 0.8),
        Offset(0.78, 0.64),
        Offset(0.92, 0.38),
      ]),
    ],
  ),
  // Aquila, the eagle, wings spread.
  _Shape(
    const [
      Offset(0.5, 0.4),
      Offset(0.44, 0.3),
      Offset(0.56, 0.5),
      Offset(0.05, 0.6),
      Offset(0.95, 0.15),
      Offset(0.65, 1),
    ],
    const [(1, 0), (0, 2), (0, 3), (0, 4), (0, 5)],
    95,
    [
      _curve(const [
        Offset(0.48, 0.45),
        Offset(0.25, 0.5),
        Offset(0.05, 0.6),
        Offset(-0.1, 0.72),
        Offset(0.15, 0.72),
        Offset(0.45, 0.58),
      ]),
      _curve(const [
        Offset(0.55, 0.35),
        Offset(0.75, 0.22),
        Offset(0.95, 0.15),
        Offset(1.1, 0.05),
        Offset(0.95, 0.32),
        Offset(0.6, 0.48),
      ]),
      _curve(const [Offset(0.44, 0.32), Offset(0.36, 0.22), Offset(0.3, 0.25)]),
      _curve(const [Offset(0.5, 0.45), Offset(0.6, 0.75), Offset(0.65, 1)]),
      _curve(const [
        Offset(0.58, 0.95),
        Offset(0.65, 1.08),
        Offset(0.74, 0.98),
      ]),
    ],
  ),
  // Pegasus's square, and Andromeda's chain off its corner.
  _Shape(
    const [
      Offset(0, 0),
      Offset(0.4, 0.05),
      Offset(0.42, 0.45),
      Offset(0.02, 0.42),
      Offset(0.65, -0.05),
      Offset(0.85, -0.2),
      Offset(1.05, -0.35),
    ],
    const [(0, 1), (1, 2), (2, 3), (3, 0), (1, 4), (4, 5), (5, 6)],
    120,
    [
      // The winged horse's body, neck, legs and wing.
      _curve(const [
        Offset(0, 0),
        Offset(-0.25, 0.15),
        Offset(-0.4, 0.35),
        Offset(-0.5, 0.38),
      ]),
      _curve(const [Offset(0.02, 0.42), Offset(-0.1, 0.65), Offset(0, 0.8)]),
      _curve(const [Offset(0.15, 0.45), Offset(0.1, 0.75)]),
      _curve(const [
        Offset(0.3, 0.05),
        Offset(0.3, -0.3),
        Offset(0.15, -0.45),
        Offset(0.45, -0.35),
        Offset(0.5, -0.05),
      ]),
      _curve(const [
        Offset(0, 0),
        Offset(0.2, -0.04),
        Offset(0.4, 0.05),
        Offset(0.46, 0.25),
        Offset(0.42, 0.45),
        Offset(0.2, 0.5),
        Offset(0.02, 0.42),
      ]),
    ],
  ),
];

/// [stroke] placed by [place], as a path.
Path _strokePath(_Stroke stroke, Offset Function(Offset) place) {
  final p = [for (final point in stroke.points) place(point)];
  final path = Path()..moveTo(p.first.dx, p.first.dy);
  for (var i = 0; i + 1 < p.length; i++) {
    if (!stroke.smooth) {
      path.lineTo(p[i + 1].dx, p[i + 1].dy);
      continue;
    }
    // Catmull-Rom, as Béziers: smooth through every point.
    final p0 = p[max(i - 1, 0)], p3 = p[min(i + 2, p.length - 1)];
    final c1 = p[i] + (p[i + 1] - p0) / 6;
    final c2 = p[i + 1] - (p3 - p[i]) / 6;
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p[i + 1].dx, p[i + 1].dy);
  }
  return path;
}

/// A [_Shape] set in the sky: [v] round it and [r] out from the pole, as
/// shares of the sky's span, turned by [angle] and grown by [scale]. It
/// leans towards the cursor as one, by [depth], so its lines stay on its
/// stars.
class _Constellation {
  const _Constellation(
    this.shape, {
    required this.v,
    required this.r,
    required this.angle,
    required this.scale,
    required this.depth,
  });

  final _Shape shape;
  final double v, r, angle, scale, depth;
}

/// A meteor, or a satellite, crossing the sky. In logical pixels of the
/// area below the header; they don't turn with the stars.
class _Streak {
  _Streak({
    required this.at,
    required this.velocity,
    required this.life,
    this.satellite,
    this.tail = 0,
    this.flareAt,
  });

  Offset at;
  final Offset velocity;
  final double life;

  /// How a satellite looks, fixed as it sets out; null for a meteor.
  final GaiaSatellite? satellite;

  /// A meteor's tail, in logical pixels.
  final double tail;

  /// When a satellite catches the sun and flares, if it does.
  final double? flareAt;

  var age = 0.0;
}

/// The sky's state. Stars are placed in a sector of an annulus about a pole
/// above the window, just wide enough to cover it: as the sky turns, what
/// leaves one side of the sector comes back at the other, out of sight.
/// Notifies when it has moved.
class _Sky extends ChangeNotifier {
  _Sky(this._random) {
    for (var i = 0; i < _pool; i++) {
      u[i] = _random.nextDouble();
      v[i] = _random.nextDouble();
      // Mostly faint, a few bright.
      final b = 0.12 + 0.78 * pow(_random.nextDouble(), 3);
      bright[i] = b;
      kind[i] = b > 0.6
          ? 2
          : b > 0.3
          ? 1
          : 0;
      // Colour shows in the brighter stars: the eye sees faint ones white.
      tint[i] = _random.nextDouble() < 0.25 + 0.6 * (b - 0.12) / 0.78
          ? 1 + _random.nextInt(kGaiaStarTints.length - 1)
          : 0;
      rate[i] = 0.4 + _random.nextDouble() * 1.2;
      phase[i] = _random.nextDouble() * 2 * pi;
      // As the starfield's.
      depth[i] = 0.03 + _random.nextDouble() * 0.97;
    }
    final shapes = [..._shapes]..shuffle(_random);
    for (final (i, shape) in shapes.indexed) {
      constellations.add(
        _Constellation(
          shape,
          v: (i + 0.2 + _random.nextDouble() * 0.6) / shapes.length,
          r: _random.nextDouble(),
          angle: (_random.nextDouble() - 0.5) * 1.2,
          scale: 0.85 + _random.nextDouble() * 0.3,
          // Among the nearer stars, as their brightness has them.
          depth: 0.5 + _random.nextDouble() * 0.4,
        ),
      );
    }
  }

  final Random _random;

  /// Each star's place: [u] a share of the annulus's area outwards, [v] a
  /// share of the sector round.
  final u = Float32List(_pool), v = Float32List(_pool);

  /// Its brightness, 0 to 1, and its twinkle's rate and phase.
  final bright = Float32List(_pool);
  final rate = Float32List(_pool), phase = Float32List(_pool);

  /// Its size, 0 to 2, and colour, of [kGaiaStarTints].
  final kind = Uint8List(_pool), tint = Uint8List(_pool);

  /// How far it leans towards the cursor, as a share of [lean].
  final depth = Float32List(_pool);

  /// How far the nearest stars lean towards the cursor, in logical pixels:
  /// the starfield's lean, set by each paint, so the two lean as one.
  var lean = Offset.zero;

  final constellations = <_Constellation>[];
  final streaks = <_Streak>[];

  var shown = false;

  /// Radians a second.
  var rotation = 0.0;
  var density = 0.0;
  var twinkle = 0.0;
  var sparkleRate = 0.0;
  var traceSpeed = 80.0;
  var figures = false;
  var aurora = 0.0;
  var auroraDrift = 1.0;
  var forceRare = false;

  /// The rare aurora's colours; null, [_rolledColours].
  GaiaRareAurora? rareColours;

  /// The rare aurora's colours, as rolled by their shares when it came.
  var _rolledColours = GaiaRareAurora.crimson;

  GaiaRareAurora get colours => rareColours ?? _rolledColours;

  GaiaRareAurora _pickColours() {
    var roll = _random.nextDouble();
    for (final colours in GaiaRareAurora.values) {
      roll -= colours.share;
      if (roll < 0) return colours;
    }
    return GaiaRareAurora.values.last;
  }

  /// The meteor shower's strength, 0 to 1.
  var shower = 0.0;
  var satellite = GaiaSatellite.dot;
  var auroraExit = GaiaAuroraExit.rise;
  var exit = GaiaSkyExit.warp;
  var plainBlink = false;
  var exitTime = 1.0;

  /// Seconds the sky has run.
  var time = 0.0;

  /// Radians the sky has turned.
  var spin = 0.0;

  /// Its fade, 0 to 1.
  var opacity = 0.0;

  /// How fast it's turning, as a share of [rotation].
  var speed = 0.0;

  /// The boxes of clears just gone, in the sky's box, each fading out from
  /// 1 so the stars come back behind it softly.
  final cleared = <(Rect, double)>[];

  /// The exit's progress, 0 to 1; null unless it's leaving by [exit].
  double? exiting;

  /// The chat emptied again mid-exit: the exit plays back to the sky as it
  /// was, rather than finishing and the sky starting over.
  var returning = false;

  /// The constellation being traced; how much of it the pen has, 0 to 1;
  /// and the seconds since it finished.
  int? drawing;
  var traced = 0.0;
  var held = 0.0;
  var _wait = 2.0;

  /// When each constellation was last traced, by [time].
  final _tracedAt = <int, double>{};

  var _nextEvent = 4.0;
  var _nextSatellite = 10.0;
  var _nextShower = 2.0;

  /// This sky's aurora is the rare one, as rolled when it came.
  var _rare = false;

  /// The aurora is the rare one.
  bool get rare => forceRare || _rare;

  /// Where each of the aurora's curtains is in its waxing and waning, in
  /// radians, and how far all have come by [auroraDrift].
  final _auroraPhase = Float64List(_bands.length);
  var _auroraClock = 0.0;

  /// Where the shower's radiant hangs, out of sight above a top corner:
  /// which side, -1 the left, and how far beyond that side and above the
  /// top, as shares of the sky's width and height.
  var _radiantSide = 1.0, _radiantOut = 0.0, _radiantUp = 0.0;

  /// Seconds until each meteor of the shower's burst under way.
  final _burst = <double>[];

  /// The average seconds from one meteor or satellite to the next. A change
  /// rescales what is pending, so it comes on the new clock.
  double get eventInterval => _eventInterval;
  var _eventInterval = 15.0;
  set eventInterval(double value) {
    if (value == _eventInterval) return;
    _nextEvent *= value / _eventInterval;
    _nextSatellite *= value / _eventInterval;
    _eventInterval = value;
  }

  /// At most three satellites up at once.
  bool get _satelliteRoom =>
      streaks.where((s) => s.satellite != null).length < 3;

  /// Stars sparkling: which, and for how long they have been.
  final sparkles = <({int star, double age})>[];

  /// What's kept clear of stars, as last painted: no star there sparkles,
  /// since none of it would show.
  var hidden = <Rect>[];
  var _nextSparkle = 1.0;

  /// Set by each paint: the area below the header, and the sidebar's edge.
  var size = Size.zero;
  var from = 0.0;

  var _pole = Offset.zero;
  var _rMin = 0.0, _rMin2 = 0.0, _rMax2 = 0.0;

  /// The sector's start, and its width, in radians.
  var _s0 = 0.0, _w = 0.0;

  bool get leaving =>
      exiting != null || cleared.isNotEmpty || (!shown && opacity > 0);

  /// Something on it moves too quickly for [GaiaSky.restRate]: coming or
  /// going, a clear fading, a meteor, or the pen tracing.
  bool get quick =>
      leaving ||
      (shown && opacity < 1) ||
      // The pen tracing, the figure sketched in, or the lines unwriting.
      (drawing != null && (held < 1.2 || held >= _hold)) ||
      streaks.any((s) => s.satellite == null);

  /// The pole the sky turns about.
  Offset get pole => _pole;

  void layout(Size size, double from) {
    this.from = from;
    if (size == this.size) return;
    this.size = size;
    // Above the middle, so the sky wheels across the window, not round it.
    _pole = Offset(size.width / 2, -size.height / 2);
    var a0 = double.infinity, a1 = double.negativeInfinity, far = 0.0;
    for (final corner in [
      Offset.zero,
      size.topRight(Offset.zero),
      size.bottomLeft(Offset.zero),
      size.bottomRight(Offset.zero),
    ]) {
      final d = corner - _pole;
      final a = atan2(d.dy, d.dx);
      a0 = min(a0, a);
      a1 = max(a1, a);
      far = max(far, d.distance);
    }
    _rMin = size.height / 2;
    final margin = _reach / _rMin;
    _s0 = a0 - margin;
    _w = min(a1 - a0 + 2 * margin, 2 * pi);
    _rMin2 = _rMin * _rMin;
    _rMax2 = far * far;
  }

  int get starCount =>
      (density * _w / 2 * (_rMax2 - _rMin2) / 1e6).round().clamp(0, _pool);

  Offset _around(double v, double r) {
    // Anticlockwise, as the northern sky turns.
    final theta = _s0 + (v * _w - spin) % _w;
    return _pole + Offset(cos(theta), sin(theta)) * r;
  }

  Offset star(int i) =>
      _around(v[i], sqrt(_rMin2 + u[i] * (_rMax2 - _rMin2))) + lean * depth[i];

  double starAlpha(int i) =>
      bright[i] *
      (1 - twinkle * 0.7 * (0.5 + 0.5 * sin(time * rate[i] + phase[i])));

  /// [c]'s radius in logical pixels.
  double _scale(_Constellation c) =>
      c.shape.size * c.scale * (size.shortestSide / 700).clamp(0.6, 1.2);

  /// Places a point of [c]'s, in its shape's terms, in the sky.
  Offset Function(Offset) place(_Constellation c) {
    final centre =
        _around(c.v, _rMin + size.height * (0.18 + c.r * 0.5)) + lean * c.depth;
    final scale = _scale(c);
    // Turning with the sky.
    final a = c.angle - spin;
    final ca = cos(a), sa = sin(a);
    return (p) =>
        centre + Offset(p.dx * ca - p.dy * sa, p.dx * sa + p.dy * ca) * scale;
  }

  List<Offset> points(_Constellation c) {
    final at = place(c);
    return [for (final p in c.shape.points) at(p)];
  }

  /// Repaints, with nothing moved.
  void repaint() => notifyListeners();

  /// Comes in with a new chat: an aurora of its own, now and then the rare
  /// one, and a radiant somewhere new.
  void begin() {
    _rare = _random.nextInt(kGaiaRareAurora) == 0;
    _rolledColours = _pickColours();
    for (var i = 0; i < _auroraPhase.length; i++) {
      _auroraPhase[i] = _random.nextDouble() * 2 * pi;
    }
    _radiantSide = _random.nextBool() ? 1 : -1;
    _radiantOut = 0.15 + 0.35 * _random.nextDouble();
    _radiantUp = 0.4 + 0.6 * _random.nextDouble();
    _burst.clear();
    _nextShower = 1 + 3 * _random.nextDouble();
  }

  /// How strong curtain [i] is just now against its usual, each waxing and
  /// waning over minutes on its own clock: the aurora greener a while, then
  /// more violet. Its green never goes far.
  double auroraMix(int i) {
    if (auroraDrift <= 0) return 1;
    final (low, high, period) = _auroraDrifts[i];
    final wave =
        0.5 + 0.5 * sin(_auroraClock * 2 * pi / period + _auroraPhase[i]);
    return low + (high - low) * wave;
  }

  /// Seconds the pen takes over the whole of the constellation being
  /// traced, at [traceSpeed]: a small one is quick, a large one slow.
  double get _traceTime {
    final c = constellations[drawing!];
    return c.shape.total * _scale(c) / traceSpeed;
  }

  /// How brightly star [j] of the constellation being traced flares, 0 to
  /// 1: at once as the pen reaches it, then dying away.
  double flare(int j) {
    final c = drawing;
    if (c == null) return 0;
    final since =
        (traced - constellations[c].shape.reached[j]) * _traceTime + held;
    return since < 0 ? 0 : exp(-since * 2.5);
  }

  void step(double dt) {
    time += dt;
    // Easing up from rest; then turning on as it goes, so the starfield
    // turning with it carries on at the same pace.
    speed += (1 - speed) * (1 - exp(-dt / _coast));
    spin += rotation * dt * speed;
    _auroraClock += dt * auroraDrift;
    for (var i = cleared.length - 1; i >= 0; i--) {
      final (rect, alpha) = cleared[i];
      final next = alpha - dt / _clearFade;
      next <= 0 ? cleared.removeAt(i) : cleared[i] = (rect, next);
    }
    if (exiting case final p? when returning) {
      final next = p - dt / exitTime;
      if (next <= 0) {
        exiting = null;
        returning = false;
      } else {
        exiting = next;
      }
    } else if (exiting case final p?) {
      final next = p + dt / exitTime;
      if (next >= 1) {
        exiting = null;
        opacity = 0;
        drawing = null;
        streaks.clear();
      } else {
        exiting = next;
      }
    } else {
      opacity = shown
          ? min(1, opacity + dt / _fadeIn)
          : max(0, opacity - dt / _fadeOut);
    }
    if (!size.isEmpty) {
      _stepDrawing(dt);
      _stepStreaks(dt);
      _stepSparkles(dt);
    }
    notifyListeners();
  }

  /// Still, as it is when not ticking: there, or gone.
  void settle() {
    final settled = shown ? 1.0 : 0.0;
    if (exiting == null &&
        opacity == settled &&
        speed == 1 &&
        cleared.isEmpty) {
      return;
    }
    exiting = null;
    returning = false;
    opacity = settled;
    speed = 1;
    cleared.clear();
    notifyListeners();
  }

  void _stepDrawing(double dt) {
    if (drawing != null) {
      if (traced < 1) {
        traced = min(1, traced + dt / _traceTime);
        return;
      }
      held += dt;
      if (held < _hold + _unwrite) return;
      drawing = null;
      _wait = _rest;
    }
    _wait -= dt;
    if (_wait > 0 || exiting != null || !shown) return;
    // Clear of the edges and the composer, and none traced in the last
    // [_repeat] seconds: of those, the one traced longest ago, or never.
    final box = Rect.fromLTRB(
      from + 40,
      30,
      size.width - 40,
      size.height * 0.72,
    );
    double last(int i) => _tracedAt[i] ?? double.negativeInfinity;
    final fits = [
      for (final (i, c) in constellations.indexed)
        if (time - last(i) >= _repeat && points(c).every(box.contains)) i,
    ]..shuffle(_random);
    if (fits.isEmpty) {
      _wait = 1;
      return;
    }
    final next = fits.reduce((a, b) => last(b) < last(a) ? b : a);
    drawing = next;
    _tracedAt[next] = time;
    traced = held = 0;
  }

  void _stepSparkles(double dt) {
    for (final (i, s) in sparkles.indexed) {
      sparkles[i] = (star: s.star, age: s.age + dt);
    }
    sparkles.removeWhere((s) => s.age >= _sparkleLife);
    if (exiting != null || !shown || sparkleRate <= 0) return;
    final view = Rect.fromLTRB(
      from + 20,
      20,
      size.width - 20,
      size.height - 20,
    );
    // As many to the area as in a large window, so a small one isn't
    // crowded with them.
    final rate = sparkleRate * view.width * view.height / _sparkleArea;
    if (rate <= 0) return;
    _nextSparkle -= dt;
    if (_nextSparkle > 0) return;
    // Spaced at random, so they don't come in step.
    _nextSparkle = -log(1 - _random.nextDouble()) / rate;
    // The brightest of a few in view: a faint star's glint would be lost.
    final count = starCount;
    int? best;
    for (var tries = 0; tries < 8 && count > 0; tries++) {
      final i = _random.nextInt(count);
      final at = star(i);
      if (!view.contains(at) || hidden.any((r) => r.contains(at))) continue;
      // At high rates the brightest would otherwise glint over themselves.
      if (sparkles.any((s) => s.star == i)) continue;
      if (best == null || bright[i] > bright[best]) best = i;
    }
    if (best != null) sparkles.add((star: best, age: 0));
  }

  void _stepStreaks(double dt) {
    for (final s in streaks) {
      s.age += dt;
      s.at += s.velocity * dt;
    }
    streaks.removeWhere((s) => s.age >= s.life);
    if (exiting != null || !shown) return;
    // Meteors and satellites each on their own clock, 7 to 3 of the
    // events, so satellites come steadily rather than in runs.
    _nextEvent -= dt;
    if (_nextEvent <= 0) {
      // Within a third either side of the average.
      _nextEvent = eventInterval / 0.7 * (2 / 3 + _random.nextDouble() * 2 / 3);
      streaks.add(_meteor());
    }
    _nextSatellite -= dt;
    // At most three up at once: a satellite due waits for one to leave.
    if (_nextSatellite <= 0 && _satelliteRoom) {
      // Within a quarter either side of the average.
      _nextSatellite = eventInterval / 0.3 * (0.75 + _random.nextDouble() / 2);
      streaks.add(_satellite());
    }
    for (var i = _burst.length - 1; i >= 0; i--) {
      _burst[i] -= dt;
      if (_burst[i] > 0) continue;
      _burst.removeAt(i);
      streaks.add(_showerMeteor());
    }
    // In bursts, spaced at random, so they don't come in step.
    final burstRate = shower * _burstPeak / 60;
    if (burstRate <= 0) return;
    _nextShower -= dt;
    if (_nextShower > 0) return;
    _nextShower = -log(1 - _random.nextDouble()) / burstRate;
    _startBurst();
  }

  /// A burst of the shower's meteors now, if the sky is up.
  void sendShowerBurst() {
    if (size.isEmpty || exiting != null || !shown) return;
    _startBurst();
  }

  /// Meteors within a few seconds, the first at once: four or five in a
  /// faint shower, up to eight or nine at a peak.
  void _startBurst() {
    final count = 4 + (4 * shower).round() + _random.nextInt(2);
    _burst.add(0);
    for (var i = 1; i < count; i++) {
      _burst.add(0.2 + 0.6 * count * _random.nextDouble());
    }
  }

  /// One of the shower's meteors, high up and streaking away from its
  /// radiant: all of them heading much the same way, fanning a little.
  _Streak _showerMeteor() {
    final span = size.width - from;
    final radiant = Offset(
      _radiantSide < 0
          ? from - span * _radiantOut
          : size.width + span * _radiantOut,
      -size.height * _radiantUp,
    );
    // On the radiant's side, so it has room to run away from it.
    final at = Offset(
      from +
          span * ((_radiantSide < 0 ? 0 : 0.35) + 0.65 * _random.nextDouble()),
      size.height * (0.02 + 0.38 * _random.nextDouble()),
    );
    final direction = (at - radiant) / (at - radiant).distance;
    return _Streak(
      at: at,
      velocity: direction * (550 + 300 * _random.nextDouble()),
      // Most of them long: from 0.7 s to 2 s.
      life: 0.7 + 1.3 * pow(_random.nextDouble(), 0.6).toDouble(),
      tail: 140 + _random.nextDouble() * 140,
    );
  }

  _Streak _meteor() {
    final span = size.width - from;
    final angle = (35 + _random.nextDouble() * 30) * pi / 180;
    final side = _random.nextBool() ? 1.0 : -1.0;
    final speed = 550 + _random.nextDouble() * 300;
    return _Streak(
      // High, and leaning in from the side it heads away from, so a long
      // one has room to run.
      at: Offset(
        from +
            span * (side > 0 ? 0.05 : 0.45) +
            span * 0.5 * _random.nextDouble(),
        size.height * (0.02 + 0.3 * _random.nextDouble()),
      ),
      velocity: Offset(side * cos(angle), sin(angle)) * speed,
      // Most of them long: from 0.7 s to 2 s.
      life: 0.7 + 1.3 * pow(_random.nextDouble(), 0.6).toDouble(),
      tail: 140 + _random.nextDouble() * 140,
    );
  }

  /// A satellite now, if the sky is up.
  void sendSatellite() {
    if (size.isEmpty || exiting != null || !shown || !_satelliteRoom) return;
    streaks.add(_satellite());
  }

  _Streak _satellite() {
    final rightwards = _random.nextBool();
    final y0 = size.height * (0.08 + 0.5 * _random.nextDouble());
    final y1 = y0 + size.height * (_random.nextDouble() - 0.5) * 0.5;
    // Off the edge by enough for a train's last car to cross too.
    final margin = satellite == GaiaSatellite.train
        ? 10 + _trainCars * _trainGap
        : 10.0;
    final start = Offset(rightwards ? from - 10 : size.width + 10, y0);
    var end = Offset(rightwards ? size.width + margin : from - margin, y1);
    // Heading out over the top, it ends there, not off in the dark.
    if (end.dy < -margin) {
      end = start + (end - start) * ((-margin - y0) / (y1 - y0));
    }
    // From 20 to 90 px/s, as many slow as fast.
    final speed = 20 * pow(4.5, _random.nextDouble());
    final life = (end - start).distance / speed;
    return _Streak(
      at: start,
      velocity: (end - start) / life,
      life: life,
      satellite: satellite,
      // A trail always flares, else about a third do.
      flareAt: satellite == GaiaSatellite.trail || _random.nextDouble() < 0.35
          ? life * (0.3 + 0.4 * _random.nextDouble())
          : null,
    );
  }
}

typedef _Band = ({
  double y,
  double height,
  double a1,
  double k1,
  double s1,
  double a2,
  double k2,
  double s2,
  double k3,
  double s3,
  Color color,
  double alpha,
});

/// The aurora's curtains: where each hangs as a share of the height, how it
/// ripples (amplitudes as shares of the height, wavenumbers a logical pixel,
/// speeds in radians a second), and its colour.
const List<_Band> _bands = [
  (
    y: 0.2,
    height: 0.16,
    a1: 0.035,
    k1: 0.006,
    s1: 0.11,
    a2: 0.015,
    k2: 0.017,
    s2: 0.23,
    k3: 0.011,
    s3: 0.19,
    color: Color(0xFF5CF2B0),
    alpha: 0.5,
  ),
  (
    y: 0.13,
    height: 0.12,
    a1: 0.025,
    k1: 0.0045,
    s1: 0.08,
    a2: 0.012,
    k2: 0.021,
    s2: 0.17,
    k3: 0.008,
    s3: 0.13,
    color: Color(0xFF4FC9E8),
    alpha: 0.35,
  ),
  (
    y: 0.27,
    height: 0.1,
    a1: 0.03,
    k1: 0.0052,
    s1: 0.14,
    a2: 0.01,
    k2: 0.014,
    s2: 0.29,
    k3: 0.013,
    s3: 0.21,
    color: Color(0xFFA87CFF),
    alpha: 0.28,
  ),
];

/// One sky in this many has the rare aurora.
const kGaiaRareAurora = 50;

/// The rare aurora's curtains, as [_bands]': main, high, low.
List<Color> _rareColors(GaiaRareAurora colours) => switch (colours) {
  // The deep red of a great storm, high, over rose, a pink fringe below.
  GaiaRareAurora.crimson => const [
    Color(0xFFFF6B8B),
    Color(0xFFFF4060),
    Color(0xFFFFA0E6),
  ],
  // A mauve ribbon over a green picket fence, as STEVE is.
  GaiaRareAurora.mauve => const [
    Color(0xFFE08CFF),
    Color(0xFFB46BFF),
    Color(0xFF7CF2C8),
  ],
  // Sunlit, its tops blue and violet.
  GaiaRareAurora.twilight => const [
    Color(0xFF6FA8FF),
    Color(0xFF9C7CFF),
    Color(0xFF5CE6FF),
  ],
  // Not one the sky shows: warm gold over amber.
  GaiaRareAurora.gold => const [
    Color(0xFFFFC65C),
    Color(0xFFFF8A4C),
    Color(0xFFFFE6A0),
  ],
};

/// How each of [_bands] waxes and wanes: its least and most against its
/// usual strength, and its period in seconds.
const _auroraDrifts = [(0.5, 1.1, 150.0), (0.2, 1.3, 110.0), (0.15, 1.7, 85.0)];

/// The sigma of the aurora's soft edges.
const _auroraBlur = 18.0;

/// Rows of the aurora's mesh, top to bottom of each column.
const _auroraRows = 16;

/// The standard normal distribution's CDF and density, tabled from -6 to
/// 6 in [_tableStep]s: the aurora's mesh looks them up thousands of times
/// a frame.
const _tableStep = 0.01;
final _cdf = _table((z) => 0.5 * (1 + _erf(z / sqrt2)));
final _pdf = _table((z) => exp(-z * z / 2) / sqrt(2 * pi));

Float64List _table(double Function(double z) f) => Float64List.fromList([
  for (var i = 0; i <= 12 / _tableStep; i++) f(i * _tableStep - 6),
]);

double _lookup(Float64List table, double z) {
  // Compared by hand: a double's clamp() boxes it.
  final at = (z + 6) / _tableStep;
  if (at <= 0) return table.first;
  final i = at.toInt();
  if (i >= table.length - 1) return table.last;
  return table[i] + (table[i + 1] - table[i]) * (at - i);
}

double _normal(double z) => _lookup(_cdf, z);

/// Abramowitz and Stegun 7.1.26: within 1.5e-7.
double _erf(double x) {
  final s = x.sign;
  x = x.abs();
  final t = 1 / (1 + 0.3275911 * x);
  final y =
      1 -
      ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) *
                  t +
              0.254829592) *
          t *
          exp(-x * x);
  return s * y;
}

/// The alpha at [y] of a curtain from [top] to [bottom], clear at [g0] and
/// ramping to [peak] at [g1] and below, once blurred by [_auroraBlur].
double _blurred(
  double y,
  double top,
  double bottom,
  double g0,
  double g1,
  double peak,
) {
  final slope = peak / (g1 - g0);
  return _segment(y, max(top, g0), min(bottom, g1), -g0 * slope, slope) +
      _segment(y, max(top, g1), bottom, peak, 0);
}

/// The Gaussian about [y] integrated against c0 + c1·s from [a] to [b].
double _segment(double y, double a, double b, double c0, double c1) {
  if (b <= a) return 0;
  final za = (a - y) / _auroraBlur, zb = (b - y) / _auroraBlur;
  return (c0 + c1 * y) * (_normal(zb) - _normal(za)) +
      c1 * _auroraBlur * (_lookup(_pdf, za) - _lookup(_pdf, zb));
}

class _SkyPainter extends CustomPainter {
  _SkyPainter(
    this.sky,
    this.top,
    this.left,
    this.background,
    this.clears,
    this.lean,
  ) : super(repaint: Listenable.merge([sky, left]));

  final _Sky sky;
  final double top;
  final ValueListenable<double>? left;

  /// The window's own background, which the sky lays over the starfield
  /// behind where it's kept clear.
  final Color background;

  /// What's to be kept clear of stars, like the greeting, in the sky's box.
  final List<(Rect, double)> Function() clears;

  /// How far the nearest stars lean towards the cursor just now.
  final Offset Function()? lean;

  /// Stars fade out over this distance from the edges.
  static const _edge = 24.0;

  /// Steps of opacity the stars are drawn in, batched by.
  static const _levels = 64;

  /// Star radii by size; the last for a constellation's star as it flares.
  static const _radii = [0.5, 0.85, 1.25, 1.9];

  /// The least a star is drawn at, dimmed to make up for it. A dot under a
  /// pixel across is one bright pixel when it sits on one and a smear of dim
  /// ones between, so as the sky turns it flashes at every pixel it crosses.
  static const _minRadius = 1.0;

  static const _tints = kGaiaStarTints;

  /// A constellation's lines.
  static const _ink = Color(0xFFB8CCFF);

  @override
  void paint(Canvas canvas, Size whole) {
    // Eased at both ends, rather than ramped.
    final opacity = Curves.easeInOut.transform(sky.opacity);
    // Shown, it still keeps the greeting clear before it has faded in.
    if (opacity <= 0 && !sky.shown) return;
    // Every part of the sky leans by it, by its own depth.
    sky.lean = lean?.call() ?? Offset.zero;
    final size = Size(whole.width, max(0, whole.height - top));
    if (size.isEmpty) return;
    canvas.translate(0, top);
    final from = max(0.0, left?.value ?? 0);
    sky.layout(size, from);
    final kept = clears();
    sky.hidden = [
      for (final (rect, _) in kept) rect.shift(Offset(0, -top)).inflate(36),
    ];
    canvas.clipRect(Rect.fromLTRB(from, 0, size.width, size.height));
    final exiting = sky.exiting;
    final dawn = sky.exit == GaiaSkyExit.dawn;
    // All but the stars go early in a showy exit; with the stars in a
    // quiet one.
    final going =
        opacity *
        switch (exiting) {
          null => 1.0,
          final p => max(
            0.0,
            1 -
                p *
                    switch (sky.exit) {
                      GaiaSkyExit.warp ||
                      GaiaSkyExit.trails ||
                      GaiaSkyExit.converge => 2.5,
                      GaiaSkyExit.dawn => 1.2,
                      GaiaSkyExit.fade ||
                      GaiaSkyExit.drift ||
                      GaiaSkyExit.blinkOut => 1.0,
                    },
          ),
        };
    if (exiting != null && dawn) _dawn(canvas, size, exiting);
    // The aurora goes by its own exit as the sky does, rather than
    // dimming: gone just before the stars are.
    if (opacity > 0) {
      final q = exiting == null ? 0.0 : min(1.0, exiting / 0.85);
      _aurora(
        canvas,
        size,
        from,
        opacity,
        // Coming back, easing to a stop: brightening at full pace to the
        // last frame, it looks to overshoot and dim when it stops.
        sky.returning ? q * q : q,
      );
    }
    _stars(canvas, size, from, opacity, exiting);
    if (exiting == null) _sparkles(canvas, opacity);
    if (going > 0) {
      _lines(canvas, going);
      _figure(canvas, going);
      _streaks(canvas, size, from, going);
    }
    if (exiting != null && sky.exit == GaiaSkyExit.converge) {
      _gather(canvas, size, from, exiting);
    }
    // Last, so nothing of the sky is behind the greeting. Coming in, there
    // from the start, as the starfield's stars are; going with the sky, so
    // theirs there don't pop back.
    final clear = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    for (final (rect, alpha) in [
      ...kept,
      ...sky.cleared,
    ]) {
      clear.color = background.withValues(
        alpha:
            background.a *
            (sky.shown ? 1 : opacity * (1 - (exiting ?? 0))) *
            alpha,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect.shift(Offset(0, -top)).inflate(36),
          const Radius.circular(40),
        ),
        clear,
      );
    }
  }

  /// Sparkling stars: each swells into a four-pointed glint, then settles.
  void _sparkles(Canvas canvas, double opacity) {
    // Softened a little: a glint's spikes taper under a pixel wide, and
    // drawn sharp they shimmer as they grow and drift across pixels.
    final paint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.6);
    for (final s in sky.sparkles) {
      // In the star's own colour.
      final colour = _tints[sky.tint[s.star]];
      final glow = pow(sin(pi * s.age / _sparkleLife), 1.5).toDouble();
      final at = sky.star(s.star);
      final reach = (5 + 9 * sky.bright[s.star]) * glow;
      final waist = reach * 0.12;
      // Wider than it's tall.
      final wide = reach * 1.1;
      canvas
        ..drawCircle(
          at,
          reach * 0.45,
          paint..color = colour.withValues(alpha: 0.12 * glow * opacity),
        )
        ..drawPath(
          Path()..addPolygon([
            at + Offset(0, -reach),
            at + Offset(waist, -waist),
            at + Offset(wide, 0),
            at + Offset(waist, waist),
            at + Offset(0, reach),
            at + Offset(-waist, waist),
            at + Offset(-wide, 0),
            at + Offset(-waist, -waist),
          ], true),
          paint..color = colour.withValues(alpha: 0.85 * glow * opacity),
        );
    }
  }

  /// The traced constellation's figure, sketched in quickly once its lines
  /// are done, and fading with them.
  void _figure(Canvas canvas, double fade) {
    final i = sky.drawing;
    if (!sky.figures || i == null || sky.traced < 1) return;
    final c = sky.constellations[i];
    final drawn = (sky.held / 1.2).clamp(0.0, 1.0);
    final out = 1 - ((sky.held - _hold) / _unwrite).clamp(0.0, 1.0);
    final paint = Paint()
      ..color = _ink.withValues(alpha: 0.32 * out * fade)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final place = sky.place(c);
    for (final stroke in c.shape.art) {
      final path = _strokePath(stroke, place);
      if (drawn >= 1) {
        canvas.drawPath(path, paint);
        continue;
      }
      // Each line drawn on from its start, all at once.
      for (final metric in path.computeMetrics()) {
        canvas.drawPath(metric.extractPath(0, metric.length * drawn), paint);
      }
    }
  }

  /// Where the composer sits, which converging stars pour into.
  static Offset _target(Size size, double from) =>
      Offset((from + size.width) / 2, size.height - 60);

  /// How far star [seed] has gone into the composer by [p], 0 to 1: they
  /// set off one after another, each speeding up as it goes.
  static double _converged(double p, double seed) {
    final local = ((p - seed * 0.45) / 0.55).clamp(0.0, 1.0);
    return local * local;
  }

  /// How much of star [seed] is left by [p] as the stars blink out: each
  /// brightens to a last glint, and fades. Played back, it is their blink
  /// in: each fade long enough not to pop on. [plain], each simply fades,
  /// eased at both ends, with no glint.
  static double _blink(double p, double seed, bool plain) {
    final off = 0.1 + seed * 0.6;
    if (p >= off) {
      final left = 1 - (p - off) / 0.3;
      if (left <= 0) return 0;
      return plain ? left * left * (3 - 2 * left) : 2.2 * left * left;
    }
    if (plain) return 1;
    final glint = 1 - (off - p) / 0.08;
    return glint > 0 ? 1 + 1.2 * glint : 1;
  }

  /// A sunrise from the bottom, warm at the horizon and violet above it,
  /// climbing as the dawn comes on and then giving way to the chat.
  void _dawn(Canvas canvas, Size size, double p) {
    final glow = sin(pi * p);
    final top = size.height * (1 - 0.95 * min(1.0, p * 1.4));
    canvas.drawRect(
      Rect.fromLTRB(0, top, size.width, size.height),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, size.height),
          Offset(0, top),
          [
            const Color(0xFFFFB27A).withValues(alpha: 0.38 * glow),
            const Color(0xFFC86FA0).withValues(alpha: 0.22 * glow),
            const Color(0xFF5B4FA8).withValues(alpha: 0),
          ],
          [0, 0.4, 1],
        ),
    );
  }

  /// A glow at the composer, as the stars pour into it.
  void _gather(Canvas canvas, Size size, double from, double p) {
    canvas.drawCircle(
      _target(size, from),
      10 + 40 * p,
      Paint()
        ..color = _ink.withValues(alpha: 0.25 * sin(pi * p))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
  }

  /// The aurora's curtains, [q] of the way, 0 to 1, through going by
  /// [_Sky.auroraExit].
  void _aurora(
    Canvas canvas,
    Size size,
    double sidebar,
    double fade,
    double q,
  ) {
    final exit = sky.auroraExit;
    // A surge early on, for a flare.
    final surge = exp(-pow((q - 0.25) / 0.15, 2)).toDouble();
    final strength =
        sky.aurora *
        fade *
        switch (exit) {
          GaiaAuroraExit.rise => 1 - q * q,
          // Bright until it is thin.
          GaiaAuroraExit.retract => 1 - q * q * q,
          // Its rays do the going.
          GaiaAuroraExit.rays => 1 - pow(q, 4),
          GaiaAuroraExit.flare => (1 + 0.7 * surge) * pow(1 - q, 2),
          GaiaAuroraExit.ebb => 1 - pow(q, 1.5),
          GaiaAuroraExit.arc => 1 - const Interval(0.5, 1).transform(q),
          // Bright a while, to see it flatten and turn, then dimming.
          GaiaAuroraExit.dusk =>
            1 - pow(const Interval(0.3, 1).transform(q), 1.5),
        };
    if (strength <= 0) return;
    final t =
        sky.time +
        switch (exit) {
          GaiaAuroraExit.rise => 3 * q * q,
          GaiaAuroraExit.flare => 6 * q,
          _ => 0,
        };
    // How much of its waving it keeps.
    final wave = switch (exit) {
      GaiaAuroraExit.flare => 1 + 0.8 * q,
      GaiaAuroraExit.arc || GaiaAuroraExit.dusk => 1 - q,
      _ => 1.0,
    };
    final rays = exit == GaiaAuroraExit.rays && q > 0;
    if (rays) {
      canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());
    }
    final h = size.height;
    const step = 12.0;
    final columns = ((size.width + 2 * step) / step).floor() + 1;
    final last = -step + (columns - 1) * step;
    // Each curtain as a mesh of columns, shaded as its gradient blurred by
    // [_auroraBlur] would be: far cheaper than blurring it as it's drawn.
    final count = _bands.length * columns * _auroraRows;
    final positions = Float32List(count * 2);
    final colors = Int32List(count);
    final indices = Uint16List(
      _bands.length * (columns - 1) * (_auroraRows - 1) * 6,
    );
    var v = 0, n = 0;
    for (final (i, band) in _bands.indexed) {
      final full = h * band.height;
      final (height, base) = switch (exit) {
        GaiaAuroraExit.rise => (
          full * (1 - 0.6 * q),
          h * band.y * (1 - q) - full * 1.2 * q,
        ),
        // The lower edge climbing to the top one, which stays.
        GaiaAuroraExit.retract => (
          full * (1 - 0.9 * q),
          h * band.y - full * 0.9 * q,
        ),
        GaiaAuroraExit.rays => (full * (1 + 0.3 * q), h * band.y),
        GaiaAuroraExit.flare => (full * (1 + 0.4 * surge), h * band.y),
        GaiaAuroraExit.ebb => (full * (1 - 0.3 * q), h * band.y),
        GaiaAuroraExit.arc ||
        GaiaAuroraExit.dusk => (full * (1 - 0.85 * q), h * band.y),
      };
      final hue = sky.rare ? _rareColors(sky.colours)[i] : band.color;
      final color = switch (exit) {
        GaiaAuroraExit.ebb ||
        GaiaAuroraExit.dusk => Color.lerp(hue, const Color(0xFF8A3C78), q)!,
        GaiaAuroraExit.flare => Color.lerp(
          hue,
          const Color(0xFFE6FFF4),
          0.25 * surge,
        )!,
        _ => hue,
      };
      final rgb = color.toARGB32() & 0xFFFFFF;
      final breathe = 0.75 + 0.25 * sin(t * 0.17 + i * 2.1);
      // Brightest at its lower edge, as a curtain is: clear at g0, full
      // from g1 down.
      // The rare one brighter, its reds being darker than the greens.
      final peak = min(
        1.0,
        band.alpha *
            strength *
            breathe *
            sky.auroraMix(i) *
            (sky.rare ? 1.4 : 1),
      );
      final g0 = base - height * 1.1, g1 = base + band.a1 * h;
      final first = v;
      for (var c = 0; c < columns; c++) {
        final x = -step + c * step;
        final y =
            base +
            (sin(x * band.k1 + t * band.s1 + i) * band.a1 * h +
                    sin(x * band.k2 - t * band.s2) * band.a2 * h) *
                wave;
        final reach = height * (0.55 + 0.45 * sin(x * band.k3 + t * band.s3));
        final top = y - reach;
        // Its ends soften as its edges do, at the sidebar as the stars do.
        final ends =
            _normal((x - sidebar + step) / _auroraBlur) *
            _normal((last - x) / _auroraBlur);
        final from = top - 2.5 * _auroraBlur, to = y + 3 * _auroraBlur;
        for (var r = 0; r < _auroraRows; r++) {
          final at = from + (to - from) * r / (_auroraRows - 1);
          final alpha = ends * _blurred(at, top, y, g0, g1, peak);
          positions[v * 2] = x;
          positions[v * 2 + 1] = at;
          final byte = alpha <= 0
              ? 0
              : alpha >= 1
              ? 255
              : (alpha * 255).round();
          colors[v++] = byte << 24 | rgb;
        }
      }
      for (var c = 0; c + 1 < columns; c++) {
        for (var r = 0; r + 1 < _auroraRows; r++) {
          final a = first + c * _auroraRows + r, b = a + _auroraRows;
          indices
            ..[n++] = a
            ..[n++] = b
            ..[n++] = a + 1
            ..[n++] = a + 1
            ..[n++] = b
            ..[n++] = b + 1;
        }
      }
    }
    final mesh = ui.Vertices.raw(
      ui.VertexMode.triangles,
      positions,
      colors: colors,
      indices: indices,
    );
    canvas.drawVertices(mesh, BlendMode.dst, Paint());
    mesh.dispose();
    if (rays) {
      // Cut into rays: each narrowing, and winking out at its own moment.
      // Each its own width, the gaps opening gradually.
      const period = 26.0;
      final cut = Paint()..blendMode = BlendMode.dstIn;
      final gap = Paint()..blendMode = BlendMode.clear;
      var k = 0;
      for (var x = 0.0; x < size.width; x += period, k++) {
        final seed = ((sin(k * 12.9898) * 43758.5453) % 1).abs();
        final thin = ((sin(k * 78.233) * 12345.678) % 1).abs();
        final width = period * (1 - 0.75 * q * (0.5 + thin));
        final left = (1 - q * 1.6 + 0.6 * seed).clamp(0.0, 1.0);
        canvas
          ..drawRect(
            Rect.fromLTWH(x, 0, width, h),
            cut..color = Colors.white.withValues(alpha: left),
          )
          ..drawRect(Rect.fromLTWH(x + width, 0, period - width, h), gap);
      }
      canvas.restore();
    }
  }

  void _stars(
    Canvas canvas,
    Size size,
    double from,
    double opacity,
    double? p,
  ) {
    final exit = sky.exit;
    final target = _target(size, from);
    // Warp: how far out from the middle each star's streak has run, its
    // tail a little behind, faster and faster.
    final centre = Offset((from + size.width) / 2, size.height * 0.42);
    double rush(double p) => 1 + 5 * pow(max(0.0, p), 2.4).toDouble();
    final head = p == null ? 1.0 : rush(p);
    final tail = p == null ? 1.0 : rush(p - 0.1);
    // Trails: how far round the sky has spun up, faster and faster.
    final swept = p == null ? 0.0 : max(0.002, 1.4 * pow(p, 1.8).toDouble());
    final lines =
        p != null && (exit == GaiaSkyExit.warp || exit == GaiaSkyExit.converge);

    // Like stars drawn together: as points, or streaks, or arcs.
    final batches = <int, List<double>>{};
    final arcs = <int, Path>{};
    void add(Offset at, int tint, int kind, double alpha, double seed) {
      final nearest = min(
        min(at.dx - from, size.width - at.dx),
        min(at.dy, size.height - at.dy),
      );
      if (nearest <= 0) return;
      final gone = p == null ? 0.0 : _converged(p, seed);
      alpha *= min(nearest / _edge, 1);
      if (p != null) {
        alpha *= switch (exit) {
          GaiaSkyExit.warp => pow(1 - p, 1.2) * (1 + 1.5 * p),
          GaiaSkyExit.trails => pow(1 - p, 1.5) * (1 + 0.5 * p),
          // Brighter as it goes, and out as it arrives.
          GaiaSkyExit.converge => (1 - pow(gone, 4)) * (1 + gone),
          // The faintest first.
          GaiaSkyExit.dawn => (1 - p / (0.3 + 0.7 * alpha)).clamp(0.0, 1.0),
          GaiaSkyExit.fade => 1 - p,
          GaiaSkyExit.drift => pow(1 - p, 1.3),
          GaiaSkyExit.blinkOut => _blink(p, seed, sky.plainBlink),
        };
      }
      final level = (alpha * opacity * _levels).round().clamp(0, _levels);
      if (level == 0) return;
      final key = (tint * _radii.length + kind) * (_levels + 1) + level;
      if (p == null ||
          exit == GaiaSkyExit.dawn ||
          exit == GaiaSkyExit.fade ||
          exit == GaiaSkyExit.drift ||
          exit == GaiaSkyExit.blinkOut) {
        // Drifting, rising a little, easing to a stop.
        final rise = p != null && exit == GaiaSkyExit.drift
            ? 40 * sin(p * pi / 2)
            : 0.0;
        (batches[key] ??= [])
          ..add(at.dx)
          ..add(at.dy - rise);
        return;
      }
      switch (exit) {
        case GaiaSkyExit.warp:
          final a = centre + (at - centre) * tail;
          final b = centre + (at - centre) * head;
          (batches[key] ??= []).addAll([a.dx, a.dy, b.dx, b.dy]);
        case GaiaSkyExit.trails:
          final d = at - sky.pole;
          final theta = atan2(d.dy, d.dx);
          (arcs[key] ??= Path()).addArc(
            Rect.fromCircle(center: sky.pole, radius: d.distance),
            theta - swept,
            swept,
          );
        case GaiaSkyExit.converge:
          final a = Offset.lerp(at, target, _converged(p - 0.06, seed))!;
          final b = Offset.lerp(at, target, gone)!;
          (batches[key] ??= []).addAll([a.dx, a.dy, b.dx, b.dy]);
        case GaiaSkyExit.dawn ||
            GaiaSkyExit.fade ||
            GaiaSkyExit.drift ||
            GaiaSkyExit.blinkOut:
      }
    }

    final count = sky.starCount;
    for (var i = 0; i < count; i++) {
      add(
        sky.star(i),
        sky.tint[i],
        sky.kind[i],
        sky.starAlpha(i),
        sky.phase[i] / (2 * pi),
      );
    }
    // The constellations' stars, brighter than most, flaring as the pen
    // reaches them.
    final halo = Paint();
    for (final (i, c) in sky.constellations.indexed) {
      for (final (j, at) in sky.points(c).indexed) {
        final flare = p == null && i == sky.drawing ? sky.flare(j) : 0.0;
        add(
          at,
          0,
          flare > 0.3 ? 3 : 2,
          0.8 + 0.2 * flare,
          (i * 7 + j * 3) % 11 / 11,
        );
        if (flare > 0.02) {
          canvas.drawCircle(
            at,
            2 + 6 * flare,
            halo..color = _tints[0].withValues(alpha: 0.18 * flare * opacity),
          );
        }
      }
    }

    final paint = Paint()..strokeCap = StrokeCap.round;
    void style(int key) {
      final style = key ~/ (_levels + 1);
      final radius = _radii[style % _radii.length];
      final drawn = max(radius, _minRadius);
      paint
        ..color = _tints[style ~/ _radii.length].withValues(
          // As much light in all as the star's own size would give.
          alpha: key % (_levels + 1) / _levels * pow(radius / drawn, 2),
        )
        ..strokeWidth = drawn * 2;
    }

    batches.forEach((key, points) {
      style(key);
      canvas.drawRawPoints(
        lines ? ui.PointMode.lines : ui.PointMode.points,
        Float32List.fromList(points),
        paint,
      );
    });
    paint.style = PaintingStyle.stroke;
    arcs.forEach((key, path) {
      style(key);
      canvas.drawPath(path, paint);
    });
  }

  void _lines(Canvas canvas, double fade) {
    final i = sky.drawing;
    if (i == null) return;
    final shape = sky.constellations[i].shape;
    final points = sky.points(sky.constellations[i]);
    final done = sky.traced;
    final out = 1 - ((sky.held - _hold) / _unwrite).clamp(0.0, 1.0);
    final line = Paint()
      ..color = _ink.withValues(alpha: 0.4 * out * fade)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    final pen = Paint();
    for (final (k, (a, b)) in shape.edges.indexed) {
      final progress =
          ((done - shape.starts[k]) / (shape.ends[k] - shape.starts[k])).clamp(
            0.0,
            1.0,
          );
      if (progress == 0) continue;
      final tip = Offset.lerp(points[a], points[b], progress)!;
      canvas.drawLine(points[a], tip, line);
      if (progress < 1) {
        canvas
          ..drawCircle(tip, 5, pen..color = _ink.withValues(alpha: 0.15 * fade))
          ..drawCircle(
            tip,
            1.5,
            pen..color = Colors.white.withValues(alpha: 0.9 * fade),
          );
      }
    }
  }

  void _streaks(Canvas canvas, Size size, double from, double fade) {
    // Leaning as the nearest stars do, being nearer still: a slow
    // satellite left still as the stars around it lean would stand out.
    canvas
      ..save()
      ..translate(sky.lean.dx, sky.lean.dy);
    // Fading out near the edges as the stars do, where it's drawn.
    double edge(Offset at) {
      final drawn = at + sky.lean;
      final nearest = min(
        min(drawn.dx - from, size.width - drawn.dx),
        min(drawn.dy, size.height - drawn.dy),
      );
      return (nearest / _edge).clamp(0.0, 1.0);
    }

    final paint = Paint()..strokeCap = StrokeCap.round;
    for (final s in sky.streaks) {
      if (s.satellite != null) {
        // A steady point, unless it catches the sun.
        final flare = switch (s.flareAt) {
          final at? => exp(-pow((s.age - at) / 0.7, 2)),
          null => 0.0,
        };
        if (flare > 0.05) {
          canvas.drawCircle(
            s.at,
            7 * flare,
            paint
              ..shader = null
              ..color = Colors.white.withValues(
                alpha: 0.2 * flare * fade * edge(s.at),
              ),
          );
        }
        _satellite(canvas, s, flare, fade, edge, paint..shader = null);
        continue;
      }
      // Flaring up, then burning out.
      final glow = pow(sin(pi * s.age / s.life), 0.8).toDouble() * fade;
      final direction = s.velocity / s.velocity.distance;
      final end = s.at - direction * s.tail * min(1, s.age / 0.12);
      canvas
        ..drawLine(
          end,
          s.at,
          paint
            ..strokeWidth = 1.5
            ..shader = ui.Gradient.linear(s.at, end, [
              Colors.white.withValues(alpha: 0.85 * glow),
              Colors.white.withValues(alpha: 0),
            ]),
        )
        ..drawCircle(
          s.at,
          1.4,
          paint
            ..shader = null
            ..color = Colors.white.withValues(alpha: 0.9 * glow),
        );
    }
    canvas.restore();
  }

  void _satellite(
    Canvas canvas,
    _Streak s,
    double flare,
    double going,
    double Function(Offset) edge,
    Paint paint,
  ) {
    final fade = going * edge(s.at);
    Color white(double alpha) => Colors.white.withValues(alpha: alpha * fade);
    final direction = s.velocity / s.velocity.distance;
    switch (s.satellite!) {
      case GaiaSatellite.dot:
        canvas.drawCircle(
          s.at,
          1 + 1.2 * flare,
          paint..color = white(0.55 + 0.45 * flare),
        );
      case GaiaSatellite.panels:
        canvas
          ..save()
          ..translate(s.at.dx, s.at.dy)
          ..rotate(direction.direction + s.age * 0.5);
        // A strut through the body, out to the panels.
        canvas
          ..drawLine(
            const Offset(-6, 0),
            const Offset(6, 0),
            paint
              ..strokeWidth = 0.6
              ..color = white(0.5),
          )
          ..drawRect(
            Rect.fromCenter(center: Offset.zero, width: 2.6, height: 2.6),
            paint..color = const Color(0xFFF2E3B8).withValues(alpha: fade),
          );
        for (final side in [-1.0, 1.0]) {
          canvas.drawRect(
            Rect.fromCenter(
              center: Offset(side * 5, 0),
              width: 4.5,
              height: 2.2,
            ),
            paint
              ..color = Color.lerp(
                const Color(0xFF8FB4FF),
                Colors.white,
                flare,
              )!.withValues(alpha: (0.75 + 0.25 * flare) * fade),
          );
        }
        canvas.restore();
      case GaiaSatellite.trail:
        final end = s.at - direction * 40 * min(1, s.age / 0.8);
        canvas
          ..drawLine(
            end,
            s.at,
            paint
              ..strokeWidth = 1
              ..shader = ui.Gradient.linear(s.at, end, [white(0.4), white(0)]),
          )
          ..drawCircle(
            s.at,
            2 + 1.5 * flare,
            paint
              ..shader = null
              ..color = white(0.75 + 0.25 * flare),
          );
      case GaiaSatellite.tumbler:
        // A glint every 1.8 s as it turns its broad side to the sun.
        final turn = (s.age % 1.8) / 1.8;
        final glint = max(exp(-pow((turn - 0.5) / 0.07, 2)), flare).toDouble();
        canvas.drawCircle(
          s.at,
          0.9 + 1.6 * glint,
          paint..color = white(0.35 + 0.65 * glint),
        );
        if (glint > 0.1) {
          paint
            ..strokeWidth = 0.8
            ..color = white(0.6 * glint);
          for (final d in [const Offset(1, 0), const Offset(0, 1)]) {
            canvas.drawLine(s.at - d * 8 * glint, s.at + d * 8 * glint, paint);
          }
        }
      case GaiaSatellite.station:
        canvas
          ..drawCircle(s.at, 5 + 3 * flare, paint..color = white(0.16))
          ..drawCircle(
            s.at,
            1.8 + flare,
            paint
              ..color = const Color(0xFFFFF2DC).withValues(alpha: 0.95 * fade),
          );
        paint
          ..strokeWidth = 0.7
          ..color = white(0.3 + 0.4 * flare);
        for (final d in [const Offset(1, 0), const Offset(0, 1)]) {
          canvas.drawLine(s.at - d * 6, s.at + d * 6, paint);
        }
      case GaiaSatellite.train:
        // Each car by its own edge, so the train fades in car by car.
        for (var i = 0; i <= _trainCars; i++) {
          final car = s.at - direction * _trainGap * i.toDouble();
          canvas.drawCircle(
            car,
            1,
            paint
              ..color = Colors.white.withValues(
                alpha: (0.7 - 0.04 * i + 0.3 * flare) * going * edge(car),
              ),
          );
        }
    }
  }

  @override
  bool shouldRepaint(_SkyPainter oldDelegate) =>
      oldDelegate.sky != sky ||
      oldDelegate.top != top ||
      oldDelegate.left != left ||
      oldDelegate.background != background ||
      oldDelegate.clears != clears ||
      oldDelegate.lean != lean;
}

/// The sky debug panel over the chat: each part of the sky, changed live,
/// and a choice of exits, each played on demand.
class GaiaSkyPanel extends StatelessWidget {
  const GaiaSkyPanel({super.key, required this.debug, required this.onTour});

  final GaiaDebug debug;

  /// Plays each way the chat changes, one after another.
  final VoidCallback onTour;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(
      String label,
      double value,
      double min,
      double max,
      String display,
      void Function(double value, {required bool save}) onChanged,
    ) => Row(
      children: [
        SizedBox(width: 64, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: (value) => onChanged(value, save: false),
            onChangeEnd: (value) => onChanged(value, save: true),
          ),
        ),
        SizedBox(width: 52, child: Text(display, textAlign: TextAlign.end)),
      ],
    );
    String percent(double value) => '${(value * 100).round()}%';
    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.88),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.35),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 8),
        child: SizedBox(
          width: 310,
          child: DefaultTextStyle.merge(
            style: theme.textTheme.bodySmall,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Sky debug',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    TextButton(
                      onPressed: debug.skyTour == null ? onTour : null,
                      child: const Text('Tour'),
                    ),
                    TextButton(
                      onPressed: debug.testSkyExit,
                      child: const Text('Play exit'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      iconSize: 14,
                      tooltip: 'Close',
                      onPressed: () => debug.setSkyPanel(false),
                    ),
                  ],
                ),
                Row(
                  children: [
                    TextButton(
                      onPressed: debug.resetSky,
                      child: const Text('Reset to defaults'),
                    ),
                    TextButton(
                      onPressed: debug.testSkyBurst,
                      child: const Text('Shower burst'),
                    ),
                  ],
                ),
                if (debug.skyTour case final step?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Tour: $step',
                      style: TextStyle(color: theme.colorScheme.primary),
                    ),
                  ),
                // The settings scroll under the title, once there are more
                // than the window has room for.
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        row(
                          'Rotation',
                          debug.skyRotation,
                          0,
                          60,
                          '${debug.skyRotation.round()}°/min',
                          debug.setSkyRotation,
                        ),
                        Row(
                          children: [
                            const SizedBox(width: 64, child: Text('Star step')),
                            Expanded(
                              child: Wrap(
                                spacing: 6,
                                children: [
                                  for (final step in kGaiaDebugStarSteps)
                                    ChoiceChip(
                                      label: Text('${step}px'),
                                      visualDensity: VisualDensity.compact,
                                      selected: debug.starStep == step,
                                      onSelected: (_) =>
                                          debug.setStarStep(step),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const SizedBox(width: 64, child: Text('Rest fps')),
                            Expanded(
                              child: Wrap(
                                spacing: 6,
                                children: [
                                  for (final rate in kGaiaDebugSkyRestRates)
                                    ChoiceChip(
                                      label: Text(rate == 0 ? 'Off' : '$rate'),
                                      visualDensity: VisualDensity.compact,
                                      selected: debug.skyRestRate == rate,
                                      onSelected: (_) =>
                                          debug.setSkyRestRate(rate),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        row(
                          'Stars',
                          debug.skyStars,
                          0,
                          1200,
                          debug.skyStars.round().toString(),
                          debug.setSkyStars,
                        ),
                        row(
                          'Shimmer',
                          debug.skyTwinkle,
                          0,
                          1,
                          percent(debug.skyTwinkle),
                          debug.setSkyTwinkle,
                        ),
                        row(
                          'Sparkle',
                          debug.skySparkles,
                          0,
                          20,
                          '${debug.skySparkles.toStringAsFixed(1)}/s',
                          debug.setSkySparkles,
                        ),
                        row(
                          'Tracing',
                          debug.skyTraceSpeed,
                          20,
                          300,
                          '${debug.skyTraceSpeed.round()}px/s',
                          debug.setSkyTraceSpeed,
                        ),
                        row(
                          'Meteors & satellites',
                          debug.skyEventInterval,
                          3,
                          60,
                          '${debug.skyEventInterval.round()}s',
                          debug.setSkyEventInterval,
                        ),
                        Row(
                          children: [
                            const SizedBox(width: 64, child: Text('Shower')),
                            Expanded(
                              child: Wrap(
                                spacing: 6,
                                children: [
                                  for (final shower in GaiaSkyShower.values)
                                    ChoiceChip(
                                      label: Text(switch (shower) {
                                        GaiaSkyShower.calendar => 'Calendar',
                                        GaiaSkyShower.off => 'Off',
                                        GaiaSkyShower.light => 'Light',
                                        GaiaSkyShower.medium => 'Medium',
                                        GaiaSkyShower.peak => 'Peak',
                                      }),
                                      visualDensity: VisualDensity.compact,
                                      selected: debug.skyShower == shower,
                                      onSelected: (_) =>
                                          debug.setSkyShower(shower),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(switch (gaiaMeteorShower(
                            DateTime.now(),
                          )) {
                            final s? =>
                              'Tonight: ${s.name}, '
                                  '${percent(s.strength)} of a peak',
                            null => 'No shower tonight',
                          }),
                        ),
                        row(
                          'Aurora',
                          debug.skyAurora,
                          0,
                          1,
                          percent(debug.skyAurora),
                          debug.setSkyAurora,
                        ),
                        row(
                          'Aurora drift',
                          debug.skyAuroraDrift,
                          0,
                          20,
                          debug.skyAuroraDrift == 0
                              ? 'Off'
                              : '${debug.skyAuroraDrift.toStringAsFixed(1)}×',
                          debug.setSkyAuroraDrift,
                        ),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Always the rare aurora '
                                '(else 1 in $kGaiaRareAurora)',
                              ),
                            ),
                            Switch(
                              value: debug.skyRareAurora,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: debug.setSkyRareAurora,
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const SizedBox(
                              width: 64,
                              child: Text('Rare colours'),
                            ),
                            Expanded(
                              child: Wrap(
                                spacing: 6,
                                children: [
                                  for (final colours in [
                                    null,
                                    ...GaiaRareAurora.values,
                                  ])
                                    ChoiceChip(
                                      label: Text(switch (colours) {
                                        null => 'Random',
                                        GaiaRareAurora.crimson => 'Crimson',
                                        GaiaRareAurora.mauve => 'Mauve',
                                        GaiaRareAurora.twilight => 'Twilight',
                                        GaiaRareAurora.gold => 'Gold',
                                      }),
                                      visualDensity: VisualDensity.compact,
                                      selected: debug.skyRareColours == colours,
                                      onSelected: (_) =>
                                          debug.setSkyRareColours(colours),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const SizedBox(
                              width: 64,
                              child: Text('Aurora out'),
                            ),
                            Expanded(
                              child: Wrap(
                                spacing: 6,
                                children: [
                                  for (final exit in GaiaAuroraExit.values)
                                    ChoiceChip(
                                      label: Text(switch (exit) {
                                        GaiaAuroraExit.rise => 'Rise',
                                        GaiaAuroraExit.retract => 'Retract',
                                        GaiaAuroraExit.rays => 'Rays',
                                        GaiaAuroraExit.flare => 'Flare',
                                        GaiaAuroraExit.ebb => 'Ebb',
                                        GaiaAuroraExit.arc => 'Arc',
                                        GaiaAuroraExit.dusk => 'Dusk',
                                      }),
                                      visualDensity: VisualDensity.compact,
                                      selected: debug.skyAuroraExit == exit,
                                      // Played at once, to see it by.
                                      onSelected: (_) async {
                                        await debug.setSkyAuroraExit(exit);
                                        debug.testSkyExit();
                                      },
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const SizedBox(width: 64, child: Text('Satellite')),
                            Expanded(
                              child: Wrap(
                                spacing: 6,
                                children: [
                                  for (final satellite in GaiaSatellite.values)
                                    ChoiceChip(
                                      label: Text(switch (satellite) {
                                        GaiaSatellite.dot => 'Dot',
                                        GaiaSatellite.panels => 'Panels',
                                        GaiaSatellite.trail => 'Trail',
                                        GaiaSatellite.tumbler => 'Tumbler',
                                        GaiaSatellite.station => 'Station',
                                        GaiaSatellite.train => 'Train',
                                      }),
                                      visualDensity: VisualDensity.compact,
                                      selected: debug.skySatellite == satellite,
                                      onSelected: (_) =>
                                          debug.setSkySatellite(satellite),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        row(
                          'Exit',
                          debug.skyExitTime,
                          0.3,
                          4,
                          '${debug.skyExitTime.toStringAsFixed(1)}s',
                          debug.setSkyExitTime,
                        ),
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final exit in GaiaSkyExit.values)
                              ChoiceChip(
                                label: Text(switch (exit) {
                                  GaiaSkyExit.warp => 'Warp',
                                  GaiaSkyExit.trails => 'Trails',
                                  GaiaSkyExit.converge => 'Converge',
                                  GaiaSkyExit.dawn => 'Dawn',
                                  GaiaSkyExit.fade => 'Fade',
                                  GaiaSkyExit.drift => 'Drift',
                                  GaiaSkyExit.blinkOut => 'Blink out',
                                }),
                                visualDensity: VisualDensity.compact,
                                selected: debug.skyExit == exit,
                                onSelected: (_) => debug.setSkyExit(exit),
                              ),
                          ],
                        ),
                        Row(
                          children: [
                            const Expanded(
                              child: Text('Blink out without glints or glow'),
                            ),
                            Switch(
                              value: debug.skyPlainBlink,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: debug.setSkyPlainBlink,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
