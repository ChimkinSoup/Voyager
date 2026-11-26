import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/snippet_editor.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/features/settings/snippets_dialog.dart';
import 'package:voyager/features/shell/shell_bottom_nav.dart';
import 'package:voyager/features/shell/shell_destinations.dart';
import 'package:voyager/features/shell/weather_forecast_sheet.dart';

/// Touch and phone-size fixes from the mobile audit (M2/M3), on the test
/// binding's default platform, Android, at the OnePlus 12R's 361×794 dp.
void main() {
  void phoneSize(WidgetTester tester, {Size size = const Size(361, 794)}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('BUG-395: a long press opens a right-click menu', () {
    late List<String> picked;

    Widget region({bool reorderable = false}) {
      final items = [
        ContextMenuItem(label: 'Star', onTap: () => picked.add('star')),
        ContextMenuItem(
          label: 'Move task to',
          children: [
            ContextMenuItem(label: 'Work', onTap: () => picked.add('work')),
          ],
        ),
        ContextMenuItem(
          label: 'Delete task',
          isDestructive: true,
          onTap: () => picked.add('delete'),
        ),
      ];
      const row = SizedBox(
        key: Key('row'),
        width: 300,
        height: 48,
        child: Text('a task'),
      );
      return MaterialApp(
        home: Scaffold(
          body: reorderable
              ? ReorderableListView(
                  buildDefaultDragHandles: false,
                  onReorderItem: (_, _) {},
                  children: [
                    ReorderableDelayedDragStartListener(
                      key: const ValueKey('r'),
                      index: 0,
                      child: ContextMenuRegion(items: items, child: row),
                    ),
                  ],
                )
              : Center(
                  child: ContextMenuRegion(items: items, child: row),
                ),
        ),
      );
    }

    setUp(() => picked = []);

    testWidgets('by touch, and its items act', (tester) async {
      await tester.pumpWidget(region());
      await tester.longPress(find.byKey(const Key('row')));
      await tester.pumpAndSettle();
      expect(find.text('Delete task'), findsOneWidget);
      await tester.tap(find.text('Delete task'));
      await tester.pumpAndSettle();
      expect(picked, ['delete']);
      expect(find.text('Delete task'), findsNothing);
    });

    testWidgets('a submenu opens on a tap, there being no hover', (
      tester,
    ) async {
      await tester.pumpWidget(region());
      await tester.longPress(find.byKey(const Key('row')));
      await tester.pumpAndSettle();
      expect(find.text('Work'), findsNothing);
      await tester.tap(find.text('Move task to'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      expect(picked, ['work']);
    });

    testWidgets('not by a mouse held down', (tester) async {
      await tester.pumpWidget(region());
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('row'))),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Delete task'), findsNothing);
    });

    testWidgets('not where a long press lifts the row to reorder it', (
      tester,
    ) async {
      await tester.pumpWidget(region(reorderable: true));
      await tester.longPress(find.byKey(const Key('row')));
      await tester.pumpAndSettle();
      expect(find.text('Delete task'), findsNothing);
    });
  });

  testWidgets('BUG-396: on Android the forecast is a sheet that fits 361 dp', (
    tester,
  ) async {
    phoneSize(tester);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final forecast = WeatherForecast(
      fetchedAt: now,
      locationLabel: 'Chicago, US',
      periods: [
        for (var h = 0; h < 5 * 24; h += 3)
          ForecastPeriod(
            time: today.add(Duration(hours: h)),
            tempC: 10 + (h % 24) / 3,
            pop: h.isEven ? 1.0 : 0.0,
            icon: 'cloudy',
            conditionCode: 803,
            description: 'clouds',
          ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          weatherForecastProvider.overrideWith((ref) async => forecast),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showWeatherForecastSheet(context),
                child: const Text('weather'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('weather'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(VoyagerSheetHandle), findsOneWidget);
    expect(find.text('Chicago, US'), findsOneWidget);
    // No overflow, in the day cards or anywhere else.
    expect(tester.takeException(), isNull);

    await tester.fling(find.text('Chicago, US'), const Offset(0, 500), 2000);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('BUG-397: the bottom bar fits its labels at font scale 2.0', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(361, 794),
            textScaler: TextScaler.linear(2.0),
          ),
          child: Scaffold(
            bottomNavigationBar: ShellBottomNav(
              selectedIndex: 0,
              accent: Colors.blue,
              onDestinationSelected: (_) {},
              orderedDestinations: getVisibleDestinations(const AppSettings()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('BUG-402: the Text snippets dialog on a phone', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.inMemory());
    tearDown(() => db.close());

    Future<void> openAdd(
      WidgetTester tester, {
      double keyboard = 0,
      double textScale = 1,
    }) async {
      phoneSize(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                viewInsets: EdgeInsets.only(bottom: keyboard),
                textScaler: TextScaler.linear(textScale),
              ),
              child: child!,
            ),
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(settingsProvider);
                return Scaffold(
                  body: TextButton(
                    onPressed: () => showSnippetsDialog(context),
                    child: const Text('open'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add snippet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add snippet'));
      await tester.pumpAndSettle();
    }

    testWidgets('the add row reads on one line per label', (tester) async {
      await openAdd(tester);
      expect(tester.takeException(), isNull);
      // A label squeezed to a letter a line is many lines tall.
      // Squeezed, each label was a column one letter wide.
      for (final label in ['Expand automatically', 'Only at word boundaries']) {
        expect(tester.getSize(find.text(label)).width, greaterThan(150));
      }
      // Replacement, the editor's second box, was ~3 characters wide.
      final replacement = find
          .descendant(
            of: find.byType(SnippetEditor),
            matching: find.byType(EditableText),
          )
          .at(1);
      expect(tester.getSize(replacement).width, greaterThan(200));
    });

    testWidgets('with the keyboard up it scrolls instead of overflowing', (
      tester,
    ) async {
      await openAdd(tester, keyboard: 330);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byTooltip('Save snippet'),
        100,
        scrollable: find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.byTooltip('Save snippet').hitTestable(), findsOneWidget);
    });

    testWidgets('at font scale 2.0 it scrolls instead of overflowing', (
      tester,
    ) async {
      await openAdd(tester, textScale: 2);
      expect(tester.takeException(), isNull);
    });
  });
}
