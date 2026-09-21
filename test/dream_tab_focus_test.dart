// Where Tab goes from the dream page's two writing surfaces.
//
// The body keeps it, the same as the journal's body — where the key never
// escapes because `MediaPasteScope` wraps the field in a `FocusScope` with
// nothing else in it. The dream page has no such wrapper, so Tab on a line
// with no list marker used to walk focus off to the page's buttons
// mid-sentence.
//
// The sticky note hands it to the body instead: the note floats over the
// editor, so reading-order traversal took it out to the "New dream" button and
// the entry list rather than into the dream the note belongs to.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/features/dream_journal/dream_journal_page.dart';
import 'package:voyager/features/dream_journal/dream_sticky_note.dart';

import 'fakes/fake_weather_api_client.dart';

Finder get _bodyField => find.widgetWithText(
  TextField,
  'Describe your dream... use #tags to mark themes',
);

Finder get _notesField => find.widgetWithText(
  TextField,
  'Jot a quick note to jog your memory later...',
);

Future<void> _pumpPage(
  WidgetTester tester, {
  String body = '',
  String notes = '',
}) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);

  final now = DateTime.now().toUtc();
  await DriftDreamRepository(db).upsertEntry(
    DreamEntry(
      id: 'harness-dream',
      title: 'Seeded dream',
      body: body,
      notes: notes,
      entryDate: now,
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
      child: const MaterialApp(home: Scaffold(body: DreamJournalPage())),
    ),
  );
  // Not pumpAndSettle: the page keeps animations alive, so settling never
  // completes.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Focuses the body and puts the caret at the end of its text.
Future<TextEditingController> _enterBody(WidgetTester tester) async {
  await tester.tap(_bodyField);
  await tester.pump();
  final controller = tester.widget<TextField>(_bodyField).controller!;
  controller.selection = TextSelection.collapsed(
    offset: controller.text.length,
  );
  await tester.pump();
  return controller;
}

/// Opens the sticky note, focuses it and puts the caret at the end.
Future<TextEditingController> _enterNotes(WidgetTester tester) async {
  await tester.tap(find.byType(DreamStickyNote), warnIfMissed: false);
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  final field = tester.widget<TextField>(_notesField);
  field.focusNode!.requestFocus();
  await tester.pump();
  final controller = field.controller!;
  controller.selection = TextSelection.collapsed(
    offset: controller.text.length,
  );
  await tester.pump();
  return controller;
}

Future<void> _disposePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('Tab in the body on a plain line leaves the caret where it is', (
    tester,
  ) async {
    await _pumpPage(tester, body: 'plain text');
    final controller = await _enterBody(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, 'plain text');
    expect(
      tester.widget<TextField>(_bodyField).focusNode,
      same(FocusManager.instance.primaryFocus),
      reason: 'Tab walked focus out of the dream body',
    );

    await _disposePage(tester);
  });

  testWidgets('Shift+Tab in the body does not walk focus back either', (
    tester,
  ) async {
    await _pumpPage(tester, body: 'plain text');
    final controller = await _enterBody(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(controller.text, 'plain text');
    expect(
      tester.widget<TextField>(_bodyField).focusNode,
      same(FocusManager.instance.primaryFocus),
    );

    await _disposePage(tester);
  });

  testWidgets('Tab still indents the bullet the body caret is on', (
    tester,
  ) async {
    await _pumpPage(tester, body: '- item');
    final controller = await _enterBody(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, '  - item');
    expect(controller.selection.baseOffset, 8);

    await _disposePage(tester);
  });

  testWidgets('Tab in the notes on a plain line hands focus to the body', (
    tester,
  ) async {
    await _pumpPage(tester, body: 'dream text', notes: 'plain note');
    final controller = await _enterNotes(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, 'plain note');
    expect(
      tester.widget<TextField>(_bodyField).focusNode,
      same(FocusManager.instance.primaryFocus),
      reason: 'Tab from the note should land in the body, not the sidebar',
    );
    // The note is a panel, not a popover: only its close button collapses it.
    expect(_notesField, findsOneWidget);

    await _disposePage(tester);
  });

  testWidgets('Tab still indents the bullet the notes caret is on', (
    tester,
  ) async {
    await _pumpPage(tester, notes: '- note');
    final controller = await _enterNotes(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, '  - note');
    expect(
      tester.widget<TextField>(_notesField).focusNode,
      same(FocusManager.instance.primaryFocus),
    );

    await _disposePage(tester);
  });
}
