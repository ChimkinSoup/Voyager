// In Light, a text button's elevation cast a mid-grey pill under its
// transparent fill, with the raw accent as text on it (1.2:1), and the due
// sticky's Acknowledge was the same faint wafer as the snoozes (BUG-042).

import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/reminders/reminder_engine.dart';
import 'package:voyager/core/reminders/reminder_os_notifier.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/features/notifications/reminder_sticky_stack.dart';

class _DueEngine extends ReminderEngine {
  _DueEngine(AppDatabase db)
    : super(
        repository: DriftReminderRepository(db),
        os: NoopReminderOsNotifier(),
        deviceId: 'device',
        onStatesWritten: () {},
        onRulesWritten: () {},
        onLogWritten: (_) {},
      );

  @override
  List<ReminderSourceView> get due => const [
    ReminderSourceView(
      sourceKey: 'rule:due',
      sourceKind: ReminderSourceKind.scheduledRule,
      sourceId: 'due',
      title: 'due',
      evaluation: null,
      targetsThisDevice: true,
    ),
  ];
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
}

/// The pixel at [offset] (global, logical = physical here) of what [key]
/// paints.
Future<Color> _pixel(WidgetTester tester, GlobalKey key, Offset offset) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final origin = boundary.localToGlobal(Offset.zero);
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final x = (offset.dx - origin.dx).round();
    final y = (offset.dy - origin.dy).round();
    final i = (y * image.width + x) * 4;
    return Color.fromARGB(
      255,
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }))!;
}

/// Tests draw shadows as outlines unless told otherwise, and the pill is one.
/// The flag has to be back before the test ends, which is before tear-downs.
Future<void> _withShadows(Future<void> Function() body) async {
  debugDisableShadows = false;
  try {
    await body();
  } finally {
    debugDisableShadows = true;
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  for (final accent in const [
    Color(0xFF7C9EFF),
    Color(0xFFFFD166),
    Color(0xFF2B6E3F),
  ]) {
    final hex = accent.toARGB32().toRadixString(16).substring(2);
    testWidgets(
      'a light text button has no pill and legible text (#$hex)',
      (tester) => _withShadows(() async {
        final theme = VoyagerTheme.forMode(AppThemeMode.light, accent: accent);
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Center(
                child: RepaintBoundary(
                  key: key,
                  child: ColoredBox(
                    color: theme.colorScheme.surface,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: TextButton(
                        onPressed: () {},
                        child: const Text('Show 23 more'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        final button = tester.getRect(find.byType(TextButton));
        // Inside the button, left of its label.
        final inside = await _pixel(
          tester,
          key,
          Offset(button.left + 4, button.center.dy),
        );
        expect(inside, theme.colorScheme.surface);

        final label = tester
            .widget<RichText>(
              find.descendant(
                of: find.byType(TextButton),
                matching: find.byType(RichText),
              ),
            )
            .text
            .style!
            .color!;
        expect(
          _contrast(label, VoyagerPalette.light.scaffold),
          greaterThanOrEqualTo(4.5),
        );
      }),
    );
  }

  testWidgets(
    'a light sticky fills Acknowledge, not the snoozes',
    (tester) => _withShadows(() async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final theme = VoyagerTheme.forMode(AppThemeMode.light);
      final key = GlobalKey();

      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              syncRepositoryProvider.overrideWithValue(
                InMemorySyncRepository(),
              ),
              reminderEngineProvider.overrideWith((ref) => _DueEngine(db)),
            ],
            child: MaterialApp(
              theme: theme,
              builder: (context, child) =>
                  Stack(children: [child!, const ReminderStickyStack()]),
              home: const Scaffold(body: Text('page')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<Color> fillOf(String label) {
        final rect = tester.getRect(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(GlassButton),
          ),
        );
        return _pixel(tester, key, Offset(rect.left + 4, rect.bottom - 4));
      }

      final accent = theme.colorScheme.primary;
      final acknowledge = await fillOf('Acknowledge');
      final snooze = await fillOf('Tomorrow');
      // Near-solid accent, as in dark; the snooze stays a faint wafer.
      expect(_contrast(acknowledge, accent), lessThan(1.1));
      expect(_contrast(snooze, accent), greaterThan(1.5));
      final label = tester
          .widget<RichText>(
            find.descendant(
              of: find.text('Acknowledge'),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style!
          .color!;
      expect(_contrast(label, acknowledge), greaterThanOrEqualTo(4.5));
    }),
  );
}
