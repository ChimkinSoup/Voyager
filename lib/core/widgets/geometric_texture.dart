import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:voyager/domain/models/enums.dart' show GeometricWaveShape;

export 'package:voyager/domain/models/enums.dart' show GeometricWaveShape;

/// Tunable parameters for the equilateral-triangle gradient texture shader.
class GeometricTextureParams {
  const GeometricTextureParams({
    this.scale = 10.0,
    this.intensity = 0.85,
    this.focalSpread = 1.0,
    this.focalPointX = 1.0,
    this.focalPointY = 0.5,
    this.variationFloor = 0.75,
  });

  /// Triangle density. Higher = smaller, more numerous triangles.
  final double scale;

  /// Peak accent color strength at the focal point (0–1).
  final double intensity;

  /// Gradient radius in aspect-corrected UV units.
  /// Larger values spread the color further from the focal point.
  final double focalSpread;

  /// Horizontal focal point (0 = left edge, 0.5 = center, 1 = right edge).
  final double focalPointX;

  /// Vertical focal point (0 = top edge, 0.5 = center, 1 = bottom edge).
  final double focalPointY;

  /// Minimum per-triangle shade (0–1). Higher values reduce very dark triangles.
  final double variationFloor;

  static const defaults = GeometricTextureParams();

  GeometricTextureParams copyWith({
    double? scale,
    double? intensity,
    double? focalSpread,
    double? focalPointX,
    double? focalPointY,
    double? variationFloor,
  }) {
    return GeometricTextureParams(
      scale: scale ?? this.scale,
      intensity: intensity ?? this.intensity,
      focalSpread: focalSpread ?? this.focalSpread,
      focalPointX: focalPointX ?? this.focalPointX,
      focalPointY: focalPointY ?? this.focalPointY,
      variationFloor: variationFloor ?? this.variationFloor,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GeometricTextureParams &&
        other.scale == scale &&
        other.intensity == intensity &&
        other.focalSpread == focalSpread &&
        other.focalPointX == focalPointX &&
        other.focalPointY == focalPointY &&
        other.variationFloor == variationFloor;
  }

  @override
  int get hashCode => Object.hash(
    scale,
    intensity,
    focalSpread,
    focalPointX,
    focalPointY,
    variationFloor,
  );
}

/// Tunable parameters for the animated wave train that sweeps the triangle
/// grid, causing eligible triangles to twinkle — individually, on their own
/// staggered timing — as the wave passes over them.
///
/// The wave always originates just off-screen past the top-right corner —
/// intentionally independent of the accent gradient's focal point
/// ([GeometricTextureParams.focalPointX]/`Y`), which can sit anywhere
/// on screen and would otherwise leave part of the grid permanently
/// unreachable (the wave only ever travels forward from its origin).
///
/// The wave repeats in space every `speed * period` units, so lowering
/// [period] doesn't shorten how far a single wave travels — it packs more
/// simultaneous, evenly-spaced wavefronts onto the screen at once.
class GeometricWaveParams {
  const GeometricWaveParams({
    this.enabled = false,
    this.shape = GeometricWaveShape.linear,
    this.directionDegrees = 135.0,
    this.speed = 0.4,
    this.width = 0.08,
    this.period = 7.0,
    this.popHoldSeconds = 0.6,
    this.popScale = 1.4,
    this.popBrightness = 0.32,
    this.maskDensity = 0.5,
    this.maskClusterScale = 5.0,
    this.twinkleSparsity = 0.15,
    this.shadowLightDegrees = 225.0,
    this.shadowOffset = 0.06,
    this.shadowSoftness = 0.04,
    this.shadowStrength = 0.45,
    this.popBrightnessVariance = 0.4,
    this.tiltAmount = 0.7,
    this.tiltShading = 0.5,
    this.massLagSeconds = 0.12,
    this.massSpring = 0.3,
    this.scatterMode = false,
    this.scatterLitAmount = 0.12,
  });

  /// Whether the wave animation runs at all. Off by default.
  ///
  /// [scatterMode] animates independently of this — see [animates].
  final bool enabled;

