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
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_cheat_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_actions.dart';
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
///
/// [variedRows] adds three more entries to the first section, covering every
/// combination the three-column layout has to hold: labelled and badged,
/// labelled and bare, and badged with no label.
///
/// [blockRow] adds one entry whose command is three lines, costed on the
/// first and last only — the middle line is what proves a blank line in the
/// field leaves that line bare instead of sliding the rest up.
Future<ProviderContainer> _seededContainer({
  bool seed = true,
  int sections = 0,
  bool variedRows = false,
  bool blockRow = false,
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
    if (variedRows) {
      const varied = [
        (id: 'labelled-badged', label: 'Append', complexity: 'O(1)'),
        (id: 'labelled-bare', label: 'Size', complexity: null),
        (id: 'bare-badged', label: null, complexity: 'O(n log n)'),
      ];
      for (final (index, row) in varied.indexed) {
        await repo.upsertCheatEntry(
          LeetCodeCheatEntry(
            id: row.id,
            sectionId: 'section-1',
            command: '.${row.id}()',
            label: row.label,
            complexity: row.complexity,
            position: kCheatPositionStep * (index + 2),
            createdAt: _now,
            updatedAt: _now,
          ),
        );
      }
    }
    if (blockRow) {
      await repo.upsertCheatEntry(
        LeetCodeCheatEntry(
          id: 'block-1',
          sectionId: 'section-1',
          command: 'outer();\n  middle();\n  inner();',
          label: 'Nested scan',
          description: 'Two passes, one of them nested.',
          complexity: 'O(n)\n\nO(n²)',
          position: kCheatPositionStep * 10,
          createdAt: _now,
          updatedAt: _now,
        ),
      );
    }
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
  bool variedRows = false,
  bool blockRow = false,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = await _seededContainer(
    seed: seed,
    sections: sections,
    variedRows: variedRows,
    blockRow: blockRow,
  );

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

/// Drags [handle] by [dy], in the steps a reorderable list needs to see the
/// pointer cross its neighbours.
Future<void> _dragBy(WidgetTester tester, Finder handle, double dy) async {
  final step = dy.isNegative ? -20.0 : 20.0;
  final gesture = await tester.startGesture(tester.getCenter(handle));
  await tester.pump(const Duration(milliseconds: 20));
  for (var moved = 0.0; moved.abs() < dy.abs(); moved += step) {
    await gesture.moveBy(Offset(0, step));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

List<String> _sectionNames(ProviderContainer container) => [
  for (final section
      in container
          .read(leetCodeCheatSheetProvider)
          .requireValue
          .sectionsOf('tab-1'))
    section.name,
];

/// The commands of the only seeded multi-entry section, in order.
List<String> _entryCommands(ProviderContainer container) => [
  for (final entry
      in container
          .read(leetCodeCheatSheetProvider)
          .requireValue
          .entriesOf('extra-section-1'))
    entry.command,
];

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

    // The label's *rendered* colour, not the declared one: its own
    // [TextStyle] merges over the [DefaultTextStyle] the button wraps it in,
    // so a `foregroundColor` on the button alone loses to the body colour
    // `bodySmall` already carries.
    testWidgets('sits on the accent and is labelled against it', (
      tester,
    ) async {
      await _pumpSheetHost(tester, sections: 3);
      await _openSheet(tester);

      final rail = find.widgetWithText(TextButton, 'Section 2');
      final scheme = Theme.of(tester.element(rail)).colorScheme;
      final states = <WidgetState>{};

      final style = tester.widget<TextButton>(rail).style!;
      expect(style.backgroundColor?.resolve(states), scheme.primary);

      final label = tester.widget<RichText>(
        find.descendant(of: rail, matching: find.byType(RichText)),
      );
      expect(label.text.style?.color, scheme.onPrimary);
    });
  });

  group('reorder handles', () {
    // Desktop only: that is where the framework draws its default handle as
    // an icon. On the test's default platform it wraps the whole item in a
    // long-press listener instead, and the stray icon would never appear.
    final windows = TargetPlatformVariant.only(TargetPlatform.windows);

    // Editing used the framework's desktop default, which floats a handle over
    // the centre-right of each item. On a section four entries tall that lands
    // in the middle of somebody's description, and on an entry it lands on top
    // of the delete button. Both lists build their own instead.
    testWidgets('no handle floats loose over the rows', (tester) async {
      await _pumpSheetHost(tester, sections: 2);
      await _openSheet(tester);
      await tester.tap(find.widgetWithText(Tooltip, 'Edit').first);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.drag_handle), findsNothing);
      expect(find.byTooltip('Drag to reorder this entry'), findsWidgets);

      await tester.tap(find.byTooltip('Close the cheat sheet'));
      await tester.pumpAndSettle();
    }, variant: windows);

    // Sections move from the rail, not the body: a section's drag proxy is
    // every entry under it, which is taller than the sheet.
    testWidgets('the rail offers grips only while Editing', (tester) async {
      await _pumpSheetHost(tester, sections: 2);
      await _openSheet(tester);
      expect(find.byTooltip('Drag to reorder this section'), findsNothing);

      await tester.tap(find.widgetWithText(Tooltip, 'Edit').first);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Drag to reorder this section'), findsNWidgets(3));

      await tester.tap(find.byTooltip('Close the cheat sheet'));
      await tester.pumpAndSettle();
    }, variant: windows);

    testWidgets('a rail grip moves the section', (tester) async {
      final container = await _pumpSheetHost(tester, sections: 2);
      await _openSheet(tester);
      await tester.tap(find.widgetWithText(Tooltip, 'Edit').first);
      await tester.pumpAndSettle();

      expect(_sectionNames(container), ['ArrayList', 'Section 1', 'Section 2']);

      final grips = find.byTooltip('Drag to reorder this section');
      final span =
          tester.getCenter(grips.at(1)).dy - tester.getCenter(grips.first).dy;
      await _dragBy(tester, grips.first, span);

      expect(_sectionNames(container), ['Section 1', 'ArrayList', 'Section 2']);

      await tester.tap(find.byTooltip('Close the cheat sheet'));
      await tester.pumpAndSettle();
    }, variant: windows);

    testWidgets('an entry grip moves the entry inside its section', (
      tester,
    ) async {
      final container = await _pumpSheetHost(tester, sections: 1);
      await _openSheet(tester);
      await tester.tap(find.widgetWithText(Tooltip, 'Edit').first);
      await tester.pumpAndSettle();

      expect(_entryCommands(container), [
        '.method10()',
        '.method11()',
        '.method12()',
        '.method13()',
      ]);

      // The one-entry seed section comes first, so its grip is index 0 and the
      // two being swapped are the next pair.
      final grips = find.byTooltip('Drag to reorder this entry');
      final span =
          tester.getCenter(grips.at(2)).dy - tester.getCenter(grips.at(1)).dy;
      await _dragBy(tester, grips.at(1), span);

      expect(_entryCommands(container), [
        '.method11()',
        '.method10()',
        '.method12()',
        '.method13()',
      ]);

      await tester.tap(find.byTooltip('Close the cheat sheet'));
      await tester.pumpAndSettle();
    }, variant: windows);
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
    final column = tester.getSize(find.byType(ListView).first);
    expect(button.width, lessThan(column.width / 2));

    // Closed before the container goes, so the route's flush-on-dispose still
    // has providers to read.
    await tester.tap(find.byTooltip('Close the cheat sheet'));
    await tester.pumpAndSettle();
  });

  testWidgets('Enter in a label moves on to that row\'s code', (tester) async {
    await _pumpSheetHost(tester);
    await _openSheet(tester);
    await tester.tap(find.widgetWithText(Tooltip, 'Edit').first);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextField, 'Label'));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'cheatCommand');

    await tester.tap(find.byTooltip('Close the cheat sheet'));
    await tester.pumpAndSettle();
  });

  testWidgets('a new section starts blank with its name field focused', (
    tester,
  ) async {
    final container = await _pumpSheetHost(tester, sections: 3);
    await _openSheet(tester);
    await tester.tap(find.widgetWithText(Tooltip, 'Edit').first);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(GlassButton, 'Add section'));
    await tester.pumpAndSettle();

    final sections = container
        .read(leetCodeCheatSheetProvider)
        .requireValue
        .sectionsOf('tab-1');
    expect(sections.last.name, isEmpty);
    expect(find.text('New section'), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'cheatSectionName');
    // The rail names it rather than showing an empty pill.
    expect(find.text('Untitled section'), findsOneWidget);

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

  group('the three-column layout', () {
    testWidgets('badges hang off one right edge, labelled row or not', (
      tester,
    ) async {
      await _pumpSheetHost(tester, variedRows: true);
      await _openSheet(tester);

      // Two badges, on rows that differ in whether they carry a label — the
      // label column is the one that collapses, not the complexity column.
      final rights = <double>[
        for (final badge in ['O(1)', 'O(n log n)'])
          tester.getTopRight(find.text(badge)).dx,
      ];
      expect(rights.first, moreOrLessEquals(rights.last, epsilon: 0.5));
    });

    testWidgets('a row with no complexity still keeps the column', (
      tester,
    ) async {
      await _pumpSheetHost(tester, variedRows: true);
      await _openSheet(tester);

      // The code plate is what gives the empty column away: were it dropped,
      // the row without a badge would run its code out under where every
      // other row's badge sits.
      double plateRight(String command) => tester
          .getTopRight(
            find
                .ancestor(
                  of: find.textContaining(command),
                  matching: find.byType(Container),
                )
                .first,
          )
          .dx;

      expect(
        plateRight('.labelled-bare()'),
        moreOrLessEquals(plateRight('.labelled-badged()'), epsilon: 0.5),
      );
    });

    testWidgets('one labelled row holds the column open for the rest', (
      tester,
    ) async {
      await _pumpSheetHost(tester, variedRows: true);
      await _openSheet(tester);

      // Some of these rows carry a label and some do not; a code column that
      // jogged left and right between them would be worse than the gutter.
      final lefts = <double>[
        for (final command in [
          '.add(e)',
          '.labelled-badged()',
          '.bare-badged()',
        ])
          tester.getTopLeft(find.textContaining(command)).dx,
      ];
      for (final left in lefts) {
        expect(left, moreOrLessEquals(lefts.first, epsilon: 0.5));
      }
    });

    testWidgets('a sheet with no labels at all has no label column', (
      tester,
    ) async {
      await _pumpSheetHost(tester);
      await _openSheet(tester);

      // Nothing is labelled here, so the code starts where the heading does
      // rather than behind an empty gutter.
      expect(
        tester.getTopLeft(find.textContaining('.add(e)')).dx,
        lessThan(tester.getTopLeft(find.text('ArrayList').last).dx + 24),
      );
    });

    testWidgets('the section heading owns the only rule on the page', (
      tester,
    ) async {
      await _pumpSheetHost(tester, variedRows: true);
      await _openSheet(tester);

      // One heading in the tab, so one rule: the hairlines that used to sit
      // between entries are gone, not merely faded.
      final rules = find.descendant(
        of: find.ancestor(
          of: find.text('ArrayList'),
          matching: find.byType(InkWell),
        ),
        matching: find.byType(ColoredBox),
      );
      expect(rules, findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(VoyagerScrollView),
          matching: find.byType(ColoredBox),
        ),
        findsOneWidget,
      );
    });
  });

  group('a cost per line', () {
    testWidgets('each badge sits on the line it belongs to', (tester) async {
      await _pumpSheetHost(tester, blockRow: true);
      await _openSheet(tester);

      double topOf(Finder finder) => tester.getTopLeft(finder).dy;

      final first = topOf(find.textContaining('outer();'));
      final last = topOf(find.textContaining('inner();'));
      // Sanity: the block really is laid out as separate lines.
      expect(last, greaterThan(first));

      // Each badge is level with its own line rather than with the block.
      expect(topOf(find.text('O(n)')), moreOrLessEquals(first, epsilon: 2));
      expect(topOf(find.text('O(n²)')), moreOrLessEquals(last, epsilon: 2));
    });

    testWidgets('a blank line leaves that line bare', (tester) async {
      await _pumpSheetHost(tester, blockRow: true);
      await _openSheet(tester);

      // Three lines, two costs: the middle line's blank entry draws nothing
      // and does not hand its neighbour's badge to it.
      expect(find.text('O(n)'), findsOneWidget);
      expect(find.text('O(n²)'), findsOneWidget);
      final middle = tester.getTopLeft(find.textContaining('middle();')).dy;
      final badges = <double>[
        tester.getTopLeft(find.text('O(n)')).dy,
        tester.getTopLeft(find.text('O(n²)')).dy,
      ];
      for (final badge in badges) {
        expect((badge - middle).abs(), greaterThan(2));
      }
    });

    testWidgets('a blank first line survives a save', (tester) async {
      final container = await _pumpSheetHost(tester);
      await _openSheet(tester);

      // Straight at the action: the field is one line per command line, so
      // trimming a leading blank would slide every badge up one.
      await LeetCodeCheatActions.detached(
        container,
      ).saveEntry('entry-1', complexity: '\nO(n)\n');

      final entry =
          (await container
                  .read(leetCodeRepositoryProvider)
                  .listCheatEntries(sectionId: 'section-1'))
              .single;
      expect(entry.complexity, '\nO(n)');
      expect(entry.complexityByLine, ['']);
    });
  });

  group('complexity tiers', () {
    test('the cheap, the moderate and the expensive are told apart', () {
      expect(cheatComplexityTier('O(1)'), CheatComplexityTier.cheap);
      // The field is free text, so the trailing note has to ride along.
      expect(cheatComplexityTier('O(1) amortized'), CheatComplexityTier.cheap);

      for (final text in ['O(log n)', 'O(n)', 'O(n log n)', 'O(logn)']) {
        expect(
          cheatComplexityTier(text),
          CheatComplexityTier.moderate,
          reason: text,
        );
      }

      for (final text in [
        'O(n^2)',
        'O(n²)',
        'O(n³)',
        'O(2^n)',
        'O(n^k)',
        'O(n!)',
      ]) {
        expect(
          cheatComplexityTier(text),
          CheatComplexityTier.expensive,
          reason: text,
        );
      }
    });

    test('anything it cannot read falls to neutral rather than a guess', () {
      for (final text in ['O(m+n)', 'amortized', '', 'fast']) {
        expect(
          cheatComplexityTier(text),
          CheatComplexityTier.unknown,
          reason: text,
        );
      }
    });
  });
}
