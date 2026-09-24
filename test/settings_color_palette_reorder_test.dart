import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/settings/settings_color_palette_section.dart';

void main() {
  const palette = [0xFF111111, 0xFF222222, 0xFF333333];

  Finder chip(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(InputChip));

  /// Returns a getter for the palette the section last saved.
  Future<List<int>? Function()> pumpPalette(
    WidgetTester tester, {
    double width = 800,
  }) async {
    List<int>? saved;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: SettingsColorPaletteSection(
                  settings: AppSettings(colorPalette: palette),
                  onSave: (settings) async => saved = settings.colorPalette,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return () => saved;
  }

  /// A point just inside [label]'s chip, on its left or right edge — the
  /// cursor sitting in the gap before or after it.
  Offset edgeOf(WidgetTester tester, String label, {required bool right}) {
    final rect = tester.getRect(chip(label));
    return Offset(right ? rect.right - 4 : rect.left + 4, rect.center.dy);
  }

  Future<TestGesture> pickUp(WidgetTester tester, String label) async {
    final gesture = await tester.startGesture(tester.getCenter(chip(label)));
    await tester.pump();
    // Past the drag slop, but still over the chip's own slot.
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    return gesture;
  }

  testWidgets('moving between two swatches opens a gap there', (tester) async {
    final saved = await pumpPalette(tester);
    final first = tester.getRect(chip('#111111'));
    final third = tester.getRect(chip('#333333'));
    final target = edgeOf(tester, '#222222', right: true);

    final gesture = await pickUp(tester, '#111111');
    await gesture.moveTo(target);
    await tester.pumpAndSettle();

    // #222222 slid left into the slot #111111 left, and the gap opened after
    // it; #333333 stays put, on the far side of the gap.
    expect(tester.getRect(chip('#222222')).left, first.left);
    expect(tester.getRect(chip('#333333')), third);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(saved(), [0xFF222222, 0xFF111111, 0xFF333333]);
  });

  testWidgets('dropping before the first swatch moves it to the front', (
    tester,
  ) async {
    final saved = await pumpPalette(tester);
    final target = edgeOf(tester, '#111111', right: false);

    final gesture = await pickUp(tester, '#333333');
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(saved(), [0xFF333333, 0xFF111111, 0xFF222222]);
  });

  testWidgets('the gap follows the cursor onto the next row', (tester) async {
    final saved = await pumpPalette(tester, width: 300);
    // Narrow enough that #333333 wraps under the other two.
    expect(
      tester.getRect(chip('#333333')).top,
      greaterThan(tester.getRect(chip('#111111')).bottom),
    );
    final target = edgeOf(tester, '#333333', right: true);

    final gesture = await pickUp(tester, '#111111');
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(saved(), [0xFF222222, 0xFF333333, 0xFF111111]);
  });

  testWidgets('dropping a swatch back in its own gap saves nothing', (
    tester,
  ) async {
    final saved = await pumpPalette(tester);

    final gesture = await pickUp(tester, '#222222');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(saved(), isNull);
  });

  testWidgets('dropping off the palette cancels and closes the gap', (
    tester,
  ) async {
    final saved = await pumpPalette(tester);
    final before = [
      for (final label in ['#111111', '#222222', '#333333'])
        tester.getRect(chip(label)),
    ];

    final gesture = await pickUp(tester, '#111111');
    await gesture.moveTo(edgeOf(tester, '#333333', right: true));
    await tester.pump();
    await gesture.moveTo(const Offset(400, 500));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(saved(), isNull);
    expect([
      for (final label in ['#111111', '#222222', '#333333'])
        tester.getRect(chip(label)),
    ], before);
  });
}
