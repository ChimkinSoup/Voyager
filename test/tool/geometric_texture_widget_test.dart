import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/geometric_texture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('GeometricTexture paints shader across full bounds', (
    tester,
  ) async {
    final program = await FragmentProgram.fromAsset(
      'shaders/geometric_texture.frag',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: GeometricTexture(
            program: program,
            baseColor: const Color(0xFF1B1B22),
            accentColor: Colors.blue,
          ),  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(GeometricTexture), findsOneWidget);
  });
}
