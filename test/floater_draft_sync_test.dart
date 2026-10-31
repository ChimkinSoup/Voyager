// A new item half-written in the main window and the hotkey floater for it are
// one draft: the app stays mounted behind the floater, so each used to keep its
// own copy, the floater opening blank beside a filled form and neither seeing
// what was typed in the other.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/calendar/calendar_page.dart';
import 'package:voyager/features/finance/finance_page.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/hotkeys/floaters/floater_host.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';
import 'package:voyager/features/hotkeys/quick_journal_entry.dart';
import 'package:voyager/features/journal/journal_page.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';
import 'package:voyager/features/todo/todo_page.dart';

import 'fakes/fake_weather_api_client.dart';
import 'support/todo_page_harness.dart';

/// The floater opened and closed by hand: the real one moves the window first.
class _ManualFloater extends FloaterController {
  _ManualFloater(super.ref);

  QuickCaptureKind? _kind;

  @override
  QuickCaptureKind? get active => _kind;

  set kind(QuickCaptureKind? kind) {
    _kind = kind;
    notifyListeners();
  }
}

class _MemoryPointerStore implements QuickJournalPointerStore {
  ({String day, String entryId})? pointer;

  @override
  Future<({String day, String entryId})?> load() async => pointer;

  @override
  Future<void> save(String day, String entryId) async =>
      pointer = (day: day, entryId: entryId);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  Future<void> frames(WidgetTester tester, [int count = 8]) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// [page] behind a [FloaterHost], as `VoyagerApp` has it.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester,
    AppDatabase db,
    Widget page,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        floaterControllerProvider.overrideWith(_ManualFloater.new),
        quickJournalPointerStoreProvider.overrideWithValue(
          _MemoryPointerStore(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (_, child) => FloaterHost(child: child!),
          home: Scaffold(body: page),
        ),
      ),
    );
    await frames(tester);
    return container;
  }

  AppDatabase newDb() {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    return db;
  }

  Future<void> setFloater(
    WidgetTester tester,
    ProviderContainer container,
    QuickCaptureKind? kind,
  ) async {
    (container.read(floaterControllerProvider) as _ManualFloater).kind = kind;
    await frames(tester);
  }

  Finder field(String label) => find.descendant(
    of: find.widgetWithText(VoyagerTextField, label),
    matching: find.byType(EditableText),
  );

  String textOf(WidgetTester tester, Finder finder) =>
      tester.widget<EditableText>(finder).controller.text;

  group('finance', () {
    Future<ProviderContainer> openSheet(WidgetTester tester) async {
      final container = await pumpApp(tester, newDb(), const FinancePage());
      await tester.tap(find.byTooltip('Log transaction'));
      await frames(tester, 12);
      return container;
    }

    testWidgets('the sheet and the floater hold one draft', (tester) async {
      final container = await openSheet(tester);
      await tester.enterText(field('Note'), 'From the sheet');
      await tester.pump();

      await setFloater(tester, container, QuickCaptureKind.finance);
      expect(textOf(tester, field('Note')), 'From the sheet');

      await tester.enterText(field('Note'), 'From the floater');
      await tester.enterText(field('Amount'), '12.50');
      await tester.pump();

      await setFloater(tester, container, null);
      expect(textOf(tester, field('Note')), 'From the floater');
      expect(textOf(tester, field('Amount')), '12.50');
    });

    testWidgets("taking the floater's fields keeps the sheet's raw figure", (
      tester,
    ) async {
      final container = await openSheet(tester);
      await tester.enterText(field('Amount'), '12.5');
      await tester.pump();

      await setFloater(tester, container, QuickCaptureKind.finance);
      await tester.enterText(field('Note'), 'Lunch');
      await tester.pump();
      await setFloater(tester, container, null);

      expect(textOf(tester, field('Amount')), '12.5');
      expect(textOf(tester, field('Note')), 'Lunch');
    });

    testWidgets('a save in the floater empties the sheet', (tester) async {
      final container = await openSheet(tester);
      await tester.enterText(field('Amount'), '9.00');
      await tester.pump();

      await setFloater(tester, container, QuickCaptureKind.finance);
      await tester.tap(find.text('Add'));
      await frames(tester);
      await setFloater(tester, container, null);

      expect(textOf(tester, field('Amount')), isEmpty);
      expect(container.read(financeCaptureDraftProvider), isNull);
    });

    testWidgets('a save landing after the floater closed empties the sheet', (
      tester,
    ) async {
      final container = await openSheet(tester);
      await tester.enterText(field('Amount'), '9.00');
      await tester.pump();

      // The floater's blur dismissed it mid-write; its write lands with the
      // sheet back on screen.
      storeFinanceCaptureDraft(container, null);
      await frames(tester);

      expect(textOf(tester, field('Amount')), isEmpty);
    });

    testWidgets('a sheet on screen keeps what is typed in it', (tester) async {
      await openSheet(tester);
      await tester.enterText(field('Amount'), '12.5');
      await tester.enterText(field('Note'), 'Lunch ');
      await frames(tester);

      expect(textOf(tester, field('Amount')), '12.5');
      expect(textOf(tester, field('Note')), 'Lunch ');
    });
  });

  group('reminder', () {
    Future<ProviderContainer> pumpDialog(WidgetTester tester) async {
      final container = await pumpApp(
        tester,
        newDb(),
        Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () {
              final container = ProviderScope.containerOf(
                context,
                listen: false,
              );
              showScheduledReminderEditor(
                context,
                draft: ref.read(scheduledReminderDraftProvider),
                onDraft: (draft) =>
                    storeScheduledReminderDraft(container, draft),
              );
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await frames(tester, 12);
      return container;
    }

    testWidgets('the dialog and the floater hold one draft', (tester) async {
      final container = await pumpDialog(tester);
      await tester.enterText(find.byType(EditableText).first, 'Water plants');
      await tester.pump();

      await setFloater(tester, container, QuickCaptureKind.reminder);
      expect(find.text('Water plants'), findsOneWidget);

      await tester.enterText(find.byType(EditableText).first, 'Feed the cat');
      await tester.tap(find.text('Daily'));
      await frames(tester);

      await setFloater(tester, container, null);
      expect(find.text('Feed the cat'), findsOneWidget);
      final kind = tester.widget<SegmentedButton<ReminderScheduleKind>>(
        find.byType(SegmentedButton<ReminderScheduleKind>),
      );
      expect(kind.selected, {ReminderScheduleKind.daily});
    });

    testWidgets('a form on screen keeps its validation line', (tester) async {
      await pumpDialog(tester);
      await tester.enterText(find.byType(EditableText).at(1), 'Just a note');
      await tester.pump();

      await tester.tap(find.text('Create'));
      await frames(tester);
      expect(find.text('Give the reminder a title'), findsOneWidget);
    });

    testWidgets('a draft handed back after the floater closed is taken up', (
      tester,
    ) async {
      final container = await pumpDialog(tester);

      // A floater save that failed after its blur dismissed it.
      storeScheduledReminderDraft(
        container,
        const ScheduledReminderDraft(title: 'Water plants'),
      );
      await frames(tester);

      expect(find.text('Water plants'), findsOneWidget);
    });
  });

  group('calendar', () {
    testWidgets('the popover and the floater hold one draft', (tester) async {
      final container = await pumpApp(tester, newDb(), const CalendarPage());
      container.read(quickCaptureRequestProvider.notifier).state =
          QuickCaptureRequest(QuickCaptureKind.calendar);
      await frames(tester, 12);
      await tester.enterText(find.byType(EditableText).first, 'Dentist');
      await tester.pump();

      await setFloater(tester, container, QuickCaptureKind.calendar);
      expect(find.text('Dentist'), findsOneWidget);

      await tester.enterText(find.byType(EditableText).first, 'Haircut');
      await tester.pump();

      await setFloater(tester, container, null);
      expect(find.text('Haircut'), findsOneWidget);
    });

    testWidgets('a blank popover leaves a waiting floater draft alone', (
      tester,
    ) async {
      final container = await pumpApp(tester, newDb(), const CalendarPage());
      await setFloater(tester, container, QuickCaptureKind.calendar);
      await tester.enterText(find.byType(EditableText).first, 'Dentist');
      await tester.pump();
      await setFloater(tester, container, null);

      await tester.tap(find.text('Add event'));
      await frames(tester, 12);
      expect(find.text('Dentist'), findsNothing);
      await tester.enterText(find.byType(EditableText).first, 'Haircut');
      await tester.pump();

      expect(container.read(calendarCaptureDraftProvider)?.title, 'Dentist');
    });

    testWidgets('notes in a blank popover go when it is clicked away', (
      tester,
    ) async {
      final container = await pumpApp(tester, newDb(), const CalendarPage());
      await tester.tap(find.text('Add event'));
      await frames(tester, 12);
      await tester.enterText(find.byType(EditableText).at(1), 'Just notes');
      await tester.pump();

      await tester.tapAt(const Offset(5, 5));
      await frames(tester, 12);

      expect(find.text('Just notes'), findsNothing);
      expect(container.read(calendarCaptureDraftProvider), isNull);
    });

    testWidgets("a floater's notes-only draft survives a click away", (
      tester,
    ) async {
      final container = await pumpApp(tester, newDb(), const CalendarPage());
      await setFloater(tester, container, QuickCaptureKind.calendar);
      await tester.enterText(find.byType(EditableText).at(1), 'Just notes');
      await tester.pump();
      await setFloater(tester, container, null);

      container.read(quickCaptureRequestProvider.notifier).state =
          QuickCaptureRequest(QuickCaptureKind.calendar);
      await frames(tester, 12);
      expect(find.text('Just notes'), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      await frames(tester, 12);

      expect(container.read(calendarCaptureDraftProvider)?.notes, 'Just notes');
    });

    Future<void> expectFloaterOnWork(
      WidgetTester tester, {
      String? defaultId,
      required String lastViewedId,
    }) async {
      final db = newDb();
      final now = utcNow();
      for (final id in [legacyCalendarId, 'work']) {
        await DriftCalendarRepository(db).upsertCalendar(
          Calendar(id: id, name: id, createdAt: now, updatedAt: now),
        );
      }
      final settings = DriftSettingsRepository(db);
      await settings.saveSettings(
        (await settings.getSettings()).copyWith(
          defaultCalendarId: defaultId,
          lastViewedCalendarId: lastViewedId,
          calendarShowAllCalendars: false,
        ),
      );
      final container = await pumpApp(tester, db, const CalendarPage());

      await setFloater(tester, container, QuickCaptureKind.calendar);
      await tester.enterText(find.byType(EditableText).first, 'Dentist');
      await tester.pump();

      final draft = container.read(calendarCaptureDraftProvider);
      expect(draft?.calendarIdBasis, 'work');
      expect(draft?.calendarId, 'work');
    }

    testWidgets('the floater follows a page opened on the default calendar', (
      tester,
    ) async {
      await expectFloaterOnWork(
        tester,
        defaultId: 'work',
        lastViewedId: legacyCalendarId,
      );
    });

    testWidgets('the floater follows a page reopened where it was left', (
      tester,
    ) async {
      await expectFloaterOnWork(tester, lastViewedId: 'work');
    });
  });

  group('todo', () {
    Future<ProviderContainer> pumpTodo(WidgetTester tester) async {
      final db = newDb();
      await seedTodoTasks(db, active: 1, done: 0);
      return pumpApp(tester, db, const TodoPage());
    }

    testWidgets('the composer and the bar hold one title', (tester) async {
      final container = await pumpTodo(tester);
      await tester.enterText(find.byType(EditableText).first, 'From the page');
      await tester.pump();

      await setFloater(tester, container, QuickCaptureKind.todo);
      expect(find.text('From the page'), findsOneWidget);

      await tester.enterText(find.byType(EditableText).first, 'From the bar');
      await tester.pump();

      await setFloater(tester, container, null);
      expect(find.text('From the bar'), findsOneWidget);
    });

    testWidgets('/search typed in the bar stays out of the hidden page', (
      tester,
    ) async {
      final container = await pumpTodo(tester);
      await setFloater(tester, container, QuickCaptureKind.todo);
      await tester.enterText(find.byType(EditableText).first, '/search milk');
      await tester.pump();

      expect(container.read(todoCaptureDraftProvider).title, '/search milk');
      await setFloater(tester, container, null);
      expect(find.text('/search milk'), findsOneWidget);
    });

    testWidgets('a task added from the composer leaves no draft behind', (
      tester,
    ) async {
      final container = await pumpTodo(tester);
      container.read(todoCaptureDraftProvider.notifier).state =
          TodoCaptureDraft(title: 'Call', dueDate: DateTime(2030));
      await tester.pump();
      expect(find.text('Call'), findsOneWidget);

      await tester.showKeyboard(find.byType(EditableText).first);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await frames(tester);

      final draft = container.read(todoCaptureDraftProvider);
      expect(draft.title, isEmpty);
      expect(draft.dueDate, isNull);
    });

    Future<ProviderContainer> pumpWithWorkList(
      WidgetTester tester,
      AppDatabase db,
    ) async {
      await seedTodoTasks(db, active: 1, done: 0);
      final now = utcNow();
      await DriftTodoRepository(db).upsertList(
        TodoListModel(id: 'work', name: 'Work', createdAt: now, updatedAt: now),
      );
      return pumpApp(tester, db, const TodoPage());
    }

    /// The bar's draft as the user left it: due on [due], filed under Work.
    Future<void> leaveBarDraft(
      ProviderContainer container,
      AppDatabase db,
      DateTime due,
    ) async {
      final settings = await DriftSettingsRepository(db).getSettings();
      container
          .read(todoCaptureDraftProvider.notifier)
          .state = TodoCaptureDraft(
        title: 'Call',
        dueDate: due,
        listId: 'work',
        listIdBasis: settings.lastViewedTodoListId,
      );
    }

    Future<void> pressEnter(WidgetTester tester) async {
      await tester.showKeyboard(find.byType(EditableText).first);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await frames(tester);
    }

    testWidgets("Enter files the bar's title under its picks", (tester) async {
      final db = newDb();
      final container = await pumpWithWorkList(tester, db);
      final due = DateTime(2030, 3, 4);
      await leaveBarDraft(container, db, due);
      await tester.pump();

      await pressEnter(tester);

      final task = (await DriftTodoRepository(db).listTasks('work')).single;
      expect(task.title, 'Call');
      expect(task.dueDate?.toLocal(), due);
      // The page followed, so the task is in view.
      expect(find.text('Call'), findsOneWidget);
    });

    testWidgets('the hotkey keeps the due date for Enter', (tester) async {
      final db = newDb();
      final container = await pumpWithWorkList(tester, db);
      final due = DateTime(2030, 3, 4);
      await leaveBarDraft(container, db, due);
      await tester.pump();

      container.read(quickCaptureRequestProvider.notifier).state =
          QuickCaptureRequest(QuickCaptureKind.todo);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await frames(tester);
      await pressEnter(tester);

      final task = (await DriftTodoRepository(db).listTasks('work')).single;
      expect(task.dueDate?.toLocal(), due);
    });

    testWidgets("a title typed in the composer leaves the bar's picks alone", (
      tester,
    ) async {
      final container = await pumpTodo(tester);
      final due = DateTime(2030);
      container.read(todoCaptureDraftProvider.notifier).state =
          TodoCaptureDraft(dueDate: due, listId: 'work', listIdBasis: 'home');
      await tester.pump();

      await tester.enterText(find.byType(EditableText).first, 'Buy');
      await tester.pump();
      container.read(quickCaptureRequestProvider.notifier).state =
          QuickCaptureRequest(QuickCaptureKind.todo);
      await frames(tester);

      var draft = container.read(todoCaptureDraftProvider);
      expect(draft.title, 'Buy');
      expect(draft.dueDate, due);
      expect(draft.listId, 'work');

      await tester.showKeyboard(find.byType(EditableText).first);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await frames(tester);

      draft = container.read(todoCaptureDraftProvider);
      expect(draft.title, isEmpty);
      expect(draft.dueDate, due);
      expect(draft.listId, 'work');
    });
  });

  group('journal', () {
    testWidgets('the page and the notepad show the same quick entry', (
      tester,
    ) async {
      final db = newDb();
      final now = DateTime.now().toUtc();
      await DriftJournalRepository(db).upsertJournal(
        Journal(id: 'journal', name: 'Journal', createdAt: now, updatedAt: now),
      );
      final container = await pumpApp(tester, db, const JournalPage());
      container.read(quickCaptureRequestProvider.notifier).state =
          QuickCaptureRequest(QuickCaptureKind.journal);
      await frames(tester, 12);

      final field = find.byType(EditableText);
      await tester.enterText(field.last, 'From the page');
      await tester.pump();
      // The window lost focus before the hotkey could open a floater at all.
      await PendingFlushRegistry.instance.flushAll();
      await frames(tester);

      await setFloater(tester, container, QuickCaptureKind.journal);
      await frames(tester, 12);
      expect(textOf(tester, field.first), 'From the page');

      await tester.enterText(field.first, 'From the notepad');
      await frames(tester, 10);

      await setFloater(tester, container, null);
      await frames(tester, 12);
      expect(textOf(tester, field.last), 'From the notepad');

      // Nor does the page's next flush put its old copy back.
      await PendingFlushRegistry.instance.flushAll();
      await frames(tester);
      final entries = await DriftJournalRepository(
        db,
      ).listEntries(journalId: 'journal');
      expect(entries.single.body, 'From the notepad');
    });
  });
}
