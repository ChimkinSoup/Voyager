import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_glyph.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';

/// [GaiaOrb]'s size in a chat.
const kGaiaOrbSize = 48.0;

/// What [GaiaOrb] is showing.
enum GaiaOrbState {
  /// Pulsing inwards: before any text, or while tools run.
  thinking('Thinking'),

  /// Swirling: text is arriving.
  speaking('Replying'),

  /// The reply is done: the sphere compacts into the tier's
  /// [GaiaTierGlyph], which then takes over.
  glyph(null);

  const GaiaOrbState(this.label);

  /// What a screen reader announces; null once the reply is done.
  final String? label;
}

/// Gaia's astral light breathes while she thinks; its rings accelerate while
/// her reply streams in, then fold
/// into the [tier]'s glyph. It eases between states, ticks only while on
/// screen ([TickerMode]) and while there's movement to show, and holds still
/// under reduced motion.
///
/// A new orb that isn't done yet blooms out of nothing. One a [GlobalKey]
/// carries elsewhere (the chat's glyph moving on to the next reply) flies
/// there from where it was, opening back out into the sphere on the way.
class GaiaOrb extends StatefulWidget {
  const GaiaOrb({
    super.key,
    required this.state,
    required this.tier,
    this.size = kGaiaOrbSize,
  });

  final GaiaOrbState state;

  /// The [GaiaTierGlyph.level] it compacts into.
  final int tier;

  final double size;

  @override
  State<GaiaOrb> createState() => _GaiaOrbState();
}

/// The glyph's scale in the orb, so it holds its own in the orb's space.
const _glyphScale = 1.5;

/// Seconds a new orb takes to bloom out of nothing.
const _bloomTime = kGaiaAstralArrivalTime;