  /// Linear sweep vs. radial expand.
  final GeometricWaveShape shape;

  /// Travel direction of the linear sweep, in degrees (0 = +X, 90 = +Y,
  /// screen-space Y-down). Default 135° sweeps down-left, away from the
  /// off-screen top-right origin. Unused in radial mode.
  final double directionDegrees;

  /// Wavefront travel speed, in aspect-corrected UV units per second.
  final double speed;

  /// Thickness of each wavefront's band of sparkles, in UV units.
  ///
  /// Every eligible triangle fires once per passing wavefront, at its own
  /// random offset within the band, and this is how far those offsets spread —
  /// so it sets how thick the band reads. Once it grows past the wavelength
  /// (`speed * period`), the offsets cover a full period and the fronts blend
  /// into an evenly-scattered twinkle field.
  final double width;

  /// Spatial period of the wave train, in seconds of travel time
  /// (wavelength = speed × period). Lower values pack more simultaneous
  /// wavefronts onto the screen rather than shortening the wave's reach.
  final double period;

  /// How long a single triangle's flash lasts, in seconds (measured at half
  /// its peak brightness). Independent of [width], which governs how far apart
  /// the flashes are spread rather than how long each one burns.
  final double popHoldSeconds;

  /// Maximum apparent growth factor for a popped triangle (>= 1.0).
  final double popScale;

  /// Extra brightness burst applied to popped triangles.
  final double popBrightness;

  /// Fraction (0–1) of triangles eligible to ever twinkle as the wave passes
  /// — controls how many triangles the wave visibly touches.
  final double maskDensity;

  /// Noise frequency for the organic mask. Lower = larger, chunkier clusters;
  /// higher = finer, more scattered clusters.
  final double maskClusterScale;

  /// Fraction (0–1) of eligible triangles that actually fire on any one
  /// wavefront pass, re-rolled per pass so a different scatter lights up each
  /// sweep. This is what keeps the wave reading as individual sparkles: with
  /// every eligible triangle firing on every pass, the band fills in solid.
  final double twinkleSparsity;

  /// Direction the scene light shines *from*, in degrees (0 = from the right,
  /// 90 = from the bottom, screen-space Y-down). Default 225° puts it at the
  /// upper-left, so popped triangles drop their shadows toward the lower-right.
  ///
  /// One fixed direction for the whole grid, deliberately: parallel shadows
  /// read as a single sheet of triangles lifting off a surface, where a
  /// per-triangle light direction reads as many unrelated lamps.
  final double shadowLightDegrees;

  /// How far a popped triangle throws its shadow, in triangle side lengths.
  /// This is also how wide the visible crescent gets, since the shadow is the
  /// triangle's own silhouette shifted this far away from the light.
  ///
  /// Values past ~0.29 (the inradius of a unit triangle) push the shadow
  /// clear of the caster and it thins out rather than growing.
  final double shadowOffset;

  /// How far the shadow fades at its outer edge, in triangle side lengths.
  /// Keep it below [shadowOffset] or the crescent never reaches full strength
  /// and the shadow reads as a faint smudge.
  final double shadowSoftness;

  /// How dark the shadow gets (0 = invisible, 1 = black). Applied as a
  /// multiply, so on a very dark [baseColor] there's little left to darken —
  /// the shadow will show mainly where the accent gradient has brightened
  /// things up.
  final double shadowStrength;

  /// How much a flash's peak brightness varies from one wave to the next
  /// (0 = every flash identical, 1 = anywhere from nothing to full).
  ///
  /// Re-rolled per wavefront, so a triangle that flares hard on one pass may
  /// barely glow on the next. Affects brightness only — a triangle's growth
  /// and its cast shadow stay at full strength regardless.
  final double popBrightnessVariance;

  /// How far a popping triangle pitches on its hinge as it lifts (0 = rises
  /// perfectly flat like an elevator, 1 = the hinged edge stays down on the
  /// grid while the opposite corner lifts to double height).
  ///
  /// Each triangle's hinge direction is a permanent, random property of that
  /// triangle — never re-rolled per wave, because a hinge belongs to the object
  /// rather than the event. The grid ends up with a fixed tilt "grain".
  final double tiltAmount;

