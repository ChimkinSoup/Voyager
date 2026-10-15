// Another device's notes reach the open notes field: saved to this device's
// row when the field is being edited, shown as stored when it is not.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.utc(2026, 1, 1);

TodoTask _task(String notes, {String id = 'a'}) => TodoTask(
  id: id,
  listId: 'list-1',
  title: 'Task',
  notes: notes,
  createdAt: _now,
  updatedAt: _now,
);

/// Reads a task, once [slow] is set, as slowly as a real database on its own
/// isolate does. The in-memory one answers before the next frame, which hid
/// BUG-236. Off by default: a delay only completes while the test pumps.
class _SlowTodoRepository extends DriftTodoRepository {
  _SlowTodoRepository(super.db);

  static var slow = false;

  @override
  Future<TodoTask?> getTask(String id) async {
    if (slow) await Future<void>.delayed(const Duration(milliseconds: 500));
    return super.getTask(id);
  }
}

Future<ProviderContainer> _device(
  AppDatabase db,
  InMemorySyncRepository server,
  String deviceId,
) async {
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      todoRepositoryProvider.overrideWithValue(_SlowTodoRepository(db)),
      syncRepositoryProvider.overrideWithValue(server),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      deviceIdProvider.overrideWith((ref) => deviceId),
    ],
  );
  final settings = container.read(settingsRepositoryProvider);
  await settings.saveSettings(await settings.getSettings());
  await container.read(settingsProvider.future);
  await container.read(todoRepositoryProvider).upsertTask(_task('hello'));
  await container.read(todoRepositoryProvider).upsertTask(_task('', id: 'b'));
  return container;
}

/// Device A with the panel open on task `a` (notes "hello", uploaded with
/// its operations), and device B ready to edit the same notes.
class _Setup {
  _Setup(this.server, this.a, this.b, this.showPanel, this.panelTask);

  final InMemorySyncRepository server;
  final ProviderContainer a;
  final ProviderContainer b;
  final ValueNotifier<bool> showPanel;
  final ValueNotifier<TodoTask> panelTask;

  RemoteSyncService get syncA => a.read(remoteSyncServiceProvider);

  /// B appends " there" and uploads; A pulls it.
  Future<void> remoteEdit() async {
    final syncB = b.read(remoteSyncServiceProvider);
    await syncB.prepareEditingSession(
      collection: FirestoreCollections.todoTasks,
      documentId: 'a',
      initialText: 'hello',
    );
    syncB.recordTodoNotesChange(
      taskId: 'a',
      before: 'hello',
      after: 'hello there',
    );
    await syncB.pushTodoTaskNow(_task('hello there').copyWith(version: 2));
    await deliverToA();
  }

  /// B stars task `a`, leaving its notes as they are.
  Future<void> remoteStar() async {
    await b
        .read(remoteSyncServiceProvider)
        .pushTodoTaskNow(
          _task('hello there').copyWith(version: 3, starred: true),
        );
    await deliverToA();
  }

  /// A pulls task `a` as the cloud holds it.
  Future<void> deliverToA() async {
    await syncA.pullForCollection(
      FirestoreCollections.todoTasks,
      documentIds: {'a'},
      documentData: {
        'a': (await server.getDocument(FirestoreCollections.todoTasks, 'a'))!,
      },
    );
  }
}

Future<_Setup> _open(WidgetTester tester, {required bool focusNotes}) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final server = InMemorySyncRepository();
  final dbA = AppDatabase.inMemory();
  final dbB = AppDatabase.inMemory();
  addTearDown(dbA.close);
  addTearDown(dbB.close);
  final a = await _device(dbA, server, 'device-a');
  final b = await _device(dbB, server, 'device-b');
  addTearDown(a.dispose);
  addTearDown(b.dispose);

  final showPanel = ValueNotifier(true);
  final panelTask = ValueNotifier(_task('hello'));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: a,
      child: MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: Listenable.merge([showPanel, panelTask]),
            builder: (context, _) => showPanel.value
                ? TodoEditPanel(
                    task: panelTask.value,
                    listColor: 0xFF3366FF,
                    onClose: () {},
                    onChanged: () {},
                    onToggleCompleted: (_) {},
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  if (focusNotes) {
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is EditableText && w.controller.text == 'hello',
      ),
    );
    await tester.pumpAndSettle();
  }
  final setup = _Setup(server, a, b, showPanel, panelTask);
  // A's session goes up first, so B edits the same characters.
  await setup.syncA.pushTodoTaskNow(_task('hello'));
  await tester.pumpAndSettle();
  return setup;
}

void main() {
  testWidgets('a live-merged notes change is saved once the field lets go', (
    tester,
  ) async {
    final setup = await _open(tester, focusNotes: true);

    await setup.remoteEdit();
    await tester.pump();
    expect(find.text('hello there'), findsOneWidget, reason: 'merged live');

    // Closed without another keystroke.
    setup.showPanel.value = false;
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final row = await setup.a.read(todoRepositoryProvider).getTask('a');
    expect(row?.notes, 'hello there');
  });

  // BUG-236: selecting another task blurs the notes, and the merge that blur
  // applies finished after the panel had moved on, writing the first task's
  // text into the second's field — saved there by the next keystroke.
  testWidgets('a merge still settling when another task is selected stays '
      'with its own task', (tester) async {
    final setup = await _open(tester, focusNotes: true);
    final repo = setup.a.read(todoRepositoryProvider);

    await setup.remoteEdit();
    await tester.pump();
    expect(find.text('hello there'), findsOneWidget, reason: 'merged live');
    // No text in it, so it is held for the field's next flush.
    await setup.remoteStar();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is EditableText && w.controller.text == 'hello there',
      ),
      'hello there again',
    );

    // What a click on another row does: the notes let go, and the panel is
    // pointed at that task.
    final taskB = (await repo.getTask('b'))!;
    _SlowTodoRepository.slow = true;
    addTearDown(() => _SlowTodoRepository.slow = false);
    FocusManager.instance.primaryFocus?.unfocus();
    setup.panelTask.value = taskB;
    // The frame that points the panel at task b, before the read is back.
    await tester.pump();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    _SlowTodoRepository.slow = false;

    expect(find.text('hello there again'), findsNothing);
    final notes = find.byWidgetPredicate(
      (w) => w is EditableText && w.controller.text.isEmpty,
    );
    expect(notes, findsWidgets);
    expect((await repo.getTask('b'))?.notes ?? '', isEmpty);
    expect((await repo.getTask('a'))?.notes, 'hello there again');
    setup.showPanel.value = false;
    await tester.pumpAndSettle(const Duration(seconds: 2));
  });

  testWidgets('notes nobody is typing in still show the change', (
    tester,
  ) async {
    final setup = await _open(tester, focusNotes: false);
    final repo = setup.a.read(todoRepositoryProvider);

    await setup.remoteEdit();
    await tester.pump();
    expect(find.text('hello there'), findsOneWidget);

    // Shown, not saved: the pull stored the row, and a save from the panel
    // would only write it again.
    final stored = await repo.getTask('a');
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect((await repo.getTask('a'))?.updatedAt, stored?.updatedAt);
    expect(stored?.notes, 'hello there');
  });
}
