// Opening the sticky note left focus nowhere, so what was typed next was lost
// (BUG-062). Now: a user typing in the body keeps the caret there through
// opening and closing the note; a user in no field gets the caret in the note.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/features/dream_journal/dream_journal_page.dart';

import 'fakes/fake_weather_api_client.dart';

const _bodyHint = 'Describe your dream... use #tags to mark themes';
const _noteHint = 'Jot a quick note to jog your memory later...';

Future<void> _pump(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// The hint of the text field holding primary focus, or null if none does.
String? _focusedFieldHint() {
  final context = FocusManager.instance.primaryFocus?.context;
  return context
      ?.findAncestorWidgetOfExactType<TextField>()
      ?.decoration
      ?.hintText;
}

Future<void> _pumpPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final now = DateTime.now().toUtc();
  await DriftDreamRepository(db).upsertEntry(
    DreamEntry(
      id: 'dream-0',
      title: 'A dream',
      body: 'I flew over the sea.',
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
  await _pump(tester, frames: 12);
}

Future<void> _click(WidgetTester tester, Finder finder) async {
  await tester.tap(finder, kind: PointerDeviceKind.mouse);
  await _pump(tester);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  // Desktop, where a mouse tap outside a text field blurs it.
  final desktop = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets('the body keeps focus while the note opens and closes', (
    tester,
  ) async {
    await _pumpPage(tester);
    await _click(tester, find.widgetWithText(TextField, _bodyHint));
    expect(_focusedFieldHint(), _bodyHint);

    await _click(tester, find.byIcon(Icons.sticky_note_2_outlined));
    expect(find.text('Dream notes'), findsOneWidget);
    expect(_focusedFieldHint(), _bodyHint);

    await _click(tester, find.byTooltip('Close'));
    expect(find.text('Dream notes'), findsNothing);
    expect(_focusedFieldHint(), _bodyHint);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, frames: 20);
  }, variant: desktop);

  testWidgets('with no field focused, opening the note focuses it', (
    tester,
  ) async {
    await _pumpPage(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await _pump(tester);
    expect(_focusedFieldHint(), isNull);

    await _click(tester, find.byIcon(Icons.sticky_note_2_outlined));
    expect(_focusedFieldHint(), _noteHint);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, frames: 20);
  }, variant: desktop);

  testWidgets('a click into the body while the note opens keeps the body', (
    tester,
  ) async {
    await _pumpPage(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await _pump(tester);

    // The note field isn't built until the card is half open.
    await tester.tap(
      find.byIcon(Icons.sticky_note_2_outlined),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('Dream notes'), findsNothing);
    await tester.tapAt(
      tester.getTopLeft(find.widgetWithText(TextField, _bodyHint)) +
          const Offset(40, 40),
      kind: PointerDeviceKind.mouse,
    );
    await _pump(tester);

    expect(find.text('Dream notes'), findsOneWidget);
    expect(_focusedFieldHint(), _bodyHint);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, frames: 20);
  }, variant: desktop);
}