  /// How strongly the pitch shows up as brightness across a triangle's face
  /// (0 = pitch is visible only through the shadow it throws).
  ///
  /// Covers two distinct effects at once: the face turning toward or away from
  /// the light (uniform across the face), and its raised side sitting nearer to
  /// the light than its hinged side (a gradient across the face). Scaled by the
  /// physical lift, so the gradient only develops once the tile has actually
  /// started to move.
  final double tiltShading;

  /// How long the physical lift trails the light flash, in seconds.
  ///
  /// Light is energy and snaps on; matter has inertia and cannot. Separating
  /// the two is what lets the eye read an energy wave passing *through* a
  /// physical object rather than one flat combined effect. 0 re-couples them.
  final double massLagSeconds;

  /// How much the lift overshoots its target and settles back (0 = no bounce).
  /// A single damped wobble riding the settle, not a sustained oscillation.
  final double massSpring;

  /// Replaces the travelling wave with an even scatter: triangles fire
  /// independently all over the screen instead of in a band, and the accent
  /// gradient is switched off so the twinkles are the only accent on screen.
  ///
  /// Overrides [enabled] rather than requiring it — turning this on animates
  /// the background whether or not the wave was enabled. The two are mutually
  /// exclusive; scatter wins.
  ///
  /// Everything per-triangle is shared with the wave: the flash curve,
  /// [popHoldSeconds], [popBrightness], [popScale], [popBrightnessVariance],
  /// and the hinge/mass/shadow physics. Only the *source of a triangle's phase*
  /// changes — position along the wave becomes pure per-triangle randomness.
  /// The clustered mask ([maskDensity]) is bypassed, so scatter is uniform and
  /// the wave's clustering stays tuned independently.
  final bool scatterMode;

  /// What fraction of triangles are lit at any given instant in [scatterMode].
  ///
  /// Exact, and deliberately independent of [popHoldSeconds]: the re-fire
  /// interval is derived from both, so stretching the hold slows each flash
  /// down without lighting any more of them. Caps around 0.25 — past that,
  /// flashes stop being distinct and smear into a constant glow.
  final double scatterLitAmount;

  /// Whether the background animates at all, in either mode.
  bool get animates => enabled || scatterMode;

  static const defaults = GeometricWaveParams();

