// The cheat sheet's behaviour as a route: where a tap on the scrim goes, what
// Android back pops, which mode it opens in, and whether the session
// underneath still hears the keyboard.
//
// The scrim test is the one worth having. The sheet opens over the fullscreen
// scratch editor, so two scrims are stacked and both want the tap — and a tap
// that dismisses the sheet must not also collapse the editor underneath.
// `LEETCODE_CHEAT_SHEET_HLD.md` §4.1 calls it the single most likely
// regression in the feature.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_cheat_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_providers.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_sheet.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_pad.dart';
import 'package:voyager/features/study/study_keyboard_shortcuts.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.utc(2026, 9, 20, 12);

final _problem = LeetCodeProblem(
  id: '1',
  createdAt: _now,
  updatedAt: _now,
  title: 'Two Sum',
  questionFrontendId: '1',
  difficulty: LeetCodeDifficulty.easy,
  tags: const ['hash-table'],
  solutions: const [LeetCodeSolution(algorithm: 'Hash map')],
  solvedAt: _now,
);

/// A container over an in-memory database seeded with one tab, one section and
/// one entry.
///
/// [sections] adds that many further sections of four entries each, for the
/// tests that need a document taller than the sheet.
Future<ProviderContainer> _seededContainer({
  bool seed = true,
  int sections = 0,
}) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftLeetCodeRepository(db);

  if (seed) {
    await repo.upsertCheatTab(
      LeetCodeCheatTab(
        id: 'tab-1',
        name: 'Java',
        languageKey: 'java',
        position: kCheatPositionStep,
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await repo.upsertCheatSection(
      LeetCodeCheatSection(
        id: 'section-1',
        tabId: 'tab-1',
        name: 'ArrayList',
        position: kCheatPositionStep,
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await repo.upsertCheatEntry(
      LeetCodeCheatEntry(
        id: 'entry-1',
        sectionId: 'section-1',
        command: '.add(e)',
        description: 'Appends to the back.',
        complexity: 'O(1) amortized',
        position: kCheatPositionStep,
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    for (var s = 1; s <= sections; s++) {
      await repo.upsertCheatSection(
        LeetCodeCheatSection(
          id: 'extra-section-$s',
          tabId: 'tab-1',
          name: 'Section $s',
          position: kCheatPositionStep * (s + 1),
          createdAt: _now,
          updatedAt: _now,
        ),
      );
      for (var e = 0; e < 4; e++) {
        await repo.upsertCheatEntry(
          LeetCodeCheatEntry(
            id: 'extra-entry-$s-$e',
            sectionId: 'extra-section-$s',
            command: '.method$s$e()',
            description: 'Does the $e thing in section $s.',
            position: kCheatPositionStep * (e + 1),
            createdAt: _now,
            updatedAt: _now,
          ),
        );
      }
    }
  }

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(leetCodeCheatSheetProvider.future);
  await container.read(settingsProvider.future);
  return container;
}

/// Pumps a page whose only control opens the cheat sheet.
Future<ProviderContainer> _pumpSheetHost(
  WidgetTester tester, {
  bool seed = true,
  int sections = 0,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = await _seededContainer(seed: seed, sections: sections);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => openLeetCodeCheatSheet(context, ref),
                child: const Text('open sheet'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('open sheet'));
  await tester.pumpAndSettle();
}

/// Where the sheet's content column is scrolled to.
///
/// The outermost scrollable above an entry, not the nearest: in Editing the
/// entry is a text field, and a field owns a [Scrollable] of its own that
/// never leaves offset zero. Nothing above the content column scrolls, so the
/// outermost one is the column in both modes.
double _contentOffset(WidgetTester tester) {
  final scrollable = find
      .ancestor(
        of: find.textContaining('.method'),
        matching: find.byType(Scrollable),
      )
      .last;
  return tester.state<ScrollableState>(scrollable).position.pixels;
}

/// Taps the scrim — the visible margin the sheet deliberately stops short of.
Future<void> _tapScrim(WidgetTester tester) async {
  await tester.tapAt(const Offset(4, 4));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  group('dismiss policy', () {
    testWidgets('a scrim tap closes it from Viewing', (tester) async {
      await _pumpSheetHost(tester);
      await _openSheet(tester);
      expect(find.text('ArrayList'), findsWidgets);

      await _tapScrim(tester);
      expect(find.text('ArrayList'), findsNothing);
    });

    testWidgets('a scrim tap is ignored while Editing', (tester) async {
      final container = await _pumpSheetHost(tester);
      await _openSheet(tester);

      await tester.tap(find.widgetWithText(Tooltip, 'Edit').first);
      await tester.pumpAndSettle();

      await _tapScrim(tester);
      // Still up: a stray click mid-sentence must not take the sheet away.
      expect(container.read(leetCodeCheatSheetOpenProvider), isTrue);
      expect(find.text('Add section'), findsOneWidget);
    });

    testWidgets('the ✕ closes it', (tester) async {
      final container = await _pumpSheetHost(tester);
      await _openSheet(tester);

      await tester.tap(find.byTooltip('Close the cheat sheet'));
      await tester.pumpAndSettle();
      expect(container.read(leetCodeCheatSheetOpenProvider), isFalse);
    });
  });

  group('mode', () {
    testWidgets('it opens in Viewing after having been closed from Editing', (
      tester,
    ) async {
      await _pumpSheetHost(tester);
      await _openSheet(tester);

      await tester.tap(find.widgetWithText(Tooltip, 'Edit').first);
      await tester.pumpAndSettle();
      expect(find.text('Add section'), findsOneWidget);

      await tester.tap(find.byTooltip('Close the cheat sheet'));
      await tester.pumpAndSettle();

      await _openSheet(tester);
      // Viewing every single time, whatever mode it was closed from.
      expect(find.text('Add section'), findsNothing);
      expect(find.widgetWithText(Tooltip, 'Edit'), findsWidgets);
    });
  });

  group('over the fullscreen scratch editor', () {
    /// Opens the scratch editor, then the cheat sheet on top of it.
    Future<ProviderContainer> pumpStacked(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = await _seededContainer();
      final controller = LeetCodeCodeController(text: 'print(1)');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: Consumer(
                  builder: (context, ref, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => openLeetCodeScratchOverlay(
                          context,
                          problem: _problem,
                          controller: controller,
                          anchorRect: const Rect.fromLTWH(0, 0, 200, 200),
                          language: 'python',
                          onCodeChanged: (_) {},
                          onLanguageChanged: (_) {},
                          onClear: () {},
                        ),
                        child: const Text('open editor'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('open editor'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Copy what you typed'), findsOneWidget);

      // The editor's own toolbar carries the entry point.
      await tester.tap(find.byTooltip('Cheat sheet  (Ctrl+Shift+C)'));
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('a scrim tap closes the sheet and leaves the editor open', (
      tester,
    ) async {
      final container = await pumpStacked(tester);
      expect(container.read(leetCodeCheatSheetOpenProvider), isTrue);

      await _tapScrim(tester);

      expect(container.read(leetCodeCheatSheetOpenProvider), isFalse);
      // The editor underneath never saw the tap.
      expect(find.byTooltip('Copy what you typed'), findsOneWidget);
    });

    testWidgets('Android back pops the sheet only', (tester) async {
      final container = await pumpStacked(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(container.read(leetCodeCheatSheetOpenProvider), isFalse);
      expect(find.byTooltip('Copy what you typed'), findsOneWidget);
    });
  });

  group('session suppression', () {
    testWidgets('space does not flip and grade keys do not grade', (
      tester,
    ) async {
      final container = await _seededContainer();
      var flips = 0;
      var grades = 0;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => StudyKeyboardShortcuts(
                onSpace: () => flips++,
                showingBack: true,
                onGrade: (_) => grades++,
                suppressed: ref.watch(leetCodeCheatSheetOpenProvider),
                child: Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () => openLeetCodeCheatSheet(context, ref),
                      child: const Text('open sheet'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The keys work while the session is the thing on screen.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(flips, 1);

      await _openSheet(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      expect(flips, 1, reason: 'space must not reach the card');
      expect(grades, 0, reason: 'grade keys must not reach the card');

      // And come back once the sheet goes away.
      await tester.tap(find.byTooltip('Close the cheat sheet'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(flips, 2);
    });
  });

  group('the empty sheet', () {
    testWidgets('points at the Edit toggle rather than seeding content', (
      tester,
    ) async {
      await _pumpSheetHost(tester, seed: false);
      await _openSheet(tester);

      expect(find.textContaining('Press Edit'), findsOneWidget);
      expect(find.text('No tabs yet'), findsOneWidget);
    });
  });

  group('copy on click', () {
    testWidgets('clicking a command copies it verbatim and toasts', (
      tester,
    ) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await _pumpSheetHost(tester);
      await _openSheet(tester);

      await tester.tap(find.textContaining('.add(e)').first);
      // The row carries both onTap (copy) and onDoubleTap (edit), so the
      // single tap is held back until the double-tap window closes.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(copied, ['.add(e)']);
      expect(find.textContaining('Copied'), findsOneWidget);
    });
  });

  group('export', () {
    testWidgets('Copy everything puts the sheet on the clipboard', (
      tester,
    ) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await _pumpSheetHost(tester);
      await _openSheet(tester);

      await tester.tap(find.byTooltip('Copy as markdown'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy everything'));
      await tester.pumpAndSettle();

      expect(copied, hasLength(1));
      expect(copied.single, contains('# Java'));
      expect(copied.single, contains('## ArrayList'));
      expect(copied.single, contains('### `.add(e)` — O(1) amortized'));
    });

    testWidgets('an empty sheet copies nothing and says so', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await _pumpSheetHost(tester, seed: false);
      await _openSheet(tester);

      await tester.tap(find.byTooltip('Copy as markdown'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy everything'));
      await tester.pump();
      await tester.pump();

      expect(copied, isEmpty);
      expect(find.text('Nothing to export'), findsOneWidget);
    });
  });

  group('search', () {
    testWidgets('filters across tabs and is cleared by entering Editing', (
      tester,
    ) async {
      await _pumpSheetHost(tester);
      await _openSheet(tester);

      await tester.enterText(find.byType(TextField).first, 'nothingmatches');
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing matches'), findsOneWidget);

      await tester.tap(find.widgetWithText(Tooltip, 'Edit').first);
      await tester.pumpAndSettle();

      // Entering Editing clears the filter: the editable document is the whole
      // tab, not a slice of it.
      expect(find.textContaining('Nothing matches'), findsNothing);
      expect(find.text('Add section'), findsOneWidget);
    });
  });

  // The rail is drawn in both modes, because dropping it on the mode toggle
  // would re-flow the content column out from under the reader — the one
  // thing §4.4 set out to avoid. Drawn means working: a rail that is on
  // screen and takes a click has to move the document, and in Editing it
  // silently did nothing, because the per-section keys it scrolls to were
  // attached by the Viewing body alone.
  group('the outline rail', () {
    for (final editing in [false, true]) {
      testWidgets('jumps to a section in ${editing ? 'Editing' : 'Viewing'}', (
        tester,
      ) async {
        await _pumpSheetHost(tester, sections: 12);
        await _openSheet(tester);
        if (editing) {
          await tester.tap(find.widgetWithText(Tooltip, 'Edit').first);
          await tester.pumpAndSettle();
        }

        // A section in the middle, so landing on it is distinguishable from
        // running to either end of the list.
        final rail = find.widgetWithText(TextButton, 'Section 6');
        expect(rail, findsOneWidget);
        expect(_contentOffset(tester), 0);

        await tester.tap(rail);
        await tester.pumpAndSettle();

        // Not "the list moved" — the section the rail points at has to be on
        // screen, which is the part that was silently missing in Editing.
        // Viewing lays the whole document out, so being *built* proves
        // nothing there; being inside the window does, in both modes.
        final landed = find.text('.method60()');
        expect(landed, findsWidgets);
        final rect = tester.getRect(landed.first);
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(900));
      });
    }
  });

  // [GlassButton] has no intrinsic-width guard, so an Align stretched this one
  // across the whole content column — a footer bar rather than the sibling of
  // "Add entry" it is meant to read as.
  testWidgets('Add section hugs its label rather than filling the column', (
    tester,
  ) async {
    await _pumpSheetHost(tester);
    await _openSheet(tester);
    await tester.tap(find.widgetWithText(Tooltip, 'Edit').first);
    await tester.pumpAndSettle();

    final button = tester.getSize(
      find.widgetWithText(GlassButton, 'Add section'),
    );
    final column = tester.getSize(find.byType(ReorderableListView).first);
    expect(button.width, lessThan(column.width / 2));

    // Closed before the container goes, so the route's flush-on-dispose still
    // has providers to read.
    await tester.tap(find.byTooltip('Close the cheat sheet'));
    await tester.pumpAndSettle();
  });

  // The editor's toolbar now carries a seventh labelled button, and six
  // labelled buttons already ask for more width than the app's smallest
  // allowed window leaves once the title has ellipsised to nothing. The group
  // scales down; an overflow would fail this test on the stripe it paints.
  testWidgets('the scratch toolbar fits the smallest allowed window', (
    tester,
  ) async {
    tester.view.physicalSize = kMainWindowMinimumSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = await _seededContainer();
    final controller = LeetCodeCodeController(text: 'print(1)');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => openLeetCodeScratchOverlay(
                  context,
                  problem: _problem,
                  controller: controller,
                  anchorRect: const Rect.fromLTWH(0, 0, 200, 200),
                  language: 'python',
                  onCodeChanged: (_) {},
                  onLanguageChanged: (_) {},
                  onClear: () {},
                ),
                child: const Text('open editor'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open editor'));
    await tester.pumpAndSettle();

    // Scaled down, but still the labelled button the other six are.
    expect(find.text('Cheat sheet'), findsOneWidget);
    expect(find.text('Compare'), findsOneWidget);
  });
}
