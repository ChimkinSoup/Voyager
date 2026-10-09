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
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.utc(2026, 1, 1);

TodoTask _task(String notes) => TodoTask(
  id: 'a',
  listId: 'list-1',
  title: 'Task',
  notes: notes,
  createdAt: _now,
  updatedAt: _now,
);

Future<ProviderContainer> _device(
  AppDatabase db,
  InMemorySyncRepository server,
  String deviceId,
) async {
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(server),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      deviceIdProvider.overrideWith((ref) => deviceId),
    ],
  );
  final settings = container.read(settingsRepositoryProvider);
  await settings.saveSettings(await settings.getSettings());
  await container.read(settingsProvider.future);
  await container.read(todoRepositoryProvider).upsertTask(_task('hello'));
  return container;
}

/// Device A with the panel open on task `a` (notes "hello", uploaded with
/// its operations), and device B ready to edit the same notes.
class _Setup {
  _Setup(this.server, this.a, this.b, this.showPanel);

  final InMemorySyncRepository server;
  final ProviderContainer a;
  final ProviderContainer b;
  final ValueNotifier<bool> showPanel;

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
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: a,
      child: MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: showPanel,
            builder: (context, show, _) => show
                ? TodoEditPanel(
                    task: _task('hello'),
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
  final setup = _Setup(server, a, b, showPanel);
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
