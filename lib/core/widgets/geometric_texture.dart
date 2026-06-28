import 'dart:ui';

import 'package:flutter/material.dart';

/// Tunable parameters for the low-poly geometric texture shader.
class GeometricTextureParams {
  const GeometricTextureParams({
    this.scale = 8.0,
    this.intensity = 0.3,
    this.randomness = 0.9,
    this.shapeComplexity = 1.0,
  });

  /// Triangle density. Higher = smaller, more numerous facets.
  final double scale;

  /// Contrast between the brightest and darkest facets (0–1).
  /// 0.3 means the darkest facet is 70% brightness of the base color.
  final double intensity;

  /// Vertex jitter amount. 0.0 = perfect grid, 1.0+ = highly irregular sizes.
  final double randomness;

  /// Mix of polygon shapes (0–1).
  /// 0.0 = only standard triangles. 1.0 = full mix of quads and both
  /// triangle orientations.
  final double shapeComplexity;

  static const defaults = GeometricTextureParams();

  GeometricTextureParams copyWith({
    double? scale,
    double? intensity,
    double? randomness,
    double? shapeComplexity,
  }) {
    return GeometricTextureParams(
      scale: scale ?? this.scale,
      intensity: intensity ?? this.intensity,
      randomness: randomness ?? this.randomness,
      shapeComplexity: shapeComplexity ?? this.shapeComplexity,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GeometricTextureParams &&
        other.scale == scale &&
        other.intensity == intensity &&
        other.randomness == randomness &&
        other.shapeComplexity == shapeComplexity;
  }

  @override
  int get hashCode => Object.hash(scale, intensity, randomness, shapeComplexity);
}

/// Full-size geometric low-poly background texture widget.
///
/// Renders the compiled GLSL shader as a flat-shaded triangle grid covering
/// its full available area. When [program] is null (still loading or failed),
/// falls back to a flat [baseColor] fill — no jank or error states visible.
///
/// Use inside a [Positioned.fill] or [SizedBox.expand] so the painter has
/// finite constraints to fill.
class GeometricTexture extends StatefulWidget {
  const GeometricTexture({
    super.key,
    required this.program,
    required this.baseColor,
    this.params = GeometricTextureParams.defaults,
  });

  final FragmentProgram? program;
  final Color baseColor;
  final GeometricTextureParams params;

  @override
  State<GeometricTexture> createState() => _GeometricTextureState();
}

class _GeometricTextureState extends State<GeometricTexture> {
  FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _shader = widget.program?.fragmentShader();
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
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;

    if (shader == null) {
      return ColoredBox(color: widget.baseColor);
    }

    return CustomPaint(
      painter: GeometricTexturePainter(
        shader: shader,
        baseColor: widget.baseColor,
        params: widget.params,
      ),
    );
  }
}

class GeometricTexturePainter extends CustomPainter {
  GeometricTexturePainter({
    required this.shader,
    required this.baseColor,
    required this.params,
  });

  final FragmentShader shader;
  final Color baseColor;
  final GeometricTextureParams params;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // Uniform layout (must match shader declaration order):
    // 0-1  vec2  u_resolution
    // 2    float u_scale
    // 3    float u_intensity
    // 4    float u_randomness
    // 5    float u_shape_complexity
    // 6-9  vec4  u_base_color
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, params.scale);
    shader.setFloat(3, params.intensity);
    shader.setFloat(4, params.randomness);
    shader.setFloat(5, params.shapeComplexity);
    shader.setFloat(6, baseColor.r);
    shader.setFloat(7, baseColor.g);
    shader.setFloat(8, baseColor.b);
    shader.setFloat(9, baseColor.a);

    final paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant GeometricTexturePainter oldDelegate) {
    return oldDelegate.shader != shader ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.params != params;
  }
}
