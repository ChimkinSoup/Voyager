import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Tunable parameters for the equilateral-triangle gradient texture shader.
class GeometricTextureParams {
  const GeometricTextureParams({
    this.scale = 10.0,
    this.intensity = 0.85,
    this.focalSpread = 1.0,
    this.focalPointX = 1.0,
    this.focalPointY = 0.5,
    this.variationFloor = 0.75,
    this.flashBrightness = 0.5,
    this.flashDensity = 0.3,
    this.flashSpeed = 1.0,
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
  
  /// Brightness of the flashing animation (0-1).
  final double flashBrightness;
  
  /// Density/Probability of a triangle flashing at any given time (0-1).
  final double flashDensity;
  
  /// Speed of the continuous flashing cycle (0.1-5.0).
  final double flashSpeed;

  static const defaults = GeometricTextureParams();

  GeometricTextureParams copyWith({
    double? scale,
    double? intensity,
    double? focalSpread,
    double? focalPointX,
    double? focalPointY,
    double? variationFloor,
    double? flashBrightness,
    double? flashDensity,
    double? flashSpeed,
  }) {
    return GeometricTextureParams(
      scale: scale ?? this.scale,
      intensity: intensity ?? this.intensity,
      focalSpread: focalSpread ?? this.focalSpread,
      focalPointX: focalPointX ?? this.focalPointX,
      focalPointY: focalPointY ?? this.focalPointY,
      variationFloor: variationFloor ?? this.variationFloor,
      flashBrightness: flashBrightness ?? this.flashBrightness,
      flashDensity: flashDensity ?? this.flashDensity,
      flashSpeed: flashSpeed ?? this.flashSpeed,
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
        other.variationFloor == variationFloor &&
        other.flashBrightness == flashBrightness &&
        other.flashDensity == flashDensity &&
        other.flashSpeed == flashSpeed;
  }

  @override
  int get hashCode => Object.hash(
    scale,
    intensity,
    focalSpread,
    focalPointX,
    focalPointY,
    variationFloor,
    flashBrightness,
    flashDensity,
    flashSpeed,
  );
}

/// Full-size equilateral-triangle background texture with an accent gradient.
///
/// Renders a uniform triangle grid where each triangle is flat-shaded with a
/// random intensity of the [accentColor], concentrated near [params.focalPoint]
/// and fading toward the edges.
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
  });

  final FragmentProgram? program;
  final Color baseColor;
  final Color accentColor;
  final GeometricTextureParams params;

  @override
  State<GeometricTexture> createState() => _GeometricTextureState();
}

class _GeometricTextureState extends State<GeometricTexture> with SingleTickerProviderStateMixin {
  FragmentShader? _shader;
  late final Ticker _ticker;
  
  // Normalized time [0, 1) that loops every 10 seconds.
  final ValueNotifier<double> _timeNotifier = ValueNotifier(0.0);
  
  // Throttle repaints to 30fps to halve GPU load. The flashing effect
  // is imperceptibly different at 30fps vs 60fps.
  static const _minFrameGap = Duration(milliseconds: 33); // ~30fps
  Duration _lastPaint = Duration.zero;

  @override
  void initState() {
    super.initState();
    _shader = widget.program?.fragmentShader();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    // Throttle: skip frames that arrive faster than 30fps
    if (elapsed - _lastPaint < _minFrameGap) return;
    _lastPaint = elapsed;
    
    // Advance normalized time, looping every 10 seconds
    final newTime = (elapsed.inMilliseconds / 10000.0) % 1.0;
    
    _timeNotifier.value = newTime;
  }

  @override
  void didUpdateWidget(covariant GeometricTexture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.program != widget.program) {
      _shader?.dispose();
      _shader = widget.program?.fragmentShader();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _shader?.dispose();
    _timeNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;

    if (shader == null) {
      return ColoredBox(color: widget.baseColor);
    }

    // RepaintBoundary is critical: it creates a separate compositing layer
    // for the shader, so its 30fps repaints are completely isolated from
    // the rest of the widget tree. Buttons, lists, and navigation are
    // unaffected by the shader animation.
    return RepaintBoundary(
      child: CustomPaint(
        painter: GeometricTexturePainter(
          shader: shader,
          baseColor: widget.baseColor,
          accentColor: widget.accentColor,
          params: widget.params,
          timeNotifier: _timeNotifier,
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
    required this.timeNotifier,
  }) : super(repaint: timeNotifier);

  final FragmentShader shader;
  final Color baseColor;
  final Color accentColor;
  final GeometricTextureParams params;
  final ValueNotifier<double> timeNotifier;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

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
    // 17    float u_flash_brightness
    // 18    float u_flash_density
    // 19    float u_flash_speed
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
    shader.setFloat(16, timeNotifier.value);
    shader.setFloat(17, params.flashBrightness);
    shader.setFloat(18, params.flashDensity);
    shader.setFloat(19, params.flashSpeed);

    final paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant GeometricTexturePainter oldDelegate) {
    return oldDelegate.shader != shader ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.params != params ||
        oldDelegate.timeNotifier != timeNotifier;
  }
}