  GeometricWaveParams copyWith({
    bool? enabled,
    GeometricWaveShape? shape,
    double? directionDegrees,
    double? speed,
    double? width,
    double? period,
    double? popHoldSeconds,
    double? popScale,
    double? popBrightness,
    double? maskDensity,
    double? maskClusterScale,
    double? twinkleSparsity,
    double? shadowLightDegrees,
    double? shadowOffset,
    double? shadowSoftness,
    double? shadowStrength,
    double? popBrightnessVariance,
    double? tiltAmount,
    double? tiltShading,
    double? massLagSeconds,
    double? massSpring,
    bool? scatterMode,
    double? scatterLitAmount,
  }) {
    return GeometricWaveParams(
      enabled: enabled ?? this.enabled,
      shape: shape ?? this.shape,
      directionDegrees: directionDegrees ?? this.directionDegrees,
      speed: speed ?? this.speed,
      width: width ?? this.width,
      period: period ?? this.period,
      popHoldSeconds: popHoldSeconds ?? this.popHoldSeconds,
      popScale: popScale ?? this.popScale,
      popBrightness: popBrightness ?? this.popBrightness,
      maskDensity: maskDensity ?? this.maskDensity,
      maskClusterScale: maskClusterScale ?? this.maskClusterScale,
      twinkleSparsity: twinkleSparsity ?? this.twinkleSparsity,
      shadowLightDegrees: shadowLightDegrees ?? this.shadowLightDegrees,
      shadowOffset: shadowOffset ?? this.shadowOffset,
      shadowSoftness: shadowSoftness ?? this.shadowSoftness,
      shadowStrength: shadowStrength ?? this.shadowStrength,
      popBrightnessVariance:
          popBrightnessVariance ?? this.popBrightnessVariance,
      tiltAmount: tiltAmount ?? this.tiltAmount,
      tiltShading: tiltShading ?? this.tiltShading,
      massLagSeconds: massLagSeconds ?? this.massLagSeconds,
      massSpring: massSpring ?? this.massSpring,
      scatterMode: scatterMode ?? this.scatterMode,
      scatterLitAmount: scatterLitAmount ?? this.scatterLitAmount,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GeometricWaveParams &&
        other.enabled == enabled &&
        other.shape == shape &&
        other.directionDegrees == directionDegrees &&
        other.speed == speed &&
        other.width == width &&
        other.period == period &&
        other.popHoldSeconds == popHoldSeconds &&
        other.popScale == popScale &&
        other.popBrightness == popBrightness &&
        other.maskDensity == maskDensity &&
        other.maskClusterScale == maskClusterScale &&
        other.twinkleSparsity == twinkleSparsity &&
        other.shadowLightDegrees == shadowLightDegrees &&
        other.shadowOffset == shadowOffset &&
        other.shadowSoftness == shadowSoftness &&
        other.shadowStrength == shadowStrength &&
        other.popBrightnessVariance == popBrightnessVariance &&
        other.tiltAmount == tiltAmount &&
        other.tiltShading == tiltShading &&
        other.massLagSeconds == massLagSeconds &&
        other.massSpring == massSpring &&
        other.scatterMode == scatterMode &&
        other.scatterLitAmount == scatterLitAmount;
  }

  // hashAll rather than hash: Object.hash tops out at 20 positional arguments
  // and this list is past it.
  @override
  int get hashCode => Object.hashAll([
    enabled,
    shape,
    directionDegrees,
    speed,
    width,
    period,
    popHoldSeconds,
    popScale,
    popBrightness,
    maskDensity,
    maskClusterScale,
    twinkleSparsity,
    shadowLightDegrees,
    shadowOffset,
    shadowSoftness,
    shadowStrength,
    popBrightnessVariance,
    tiltAmount,
    tiltShading,
    massLagSeconds,
    massSpring,
    scatterMode,
    scatterLitAmount,
  ]);
}

/// Full-size equilateral-triangle background texture with an accent gradient
/// and an optional animated wave "pop" effect.
///
/// Renders a uniform triangle grid where each triangle is flat-shaded with a
/// random intensity of the [accentColor], concentrated near [params.focalPoint]
/// and fading toward the edges. When [GeometricWaveParams.enabled] is true, a
/// wave periodically sweeps the grid and lifts a clustered, noise-selected
/// subset of triangles off the screen toward the viewer.
///
/// [GeometricWaveParams.scatterMode] replaces that wave with an even scatter of
/// independently firing triangles and drops the accent gradient. It animates on
/// its own, without [GeometricWaveParams.enabled] — see
/// [GeometricWaveParams.animates].
///
/// When [program] is null (still loading or failed), falls back to a flat
/// [baseColor] fill — no jank or error states visible.
///
/// Use inside a [Positioned.fill] so the painter has finite constraints.
class GeometricTexture extends StatefulWidget {
  const GeometricTexture({
    super.key,
    required this.program,
    required this.baseColor,
    required this.accentColor,
    this.params = GeometricTextureParams.defaults,
    this.waveParams = GeometricWaveParams.defaults,
    this.debugRowFade = false,
  });

  final FragmentProgram? program;
  final Color baseColor;
  final Color accentColor;
  final GeometricTextureParams params;
  final GeometricWaveParams waveParams;

  /// Dev-only row fade visualiser (see [GeometricTexturePainter.debugRowFade]).
  /// Also drives the animation clock so the rows fade even when no wave is on.
  final bool debugRowFade;

  @override
  State<GeometricTexture> createState() => _GeometricTextureState();
}

class _GeometricTextureState extends State<GeometricTexture> {
  FragmentShader? _shader;
  Timer? _timer;
  final Stopwatch _clock = Stopwatch();
  Duration _elapsed = Duration.zero;

