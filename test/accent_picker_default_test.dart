// BUG-213: the accent picker doesn't tick a swatch for an accent outside the
// palette, and Save without a choice keeps that accent.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/settings/settings_color_palette_section.dart';

void main() {
  Future<List<AppSettings>> openPicker(WidgetTester tester) async {
    final saved = <AppSettings>[];
    const settings = AppSettings();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          colorPaletteProvider.overrideWithValue(const [
            0xFFF2D5CF,
            0xFFEEBEBE,
          ]),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => pickAccentColor(
                  context,
                  ref,
                  settings,
                  (s) async => saved.add(s),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return saved;
  }

  testWidgets('BUG-213: the default accent ticks no swatch; Save keeps it', (
    tester,
  ) async {
    final saved = await openPicker(tester);
    expect(find.byIcon(PhosphorIconsFill.checkFat), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
  });

  testWidgets('BUG-213: Enter without a choice keeps the default accent', (
    tester,
  ) async {
    final saved = await openPicker(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
  });

  testWidgets('a picked swatch is saved', (tester) async {
    final saved = await openPicker(tester);
    await tester.tap(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved.single.accentColor, 0xFFF2D5CF);
  });
}
