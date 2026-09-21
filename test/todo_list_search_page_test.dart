// The Todo page's ephemeral list search, driven through the real page
// (TODO_LIST_SEARCH_HLD.md): how it opens, what it hides, and the page
// behaviour a live filter changes — reorder, the edit panel, the composer.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_edit_panel.dart';
import 'package:voyager/features/todo/todo_list_search_bar.dart';

import 'support/todo_page_harness.dart';

/// A matched title is rich text (its hit is emphasised), which `find.text`
/// only sees with [findRichText].
Finder _row(String title) => _inList(find.text(title, findRichText: true));

/// [inner], restricted to the part of the page that is not the edit panel.
///
/// A search opens its top match in the panel, so a matched title is on screen
/// twice — once as a row, once in the panel's own title field — and a bare
/// `find.text` no longer says which of the two a test means. The panel also
/// shows the match's subtasks and its list, so those collide as well.
Finder _inList(Finder inner) {
  return find.byElementPredicate((element) {
    if (!inner.evaluate().contains(element)) return false;
    var inPanel = false;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget is TodoEditPanel) {
        inPanel = true;
        return false;
      }
      return true;
    });
    return !inPanel;
  }, description: 'outside the edit panel');
}

Future<void> _pressCtrlF(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// Types [query] into the open search bar and waits out the debounce.
Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(
    find.descendant(
      of: find.byType(TodoListSearchBar),
      matching: find.byType(TextField),
    ),
    query,
  );
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 200));
}

