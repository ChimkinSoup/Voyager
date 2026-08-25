// The stat popup is sized to its value: a number long enough to wrap widens
// the popup instead of breaking across two lines, while a "no data yet"
// sentence — which reads fine wrapped — leaves it at its resting width.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/life_tracker/blossom_stat_popup.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';
import 'package:voyager/features/life_tracker/life_tree_popover.dart';

class _FixedSettings extends SettingsNotifier {
  _FixedSettings(this.settings);

  final AppSettings settings;

  @override
  Future<AppSettings> build() async => settings;
}

Future<double> _popupWidth(WidgetTester tester, {DateTime? birthDate}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          () => _FixedSettings(AppSettings(birthDate: birthDate)),
        ),
        lifeTrackerStatsProvider.overrideWith(
          (ref) async =>
              const LifeTrackerCachedStats(tasksConquered: 0, lifetimeMood: 5),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showTreePopover(
                  context: context,
                  anchorGlobalCenter: const Offset(400, 300),
                  width: statPopupWidth,
                  maxWidth: statPopupMaxWidth,
                  builder: (_) => const BlossomStatPopup(
                    stat: LifeStat.kmTraveled,
                    accentColor: Colors.green,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // Let the overridden settings resolve before the popup reads them.
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  // The glass has to follow the content, or a widened popup overflows it.
  expect(
    tester.getSize(find.byType(GlassSurface)).width,
    tester.getSize(find.byType(BlossomStatPopup)).width,
  );
  return tester.getSize(find.byType(BlossomStatPopup)).width;
}

void main() {
  testWidgets('a long kilometre count widens the popup', (tester) async {
    final width = await _popupWidth(
      tester,
      birthDate: DateTime.utc(1998, 5, 20),
    );
    expect(width, greaterThan(statPopupWidth));
    expect(width, lessThanOrEqualTo(statPopupMaxWidth));
  });

  testWidgets('the "set your birth date" placeholder does not', (tester) async {
    expect(await _popupWidth(tester), statPopupWidth);
  });
}
