// Closing the event panel's time picker with Esc used to unfocus everything,
// which parked focus on the panel's route scope — above every key handler in
// the panel — so Ctrl+Enter did nothing and typing went nowhere (BUG-082).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_event_panel.dart';

import 'fakes/fake_weather_api_client.dart';

Future<ProviderContainer> _container() async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final settingsRepo = DriftSettingsRepository(db);
  await settingsRepo.saveSettings(await settingsRepo.getSettings());
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  return container;
}

Future<List<Map<String, dynamic>>> _pumpPanel(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = await _container();
  final now = DateTime.utc(2026, 1, 1);
  final saved = <Map<String, dynamic>>[];
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: VoyagerTheme.dark(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 384,
              child: CalendarEventPanel(
                event: CalendarEvent(
                  id: 'e1',
                  createdAt: now,
                  updatedAt: now,
                  calendarId: 'c1',
                  title: 'Focus test',
                  start: DateTime(2026, 10, 7, 10),
                  end: DateTime(2026, 10, 7, 11),
                  isFullDay: false,
                ),
                initialDate: DateTime(2026, 10, 7),
                calendars: const [],
                initialCalendarId: 'c1',
                onSave: saved.add,
                onCancel: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return saved;
}

/// Opens the time picker from the time chip and closes it with Esc.
Future<void> _escapeTimePicker(WidgetTester tester) async {
  await tester.tap(find.textContaining('10:00').first);
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('after Esc closes the time picker, the Title has the caret and '
      'Ctrl+Enter saves', (tester) async {
    final saved = await _pumpPanel(tester);
    await _escapeTimePicker(tester);

    final focusedField = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>();
    expect(focusedField?.controller.text, 'Focus test');
    // A caret, not the whole title selected: the next keystroke must not
    // replace it.
    expect(
      focusedField?.controller.selection,
      const TextSelection.collapsed(offset: 'Focus test'.length),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(saved, hasLength(1));
    expect(saved.single['title'], 'Focus test');
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('on a touch device the picker closing leaves nothing focused, '
      'so no soft keyboard comes up', (tester) async {
    await _pumpPanel(tester);
    await _escapeTimePicker(tester);

    final focusedField = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>();
    expect(focusedField, isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
