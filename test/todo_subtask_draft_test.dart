// Text typed into "Add subtask" and never submitted is kept per parent task:
// pointing the panel at another task, closing it, or restarting the app brings
// it back for the task it was typed under, and submitting it retires it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';
import 'package:voyager/features/todo/todo_subtask_draft_store.dart';

import 'fakes/fake_weather_api_client.dart';

const _listId = 'list-1';
final _now = DateTime.utc(2026, 1, 1);

TodoTask _task(String id) => TodoTask(
  id: id,
  listId: _listId,
  title: 'Task $id',
  createdAt: _now,
  updatedAt: _now,
);

/// Hosts the panel the way the page does: one State, re-pointed at whichever
/// task is selected, and unmounted when nothing is.
class _Host extends StatefulWidget {
  const _Host({super.key});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  TodoTask? task = _task('a');

  void show(TodoTask? next) => setState(() => task = next);

  @override
  Widget build(BuildContext context) {
    final task = this.task;
    if (task == null) return const SizedBox.shrink();
    return TodoEditPanel(
      task: task,
      listColor: 0xFF3366FF,
      onClose: () {},
      onChanged: () {},
      onToggleCompleted: (_) {},
    );
  }
}

String _subtaskFieldText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.ancestor(
          of: find.text('Add subtask'),
          matching: find.byType(TextField),
        ),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

Finder get _subtaskField => find.ancestor(
  of: find.text('Add subtask'),
  matching: find.byType(TextField),
);

void main() {
  testWidgets('draft follows its task across switches, closes and submit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final settingsRepo = DriftSettingsRepository(db);
    await settingsRepo.saveSettings(await settingsRepo.getSettings());
    final repo = DriftTodoRepository(db);
    await repo.upsertTask(_task('a'));
    await repo.upsertTask(_task('b'));

    final drafts = MemoryTodoSubtaskDraftStore();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        todoSubtaskDraftStoreProvider.overrideWithValue(drafts),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);

    final hostKey = GlobalKey<_HostState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 420,
                height: 900,
                child: _Host(key: hostKey),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(_subtaskField, 'buy boxes');
    await tester.pumpAndSettle();
    expect(drafts.drafts, {'a': 'buy boxes'});

    // Switching tasks: B starts empty, and A's draft is untouched.
    hostKey.currentState!.show(_task('b'));
    await tester.pumpAndSettle();
    expect(_subtaskFieldText(tester), isEmpty);
    expect(drafts.drafts, {'a': 'buy boxes'});

    await tester.enterText(_subtaskField, 'call landlord');
    await tester.pumpAndSettle();

    hostKey.currentState!.show(_task('a'));
    await tester.pumpAndSettle();
    expect(_subtaskFieldText(tester), 'buy boxes');

    // Closing the panel (page switch, list change…) and reopening.
    hostKey.currentState!.show(null);
    await tester.pumpAndSettle();
    hostKey.currentState!.show(_task('b'));
    await tester.pumpAndSettle();
    expect(_subtaskFieldText(tester), 'call landlord');

    // Submitting turns the draft into a subtask and retires it.
    await tester.tap(_subtaskField);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect((await repo.listSubtasks('b')).map((t) => t.title), [
      'call landlord',
    ]);
    expect(_subtaskFieldText(tester), isEmpty);
    expect(drafts.drafts, {'a': 'buy boxes'});
  });

  test(
    'file store keeps drafts across instances, as across a restart',
    () async {
      final dir = await Directory.systemTemp.createTemp('subtask_drafts');
      addTearDown(() => dir.delete(recursive: true));

      final first = FileTodoSubtaskDraftStore(directory: () async => dir);
      first
        ..save('a', 'b')
        ..save('a', 'buy boxes')
        ..save('b', 'call landlord')
        ..save('b', '  ');
      // Let the queued write land.
      await first.load('a');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final second = FileTodoSubtaskDraftStore(directory: () async => dir);
      expect(await second.load('a'), 'buy boxes');
      expect(await second.load('b'), isNull);
    },
  );
}
