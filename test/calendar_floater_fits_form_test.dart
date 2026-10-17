// The calendar floater's window is sized to the panel: a new all-day event,
// no validation line, with nothing left over, or it opens above a band of dead
// background. Measured in the real theme and faces, which is what the panel is
// actually laid out in.
//
// The empty-title line is not reserved: the panel, which does not scroll,
// reports its height and the window grows by that. The pickers the panel
// opens have to come up whole inside the window too.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/report_height.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/features/calendar/calendar_event_panel.dart';
import 'package:voyager/features/hotkeys/floaters/floater_app_icon.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';

import 'fakes/fake_weather_api_client.dart';
import 'narrow_window_harness.dart';

/// The panel's bottom padding, below the Save button.
const _bottomPadding = 14.0;

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  // The panel's height, as the floater would be told it.
  var reportedHeight = 0.0;

  Future<void> pumpFloater(WidgetTester tester) async {
    reportedHeight = 0;
    await loadRealFonts(tester);
    tester.view.physicalSize = kCalendarFloaterSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: Scaffold(
            body: VoyagerScrollView(
              child: ReportHeight(
                onHeight: (h) => reportedHeight = h,
                child: CalendarEventPanel(
                  initialDate: DateTime(2026, 10, 16),
                  calendars: const [],
                  initialCalendarId: legacyCalendarId,
                  focusTitleOnOpen: true,
                  onSave: (_) {},
                  onCancel: () {},
                  leading: const FloaterAppIcon(
                    VoyagerIcons.calendar,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  /// The floater's window, which a picker has to stay inside of.
  final window = Offset.zero & kCalendarFloaterSize;

  void expectInsideWindow(WidgetTester tester, Finder finder, String what) {
    final rect = tester.getRect(finder);
    expect(rect.left, greaterThanOrEqualTo(0.0), reason: '$what off the left');
    expect(rect.top, greaterThanOrEqualTo(0.0), reason: '$what off the top');
    expect(
      rect.right,
      lessThanOrEqualTo(window.right),
      reason: '$what off the right',
    );
    expect(
      rect.bottom,
      lessThanOrEqualTo(window.bottom),
      reason: '$what off the bottom',
    );
  }

  testWidgets(
    'the calendar floater fits the new-event panel',
    (tester) async {
      await pumpFloater(tester);

      double formHeight() =>
          tester.getRect(find.widgetWithText(GlassButton, 'Save')).bottom +
          _bottomPadding;

      // The window opens at the default panel's height, to the pixel, and
      // what the panel reports is the whole of it.
      expect(formHeight(), lessThanOrEqualTo(kCalendarFloaterSize.height));
      expect(kCalendarFloaterSize.height - formHeight(), lessThan(1.0));
      expect(reportedHeight, closeTo(formHeight(), 0.01));
      final opened = reportedHeight;

      // Save with an empty title puts the validation line under the title,
      // and the reported height grows to take it in.
      await tester.tap(find.widgetWithText(GlassButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Title cannot be empty'), findsOneWidget);
      expect(reportedHeight, greaterThan(opened));
      expect(reportedHeight, closeTo(formHeight(), 0.01));

      // Typing clears the line, and the height goes back.
      await tester.enterText(find.byType(EditableText).first, 'Lunch');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Title cannot be empty'), findsNothing);
      expect(reportedHeight, opened);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    "the date picker opens whole inside the floater's window",
    (tester) async {
      await pumpFloater(tester);

      await tester.tap(find.text('Fri, Oct 16'));
      await tester.pumpAndSettle();

      expectInsideWindow(
        tester,
        find.byType(ContextualPopover),
        'the date picker',
      );
      expectInsideWindow(tester, find.text('Today'), 'the quick-pick row');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    "the time picker opens whole inside the floater's window",
    (tester) async {
      await pumpFloater(tester);

      // All day is the default; switching it off brings out the time pill.
      await tester.tap(find.byTooltip('All day (on)'));
      await tester.pump();
      await tester.tap(find.text('12:00 PM'));
      await tester.pumpAndSettle();

      expectInsideWindow(
        tester,
        find.byType(ContextualPopover),
        'the time picker',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
