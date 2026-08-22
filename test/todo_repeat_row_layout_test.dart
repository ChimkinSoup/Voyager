// Layout guards for the to-do edit panel's due-date row:
//
//   [ date & time pill ] [ repeat ] ————————————— [ Reset due date ]
//
// The repeat toggle sits with the pill on the left; "Reset due date" is pushed
// hard right so it reads as the row's escape hatch rather than a third setting.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';

import 'fakes/fake_weather_api_client.dart';

/// Mirrors `_todoEditPanelWidth` in todo_page.dart. The panel is a fixed-width
/// side panel — the open animation slides a 420-wide child rather than
/// relaying it out — so this is the only width the row is ever built at.
const double kTodoEditPanelWidth = 420.0;

/// The narrowest the row survives, with the reset button at its natural size.
/// Guarded below so that shrinking [kTodoEditPanelWidth] past it fails loudly
/// instead of overflowing in the UI.
const double kTodoRowMinWidth = 340.0;

const _listId = 'list-1';

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

TodoTask task({DateTime? dueDate, RecurrenceRule? recurrence}) {
  final now = DateTime.utc(2026, 1, 1);
  return TodoTask(
    id: 't1',
    listId: _listId,
    title: 'Water the plants',
    createdAt: now,
    updatedAt: now,
    dueDate: dueDate,
    recurrence: recurrence ?? RecurrenceRule.none,
  );
}

Future<void> _pumpPanel(
  WidgetTester tester,
  ProviderContainer container,
  TodoTask t, {
  double width = kTodoEditPanelWidth,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: 800,
              child: TodoEditPanel(
                key: ValueKey(t.id + t.recurrence.toStorage()),
                task: t,
                listColor: 0xFF3366FF,
                onClose: () {},
                onChanged: () {},
                onDeleted: () {},
                onToggleStar: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('reset sits at the right edge with repeat beside the pill', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = await _container();
    await _pumpPanel(
      tester,
      container,
      task(dueDate: DateTime(2026, 3, 2, 9, 30).toUtc()),
    );
    expect(tester.takeException(), isNull);

    final panelRect = tester.getRect(find.byType(TodoEditPanel));
    final pill = tester.getRect(find.textContaining('Mar 2'));
    final repeat = tester.getRect(find.byIcon(PhosphorIconsRegular.repeat));
    final reset = tester.getRect(find.text('Reset due date'));

    // Left to right: pill, repeat, then a gap, then reset.
    expect(pill.right, lessThanOrEqualTo(repeat.left + 1));
    expect(repeat.right, lessThanOrEqualTo(reset.left + 1));

    // Reset is right-aligned: it ends against the panel's content edge, and
    // there is real space between it and the repeat toggle.
    expect(reset.right, greaterThan(repeat.right + 40));
    expect(panelRect.right - reset.right, lessThan(32));

    // All three share the row.
    expect((pill.center.dy - repeat.center.dy).abs(), lessThan(24));
    expect((reset.center.dy - repeat.center.dy).abs(), lessThan(24));
  });

  testWidgets('the repeat toggle is present with no due date, reset is not', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = await _container();
    await _pumpPanel(tester, container, task());
    expect(tester.takeException(), isNull);

    expect(find.byIcon(PhosphorIconsRegular.repeat), findsOneWidget);
    expect(find.text('Reset due date'), findsNothing);
    expect(find.text('Set date & time'), findsOneWidget);
  });

  testWidgets('the row still fits at the narrowest supported panel width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = await _container();
    await _pumpPanel(
      tester,
      container,
      task(dueDate: DateTime(2026, 12, 22, 14, 45).toUtc()),
      width: kTodoRowMinWidth,
    );
    expect(tester.takeException(), isNull);

    final panelRect = tester.getRect(find.byType(TodoEditPanel));
    final reset = tester.getRect(find.text('Reset due date'));
    expect(reset.right, lessThanOrEqualTo(panelRect.right));
    expect(
      tester.getRect(find.byIcon(PhosphorIconsRegular.repeat)).right,
      lessThanOrEqualTo(reset.left + 1),
    );
  });
}
