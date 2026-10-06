// In Light, the journal switcher drew each name in its own pastel colour on
// cream: "Gamma" #EA999C on the menu measured 2.0:1 (BUG-057).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/scope_switcher.dart';
import 'package:voyager/domain/models/enums.dart';

const _gamma = Color(0xFFEA999C);

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
}

Future<void> _pump(WidgetTester tester, AppThemeMode mode) {
  return tester.pumpWidget(
    MaterialApp(
      theme: VoyagerTheme.forMode(mode),
      home: Scaffold(
        body: ScopeSwitcher<String?>(
          selectedValue: 'g',
          accent: _gamma,
          onSelected: (_) {},
          items: const [
            ScopeSwitcherItem(value: null, label: 'All journals', count: '3'),
            ScopeSwitcherItem(
              value: 'g',
              label: 'Gamma',
              count: '3',
              color: _gamma,
            ),
          ],
        ),
      ),
    ),
  );
}

Color _colorOf(WidgetTester tester, Finder text) =>
    tester.widget<Text>(text).style!.color!;

void main() {
  testWidgets('Light: the title and the menu names clear 4.5:1 on cream', (
    tester,
  ) async {
    await _pump(tester, AppThemeMode.light);
    final cream = Theme.of(
      tester.element(find.text('Gamma')),
    ).scaffoldBackgroundColor;

    expect(
      _contrast(_colorOf(tester, find.text('Gamma')), cream),
      greaterThanOrEqualTo(4.5),
    );

    await tester.tap(find.text('Gamma'));
    await tester.pumpAndSettle();
    for (final name in ['Gamma', 'All journals']) {
      expect(
        _contrast(_colorOf(tester, find.text(name).last), cream),
        greaterThanOrEqualTo(4.5),
        reason: name,
      );
    }
  });

  testWidgets('Dark keeps the journal colour as it is', (tester) async {
    await _pump(tester, AppThemeMode.dark);
    expect(_colorOf(tester, find.text('Gamma')), _gamma);

    await tester.tap(find.text('Gamma'));
    await tester.pumpAndSettle();
    expect(_colorOf(tester, find.text('Gamma').last), _gamma);
  });
}
