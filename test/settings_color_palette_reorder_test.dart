import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/settings/settings_color_palette_section.dart';

void main() {
  const palette = [0xFF111111, 0xFF222222, 0xFF333333];

  Future<List<int>?> dragSwatch(
    WidgetTester tester, {
    required String from,
    required String onto,
  }) async {
    List<int>? saved;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SettingsColorPaletteSection(
              settings: AppSettings(colorPalette: palette),
              onSave: (settings) async => saved = settings.colorPalette,
            ),
          ),
        ),
      ),
    );

    // Both centers up front: once the drag starts the dragged chip's label
    // exists twice (in place, faded, and in the drag feedback), so `find.text`
    // on it is ambiguous.
    final start = tester.getCenter(find.text(from));
    final end = tester.getCenter(find.text(onto));

    final gesture = await tester.startGesture(start);
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    return saved;
  }

  testWidgets('dragging a swatch rightward lands it after the drop target', (
    tester,
  ) async {
    final saved = await dragSwatch(tester, from: '#111111', onto: '#333333');
    expect(saved, [0xFF222222, 0xFF333333, 0xFF111111]);
  });

  testWidgets('dragging a swatch leftward lands it before the drop target', (
    tester,
  ) async {
    final saved = await dragSwatch(tester, from: '#333333', onto: '#111111');
    expect(saved, [0xFF333333, 0xFF111111, 0xFF222222]);
  });

  testWidgets('dropping a swatch on itself saves nothing', (tester) async {
    final saved = await dragSwatch(tester, from: '#222222', onto: '#222222');
    expect(saved, isNull);
  });
}
