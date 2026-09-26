// Every page has to fit the smallest window the desktop build allows.
//
// desktop_window.dart sets a 720x520 minimum. The shell's rail, its padding
// and the divider beside it take 96px, so a page is handed 624x520 at the
// smallest. A RenderFlex that cannot fit reports an overflow through
// FlutterError, so each page is pumped at that size (and a few wider ones,
// since a breakpoint can leave a gap above the floor), every view switch on
// it is pressed, and every overflow is collected rather than only the first.
// See narrow_window_harness.dart for sweeping real data.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';
import 'package:voyager/features/shell/shell_destinations.dart';

import 'narrow_window_harness.dart';

/// From the page area inside a 720px window — 720 minus the rail column
/// (8 + 72 + 4) and the 12px divider — up to a comfortable desktop width.
const _pageWidths = <double>[624, 760, 900, 980, 1100];

/// Long enough to wrap, so the row beside a side panel is at its tallest.
const _probeTitle = 'Overflow probe with a title long enough to wrap its row';

/// A row written into the pages that open a right-hand edit panel beside
/// their list, so the sweep can open it. At the minimum width the host
/// overlays rather than crushing the list under a 420px push.
final _panelSeeds = <String, Future<void> Function(AppDatabase db)>{
  '/todo': (db) async {
    final now = utcNow();
    final repo = DriftTodoRepository(db);
    await repo.upsertList(
      TodoListModel(
        id: 'overflow-probe',
        name: 'Overflow probe',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repo.upsertTask(
      TodoTask(
        id: newId(),
        listId: 'overflow-probe',
        title: _probeTitle,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final settings = DriftSettingsRepository(db);
    await settings.saveSettings(
      (await settings.getSettings()).copyWith(
        lastViewedTodoListId: 'overflow-probe',
        todoShowAllTasks: false,
      ),
    );
  },
  '/jobs': (db) async {
    final now = utcNow();
    final repo = DriftJobRepository(db);
    await repo.ensureSeeded();
    await repo.upsertApplication(
      JobApplication(
        id: newId(),
        company: _probeTitle,
        title: 'Senior Staff Software Engineer, Platform Infrastructure',
        status: 'Applied',
        dateApplied: DateTime(2026, 9, 30),
        createdAt: now,
        updatedAt: now,
      ),
    );
  },
  '/rankings': (db) async {
    final now = utcNow();
    final repo = DriftRankingRepository(db);
    await repo.upsertCategory(
      RankingCategory(
        id: 'overflow-probe',
        name: 'Overflow probe',
        colorValue: 0xFF7C9EFF,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repo.upsertParent(
      RankingParent(
        id: newId(),
        categoryId: 'overflow-probe',
        title: _probeTitle,
        createdAt: now,
        updatedAt: now,
      ),
    );
  },
};

/// Controls that open a dialog built privately inside the page, which
/// narrow_window_modal_overflow_test.dart cannot reach through a public show
/// function. Each is opened and closed in turn.
const _dialogTaps = <String, List<String>>{
  '/analytics': ['New tracker'],
  '/settings': [
    'App accent color',
    'Birth date',
    'Job application profile',
    'LeetCode username',
    'Navigation pages',
    'Startup page',
  ],
};

/// Pumps [page] into a [size] surface, visits its views, side panels and
/// in-page dialogs, and returns every overflow reported on the way.
Future<Set<String>> _overflowsFor(
  WidgetTester tester,
  ShellDestination destination,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  final seed = _panelSeeds[destination.path];
  final (db, container) = await openHarnessContainer(seed: seed);
  if (destination.path == '/rankings') {
    container.read(rankingSelectedCategoryProvider.notifier).state =
        'overflow-probe';
  }
  final page = destination.page;
  try {
    return await collectOverflows(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: VoyagerTheme.forMode(AppThemeMode.dark),
            home: Scaffold(backgroundColor: Colors.transparent, body: page),
          ),
        ),
      );
      await settle(tester);
      await visitSegments(tester);
      // Calendar's view switch is its own control, not a SegmentedButton,
      // and its editor opens as a sidebar.
      if (destination.path == '/calendar') {
        for (final mode in const ['Week', 'Year', 'Month']) {
          await tester.tap(find.text(mode).first, warnIfMissed: false);
          await settle(tester);
        }
        await tester.tap(find.text('Add event'));
        await settle(tester);
      }
      if (seed != null) {
        await tester.tap(find.text(_probeTitle).first);
        await settle(tester);
        expect(
          find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString().endsWith('EditPanel'),
          ),
          findsOneWidget,
          reason: 'tapping the probe row opens its edit panel',
        );
      }
      for (final label in _dialogTaps[destination.path] ?? const <String>[]) {
        // Lists build lazily, so scroll the page until the control exists.
        //
        // Driven through the scroll position rather than `scrollUntilVisible`:
        // that drags from the centre of the list, which lands on whatever
        // happens to be laid out there, and a text field under that point
        // swallows the whole gesture and scrolls nothing. Which control sits
        // at the centre shifts with any copy change on the page, so the drag
        // is left out of it entirely.
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        while (find.text(label).evaluate().isEmpty &&
            position.pixels < position.maxScrollExtent) {
          position.jumpTo(
            (position.pixels + 200).clamp(0.0, position.maxScrollExtent),
          );
          await settle(tester);
        }
        await tester.ensureVisible(find.text(label).first);
        await settle(tester);
        final control = find.text(label).first;
        await tester.tap(control);
        await settle(tester);
        final navigator = Navigator.of(
          tester.element(find.byType(Scaffold).first),
          rootNavigator: true,
        );
        expect(navigator.canPop(), isTrue, reason: '"$label" opens a dialog');
        navigator.popUntil((route) => route.isFirst);
        await settle(tester);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  } finally {
    container.dispose();
    await db.close();
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  for (final destination in shellDestinations) {
    testWidgets(
      '${destination.label} fits every width down to the minimum window',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      // Layout only. The semantics pass trips its own assertions on some
      // pages here (a zero-size twoPane viewport), which is not what this
      // file is testing.
      semanticsEnabled: false,
      (tester) async {
        addTearDown(tester.view.reset);
        await loadRealFonts(tester);

        final found = <String>[];
        for (final width in _pageWidths) {
          final size = Size(width, minWindowSize.height);
          for (final overflow in await _overflowsFor(
            tester,
            destination,
            size,
          )) {
            found.add('${width.toInt()}px: $overflow');
          }
        }
        expect(found, isEmpty);
      },
    );
  }
}
