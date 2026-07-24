import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // PaperTexturePainter catches RangeError and falls back to a flat fill, so a
  // drift between the shader's uniform count and the painter's setFloat calls
  // fails silently at runtime (the light background just stops texturing).
  // Pin the count so drift fails here instead.
  test('paper texture shader exposes exactly 13 float uniforms', () async {
    final program = await FragmentProgram.fromAsset(
      'shaders/paper_texture.frag',
    );
    final shader = program.fragmentShader();
    addTearDown(shader.dispose);

    // Uniform layout (must match paper_texture.frag and PaperTexturePainter):
    //   0-1   vec2  u_resolution
    //   2-5   vec4  u_base_color
    //   6-9   vec4  u_speck_color
    //   10    u_grain_scale
    //   11    u_grain_strength
    //   12    u_fiber_strength
    for (var i = 0; i <= 12; i++) {
      shader.setFloat(i, 0.5);
    }

    expect(
      () => shader.setFloat(13, 0.5),
      throwsA(isA<Error>()),
      reason: 'shader declares more uniforms than the painter writes',
    );
  });
}
