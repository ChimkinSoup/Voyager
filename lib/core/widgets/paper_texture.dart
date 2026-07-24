import 'dart:ui';

import 'package:flutter/material.dart';

/// Tunable parameters for the light theme's paper grain.
@immutable
class PaperTextureParams {
  const PaperTextureParams({
    this.grainScale = 1400.0,
    this.grainStrength = 0.34,
    this.fiberStrength = 0.014,
  });

  /// Grain cells across the window's width. High values give the fine, almost
  /// per-pixel speckle of a matte stock; low values give visible tooth.
  final double grainScale;

  /// How far a speck pulls the ground toward the speck color (0–1).
  final double grainStrength;

  /// Strength of the slow, large-scale density blotch (0–1). Kept very low —
  /// past a couple of percent it stops reading as paper and starts reading as
  /// a dirty gradient.
  final double fiberStrength;

  static const defaults = PaperTextureParams();

  @override
  bool operator ==(Object other) {
    return other is PaperTextureParams &&
        other.grainScale == grainScale &&
        other.grainStrength == grainStrength &&
        other.fiberStrength == fiberStrength;
  }

  @override
  int get hashCode => Object.hash(grainScale, grainStrength, fiberStrength);
}

/// Full-screen warm-cream paper ground for the light theme.
///
/// Static by design: unlike the dark theme's triangle grid there is no time
/// uniform and no timer, so this paints once per size/color change and is then
/// held by the compositor. The only motion in the light background comes from
/// the petals drawn on top.
///
/// Falls back to a flat [baseColor] fill when [program] is null (still loading
/// or failed to compile) — same graceful degradation as the geometric texture.
///
/// Use inside a [Positioned.fill].
class PaperTexture extends StatefulWidget {
  const PaperTexture({
    super.key,
    required this.program,
    required this.baseColor,
    required this.speckColor,
    this.params = PaperTextureParams.defaults,
  });

  final FragmentProgram? program;

  /// The cream ground.
  final Color baseColor;

  /// Tone the specks are pulled toward — a light warm gray.
  final Color speckColor;

  final PaperTextureParams params;

  @override
  State<PaperTexture> createState() => _PaperTextureState();
}

class _PaperTextureState extends State<PaperTexture> {
  FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _shader = widget.program?.fragmentShader();
  }

  @override
  void didUpdateWidget(covariant PaperTexture oldWidget) {
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
    if (shader == null) return ColoredBox(color: widget.baseColor);

    return RepaintBoundary(
      child: CustomPaint(
        isComplex: true,
        painter: PaperTexturePainter(
          shader: shader,
          baseColor: widget.baseColor,
          speckColor: widget.speckColor,
          params: widget.params,
        ),
      ),
    );
  }
}

class PaperTexturePainter extends CustomPainter {
  PaperTexturePainter({
    required this.shader,
    required this.baseColor,
    required this.speckColor,
    required this.params,
  });

  final FragmentShader shader;
  final Color baseColor;
  final Color speckColor;
  final PaperTextureParams params;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // Uniform layout (must match shader declaration order):
    // 0-1   vec2  u_resolution
    // 2-5   vec4  u_base_color
    // 6-9   vec4  u_speck_color
    // 10    float u_grain_scale
    // 11    float u_grain_strength
    // 12    float u_fiber_strength
    try {
      shader.setFloat(0, size.width);
      shader.setFloat(1, size.height);
      shader.setFloat(2, baseColor.r);
      shader.setFloat(3, baseColor.g);
      shader.setFloat(4, baseColor.b);
      shader.setFloat(5, baseColor.a);
      shader.setFloat(6, speckColor.r);
      shader.setFloat(7, speckColor.g);
      shader.setFloat(8, speckColor.b);
      shader.setFloat(9, speckColor.a);
      shader.setFloat(10, params.grainScale);
      shader.setFloat(11, params.grainStrength);
      shader.setFloat(12, params.fiberStrength);

      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    } on RangeError {
      // Stale shader bundle (a .frag edit needs a full restart, not a hot
      // reload). Flat fill for this frame beats throwing on every paint.
      canvas.drawRect(Offset.zero & size, Paint()..color = baseColor);
    }
  }

  @override
  bool shouldRepaint(covariant PaperTexturePainter oldDelegate) {
    return oldDelegate.shader != shader ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.speckColor != speckColor ||
        oldDelegate.params != params;
  }
}