  // The wave is driven by a plain [Timer] rather than a [Ticker] on purpose.
  // A running Ticker calls scheduleFrame() on *every* vsync, which pins the
  // entire app's frame pipeline at the display's native refresh rate (measured
  // at 119fps on this hardware) for as long as the wave is enabled — even on
  // frames where nothing was repainted. The shader itself is cheap (~0.75ms
  // fullscreen), but Dart is single-threaded, so running the full build/layout/
  // paint pipeline over the whole widget tree 119 times a second saturates the
  // UI thread and pushes input handling and state updates seconds behind.
  //
  // A Timer only wakes us when we actually intend to redraw, so the app
  // produces ~30 frames/sec instead of ~119 and stays idle in between. The
  // wave is a slow ambient effect; it gains nothing from native refresh rate.
  static const _frameInterval = Duration(milliseconds: 33); // ~30fps

  // The wave animates on its own; the debug visualiser also needs the clock
  // running so its rows can fade.
  bool get _animating => widget.waveParams.animates || widget.debugRowFade;

  @override
  void initState() {
    super.initState();
    _shader = widget.program?.fragmentShader();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant GeometricTexture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.program != widget.program) {
      _shader?.dispose();
      _shader = widget.program?.fragmentShader();
      setState(() {});
    }
    final wasAnimating =
        oldWidget.waveParams.animates || oldWidget.debugRowFade;
    if (wasAnimating != _animating) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (_animating) {
      if (_timer != null) return;
      _clock.start();
      _timer = Timer.periodic(_frameInterval, (_) {
        if (!mounted) return;
        setState(() => _elapsed = _clock.elapsed);
      });
    } else {
      _timer?.cancel();
      _timer = null;
      _clock.stop();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;

    if (shader == null) {
      return ColoredBox(color: widget.baseColor);
    }

    // RepaintBoundary gives the background its own compositor layer. Without
    // it, markNeedsPaint walks up to the root, so each wave redraw re-records
    // the root layer and everything painted alongside it. willChange tells the
    // raster cache not to try caching a picture that changes every frame —
    // otherwise it repeatedly allocates a full-window offscreen surface, fills
    // it, and throws it away.
    return RepaintBoundary(
      child: CustomPaint(
        isComplex: true,
        willChange: _animating,
        painter: GeometricTexturePainter(
          shader: shader,
          baseColor: widget.baseColor,
          accentColor: widget.accentColor,
          params: widget.params,
          waveParams: widget.waveParams,
          time: _elapsed.inMicroseconds / 1e6,
          debugRowFade: widget.debugRowFade,
        ),
      ),
    );
  }
}

class GeometricTexturePainter extends CustomPainter {
  GeometricTexturePainter({
    required this.shader,
    required this.baseColor,
    required this.accentColor,
    required this.params,
    this.waveParams = GeometricWaveParams.defaults,
    this.time = 0.0,
    this.debugRowFade = false,
  });

  final FragmentShader shader;
  final Color baseColor;
  final Color accentColor;
  final GeometricTextureParams params;
  final GeometricWaveParams waveParams;
  final double time;

  /// Dev-only: replace the render with clean rows fading between dark and
  /// regular so the shade transition curve can be inspected in isolation.
  final bool debugRowFade;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final directionRadians = waveParams.directionDegrees * (math.pi / 180.0);
    final lightRadians = waveParams.shadowLightDegrees * (math.pi / 180.0);

