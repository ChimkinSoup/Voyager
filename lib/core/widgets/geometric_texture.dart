import 'dart:ui';

import 'package:flutter/material.dart';

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
    this.animationSpeedMultiplier = 1.0,
  });

  final FragmentProgram? program;
  final Color baseColor;
  final Color accentColor;
  final GeometricTextureParams params;
  final double animationSpeedMultiplier;

  @override
  State<GeometricTexture> createState() => _GeometricTextureState();
}

class _GeometricTextureState extends State<GeometricTexture> with SingleTickerProviderStateMixin {
  FragmentShader? _shader;
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _shader = widget.program?.fragmentShader();
    
    // Play a single sweep animation when the texture is first loaded.
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (2600 * widget.animationSpeedMultiplier).toInt()),
    );
    
    if (widget.program != null) {
      _startAnimation();
    }
  }

  void _startAnimation() {
    // We only want it to play once, but we delay slightly so it's smooth
    // after the initial app render.
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        _controller.forward(from: 0.0);
      }
    });
  }

  @override
  void didUpdateWidget(covariant GeometricTexture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.program != widget.program) {
      _shader?.dispose();
      _shader = widget.program?.fragmentShader();
      
      if (oldWidget.program == null && widget.program != null) {
        _startAnimation();
      }
      
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;

    if (shader == null) {
      return ColoredBox(color: widget.baseColor);
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: GeometricTexturePainter(
            shader: shader,
            baseColor: widget.baseColor,
            accentColor: widget.accentColor,
            params: widget.params,
            animationTime: _controller.value,
          ),
        );
      },
    );
  }
}

class GeometricTexturePainter extends CustomPainter {
  GeometricTexturePainter({
    required this.shader,
    required this.baseColor,
    required this.accentColor,
    required this.params,
    required this.animationTime,
  });

  final FragmentShader shader;
  final Color baseColor;
  final Color accentColor;
  final GeometricTextureParams params;
  final double animationTime;

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
    // 16    float u_animation_time
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
    shader.setFloat(16, animationTime);

    final paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant GeometricTexturePainter oldDelegate) {
    return oldDelegate.shader != shader ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.params != params ||
        oldDelegate.animationTime != animationTime;
  }
}

