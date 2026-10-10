// During a cold sign-in's pull the To-Do page has no lists yet, and it used to
// show only "Create your first list": the todo hotkey switched to it and
// focused a composer that wasn't there, so the typed task went nowhere
// (BUG-221).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';
import 'package:voyager/features/todo/todo_page.dart';

import 'fakes/fake_weather_api_client.dart';

Future<void> _frames(WidgetTester tester, [int count = 6]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<(AppDatabase, ProviderContainer)> _pumpEmptyTodoPage(
  WidgetTester tester, {
  List<Override> overrides = const [],
}) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: TodoPage())),
    ),
  );
  await _frames(tester);
  return (db, container);
}

EditableText _composer(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText).first);

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the todo hotkey with no lists yet still takes the task', (
    tester,
  ) async {
    final (db, container) = await _pumpEmptyTodoPage(tester);
    expect(find.text('Create your first list'), findsOneWidget);

    container.read(quickCaptureRequestProvider.notifier).state =
        QuickCaptureRequest(QuickCaptureKind.todo);
    await _frames(tester);
    expect(_composer(tester).focusNode.hasFocus, isTrue);

    await tester.enterText(find.byType(EditableText).first, 'P26 pull task');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _frames(tester);

    final tasks = await DriftTodoRepository(db).listTasks(legacyTodoListId);
    expect(tasks.map((t) => t.title), ['P26 pull task']);
  });

  testWidgets('lists arriving mid-typing keep the composer focused', (
    tester,
  ) async {
    final (db, container) = await _pumpEmptyTodoPage(tester);
    container.read(quickCaptureRequestProvider.notifier).state =
        QuickCaptureRequest(QuickCaptureKind.todo);
    await _frames(tester);
    await tester.enterText(find.byType(EditableText).first, 'half typ');

    // What the pull does: a repository write, then the providers re-read.
    final now = DateTime.now().toUtc();
    await DriftTodoRepository(db).upsertList(
      TodoListModel(
        id: 'pulled',
        name: 'Pulled',
        createdAt: now,
        updatedAt: now,
      ),
    );
    container.invalidate(todoListsProvider);
    await _frames(tester);

    expect(find.text('Create your first list'), findsNothing);
    final composer = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .firstWhere((e) => e.controller.text == 'half typ');
    expect(composer.focusNode.hasFocus, isTrue);
  });

  testWidgets('a task typed during the first pull waits for the lists', (
    tester,
  ) async {
    final auth = InMemoryAuthRepository();
    await auth.signInWithEmail('qa@example.com', 'password');
    final (db, container) = await _pumpEmptyTodoPage(
      tester,
      overrides: [authRepositoryProvider.overrideWithValue(auth)],
    );
    expect(container.read(authNotifierProvider).isAuthenticated, isTrue);
    container.read(startupPullPendingProvider.notifier).state = true;
    await _frames(tester);
    expect(find.text('Create your first list'), findsNothing);

    container.read(quickCaptureRequestProvider.notifier).state =
        QuickCaptureRequest(QuickCaptureKind.todo);
    await _frames(tester);
    await tester.enterText(find.byType(EditableText).first, 'held task');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _frames(tester);

    final repo = DriftTodoRepository(db);
    expect(await repo.listLists(), isEmpty, reason: 'no built-in list yet');
    expect(find.textContaining('1 task will be added'), findsOneWidget);

    // The pull brings the account's list, then ends.
    final now = DateTime.now().toUtc();
    await repo.upsertList(
      TodoListModel(
        id: 'pulled',
        name: 'Pulled',
        createdAt: now,
        updatedAt: now,
      ),
    );
    container.invalidate(todoListsProvider);
    container.read(startupPullPendingProvider.notifier).state = false;
    await _frames(tester);

    expect((await repo.listLists()).map((l) => l.id), ['pulled']);
    expect((await repo.listTasks('pulled')).map((t) => t.title), ['held task']);
  });
}