    // Uniform layout (must match shader declaration order):
    // 0-1   vec2  u_resolution
    // 2     float u_scale
    // 3     float u_intensity
    // 4     float u_focal_spread
    // 5-6   vec2  u_focal_point
    // 7     float u_variation_floor
    // 8-11  vec4  u_base_color
    // 12-15 vec4  u_accent_color
    // 16    float u_time
    // 17    float u_wave_enabled
    // 18    float u_wave_mode
    // 19-20 vec2  u_wave_direction
    // 21    float u_wave_speed
    // 22    float u_wave_width
    // 23    float u_wave_period
    // 24    float u_pop_hold_time
    // 25    float u_pop_scale
    // 26    float u_pop_brightness
    // 27    float u_mask_density
    // 28    float u_mask_cluster_scale
    // 29    float u_twinkle_sparsity
    // 30-31 vec2  u_shadow_light_dir
    // 32    float u_shadow_offset
    // 33    float u_shadow_softness
    // 34    float u_shadow_strength
    // 35    float u_pop_brightness_variance
    // 36    float u_tilt_amount
    // 37    float u_tilt_shading
    // 38    float u_mass_lag
    // 39    float u_mass_spring
    // 40    float u_scatter_mode
    // 41    float u_scatter_lit_amount
    // 42    float u_debug_row_fade
    try {
      shader.setFloat(0, size.width);
      shader.setFloat(1, size.height);
      shader.setFloat(2, params.scale);
      shader.setFloat(3, params.intensity);
      shader.setFloat(4, params.focalSpread);
      shader.setFloat(5, params.focalPointX);
      shader.setFloat(6, params.focalPointY);
      shader.setFloat(7, params.variationFloor);
      shader.setFloat(8, baseColor.r);
      shader.setFloat(9, baseColor.g);
      shader.setFloat(10, baseColor.b);
      shader.setFloat(11, baseColor.a);
      shader.setFloat(12, accentColor.r);
      shader.setFloat(13, accentColor.g);
      shader.setFloat(14, accentColor.b);
      shader.setFloat(15, accentColor.a);
      shader.setFloat(16, time);
      // The shader's master gate covers both modes — scatter animates whether
      // or not the wave itself was enabled.
      shader.setFloat(17, waveParams.animates ? 1.0 : 0.0);
      shader.setFloat(
        18,
        waveParams.shape == GeometricWaveShape.radial ? 1.0 : 0.0,
      );
      shader.setFloat(19, math.cos(directionRadians));
      shader.setFloat(20, math.sin(directionRadians));
      shader.setFloat(21, waveParams.speed);
      shader.setFloat(22, waveParams.width);
      shader.setFloat(23, waveParams.period);
      shader.setFloat(24, waveParams.popHoldSeconds);
      shader.setFloat(25, waveParams.popScale);
      shader.setFloat(26, waveParams.popBrightness);
      shader.setFloat(27, waveParams.maskDensity);
      shader.setFloat(28, waveParams.maskClusterScale);
      shader.setFloat(29, waveParams.twinkleSparsity);
      shader.setFloat(30, math.cos(lightRadians));
      shader.setFloat(31, math.sin(lightRadians));
      shader.setFloat(32, waveParams.shadowOffset);
      shader.setFloat(33, waveParams.shadowSoftness);
      shader.setFloat(34, waveParams.shadowStrength);
      shader.setFloat(35, waveParams.popBrightnessVariance);
      shader.setFloat(36, waveParams.tiltAmount);
      shader.setFloat(37, waveParams.tiltShading);
      shader.setFloat(38, waveParams.massLagSeconds);
      shader.setFloat(39, waveParams.massSpring);
      shader.setFloat(40, waveParams.scatterMode ? 1.0 : 0.0);
      shader.setFloat(41, waveParams.scatterLitAmount);
      shader.setFloat(42, debugRowFade ? 1.0 : 0.0);

      final paint = Paint()..shader = shader;
      canvas.drawRect(Offset.zero & size, paint);
    } on RangeError {
      // The compiled shader's uniform count doesn't match this code — e.g. a
      // stale shader bundle left over from a hot reload (.frag changes need a
      // full restart to recompile). Fall back to a flat fill for this frame
      // instead of throwing on every tick, which can otherwise pile up
      // framework error-reporting work fast enough to stall the UI thread.
      canvas.drawRect(Offset.zero & size, Paint()..color = baseColor);
    }
  }

  @override
  bool shouldRepaint(covariant GeometricTexturePainter oldDelegate) {
    return oldDelegate.shader != shader ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.params != params ||
        oldDelegate.waveParams != waveParams ||
        oldDelegate.time != time ||
        oldDelegate.debugRowFade != debugRowFade;
  }
}
