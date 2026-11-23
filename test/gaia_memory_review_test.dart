import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_memory_review.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';
import 'package:voyager/features/gaia/utility/gaia_utility.dart';

import 'fakes/gaia_fakes.dart';

/// The Memories tab's review (GAIA_SETTINGS_HLD.md Phase 5): decks dealt
/// from the review bar, decided one key at a time, cards decided elsewhere
/// skipped, Ctrl+Z undoing any decision, and the summary at the end. The
/// fake main instance applies each write, as the host would.
void main() {
  final at = DateTime.utc(2026, 11, 23);

  GaiaMemoryTopic topic(String id, String name, {String? parentId}) =>
      GaiaMemoryTopic(
        id: id,
        name: name,
        parentId: parentId,
        createdAt: at,
        updatedAt: at,
      );

  GaiaMemory memory(
    String id,
    String text, {
    GaiaMemoryStatus status = GaiaMemoryStatus.active,
    List<String> topicIds = const [],
    bool pinned = false,
  }) => GaiaMemory(
    id: id,
    createdAt: at,
    updatedAt: at,
    text: text,
    status: status,
    topicIds: topicIds,
    pinned: pinned,
  );

  late List<(String, Map<String, Object?>)> requests;
  late List<GaiaMemory> memories;
  late List<GaiaMemoryTopic> topics;
  late List<GaiaMergeSuggestion> merges;
  late List<GaiaPinSuggestion> pins;
  late Map<String, String> refuse;
  late Map<String, Completer<void>> hold;

  List<Map<String, Object?>> sent(String method) => [
    for (final (m, params) in requests)
      if (m == method) params,
  ];

  GaiaMemory? stored(String id) =>
      memories.where((memory) => memory.id == id).firstOrNull;

  void change(String id, GaiaMemory? Function(GaiaMemory memory) to) {
    memories = [
      for (final memory in memories)
        if (memory.id != id) memory else ?to(memory),
    ];
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// The trash, so a revert can bring one back.
  final trash = <String, GaiaMemory>{};

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
    hold = {};
    trash.clear();
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main()
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        requests.add((method, params));
        if (hold[method] case final gate?) await gate.future;
        if (refuse[method] case final why?) throw GaiaPipeException(why);
        final id = params['memoryId'] as String?;
        switch (method) {
          case 'hello':
            return {
              'aborted': false,
              'accent': 0xFF7C9EFF,
              'deviceId': 'laptop',
              'settings': GaiaSettings.initial().toJson(),
              'inbox': 0,
            };
          case 'chats':
          case 'messages':
          case 'drafts':
          case 'btws':
          case 'queue':
            return <Object?>[];
          case 'memories':
            return gaiaMemoryListToJson((
              memories: memories,
              topics: topics,
              projects: const {},
              pins: pins,
              merges: merges,
            ));
          case 'memoryTopics':
            return gaiaTopicLinesToJson(gaiaTopicLines(GaiaTopicTree(topics)));
          case 'decideMemory':
            if (params['accept'] == true) {
              change(id!, (m) => m.copyWith(status: GaiaMemoryStatus.active));
              if (params['pin'] == true) {
                change(id, (m) => m.copyWith(pinned: true));
              }
              return {'id': id, 'state': 'accepted', 'text': stored(id)!.text};
            }
            trash[id!] = stored(id)!;
            change(id, (_) => null);
            return {'id': id, 'state': 'rejected', 'text': trash[id]!.text};
          case 'deleteMemory':
            trash[id!] = stored(id)!;
            change(id, (_) => null);
          case 'archiveMemory':
            change(id!, (m) => m.copyWith(status: GaiaMemoryStatus.archived));
          case 'pinMemory':
            change(id!, (m) => m.copyWith(pinned: params['pinned'] == true));
            pins = [
              for (final pin in pins)
                if (pin.memory.id != id) pin,
            ];
          case 'pinLater':
            pins = [
              for (final pin in pins)
                if (pin.memory.id != id) pin,
            ];
          case 'mergeTopic':
            merges = [];
            topics = [
              for (final topic in topics)
                if (topic.id != params['topicId']) topic,
            ];
          case 'keepApart':
            merges = [];
          case 'newTopic':
            final made = topic('n${topics.length}', params['name']! as String);
            topics = [...topics, made];
            return made.id;
          case 'addMemoryTopic':
            change(
              id!,
              (m) => m.copyWith(
                topicIds: [...m.topicIds, params['topicId']! as String],
              ),
            );
          case 'deleteTopic':
            final gone = params['topicId']! as String;
            topics = [
              for (final topic in topics)
                if (topic.id != gone) topic,
            ];
            memories = [
              for (final m in memories)
                m.copyWith(topicIds: [...m.topicIds]..remove(gone)),
            ];
          case 'editMemory':
            change(id!, (m) => m.copyWith(text: params['text']! as String));
          case 'revertMemories':
            for (final json in params['memories']! as List) {
              final was = gaiaMemoryFromJson(json! as Map);
              if (stored(was.id) == null) {
                memories = [...memories, was];
              } else {
                change(was.id, (_) => was);
              }
            }
            for (final json in params['topics']! as List) {
              final was = gaiaMemoryTopicFromJson(json! as Map);
              topics = [
                for (final topic in topics)
                  if (topic.id != was.id) topic,
                was,
              ];
            }
          case 'placedMemory':
            final placement = gaiaPlacementFromJson(params['placement']);
            change(id!, (m) => m.copyWith(topicIds: placement.topicIds));
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
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => controller.openPanel());
    await settle(tester);
    return controller;
  }

  setUp(() {
    topics = [topic('t1', 'School'), topic('t2', 'Schools')];
    memories = [];
    merges = [];
    pins = [];
  });

  Finder inReview(Finder finder) =>
      find.descendant(of: find.byType(GaiaMemoryReviewView), matching: finder);

  Future<void> key(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
    bool control = false,
  }) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
  }

  testWidgets('a 30-memory inbox is cleared from the keyboard alone, and '
      'each decision undone with Ctrl+Z', (tester) async {
    memories = [
      for (var i = 0; i < 30; i++)
        memory('p$i', 'Fact $i', status: GaiaMemoryStatus.proposed),
      memory('a1', 'I like tea'),
    ];
    pins = [(memory: memories.last, why: 'About you in general')];
    merges = [(from: topics[1], into: topics[0], why: 'Near-identical names')];
    final controller = await pump(tester);

    expect(find.text('30 in the inbox · 2 suggestions'), findsOneWidget);
    await tester.tap(find.text('Review'));
    await settle(tester);
    expect(inReview(find.text('Fact 0')), findsOneWidget);
    expect(inReview(find.text('1 / 32')), findsOneWidget);

    // Ten each way, oldest first.
    for (var i = 0; i < 30; i++) {
      expect(inReview(find.text('Fact $i')), findsWidgets, reason: 'card $i');
      await key(tester, switch (i % 3) {
        0 => LogicalKeyboardKey.enter,
        1 => LogicalKeyboardKey.keyD,
        _ => LogicalKeyboardKey.arrowRight,
      });
    }
    // Then the pin suggestion, then the merge.
    expect(inReview(find.text('Pin this?')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.enter);
    expect(inReview(find.text('Merge these topics?')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.enter);

    expect(
      inReview(
        find.text(
          '10 remembered · 10 declined · 10 skipped · 1 pinned · '
          '1 merged',
        ),
      ),
      findsOneWidget,
    );
    expect(
      memories.where((m) => m.status == GaiaMemoryStatus.proposed),
      hasLength(10),
    );
    expect(stored('a1')!.pinned, isTrue);
    expect(topics.map((t) => t.id), ['t1']);

    // Ctrl+Z puts each back, last first: the merge, the pin, a skip, a
    // decline, a remember.
    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(topics.map((t) => t.id).toSet(), {'t1', 't2'});
    expect(inReview(find.text('32 / 32')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(stored('a1')!.pinned, isFalse);
    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(inReview(find.text('30 / 32')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(stored('p28')!.status, GaiaMemoryStatus.proposed);
    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(stored('p27')!.status, GaiaMemoryStatus.proposed);
    expect(inReview(find.text('Fact 27')), findsOneWidget);

    // Esc goes back to the list.
    await key(tester, LogicalKeyboardKey.escape);
    expect(controller.review, isNull);
    expect(find.byType(GaiaMemoryReviewView), findsNothing);
    expect(controller.panel.open, isTrue);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Shift+Enter remembers and pins; ← goes back to a decided '
      'card; one decided elsewhere is skipped', (tester) async {
    memories = [
      for (var i = 0; i < 3; i++)
        memory('p$i', 'Fact $i', status: GaiaMemoryStatus.proposed),
    ];
    final controller = await pump(tester);
    await tester.tap(find.text('Review'));
    await settle(tester);

    await key(tester, LogicalKeyboardKey.enter, shift: true);
    expect(stored('p0')!.pinned, isTrue);
    expect(stored('p0')!.status, GaiaMemoryStatus.active);

    // p2 is remembered on another device while p1 is in front.
    change('p2', (m) => m.copyWith(status: GaiaMemoryStatus.active));
    await tester.runAsync(() => controller.writeMemories('memories'));
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(inReview(find.text('2 skipped')), findsNothing);
    expect(inReview(find.text('1 remembered · 1 skipped')), findsOneWidget);

    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(inReview(find.text('Fact 1')), findsOneWidget);
    expect(inReview(find.textContaining('Skipped')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(
      inReview(find.text('Remembered · Ctrl+Z undoes it')),
      findsNothing,
      reason: 'Ctrl+Z undoes the skip, the last decision',
    );
    expect(inReview(find.text('Remembered')), findsOneWidget);

    // Remember and pin, undone: back in the inbox, unpinned.
    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(stored('p0')!.status, GaiaMemoryStatus.proposed);
    expect(stored('p0')!.pinned, isFalse);
    expect(inReview(find.text('Fact 0')), findsOneWidget);
    expect(inReview(find.text('1 / 3')), findsOneWidget);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a refused write puts the card back, saying why', (tester) async {
    memories = [
      memory('p0', 'Fact 0', status: GaiaMemoryStatus.proposed),
      memory('p1', 'Fact 1', status: GaiaMemoryStatus.proposed),
    ];
    final controller = await pump(tester);
    final toasts = <GaiaRunToast>[];
    final listening = controller.toasts.listen(toasts.add);
    addTearDown(listening.cancel);
    await tester.tap(find.text('Review'));
    await settle(tester);

    refuse['decideMemory'] = 'Gaia is aborted. Rearm to save memories.';
    await key(tester, LogicalKeyboardKey.enter);
    expect(inReview(find.text('Fact 0')), findsOneWidget);
    expect(inReview(find.text('1 / 2')), findsOneWidget);
    expect(toasts.single.body, 'Gaia is aborted. Rearm to save memories.');
    expect(stored('p0')!.status, GaiaMemoryStatus.proposed);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('writes refused late put back the earliest card', (tester) async {
    memories = [
      for (var i = 0; i < 4; i++)
        memory('p$i', 'Fact $i', status: GaiaMemoryStatus.proposed),
    ];
    final controller = await pump(tester);
    await tester.tap(find.text('Review'));
    await settle(tester);

    final slow = hold['decideMemory'] = Completer();
    refuse['decideMemory'] = 'Gaia is aborted.';
    await key(tester, LogicalKeyboardKey.enter);
    await key(tester, LogicalKeyboardKey.enter);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(controller.review!.index, 3);
    slow.complete();
    await settle(tester);
    expect(controller.review!.index, 0);
    expect(inReview(find.text('Fact 0')), findsOneWidget);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a topic: keep, archive, delete and pin, each undone', (
    tester,
  ) async {
    memories = [
      memory('a0', 'Fact 0', topicIds: ['t1']),
      memory('a1', 'Fact 1', topicIds: ['t1']),
      memory('a2', 'Fact 2', topicIds: ['t1']),
      memory('a3', 'Fact 3', topicIds: ['t1']),
      memory('x', 'Elsewhere', topicIds: ['t2']),
    ];
    final controller = await pump(tester);
    await tester.tap(find.text('School').first);
    await settle(tester);
    await tester.tap(find.text('Review these (4)'));
    await settle(tester);
    expect(inReview(find.text('Reviewing School')), findsOneWidget);

    await key(tester, LogicalKeyboardKey.keyP);
    expect(stored('a0')!.pinned, isTrue);
    expect(inReview(find.text('1 / 4')), findsOneWidget, reason: 'P stays');
    await key(tester, LogicalKeyboardKey.enter);
    await key(tester, LogicalKeyboardKey.backspace);
    expect(stored('a1')!.status, GaiaMemoryStatus.archived);
    await key(tester, LogicalKeyboardKey.backspace, control: true);
    expect(stored('a2'), isNull);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(
      inReview(find.text('2 kept · 1 archived · 1 deleted')),
      findsOneWidget,
    );

    for (var i = 0; i < 5; i++) {
      await key(tester, LogicalKeyboardKey.keyZ, control: true);
    }
    expect(stored('a2')?.status, GaiaMemoryStatus.active);
    expect(stored('a1')!.status, GaiaMemoryStatus.active);
    expect(stored('a0')!.pinned, isFalse);
    expect(inReview(find.text('Fact 0')), findsOneWidget);
    expect(controller.review!.index, 0);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('E edits in place; the keys are off while it does', (
    tester,
  ) async {
    memories = [memory('p0', 'Fact 0', status: GaiaMemoryStatus.proposed)];
    await pump(tester);
    await tester.tap(find.text('Review'));
    await settle(tester);

    await key(tester, LogicalKeyboardKey.keyE);
    await tester.enterText(inReview(find.byType(EditableText)), 'Fact zero');
    await key(tester, LogicalKeyboardKey.keyD);
    expect(sent('decideMemory'), isEmpty, reason: 'D typed, not decided');
    await key(tester, LogicalKeyboardKey.enter);
    expect(sent('editMemory').single['text'], 'Fact zero');
    expect(sent('decideMemory'), isEmpty, reason: 'Enter saved the edit');
    expect(inReview(find.text('Fact zero')), findsOneWidget);

    await key(tester, LogicalKeyboardKey.keyA);
    expect(sent('decideMemory').single['accept'], isTrue);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('A pressed while an edit is saving remembers the edit', (
    tester,
  ) async {
    memories = [memory('p0', 'Fact 0', status: GaiaMemoryStatus.proposed)];
    await pump(tester);
    await tester.tap(find.text('Review'));
    await settle(tester);

    await key(tester, LogicalKeyboardKey.keyE);
    await tester.enterText(inReview(find.byType(EditableText)), 'Fact zero');
    final saving = hold['editMemory'] = Completer();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await settle(tester);
    expect(sent('decideMemory'), isEmpty, reason: 'waits for the edit');
    saving.complete();
    await settle(tester);
    expect(sent('decideMemory').single['text'], 'Fact zero');
    expect(stored('p0')!.text, 'Fact zero');
    expect(stored('p0')!.status, GaiaMemoryStatus.active);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('an undo refused can be tried again; two quick undos end on '
      'the earlier card', (tester) async {
    memories = [
      for (var i = 0; i < 3; i++)
        memory('p$i', 'Fact $i', status: GaiaMemoryStatus.proposed),
    ];
    final controller = await pump(tester);
    await tester.tap(find.text('Review'));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.backspace);
    await key(tester, LogicalKeyboardKey.backspace);
    expect(stored('p0'), isNull);
    expect(stored('p1'), isNull);

    refuse['revertMemories'] = 'Gaia is aborted.';
    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(stored('p1'), isNull);
    expect(controller.review!.lastDecided, 1, reason: 'still to undo');
    refuse.clear();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    await settle(tester);
    expect(stored('p0')!.status, GaiaMemoryStatus.proposed);
    expect(stored('p1')!.status, GaiaMemoryStatus.proposed);
    expect(controller.review!.index, 0);
    expect(inReview(find.text('Fact 0')), findsOneWidget);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Choose… into a new topic, undone, takes the topic away too', (
    tester,
  ) async {
    memories = [memory('u0', 'Exam on Monday')];
    final runner = FakeUtilityRunner(
      (job) => job.startsWith('File each fact')
          ? '[{"n": 1, "topics": [], "new": null, "tags": []}]'
          : '{"topics": [], "new": null, "tags": []}',
    );
    await pump(tester, utility: GaiaUtility(runner));
    await tester.tap(find.text('Unsorted'));
    await settle(tester);
    await tester.tap(find.text('Review these (1)'));
    await settle(tester);

    await key(tester, LogicalKeyboardKey.keyT);
    await tester.enterText(find.byType(EditableText).last, 'Exams');
    await tester.pump();
    await tester.tap(find.text('New topic: Exams'));
    await settle(tester);
    final made = topics.singleWhere((topic) => topic.name == 'Exams');
    expect(stored('u0')!.topicIds, [made.id]);

    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(stored('u0')!.topicIds, isEmpty);
    expect(topics.where((topic) => topic.name == 'Exams'), isEmpty);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Unsorted dealt while a sort runs asks once it ends', (
    tester,
  ) async {
    memories = [memory('u0', 'Exam on Monday'), memory('u1', 'Buy rice')];
    final runner = FakeUtilityRunner(
      (job) => job.startsWith('File each fact')
          ? '[{"n": 1, "topics": ["t1"], "new": null, "tags": []}]'
          : '{"topics": [], "new": null, "tags": []}',
    );
    final controller = await pump(tester, utility: GaiaUtility(runner));
    final list = controller.memoryList!.memories;
    await tester.runAsync(() async {
      final other = controller.sortMemories([list.last]);
      controller.startReview(GaiaMemoryReview.unsorted(controller));
      await other;
    });
    await settle(tester);
    expect(controller.memorySorted['u0']?.topicIds, ['t1']);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Unsorted: each with a placement asked for ahead, filed '
      'there and undone', (tester) async {
    memories = [
      memory('u0', 'Exam on Monday'),
      memory('u1', 'Buy rice'),
      memory('s', 'Sorted', topicIds: ['t1']),
    ];
    final runner = FakeUtilityRunner(
      (job) => job.startsWith('File each fact')
          ? '[{"n": 1, "topics": ["t1"], "new": null, "tags": ["exam"]}]'
          : '{"topics": [], "new": null, "tags": []}',
    );
    final controller = await pump(tester, utility: GaiaUtility(runner));
    await tester.tap(find.text('Unsorted'));
    await settle(tester);
    await tester.tap(find.text('Review these (2)'));
    await settle(tester);
    expect(controller.memorySorted['u0']?.topicIds, ['t1']);
    expect(inReview(find.text('File it in:')), findsOneWidget);

    await key(tester, LogicalKeyboardKey.enter);
    expect(stored('u0')!.topicIds, ['t1']);
    expect(inReview(find.text('Buy rice')), findsOneWidget);
    expect(
      inReview(find.text('No topic suggested. T to choose.')),
      findsOneWidget,
    );

    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(stored('u0')!.topicIds, isEmpty);
    expect(controller.memorySorted['u0']?.topicIds, ['t1']);
    expect(inReview(find.text('Exam on Monday')), findsOneWidget);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });
}