class _GaiaOrbState extends State<GaiaOrb> with TickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final _orb = _Orb(widget.state, widget.tier);
  var _lastTick = Duration.zero;

  /// Its flight from where it was, once carried elsewhere.
  late final _flight = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _orb.reduced = MediaQuery.disableAnimationsOf(context);
    if (_orb.reduced) _orb.snap();
    _sync();
  }

  @override
  void didUpdateWidget(GaiaOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    _orb.state = widget.state;
    _orb.tier = widget.tier;
    _sync();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _flight.dispose();
    _orb.dispose();
    super.dispose();
  }

  void _sync() {
    final run =
        !_orb.reduced &&
        !_orb.settled &&
        TickerMode.valuesOf(context).enabled &&
        GaiaAmbient.of(context);
    if (run == _ticker.isActive) return;
    if (run) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    // Capped, so a stall doesn't jump the orb.
    final dt = min((elapsed - _lastTick).inMicroseconds / 1e6, 0.1);
    _lastTick = elapsed;
    _orb.step(dt);
    if (_orb.settled) {
      _ticker.stop();
      // Hands over to the glyph.
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.state.label;
    final landed = widget.state == GaiaOrbState.glyph && _orb.settled;
    return Semantics(
      label: label,
      liveRegion: label != null,
      child: _Flight(
        flight: _flight,
        enabled: !_orb.reduced,
        child: SizedBox.square(
          dimension: widget.size,
          // The material's final frame paints this exact glyph. No crossfade
          // is needed: doubling its translucent rings would flash on handoff.
          child: landed
              ? Transform.scale(
                  key: const ValueKey('glyph'),
                  scale: _glyphScale,
                  child: GaiaTierGlyph(
                    level: widget.tier,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                )
              : RepaintBoundary(
                  key: const ValueKey('orb'),
                  child: CustomPaint(
                    size: Size.square(widget.size),
                    painter: _OrbPainter(
                      _orb,
                      accent: Theme.of(context).colorScheme.primary,
                      ink: Theme.of(context).colorScheme.onSurface,
                      surface: Theme.of(context).scaffoldBackgroundColor,
                      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Paints [child] flying in along [flight] from where it last showed,
/// whenever it's moved elsewhere in the tree.
class _Flight extends SingleChildRenderObjectWidget {
  const _Flight({
    required this.flight,
    required this.enabled,
    required super.child,
  });

  final AnimationController flight;
  final bool enabled;

  @override
  _RenderFlight createRenderObject(BuildContext context) =>
      _RenderFlight(flight)..enabled = enabled;

  @override
  void updateRenderObject(BuildContext context, _RenderFlight renderObject) =>
      renderObject.enabled = enabled;
}

class _RenderFlight extends RenderProxyBox {
  _RenderFlight(this.flight);

  final AnimationController flight;
  var enabled = true;

  /// Where its child showed after the last frame, globally; null before
  /// the first.
  Offset? _shown;

  /// Where it's flying from, relative to where it's laid out.
  var _from = Offset.zero;

  /// Moved since the last paint.
  var _moved = false;

  /// Flying, with [flight] yet to start.
  var _waiting = false;

  var _tracking = false;

  Offset get _lag => !enabled
      ? Offset.zero
      : _waiting
      ? _from
      : _from * (1 - Curves.easeInOutCubic.transform(flight.value));

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    flight.addListener(markNeedsPaint);
    // Back in the tree, having shown elsewhere.
    if (_shown != null) _moved = true;
    if (!_tracking) {
      _tracking = true;
      SchedulerBinding.instance.addPostFrameCallback(_track);
    }
  }

  @override
  void detach() {
    flight.removeListener(markNeedsPaint);
    super.detach();
  }

  /// Notes where it showed after each frame, scrolled or not: once it's
  /// been moved, it's too late to look.
  void _track(Duration _) {
    if (!attached) {
      _tracking = false;
      return;
    }
    _shown = localToGlobal(Offset.zero) + _lag;
    SchedulerBinding.instance.addPostFrameCallback(_track);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_moved) {
      _moved = false;
      final from = _shown! - localToGlobal(Offset.zero);
      if (enabled && from != Offset.zero) {
        _from = from;
        _waiting = true;
        // After the frame, as starting it here would mark this for painting
        // mid-paint.
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _waiting = false;
          if (attached) flight.forward(from: 0);
        });
      }
    }
    context.paintChild(child!, offset + _lag);
  }
}

/// Finite arrival and glyph transitions share one reversible progress value.
/// A new message can interrupt gathering without restarting the orb's clock.
class _Orb extends GaiaOrbMotion {
  _Orb(this._state, this.tier) {
    if (_state == GaiaOrbState.glyph) gather = bloom = 1;
    thinking = _state == GaiaOrbState.thinking ? 1 : 0;
    speaking = _state == GaiaOrbState.speaking ? 1 : 0;
  }

  GaiaOrbState _state;
  int tier;
  bool reduced = false;

  set state(GaiaOrbState value) {
    if (value == _state) return;
    _state = value;
    if (reduced) snap();
  }

  bool get settled => _state == GaiaOrbState.glyph && gather == 1;

  void snap() {
    snapTo(
      thinks: _state == GaiaOrbState.thinking,
      speaks: _state == GaiaOrbState.speaking,
      gathers: _state == GaiaOrbState.glyph,
    );
    notifyListeners();
  }

  void step(double dt) {
    advance(
      dt,
      thinks: _state == GaiaOrbState.thinking,
      speaks: _state == GaiaOrbState.speaking,
      gathers: _state == GaiaOrbState.glyph,
      thinkingStyle: GaiaOrbThinking.focus,
      replyingStyle: GaiaOrbReplying.outpour,
    );
    notifyListeners();
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(
    this.orb, {
    required this.accent,
    required this.ink,
    required this.surface,
    required this.devicePixelRatio,
  }) : super(repaint: orb);

  final _Orb orb;
  final Color accent, ink, surface;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    paintGaiaMaterialOrb(
      canvas,
      size,
      material: GaiaOrbMaterial.astral,
      centre: size.center(Offset.zero),
      radius: min(size.width, size.height) / 2,
      clock: orb.clock,
      thinking: orb.thinking,
      replying: orb.speaking,
      done: orb.gather,
      revealAge: orb.bloom * _bloomTime,
      burstAge: 4,
      accent: accent,
      ink: ink,
      surface: surface,
      tier: orb.tier,
      devicePixelRatio: devicePixelRatio,
      thinkingStyle: GaiaOrbThinking.focus,
      replyingStyle: GaiaOrbReplying.outpour,
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.orb != orb ||
      old.accent != accent ||
      old.ink != ink ||
      old.surface != surface ||
      old.devicePixelRatio != devicePixelRatio;
}
