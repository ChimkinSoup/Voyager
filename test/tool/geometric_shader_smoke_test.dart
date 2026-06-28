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

    const color = Color(0xFF1B1B22);
    // Uniform layout:
    // 0-1  u_resolution, 2 u_scale, 3 u_intensity,
    // 4 u_randomness, 5 u_shape_complexity, 6-9 u_base_color
    shader.setFloat(0, 800);
    shader.setFloat(1, 600);
    shader.setFloat(2, 8.0);
    shader.setFloat(3, 0.3);
    shader.setFloat(4, 0.9);
    shader.setFloat(5, 1.0);
    shader.setFloat(6, color.r);
    shader.setFloat(7, color.g);
    shader.setFloat(8, color.b);
    shader.setFloat(9, color.a);
  });
}
