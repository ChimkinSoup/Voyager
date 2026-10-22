// The quick to-do bar's due picker takes an optional time, as the Todo
// page's does; it used to offer a date only.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/core/widgets/time_entry_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/features/hotkeys/floaters/todo_floater.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  Future<AppDatabase> pumpFloater(WidgetTester tester) async {
    // Bar-sized, as the floater opens; [openDuePanel] grows it the way the
    // floater controller would.
    tester.view.physicalSize = const Size(1344, 60);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        ],
        child: const MaterialApp(home: Scaffold(body: TodoFloater())),
      ),
    );
    await tester.pumpAndSettle();
    return db;
  }

  Future<void> openDuePanel(WidgetTester tester) async {
    await tester.tap(find.byIcon(PhosphorIconsRegular.calendar));
    tester.view.physicalSize = Size(
      1344,
      60 + kDateTimeSelectorPopoverSize.height + 134,
    );
    await tester.pumpAndSettle();
  }

  Finder timeField() => find.descendant(
    of: find.byType(TimeEntryField),
    matching: find.byType(EditableText),
  );

  Future<DateTime?> saveAndReadDue(WidgetTester tester, AppDatabase db) async {
    final title = find.byType(EditableText).first;
    await tester.enterText(title, 'task');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final repo = DriftTodoRepository(db);
    final lists = await repo.listLists();
    final tasks = await repo.listTasks(lists.single.id);
    return tasks.single.dueDate?.toLocal();
  }

  testWidgets('a typed 12:00 AM is saved as a time, not as no time', (
    tester,
  ) async {
    final db = await pumpFloater(tester);

    await openDuePanel(tester);
    await tester.tap(timeField());
    await tester.enterText(timeField(), '12:00 AM');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.textContaining(RegExp(r'at 12:00\sAM')), findsOneWidget);
    final due = await saveAndReadDue(tester, db);
    expect((due!.hour, due.minute), (0, 0));
    final repo = DriftTodoRepository(db);
    final lists = await repo.listLists();
    expect((await repo.listTasks(lists.single.id)).single.dueHasTime, isTrue);
  });

  testWidgets('a typed time is kept on the saved task', (tester) async {
    final db = await pumpFloater(tester);

    await openDuePanel(tester);
    await tester.tap(timeField());
    await tester.enterText(timeField(), '3:30 PM');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.textContaining(RegExp(r'at 3:30\sPM')), findsOneWidget);
    final due = await saveAndReadDue(tester, db);
    expect((due!.hour, due.minute), (15, 30));
  });

  testWidgets('reopening with a time set focuses the time field', (
    tester,
  ) async {
    await pumpFloater(tester);
    await openDuePanel(tester);
    await tester.tap(timeField());
    await tester.enterText(timeField(), '3:30 PM');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await openDuePanel(tester);
    expect(tester.widget<EditableText>(timeField()).focusNode.hasFocus, isTrue);
  });

  testWidgets('closing the panel without Done keeps the pick', (tester) async {
    final db = await pumpFloater(tester);

    await openDuePanel(tester);
    await tester.tap(find.text('Tomorrow'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(PhosphorIconsRegular.calendar));
    await tester.pumpAndSettle();

    final due = await saveAndReadDue(tester, db);
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    expect(
      (due!.month, due.day, due.hour, due.minute),
      (tomorrow.month, tomorrow.day, 0, 0),
    );
  });

  testWidgets('Done without a time saves a date only', (tester) async {
    final db = await pumpFloater(tester);

    await openDuePanel(tester);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    final due = await saveAndReadDue(tester, db);
    expect((due!.hour, due.minute), (0, 0));
  });
}
