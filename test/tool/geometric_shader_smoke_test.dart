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

  test('geometric texture shader loads and accepts all uniforms', () async {
    final program = await FragmentProgram.fromAsset(
      'shaders/geometric_texture.frag',
    );
    expect(program, isNotNull);
    final shader = program.fragmentShader();
    addTearDown(shader.dispose);

    const base = Color(0xFF1B1B22);
    const accent = Color(0xFF7C9EFF);

    // Uniform layout:
    // 0-1   u_resolution   (vec2)
    // 2     u_scale
    // 3     u_intensity
    // 4     u_focal_spread
    // 5-6   u_focal_point  (vec2)
    // 7-10  u_base_color   (vec4)
    // 11-14 u_accent_color (vec4)
    shader.setFloat(0, 800);
    shader.setFloat(1, 600);
    shader.setFloat(2, 10.0);
    shader.setFloat(3, 0.85);
    shader.setFloat(4, 1.0);
    shader.setFloat(5, 1.0);  // focal x
    shader.setFloat(6, 0.5);  // focal y
    shader.setFloat(7, base.r);
    shader.setFloat(8, base.g);
    shader.setFloat(9, base.b);
    shader.setFloat(10, base.a);
    shader.setFloat(11, accent.r);
    shader.setFloat(12, accent.g);
    shader.setFloat(13, accent.b);
    shader.setFloat(14, accent.a);
  });
}
