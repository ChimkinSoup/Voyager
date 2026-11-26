// On a phone the soft keyboard (or landscape) left the journal and dream
// editors less height than the rows above the body need, so the body's
// Expanded collapsed to nothing and text was typed blind (BUG-385).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/features/dream_journal/dream_journal_page.dart';

import 'fakes/fake_weather_api_client.dart';
import 'narrow_window_harness.dart';
import 'support/journal_page_harness.dart';

Future<void> _frames(WidgetTester tester, [int count = 10]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Focuses the body, raises a [keyboard]-tall soft keyboard and types, then
/// checks the body still has room for three lines and the caret is on screen.
Future<void> _typeWithKeyboardUp(WidgetTester tester, double keyboard) async {
  final body = find.byType(TagHighlightedTextField);
  final editable = find.descendant(
    of: body,
    matching: find.byType(EditableText),
  );
  final state = tester.state<EditableTextState>(editable)..requestKeyboard();
  await _frames(tester);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  await _frames(tester);
  tester.testTextInput.enterText(List.filled(12, 'line of text').join('\n'));
  await _frames(tester);

  expect(tester.takeException(), isNull);
  // The same field, still focused: a remount would close the keyboard.
  expect(tester.state<EditableTextState>(editable), same(state));
  expect(state.widget.focusNode.hasFocus, isTrue);

  final visibleBottom = tester.view.physicalSize.height - keyboard;
  final rect = tester.getRect(body);
  final visibleHeight =
      rect.bottom.clamp(0.0, visibleBottom) -
      rect.top.clamp(0.0, visibleBottom);
  expect(visibleHeight, greaterThanOrEqualTo(66), reason: '$rect');
  final editor = state.renderEditable;
  final caret = MatrixUtils.transformRect(
    editor.getTransformTo(null),
    editor.getLocalRectForCaret(editor.selection!.extent),
  );
  expect(caret.top, greaterThanOrEqualTo(0));
  expect(caret.bottom, lessThanOrEqualTo(visibleBottom));
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('journal: phone portrait, emoji panel up', (tester) async {
    // The page's share of a 361x794 phone: status bar, strip and bottom nav
    // taken off.
    tester.view.physicalSize = const Size(361, 649);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadRealFonts(tester);
    await pumpJournalPage(tester, theme: VoyagerTheme.dark());
    await tester.tap(find.text('Seeded entry').first);
    await _frames(tester);

    await _typeWithKeyboardUp(tester, 360);

    await disposeJournalPage(tester);
  });

  testWidgets('journal: phone landscape, keyboard up', (tester) async {
    tester.view.physicalSize = const Size(680, 329);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadRealFonts(tester);
    await pumpJournalPage(tester, theme: VoyagerTheme.dark());

    await _typeWithKeyboardUp(tester, 200);

    await disposeJournalPage(tester);
  });

  testWidgets('dreams: phone landscape, keyboard up', (tester) async {
    tester.view.physicalSize = const Size(680, 329);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadRealFonts(tester);
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final now = DateTime.now().toUtc();
    await DriftDreamRepository(db).upsertEntry(
      DreamEntry(
        id: 'dream-0',
        title: 'A dream',
        body: '',
        entryDate: DateTime(2026, 10, 14, 9, 1).toUtc(),
        createdAt: now,
        updatedAt: now,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: const Scaffold(body: DreamJournalPage()),
        ),
      ),
    );
    await _frames(tester, 12);

    await _typeWithKeyboardUp(tester, 200);

    await tester.pumpWidget(const SizedBox.shrink());
    await _frames(tester, 40);
  });
}