/// The composer at the bottom of the page — the only [LabeledTextField] on it
/// while the edit panel is closed.
Finder get _composer => find.descendant(
  of: find.byType(LabeledTextField),
  matching: find.byType(TextField),
);

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('Ctrl+F opens the bar; Esc closes it and drops the filter', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 4, done: 0);
    expect(find.byType(TodoListSearchBar), findsNothing);

    await _pressCtrlF(tester);
    expect(find.byType(TodoListSearchBar), findsOneWidget);

    // Deliberately not the whole title: the query lives in the bar's own
    // field, and a findRichText search would match that too.
    await _search(tester, '2');
    expect(_row('Task 2'), findsOneWidget);
    expect(find.text('Task 0'), findsNothing);
    expect(find.text('1 match'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(TodoListSearchBar), findsNothing);
    expect(find.text('Task 0'), findsOneWidget);
    // Still one *row*: the panel the search landed on stays open past the
    // close, so the title is also in its field.
    expect(_row('Task 2'), findsOneWidget);
  });

  testWidgets('the × button closes the bar the same way Esc does', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 4, done: 0);
    await _pressCtrlF(tester);
    await _search(tester, '2');
    expect(find.text('Task 0'), findsNothing);

    await tester.tap(find.byTooltip('Close search'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(TodoListSearchBar), findsNothing);
    expect(find.text('Task 0'), findsOneWidget);
  });

  testWidgets('Ctrl+F on an open bar selects the query it already has', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 4, done: 0);
    await _pressCtrlF(tester);
    await _search(tester, '2');

    await _pressCtrlF(tester);
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(TodoListSearchBar),
        matching: find.byType(TextField),
      ),
    );
    // Selected, not cleared: the next keystroke replaces the old query.
    expect(field.controller!.selection.textInside(field.controller!.text), '2');
    expect(find.byType(TodoListSearchBar), findsOneWidget);
  });

  testWidgets('switching to the all-tasks view clears the filter', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 3, done: 0, seedSecondList: true);
    await _pressCtrlF(tester);
    await _search(tester, '1');
    expect(find.text('Task 0'), findsNothing);

    await tester.tap(find.text('Harness'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All tasks'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(TodoListSearchBar), findsNothing);
    expect(find.text('Task 0'), findsOneWidget);
    expect(find.text('Second Task 1'), findsOneWidget);
  });

  testWidgets('a query filters both sections and counts the matches', (
    tester,
  ) async {
    // Task 0-2 active, Task 3-4 completed. "Task " matches everything; "3"
    // only the completed one.
    await pumpTodoPage(tester, active: 3, done: 2);
    await _pressCtrlF(tester);
    await _search(tester, '3');

    expect(_row('Task 3'), findsOneWidget);
    expect(find.text('Task 0'), findsNothing);
    expect(find.text('1 match'), findsOneWidget);
    // The section header counts what it is actually showing.
    expect(find.text('Completed (1)'), findsOneWidget);
  });

  testWidgets('notes and subtasks surface the parent row', (tester) async {
    await pumpTodoPage(
      tester,
      active: 3,
      done: 0,
      withNotes: const {'task-00001'},
      seedExtra: (repo) async {
        final now = DateTime.now().toUtc();
        await repo.upsertTask(
          TodoTask(
            id: 'sub-1',
            listId: todoHarnessListId,
            parentTaskId: 'task-00002',
            title: 'buy oat milk',
            createdAt: now,
            updatedAt: now,
          ),
        );
      },
    );

    await _pressCtrlF(tester);
    await _search(tester, 'milk');
    // The subtask is not a row of its own — its parent stands in for it, and
    // its title carries no highlight because nothing in it matched.
    expect(_row('Task 2'), findsOneWidget);
    expect(_inList(find.text('buy oat milk')), findsNothing);
    expect(find.text('Task 0'), findsNothing);

    await _search(tester, 'a note');
    expect(_row('Task 1'), findsOneWidget);
    expect(find.text('Task 2'), findsNothing);
  });

  testWidgets('no matches shows the empty state', (tester) async {
    await pumpTodoPage(tester, active: 3, done: 0);
    await _pressCtrlF(tester);
    await _search(tester, 'nothing here');

    expect(find.text('No tasks match'), findsOneWidget);
    expect(find.text('0 matches'), findsOneWidget);
    expect(find.text('Task 0'), findsNothing);
  });

  testWidgets('hidden completed tasks are not searched', (tester) async {
    // Task 0-1 active, Task 2-3 completed but hidden by the setting, so the
    // only rows a query could match are the active ones.
    await pumpTodoPage(tester, active: 2, done: 2, hideCompleted: true);
    await _pressCtrlF(tester);
    await _search(tester, '3');

    expect(find.text('No tasks match'), findsOneWidget);
    expect(find.text('0 matches'), findsOneWidget);
  });

  testWidgets('a filtered all-tasks row names the list it belongs to', (
    tester,
  ) async {
    await pumpTodoPage(
      tester,
      active: 2,
      done: 0,
      seedSecondList: true,
      showAllTasks: true,
    );
    await _pressCtrlF(tester);
    // A substring, so the query in the bar's own field is not itself a
    // match for the badge text this asserts on.
    await _search(tester, 'econd');

    expect(_row('Second Task 1'), findsOneWidget);
    expect(
      _inList(find.text(todoHarnessSecondListName)),
      findsOneWidget,
      reason: 'the badge says which list the match came from',
    );
    expect(find.text('Task 0'), findsNothing);
  });

  testWidgets('drag-reorder is off while a filter is applied', (tester) async {
    await pumpTodoPage(tester, active: 4, done: 0);
    expect(find.byType(SliverReorderableList), findsOneWidget);

    await _pressCtrlF(tester);
    await _search(tester, 'Task');
    expect(
      find.byType(SliverReorderableList),
      findsNothing,
      reason: 'a filtered list has no manual order to drag rows into',
    );

    await _search(tester, '');
    expect(find.byType(SliverReorderableList), findsOneWidget);
  });

  testWidgets('the edit panel closes when nothing matches at all', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 4, done: 0);
    await tester.tap(find.text('Task 0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TodoEditPanel), findsOneWidget);

    await _pressCtrlF(tester);
    await _search(tester, 'zzz');
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(TodoEditPanel), findsNothing);
  });

  testWidgets('a query opens the top match in the edit panel', (tester) async {
    await pumpTodoPage(tester, active: 4, done: 0);
    expect(find.byType(TodoEditPanel), findsNothing);

    await _pressCtrlF(tester);
    await _search(tester, '2');
    await tester.pump(const Duration(milliseconds: 400));

    expect(_panelTaskTitle(tester), 'Task 2');
  });

  testWidgets('a task the panel was open on is replaced by the top match', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 4, done: 0);
    await tester.tap(find.text('Task 0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_panelTaskTitle(tester), 'Task 0');

    await _pressCtrlF(tester);
    await _search(tester, '3');
    await tester.pump(const Duration(milliseconds: 400));

    expect(_panelTaskTitle(tester), 'Task 3');
  });

  testWidgets('Enter walks the panel through the matches', (tester) async {
    await pumpTodoPage(tester, active: 4, done: 0);
    await _pressCtrlF(tester);
    await _search(tester, 'Task');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_panelTaskTitle(tester), 'Task 0');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_panelTaskTitle(tester), 'Task 1');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_panelTaskTitle(tester), 'Task 0');
  });

  testWidgets('a burst of Enters lands the panel on the last match', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 8, done: 0);
    await _pressCtrlF(tester);
    await _search(tester, 'Task');
    expect(_panelTaskTitle(tester), 'Task 0');

    // Faster than the walk window, i.e. what a held Enter looks like. The
    // panel deliberately doesn't follow every one of these — rebuilding it is
    // most of what a step costs — so only the match the walk ends on matters.
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(_panelTaskTitle(tester), 'Task 4');
  });

  testWidgets('clicking a match moves the Enter cursor onto it', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 4, done: 0);
    await _pressCtrlF(tester);
    await _search(tester, 'Task');
    await tester.pump(const Duration(milliseconds: 400));
    expect(activeMatchRowTitle(tester), 'Task 0');

    await tester.tap(_row('Task 2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(activeMatchRowTitle(tester), 'Task 2');

    // Enter resumes from the clicked row rather than from where the walk had
    // reached, so the ring and the panel never name two different tasks.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(activeMatchRowTitle(tester), 'Task 3');
    expect(_panelTaskTitle(tester), 'Task 3');
  });

  testWidgets('closing the bar leaves the panel search landed on open', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 4, done: 0);
    await _pressCtrlF(tester);
    await _search(tester, '1');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_panelTaskTitle(tester), 'Task 1');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(TodoListSearchBar), findsNothing);
    expect(_panelTaskTitle(tester), 'Task 1');
  });

  testWidgets('/search in the composer hands off with its query', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 4, done: 0);

    await tester.enterText(_composer, '/search 3');
    await tester.pump();

    expect(find.byType(TodoListSearchBar), findsOneWidget);
    // Nothing was submitted as a task, and the composer is empty again.
    expect(tester.widget<TextField>(_composer).controller!.text, isEmpty);
    expect(_row('Task 3'), findsOneWidget);
    expect(find.text('Task 0'), findsNothing);
  });

  testWidgets('/searchmilk is an ordinary task title', (tester) async {
    await pumpTodoPage(tester, active: 2, done: 0);

    await tester.enterText(_composer, '/searchmilk');
    await tester.pump();

    expect(find.byType(TodoListSearchBar), findsNothing);
    expect(tester.widget<TextField>(_composer).controller!.text, '/searchmilk');
  });

  testWidgets('switching list clears the filter and closes the bar', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 3, done: 0, seedSecondList: true);
    await _pressCtrlF(tester);
    await _search(tester, '1');
    expect(find.text('Task 0'), findsNothing);

    await tester.tap(find.text('Harness'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(todoHarnessSecondListName).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(TodoListSearchBar), findsNothing);
    expect(find.text('Second Task 1'), findsOneWidget);
  });

  testWidgets('Enter walks to the next match and Shift+Enter back', (
    tester,
  ) async {
    await pumpTodoPage(tester, active: 4, done: 0);
    await _pressCtrlF(tester);
    await _search(tester, 'Task');

    await tester.pump(const Duration(milliseconds: 400));

    // The first match wears the active ring from the start; Enter moves it on
    // and Shift+Enter brings it back, wrapping at both ends.
    expect(activeMatchRowTitle(tester), 'Task 0');

    // Settled after each step, not pumped once: the step also moves the edit
    // panel onto the new match (a post-frame callback), and mid-flight the
    // row wearing the selection and the row wearing the ring are two
    // different tasks — which [activeMatchRowTitle] cannot tell apart.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(activeMatchRowTitle(tester), 'Task 1');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(activeMatchRowTitle(tester), 'Task 0');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      activeMatchRowTitle(tester),
      'Task 3',
      reason: 'stepping back from the first match wraps to the last',
    );
  });
}

/// The title of the task the edit panel is showing, or null when it is closed.
String? _panelTaskTitle(WidgetTester tester) {
  final panels = find.byType(TodoEditPanel).evaluate();
  if (panels.isEmpty) return null;
  return (panels.first.widget as TodoEditPanel).task.title;
}

/// The title of the row currently wearing the active-match ring, found by the
/// only decoration on the page whose fill is not one of the resting surfaces —
/// the ring's accent wash.
String? activeMatchRowTitle(WidgetTester tester) {
  for (final element in find.byType(AnimatedContainer).evaluate()) {
    final container = element.widget as AnimatedContainer;
    final decoration = container.decoration as BoxDecoration?;
    final border = decoration?.border;
    if (border is! Border) continue;
    // The accent ring is the only opaque-ish coloured border a row wears in a
    // test theme; resting rows use a 6%-alpha onSurface hairline.
    if (border.top.color.a < 0.4) continue;
    final title = find.descendant(
      of: find.byWidget(container),
      matching: find.byType(Text),
    );
    final texts = title.evaluate().toList();
    if (texts.isEmpty) continue;
    final widget = texts.first.widget as Text;
    return widget.data ?? widget.textSpan?.toPlainText();
  }
  return null;
}
