// Dark theme parity (DARK_THEME_AUDIT.md): the dark surfaces that sat over the
// animated triangle grid, and the chrome that ignored theme tokens.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/paper_texture.dart';
import 'package:voyager/core/widgets/surface_grain.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_flashcard.dart';
import 'package:voyager/features/settings/settings_page.dart';
import 'package:voyager/features/shell/shell_nav_theme.dart';
import 'package:voyager/features/study/study_grading_row.dart';

class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<AppSettings> getSettings() async => const AppSettings();

  @override
  Future<Map<String, int>> getTagColors() async => const {};

  @override
  Future<void> saveSettings(
    AppSettings settings, {
    bool recordLocalActivity = true,
  }) async {}

  @override
  noSuchMethod(Invocation invocation) => null;
}

class _ThemedSettings extends SettingsNotifier {
  _ThemedSettings(this.mode);

  final AppThemeMode mode;

  @override
  Future<AppSettings> build() async => AppSettings(themeMode: mode);
}

Future<BuildContext> _contextUnder(WidgetTester tester, ThemeData theme) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) {
          captured = context;
          return const SizedBox();
        },
      ),
    ),
  );
  return captured;
}

/// WCAG relative-contrast ratio between two opaque colours.
double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('sidebar rows and shell nav', () {
    testWidgets('dark rows are near-solid so the grid cannot show through', (
      tester,
    ) async {
      final context = await _contextUnder(tester, VoyagerTheme.dark());
      expect(
        VoyagerListItemSurface.restingColor(context).a,
        closeTo(0.85, 1e-3),
      );
      expect(
        VoyagerListItemSurface.selectedColor(context).a,
        closeTo(VoyagerListItemSurface.solidAlpha, 1e-3),
      );
      expect(
        VoyagerListItemSurface.hoverColor(context).a,
        closeTo(VoyagerListItemSurface.solidAlpha, 1e-3),
      );
      expect(
        shellNavSelectedFill(Theme.of(context)).a,
        closeTo(VoyagerListItemSurface.solidAlpha, 1e-3),
        reason: 'the rail and the lists share one dark fill policy',
      );
    });

    testWidgets('light rows keep their translucent tint', (tester) async {
      final context = await _contextUnder(tester, VoyagerTheme.light());
      expect(
        VoyagerListItemSurface.restingColor(context).a,
        closeTo(0.25, 1e-3),
      );
      expect(
        VoyagerListItemSurface.selectedColor(context).a,
        closeTo(0.65, 1e-3),
      );
      expect(VoyagerListItemSurface.hoverColor(context).a, closeTo(0.75, 1e-3));
    });
  });

  testWidgets('grade buttons label in Frappe crust on their plates, in dark', (
    tester,
  ) async {
    final theme = VoyagerTheme.dark();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: StudyGradingRow(
              interval: 1,
              ease: 2.5,
              enabled: true,
              snapDim: false,
              onGrade: (_) {},
            ),
          ),
        ),
      ),
    );

    // The plates are saturated Catppuccin Frappe accents, which are light
    // pastels -- bone ink would sit near 1.5:1 on Frappe green. The label is
    // Frappe crust, and every plate has to stay light enough to carry it.
    for (final label in ['Fail', 'Hard', 'Good', 'Easy']) {
      final button = tester.widget<GlassButton>(
        find.widgetWithText(GlassButton, label),
      );
      final text = tester.widget<Text>(
        find.descendant(
          of: find.widgetWithText(GlassButton, label),
          matching: find.text(label),
        ),
      );
      expect(
        text.style?.color?.toARGB32(),
        const Color(0xFF232634).toARGB32(),
        reason: label,
      );
      expect(
        _contrastRatio(button.color!, text.style!.color!),
        greaterThan(4.5),
        reason: label,
      );
    }
  });

  group('scrims', () {
    for (final (name, theme) in [
      ('dark', VoyagerTheme.dark()),
      ('light', VoyagerTheme.light()),
    ]) {
      testWidgets('showVoyagerDialog uses the $name theme scrim', (
        tester,
      ) async {
        final context = await _contextUnder(tester, theme);
        showVoyagerDialog<void>(
          context: context,
          builder: (_) => const SizedBox(width: 100, height: 100),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // The home route has a barrier too; the dialog's is the dismissible one.
        final barrier = tester.widget<ModalBarrier>(
          find.byWidgetPredicate((w) => w is ModalBarrier && w.dismissible),
        );
        expect(barrier.color, VoyagerColors.of(context).scrim);
      });
    }
  });

  testWidgets('dark flashcard is a paper plate, not a backdrop blur', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 9, 15);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            _StubSettingsRepository(),
          ),
        ],
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 800,
              child: LeetCodeFlashcard(
                problem: LeetCodeProblem(
                  id: 'p1',
                  createdAt: now,
                  updatedAt: now,
                  title: 'Two Sum',
                  difficulty: LeetCodeDifficulty.easy,
                  solvedAt: now,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(SurfaceGrain), findsWidgets);
    expect(find.byType(PaperTexture), findsNothing);
  });

  // Semantics off: SettingsPage mounted outside the shell hands the semantics
  // pass a nested viewport with a non-finite rect, on both themes and before
  // any of the appearance controls are touched.
  group('Settings appearance', () {
    Future<void> pumpSettings(WidgetTester tester, AppThemeMode mode) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(
              _StubSettingsRepository(),
            ),
            settingsProvider.overrideWith(() => _ThemedSettings(mode)),
            journalsProvider.overrideWith((ref) async => []),
            todoListStatsProvider.overrideWith((ref) async => {}),
          ],
          child: MaterialApp(
            theme: VoyagerTheme.forMode(mode),
            home: const Scaffold(body: SettingsPage()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets(
      'dark shows the geometric controls instead of petals',
      semanticsEnabled: false,
      (tester) async {
        await pumpSettings(tester, AppThemeMode.dark);

        expect(find.text('Grid intensity'), findsOneWidget);
        expect(find.text('Glow spread'), findsOneWidget);
        expect(find.text('Wave'), findsOneWidget);
        expect(find.text('Petal color'), findsNothing);
      },
    );

    testWidgets(
      'light shows petals and no geometric controls',
      semanticsEnabled: false,
      (tester) async {
        await pumpSettings(tester, AppThemeMode.light);

        expect(find.text('Petal color'), findsOneWidget);
        expect(find.text('Grid intensity'), findsNothing);
        expect(find.text('Wave'), findsNothing);
      },
    );

    testWidgets(
      'the wave switch drives the live wave params',
      semanticsEnabled: false,
      (tester) async {
        await pumpSettings(tester, AppThemeMode.dark);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(SettingsPage)),
        );
        final before = container.read(geometricWaveParamsProvider).enabled;

        final wave = find.widgetWithText(SwitchListTile, 'Wave');
        await tester.ensureVisible(wave);
        await tester.pump();
        await tester.tap(wave);
        await tester.pump();

        expect(container.read(geometricWaveParamsProvider).enabled, !before);
        // Let the debounced persist run before the scope is torn down.
        await tester.pump(const Duration(milliseconds: 300));
      },
    );
  });
}
