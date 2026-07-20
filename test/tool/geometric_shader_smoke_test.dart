import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Color channels are normalized 0-1 for shader uniforms', () {
    const color = Color(0xFF1B1B22);
    expect(color.r, greaterThan(0));
    expect(color.r, lessThanOrEqualTo(1));
    expect(color.r / 255.0, lessThan(0.01));
  });

  // GeometricTexturePainter catches RangeError and falls back to a flat fill,
  // so a shader whose uniform count has drifted from the painter's setFloat
  // calls does not throw — the background just silently stops rendering. This
  // pins the count so that drift fails here instead.
  test('geometric texture shader exposes exactly 42 float uniforms', () async {
    final program = await FragmentProgram.fromAsset(
      'shaders/geometric_texture.frag',
    );
    final shader = program.fragmentShader();
    addTearDown(shader.dispose);

    // Uniform layout (must match both geometric_texture.frag's declaration
    // order and GeometricTexturePainter.paint):
    //   0-1   vec2  u_resolution        21    u_wave_speed
    //   2     u_scale                   22    u_wave_width
    //   3     u_intensity               23    u_wave_period
    //   4     u_focal_spread            24    u_pop_hold_time
    //   5-6   vec2  u_focal_point       25    u_pop_scale
    //   7     u_variation_floor         26    u_pop_brightness
    //   8-11  vec4  u_base_color        27    u_mask_density
    //   12-15 vec4  u_accent_color      28    u_mask_cluster_scale
    //   16    u_time                    29    u_twinkle_sparsity
    //   17    u_wave_enabled            30-31 vec2 u_shadow_light_dir
    //   18    u_wave_mode               32    u_shadow_offset
    //   19-20 vec2  u_wave_direction    33    u_shadow_softness
    //   34    u_shadow_strength         38    u_mass_lag
    //   35    u_pop_brightness_variance 39    u_mass_spring
    //   36    u_tilt_amount             40    u_scatter_mode
    //   37    u_tilt_shading            41    u_scatter_lit_amount
    for (var i = 0; i <= 41; i++) {
      shader.setFloat(i, 0.5);
    }

    expect(
      () => shader.setFloat(42, 0.5),
      throwsA(isA<Error>()),
      reason: 'shader declares more uniforms than the painter writes',
    );
  });
}
