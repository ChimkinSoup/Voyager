import 'dart:async';

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/features/gaia/companion/settings/gaia_memories_tab.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';
import 'package:voyager/features/gaia/utility/gaia_utility.dart';

import 'fakes/gaia_fakes.dart';

/// The settings panel's Memories tab (GAIA_SETTINGS_HLD.md Phase 4): topics
/// browsed by breadcrumb and chips in one scroll, cards edited in place,
/// topic actions, drag, the inbox and Sort these, and the recall and inbox
/// chips opening it with no round trip to Voyager.
void main() {
  final at = DateTime.utc(2026, 11, 23);

  GaiaChat chat(String id, String title) => GaiaChat(
    id: id,
    title: title,
    createdAt: at,
    updatedAt: at,
    lastMessageAt: at,
    tier: GaiaTier.standard,
  );

  GaiaMemoryTopic topic(
    String id,
    String name, {
    String? parentId,
    String? projectId,
  }) => GaiaMemoryTopic(
    id: id,
    name: name,
    parentId: parentId,
    projectId: projectId,
    createdAt: at,
    updatedAt: at,
  );

  GaiaMemory memory(
    String id,
    String text, {
    GaiaMemoryStatus status = GaiaMemoryStatus.active,
    List<String> topicIds = const [],
    bool pinned = false,
    String? sourceChatId,
    List<String> tags = const [],
    GaiaSuggestedTopic? suggestedTopic,
  }) => GaiaMemory(
    id: id,
    createdAt: at,
    updatedAt: at,
    text: text,
    status: status,
    topicIds: topicIds,
    pinned: pinned,
    sourceChatId: sourceChatId,
    tags: tags,
    suggestedTopic: suggestedTopic,
  );

  late List<(String, Map<String, Object?>)> requests;
  late List<GaiaMemory> memories;
  late List<GaiaMemoryTopic> topics;
  late List<GaiaMergeSuggestion> merges;
  late List<GaiaPinSuggestion> pins;

  /// Requests the main instance refuses, by method, with what it says.
  late Map<String, String> refuse;

  /// The `memories` answer waits for this, when set.
  Future<void>? memoriesHeld;
  late FakeGaiaPipe main;
  TestGesture? hovering;

  List<Map<String, Object?>> sent(String method) => [
    for (final (m, params) in requests)
      if (m == method) params,
  ];

  Future<GaiaController> pump(
    WidgetTester tester, {
    GaiaUtility? utility,
  }) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    requests = [];
    refuse = {};
    memoriesHeld = null;
    topics = [
      topic('t1', 'School'),
      topic('t2', 'CS246', parentId: 't1'),
      topic('t3', 'Food'),
      topic('tp', 'Trip', projectId: 'p1'),
    ];
    memories = [
      memory(
        'm1',
        'Assignment 3 is due Friday',
        topicIds: ['t2'],
        sourceChatId: 'c1',
        tags: ['school'],
      ),
      memory('m2', 'I like green tea', topicIds: ['t3'], pinned: true),
      memory('m3', 'I prefer metric units'),
      memory(
        'm4',
        'Old locker code 1234',
        status: GaiaMemoryStatus.archived,
        topicIds: ['t1'],
      ),
      memory(
        'm5',
        'I like naps',
        status: GaiaMemoryStatus.proposed,
        sourceChatId: 'c2',
      ),
      memory('m6', 'Pack sunscreen', topicIds: ['tp']),
    ];
    merges = [];
    pins = [];
    late FakeGaiaPipe companion;
    main = FakeGaiaPipe.main()
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        requests.add((method, params));
        if (refuse[method] case final why?) throw GaiaPipeException(why);
        switch (method) {
          case 'hello':
            return {
              'aborted': false,
              'accent': 0xFF7C9EFF,
              'deviceId': 'laptop',
              'settings': GaiaSettings.initial().toJson(),
              'inbox': 120,
            };
          case 'chats':
            return [
              chat('c1', 'Parser').toJson(),
              chat('c2', 'Errands').toJson(),
            ];
          case 'messages':
          case 'drafts':
          case 'btws':
          case 'queue':
            return <Object?>[];
          case 'memories':
            if (memoriesHeld case final held?) await held;
            return gaiaMemoryListToJson((
              memories: memories,
              topics: topics,
              projects: {'p1'},
              pins: pins,
              merges: merges,
            ));
          case 'memoryTopics':
            return gaiaTopicLinesToJson(gaiaTopicLines(GaiaTopicTree(topics)));
          case 'newTopic':
            final made = topic(
              'new',
              params['name']! as String,
              parentId: params['parentId'] as String?,
            );
            topics = [...topics, made];
            return made.id;
          case 'decideMemory':
            return {
              'id': params['memoryId'],
              'state': 'accepted',
              'text': params['text'],
            };
          case 'placedMemory':
            return gaiaMemoryFilingToJson((topics: const [], suggested: null));
        }
        return null;
      };
    await main.startCompanion();
    final controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {kGaiaClaudeCodeAdapter: FakeClaudeRunner()},
      cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
      exit: (_) {},
      utility: utility,
      panel: GaiaSettingsPanel()..tab = GaiaPanelTab.memories,
    );
    await tester.runAsync(() async {
      await controller.start();
      await controller.openWindow();
      await controller.selectChat('c1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    return controller;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> open(WidgetTester tester, GaiaController controller) async {
    await tester.runAsync(() => controller.openPanel());
    await settle(tester);
  }

  Finder inTab(Finder finder) =>
      find.descendant(of: find.byType(GaiaMemoriesTab), matching: finder);

  /// A topic's chip in the strip.
  Finder chip(String id) => inTab(find.byKey(ValueKey(id)));

  /// A mouse over [finder], so a card shows its hover actions: one mouse
  /// for the test.
  Future<TestGesture> hover(WidgetTester tester, Finder finder) async {
    var mouse = hovering;
    if (mouse == null) {
      mouse = hovering = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(() {
        hovering = null;
        return mouse!.removePointer();
      });
    }
    await mouse.moveTo(tester.getCenter(finder));
    await tester.pump(const Duration(milliseconds: 300));
    return mouse;
  }

  Future<void> rightClick(WidgetTester tester, Finder finder) async {
    final mouse = await tester.startGesture(
      tester.getCenter(finder),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.up();
    // The rows grow in one after another.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('one scroll: breadcrumb and chips browse topics without a '
      'tree, and the memories narrow to the topic in view', (tester) async {
    final controller = await pump(tester);
    await open(tester, controller);
    expect(sent('memories'), isNotEmpty);
    // One vertical scroll in the tab: nothing scrolls on its own.
    expect(
      inTab(
        find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      ),
      findsOneWidget,
    );
    expect(inTab(find.text('All memories')), findsOneWidget);
    // Root chips with what they hold, Unsorted, and + Topic.
    expect(chip('t1'), findsOneWidget);
    expect(chip('t3'), findsOneWidget);
    expect(inTab(find.text('Unsorted')), findsOneWidget);
    expect(inTab(find.text('+ Topic')), findsWidgets);
    expect(chip('t2'), findsNothing);
    // The inbox across every topic, pinned, remembered, archived folded.
    expect(inTab(find.text('Inbox (1)')), findsOneWidget);
    expect(inTab(find.text('Pinned (1)')), findsOneWidget);
    expect(inTab(find.text('Remembered (3)')), findsOneWidget);
    expect(inTab(find.text('Archived (1)')), findsOneWidget);
    expect(inTab(find.text('Old locker code 1234')), findsNothing);
    await tester.tap(inTab(find.text('Show')));
    await tester.pump();
    expect(inTab(find.text('Old locker code 1234')), findsOneWidget);

    await tester.tap(chip('t1'));
    await tester.pump();
    // School › its subtopic's memory, and the archived one in School.
    expect(chip('t2'), findsOneWidget);
    expect(inTab(find.text('Assignment 3 is due Friday')), findsOneWidget);
    expect(inTab(find.text('I like green tea')), findsNothing);
    // The inbox folds in a topic, so its own memories aren't buried.
    expect(inTab(find.text('Inbox (1)')), findsOneWidget);
    expect(inTab(find.text('I like naps')), findsNothing);
    await tester.tap(inTab(find.text('Show')).first);
    await tester.pump();
    expect(inTab(find.text('I like naps')), findsOneWidget);
    // Without its subtopics, only School's own.
    await tester.tap(inTab(find.text('Include subtopics')));
    await tester.pump();
    expect(inTab(find.text('Assignment 3 is due Friday')), findsNothing);
    await tester.tap(inTab(find.text('Include subtopics')));
    await tester.pump();

    await tester.tap(chip('t2'));
    await tester.pump();
    expect(inTab(find.text('School')), findsOneWidget); // the crumb
    await tester.tap(inTab(find.text('School')));
    await tester.pump();
    await tester.tap(inTab(find.text('All memories')));
    await tester.pump();
    await tester.tap(inTab(find.text('Unsorted')));
    await tester.pump();
    expect(inTab(find.text('I prefer metric units')), findsOneWidget);
    expect(inTab(find.text('Pack sunscreen')), findsNothing);
  });

  testWidgets('search filters memories, tags and topic names, and the chips', (
    tester,
  ) async {
    final controller = await pump(tester);
    await open(tester, controller);
    await tester.enterText(inTab(find.byType(EditableText)).first, 'tea');
    await tester.pump();
    expect(inTab(find.text('I like green tea')), findsOneWidget);
    expect(inTab(find.text('Pack sunscreen')), findsNothing);
    expect(chip('t1'), findsNothing);
    expect(chip('t3'), findsOneWidget);
    await tester.enterText(inTab(find.byType(EditableText)).first, 'school');
    await tester.pump();
    // By tag, and by topic name.
    expect(inTab(find.text('Assignment 3 is due Friday')), findsOneWidget);
    expect(chip('t1'), findsOneWidget);
  });

  testWidgets("Ctrl+F is the tab's search, not Gaia's; Esc clears it, lets "
      'go of it, then closes the panel; F2 renames the topic in view', (
    tester,
  ) async {
    final controller = await pump(tester);
    await open(tester, controller);
    Future<void> ctrl(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 300));
    }

    await ctrl(LogicalKeyboardKey.keyF);
    final search = tester.state<EditableTextState>(
      inTab(find.byType(EditableText)).first,
    );
    expect(search.widget.focusNode.hasFocus, isTrue);
    await tester.enterText(inTab(find.byType(EditableText)).first, 'tea');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(search.widget.controller.text, isEmpty);
    expect(controller.panel.open, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(search.widget.focusNode.hasFocus, isFalse);
    expect(controller.panel.open, isTrue);

    await tester.tap(chip('t3'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    await tester.enterText(inTab(find.byType(EditableText)).at(1), 'Cooking');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(sent('renameTopic').single, {'topicId': 't3', 'name': 'Cooking'});

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(controller.panel.open, isFalse);
  });

  testWidgets('a card edits in place: Enter saves text and tags, Esc cancels', (
    tester,
  ) async {
    final controller = await pump(tester);
    await open(tester, controller);
    await tester.tap(inTab(find.text('I prefer metric units')));
    await tester.pump();
    final fields = inTab(find.byType(EditableText));
    // The search, then the text and its tags.
    await tester.enterText(fields.at(1), 'I prefer metric units, always');
    await tester.enterText(fields.at(2), 'units, Measure');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(sent('editMemory').single, {
      'memoryId': 'm3',
      'text': 'I prefer metric units, always',
      'tags': ['units', ' Measure'],
    });

    await tester.tap(inTab(find.text('Pack sunscreen')));
    await tester.pump();
    await tester.enterText(inTab(find.byType(EditableText)).at(1), 'nope');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(sent('editMemory'), hasLength(1));
    expect(controller.panel.open, isTrue);

    // A refusal says why.
    refuse['editMemory'] = 'Already remembered: I like green tea';
    await tester.tap(inTab(find.text('Pack sunscreen')));
    await tester.pump();
    await tester.enterText(inTab(find.byType(EditableText)).at(1), 'tea');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.text('Already remembered: I like green tea'), findsOneWidget);
  });

  testWidgets("a card's topics: a click takes one out, + Topic adds one from "
      'the picker or makes a new one', (tester) async {
    final controller = await pump(tester);
    await open(tester, controller);
    await tester.tap(inTab(find.text('School › CS246')));
    await settle(tester);
    expect(sent('removeMemoryTopic').single, {
      'memoryId': 'm1',
      'topicId': 't2',
    });

    // + Topic on Pack sunscreen's card: the picker, by path.
    final plus = inTab(find.text('+ Topic'));
    // The strip's + Topic is first; the cards' follow in list order.
    await tester.tap(plus.last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Add to topic'), findsOneWidget);
    // Not the topic it's in already: that's only its own chip, behind.
    expect(find.text('School › CS246'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).last, 'foo');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(sent('addMemoryTopic').single, {'memoryId': 'm1', 'topicId': 't3'});

    await tester.tap(plus.last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(EditableText).last, 'Exams');
    await tester.pump();
    expect(find.text('New topic: Exams'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(sent('newTopic').single, {'name': 'Exams'});
    expect(sent('addMemoryTopic').last['topicId'], 'new');
  });

  testWidgets('hover actions: Remember, Archive, pin with its refusal, and '
      'Delete with a toast that undoes', (tester) async {
    final controller = await pump(tester);
    await open(tester, controller);
    await hover(tester, inTab(find.text('I like naps')));
    await tester.tap(inTab(find.byTooltip('Remember')));
    await settle(tester);
    expect(sent('decideMemory').single, {
      'memoryId': 'm5',
      'accept': true,
      'text': 'I like naps',
    });

    await hover(tester, inTab(find.text('Pack sunscreen')));
    await tester.tap(inTab(find.byTooltip('Archive')).hitTestable());
    await settle(tester);
    expect(sent('archiveMemory').single, {'memoryId': 'm6'});

    refuse['pinMemory'] = 'Pinned memories are over the budget.';
    await hover(tester, inTab(find.text('Pack sunscreen')));
    await tester.tap(inTab(find.byTooltip('Pin to every chat')).hitTestable());
    await settle(tester);
    expect(find.text('Pinned memories are over the budget.'), findsOneWidget);

    await hover(tester, inTab(find.text('Pack sunscreen')));
    await tester.tap(inTab(find.byTooltip('Delete')).hitTestable());
    await settle(tester);
    expect(sent('deleteMemory').single, {'memoryId': 'm6'});
    expect(find.text('Click to undo.'), findsOneWidget);
    await tester.tap(find.text('Click to undo.'));
    await settle(tester);
    expect(sent('undeleteMemory').single, {'memoryId': 'm6'});
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("a topic chip's menu: rename in place, move under, merge "
      "into and delete, confirmed; a project's topic can't be merged away or "
      'deleted', (tester) async {
    final controller = await pump(tester);
    await open(tester, controller);
    await rightClick(tester, chip('t3'));
    await tester.tap(find.text('Rename'));
    await tester.pump();
    await tester.enterText(inTab(find.byType(EditableText)).at(1), 'Cooking');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(sent('renameTopic').single, {'topicId': 't3', 'name': 'Cooking'});

    await rightClick(tester, chip('t3'));
    await tester.tap(find.text('Move under…'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Top level'), findsOneWidget);
    await tester.tap(find.text('School').last);
    await settle(tester);
    expect(sent('moveTopic').single, {'topicId': 't3', 'parentId': 't1'});

    await rightClick(tester, chip('t3'));
    await tester.tap(find.text('Merge into…'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('School › CS246').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Merge "Food" into "School › CS246"?'), findsOneWidget);
    await tester.tap(find.text('Merge'));
    await settle(tester);
    expect(sent('mergeTopic').single, {'topicId': 't3', 'intoId': 't2'});
    // It shows the topic merged into, as the page does.
    expect(inTab(find.text('CS246')), findsOneWidget);
    await tester.tap(inTab(find.text('All memories')));
    await tester.pump();

    await rightClick(tester, chip('t1'));
    await tester.tap(find.text('Delete'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.textContaining('Its subtopics move up to the top level'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(sent('deleteTopic'), isEmpty);

    await rightClick(tester, chip('tp'));
    expect(find.text('Merge into…'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    expect(
      find.textContaining("A project's topic", findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('+ Topic in the strip names a new topic under the one in view', (
    tester,
  ) async {
    final controller = await pump(tester);
    await open(tester, controller);
    await tester.tap(chip('t1'));
    await tester.pump();
    await tester.tap(inTab(find.text('+ Subtopic')));
    await tester.pump();
    await tester.enterText(inTab(find.byType(EditableText)).at(1), 'Exams');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(sent('newTopic').single, {'name': 'Exams', 'parentId': 't1'});
  });

  testWidgets('a card dragged onto a chip moves there, from the topics in '
      'view; with Ctrl it is added', (tester) async {
    final controller = await pump(tester);
    await open(tester, controller);
    await tester.tap(chip('t1'));
    await tester.pump();

    Future<void> drag({bool ctrl = false}) async {
      final mouse = await tester.startGesture(
        tester.getCenter(inTab(find.text('Assignment 3 is due Friday'))),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(0, 30));
      await tester.pump();
      await mouse.moveTo(tester.getCenter(chip('t2')));
      await tester.pump();
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await mouse.up();
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
    }

    await drag();
    expect(sent('moveMemory').single, {
      'memoryId': 'm1',
      'topicId': 't2',
      'within': unorderedEquals(['t1', 't2']),
    });
    await drag(ctrl: true);
    expect(sent('addMemoryTopic').single, {'memoryId': 'm1', 'topicId': 't2'});
  });

  testWidgets('pin and merge suggestions in the inbox', (tester) async {
    final controller = await pump(tester);
    pins = [(memory: memories[2], why: 'recalled in 8 of 10 chats')];
    merges = [(from: topics[2], into: topics[0], why: 'they share 3 memories')];
    await open(tester, controller);
    expect(inTab(find.text('Inbox (3)')), findsOneWidget);
    expect(inTab(find.text('Merge "Food" into "School"?')), findsOneWidget);
    await tester.tap(inTab(find.text('Keep both')));
    await settle(tester);
    expect(sent('keepApart').single, {'topicId': 't3', 'intoId': 't1'});
    await tester.tap(inTab(find.text('Merge')));
    await settle(tester);
    expect(sent('mergeTopic').single, {'topicId': 't3', 'intoId': 't1'});
    expect(
      inTab(find.text('Pin this? recalled in 8 of 10 chats.')),
      findsOneWidget,
    );
    await tester.tap(inTab(find.text('Not now')));
    await settle(tester);
    expect(sent('pinLater').single, {'memoryId': 'm3'});
    await tester.tap(inTab(find.text('Pin')));
    await settle(tester);
    expect(sent('pinMemory').single, {'memoryId': 'm3', 'pinned': true});
  });

  testWidgets("Unsorted's Sort these shows where each would go, and Accept "
      'files it', (tester) async {
    final runner = FakeUtilityRunner(
      (job) => job.startsWith('File each fact')
          ? '[{"n": 1, "topics": ["t3"], "new": null, "tags": ["si"]}]'
          : '{"topics": [], "new": null, "tags": []}',
    );
    final controller = await pump(tester, utility: GaiaUtility(runner));
    await open(tester, controller);
    await tester.tap(inTab(find.text('Unsorted')));
    await tester.pump();
    await tester.tap(inTab(find.text('Sort these')));
    await settle(tester);
    expect(inTab(find.text('Suggested:')), findsOneWidget);
    expect(inTab(find.text('Food')), findsOneWidget);
    await tester.tap(inTab(find.text('Accept')));
    await settle(tester);
    expect(sent('placedMemory').single, {
      'memoryId': 'm3',
      'placement': {
        'topicIds': ['t3'],
        'suggested': null,
        'tags': ['si'],
      },
    });
    expect(inTab(find.text('Suggested:')), findsNothing);
  });

  testWidgets("Sort these leaves out Unsorted's archived memories while "
      'they are folded away', (tester) async {
    final runner = FakeUtilityRunner((_) => '[]');
    final controller = await pump(tester, utility: GaiaUtility(runner));
    memories = [
      ...memories,
      memory('a1', 'An archived stray', status: GaiaMemoryStatus.archived),
    ];
    await open(tester, controller);
    await tester.tap(inTab(find.text('Unsorted')));
    await tester.pump();
    await tester.tap(inTab(find.text('Sort these')));
    await settle(tester);
    final sorting = [
      for (final (i, job) in runner.jobs.indexed)
        if (job.startsWith('File each fact')) runner.inputs[i],
    ];
    expect(sorting, isNotEmpty);
    expect(
      sorting.any((input) => input.contains('I prefer metric units')),
      isTrue,
    );
    expect(
      sorting.any((input) => input.contains('An archived stray')),
      isFalse,
    );
  });

  testWidgets('a recall chip opens Memories with that memory shown, from a '
      'floater too, with nothing asked of Voyager', (tester) async {
    final controller = await pump(tester);
    await tester.runAsync(() => controller.onHotkey('small'));
    await tester.pump();
    expect(controller.layout, isNot(GaiaMode.window));
    await tester.runAsync(() => controller.openMemory('m4'));
    await settle(tester);
    expect(controller.layout, GaiaMode.window);
    expect(controller.panel.open, isTrue);
    expect(controller.panel.tab, GaiaPanelTab.memories);
    // Archived, so its section is opened for it.
    expect(inTab(find.text('Old locker code 1234')), findsOneWidget);
    expect(sent('openMemory'), isEmpty);
    expect(controller.revealMemoryId, isNull);
  });

  testWidgets('a revealed memory far down the list is scrolled to, though '
      'cards are built only as they scroll in', (tester) async {
    final controller = await pump(tester);
    memories = [
      memory('old', 'The oldest thing I told Gaia'),
      for (var i = 0; i < 300; i++) memory('f$i', 'Filler memory number $i'),
    ];
    await open(tester, controller);
    // Newest first: the oldest is last, and not built.
    expect(inTab(find.text('The oldest thing I told Gaia')), findsNothing);
    await tester.runAsync(() => controller.openMemory('old'));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await settle(tester);
    expect(
      inTab(find.text('The oldest thing I told Gaia')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('the inbox chip opens Memories at its inbox, from inside a '
      'topic with a search typed', (tester) async {
    final controller = await pump(tester);
    await open(tester, controller);
    await tester.tap(chip('t1'));
    await tester.pump();
    await tester.enterText(inTab(find.byType(EditableText)).first, 'zzz');
    await tester.pump();
    await tester.runAsync(() async => controller.closePanel());
    await settle(tester);
    await tester.runAsync(() => controller.putSettings({'memoryAlertAt': 100}));
    await tester.pump();
    await tester.tap(find.text('120 memories to review'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(controller.panel.open, isTrue);
    expect(controller.panel.tab, GaiaPanelTab.memories);
    // All memories, no search, the inbox open.
    expect(inTab(find.text('zzz')), findsNothing);
    expect(chip('t1'), findsOneWidget);
    expect(inTab(find.text('I like naps')), findsOneWidget);
  });

  testWidgets('a recall chip clears a typed search to show its memory', (
    tester,
  ) async {
    final controller = await pump(tester);
    await open(tester, controller);
    await tester.enterText(inTab(find.byType(EditableText)).first, 'zzz');
    await tester.pump();
    await tester.runAsync(() => controller.openMemory('m6'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(inTab(find.text('Pack sunscreen')), findsOneWidget);
  });

  testWidgets('a recall chip shows a memory remembered since the tab last '
      'read its list', (tester) async {
    final controller = await pump(tester);
    await open(tester, controller);
    await tester.runAsync(() async => controller.closePanel());
    await settle(tester);
    memories = [...memories, memory('fresh', 'Remembered just now')];
    // A frame builds before the list is read again, as across the real pipe.
    final held = Completer<void>();
    memoriesHeld = held.future;
    await tester.runAsync(() => controller.openMemory('fresh'));
    await tester.pump();
    held.complete();
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Not found'), findsNothing);
    expect(inTab(find.text('Remembered just now')), findsOneWidget);
  });

  testWidgets('the memories event reads it again only while it shows', (
    tester,
  ) async {
    final controller = await pump(tester);
    await open(tester, controller);
    final before = sent('memories').length;
    main.notify('memories');
    await settle(tester);
    expect(sent('memories').length, before + 1);
    await tester.runAsync(
      () async => controller.showPanelTab(GaiaPanelTab.queue),
    );
    await settle(tester);
    main.notify('memories');
    await settle(tester);
    expect(sent('memories').length, before + 1);
  });
}
