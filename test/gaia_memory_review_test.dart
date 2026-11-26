import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_chat_body.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_memory_card.dart';
import 'package:voyager/features/gaia/companion/gaia_memory_review.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/gaia_text_settings.dart';
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
    String? sourceChatId,
  }) => GaiaMemory(
    id: id,
    createdAt: at,
    updatedAt: at,
    text: text,
    status: status,
    topicIds: topicIds,
    pinned: pinned,
    sourceChatId: sourceChatId,
  );

  late List<(String, Map<String, Object?>)> requests;
  late List<GaiaMemory> memories;
  late List<GaiaMemoryTopic> topics;
  late List<GaiaMergeSuggestion> merges;
  late List<GaiaPinSuggestion> pins;
  late List<GaiaMemorySuggestion> suggestions;
  late Set<String> left;

  /// What the main instance answers `sweepPlan` with.
  Map<String, Object?>? sweepPlan;
  late Map<String, String> refuse;
  late Map<String, Completer<void>> hold;
  late List<GaiaChat> chats;
  late Map<String, List<GaiaMessage>> messages;

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

  late FakeClaudeRunner runner;

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
            return [for (final chat in chats) chat.toJson()];
          case 'messages':
            return [
              for (final message in messages[params['chatId']] ?? const [])
                message.toJson(),
            ];
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
              suggestions: suggestions,
              leftUnsorted: left,
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
          case 'offerRevision':
            final arguments = params['arguments']! as Map;
            final was = stored(arguments['id']! as String)!;
            GaiaMemoryTopic? named(String name) =>
                topics.where((topic) => topic.name == name).firstOrNull;
            final changes = [
              for (final name in (arguments['removeTopics'] as List? ?? []))
                GaiaTopicChange(
                  add: false,
                  topicId: named(name as String)!.id,
                  path: name,
                ),
              for (final name in (arguments['addTopics'] as List? ?? []))
                GaiaTopicChange(
                  add: true,
                  topicId: named(name as String)?.id,
                  name: named(name) == null ? name : null,
                  path: name,
                ),
            ];
            return {
              'memoryId': was.id,
              'was': was.text,
              'text': arguments['text'] ?? was.text,
              if (changes.isNotEmpty) ...{
                'topics': [for (final change in changes) change.toJson()],
                'had': was.topicIds.length,
              },
            };
          case 'reviseMemory':
            final made = <String>[];
            if (params['accept'] == true) {
              change(id!, (m) => m.copyWith(text: params['text']! as String));
              for (final json in params['topics'] as List? ?? []) {
                final topicChange = GaiaTopicChange.fromJson(
                  (json as Map).cast(),
                );
                var topicId = topicChange.topicId;
                if (topicId == null) {
                  final topicMade = topic(
                    'n${topics.length}',
                    topicChange.name!,
                  );
                  topics = [...topics, topicMade];
                  made.add(topicId = topicMade.id);
                }
                change(
                  id,
                  (m) => m.copyWith(
                    topicIds: topicChange.add
                        ? [...m.topicIds, topicId!]
                        : ([...m.topicIds]..remove(topicId)),
                  ),
                );
              }
            }
            return {'made': made, 'skipped': <String>[]};
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
          case 'updateMemory':
            final proposal = stored(id!)!;
            final old = stored(proposal.replacesId!)!;
            change(old.id, (m) => m.copyWith(text: proposal.text));
            trash[id] = proposal;
            change(id, (_) => null);
            return [gaiaMemoryToJson(old), gaiaMemoryToJson(proposal)];
          case 'placedMemory':
            final placement = gaiaPlacementFromJson(params['placement']);
            change(id!, (m) => m.copyWith(topicIds: placement.topicIds));
            return gaiaMemoryFilingToJson((topics: const [], suggested: null));
          case 'leaveUnsorted':
            left.add(id!);
          case 'undoLeaveUnsorted':
            left.remove(id);
          // The sweep's suggestions (GAIA_MEMORY_TOPICS_HLD.md §27.4), as
          // GaiaMemories.decideSuggestion applies them.
          case 'decideSuggestion':
            final suggestion = suggestions.singleWhere(
              (s) => s.id == params['id'],
            );
            suggestions = [...suggestions]..remove(suggestion);
            final named = [
              for (final memoryId in suggestion.memoryIds) stored(memoryId)!,
            ];
            var before = <GaiaMemory>[];
            if (params['keep'] case final String keep) {
              final other = named.firstWhere((m) => m.id != keep);
              trash[other.id] = other;
              change(other.id, (_) => null);
              before = [other];
            } else if (params['accept'] == true) {
              before = named;
              switch (suggestion.kind) {
                case GaiaSuggestionKind.same:
                  change(
                    named.first.id,
                    (m) => m.copyWith(
                      text: params['text'] as String? ?? suggestion.text,
                      pinned: named.any((m) => m.pinned),
                      topicIds: [
                        ...{for (final m in named) ...m.topicIds},
                      ],
                    ),
                  );
                  for (final other in named.skip(1)) {
                    trash[other.id] = other;
                    change(other.id, (_) => null);
                  }
                case GaiaSuggestionKind.expired:
                  change(
                    named.single.id,
                    (m) => m.copyWith(status: GaiaMemoryStatus.archived),
                  );
                default:
              }
            }
            return {
              'memories': [for (final m in before) gaiaMemoryToJson(m)],
              'topics': <Object?>[],
              'suggestion': gaiaMemorySuggestionToJson(suggestion),
            };
          case 'restoreSuggestion':
            suggestions = [
              ...suggestions,
              gaiaMemorySuggestionFromJson(params['suggestion'])!,
            ];
          case 'sweepPlan':
            return sweepPlan;
          case 'sweepFound':
            return (params['suggestions']! as List).length;
          case 'sweepUnsorted':
            final except = (params['except']! as List).cast<String>();
            return [
              for (final m in memories)
                if (m.topicIds.isEmpty && !except.contains(m.id))
                  {'id': m.id, 'text': m.text},
            ];
          case 'sweepPlaced':
            return (params['placements']! as Map).length;
        }
        return null;
      };
    await main.startCompanion();
    final controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {kGaiaClaudeCodeAdapter: runner = FakeClaudeRunner()},
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
    suggestions = [];
    left = {};
    sweepPlan = null;
    chats = [];
    messages = {};
  });

  GaiaMemorySuggestion sweepCard(
    String id,
    GaiaSuggestionKind kind,
    List<String> memoryIds, {
    String? text,
    String why = 'Because',
    GaiaPlacement? placement,
  }) => (
    id: id,
    kind: kind,
    memoryIds: memoryIds,
    topicIds: const [],
    text: text,
    why: why,
    placement: placement,
    madeAt: at,
  );

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

  testWidgets('"Update this?" strikes the old text through; Enter updates '
      'it, A keeps both, and Ctrl+Z puts each back', (tester) async {
    memories = [
      memory('toronto', 'I live in Toronto', pinned: true),
      memory(
        'u1',
        'I moved to Vancouver',
        status: GaiaMemoryStatus.proposed,
      ).copyWith(replacesId: 'toronto'),
      memory(
        'u2',
        'I work at Shopify now',
        status: GaiaMemoryStatus.proposed,
      ).copyWith(replacesId: 'toronto'),
    ];
    await pump(tester);
    await tester.tap(find.text('Review'));
    await settle(tester);
    expect(inReview(find.text('Update this?')), findsOneWidget);
    final old = tester.widget<Text>(inReview(find.text('I live in Toronto')));
    expect(old.style?.decoration, TextDecoration.lineThrough);
    for (final label in ['Update', 'Keep both', 'Dismiss']) {
      expect(inReview(find.text(label)), findsOneWidget, reason: label);
    }
    expect(inReview(find.text('Remember and pin')), findsNothing);

    await key(tester, LogicalKeyboardKey.enter);
    expect(sent('updateMemory').single['memoryId'], 'u1');
    expect(stored('toronto')!.text, 'I moved to Vancouver');
    expect(stored('toronto')!.pinned, isTrue);
    expect(stored('u1'), isNull);
    // The next one updates what the first wrote, struck through.
    expect(
      tester
          .widgetList<Text>(inReview(find.text('I moved to Vancouver')))
          .any((text) => text.style?.decoration == TextDecoration.lineThrough),
      isTrue,
    );
    await key(tester, LogicalKeyboardKey.keyA);
    expect(stored('u2')!.status, GaiaMemoryStatus.active);
    expect(stored('toronto')!.text, 'I moved to Vancouver');
    expect(inReview(find.text('1 updated · 1 remembered')), findsOneWidget);

    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(stored('u2')!.status, GaiaMemoryStatus.proposed);
    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(stored('toronto')!.text, 'I live in Toronto');
    expect(stored('u1')!.status, GaiaMemoryStatus.proposed);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a proposal whose memory is archived since is a plain one', (
    tester,
  ) async {
    memories = [
      memory('toronto', 'I live in Toronto', status: GaiaMemoryStatus.archived),
      memory(
        'u1',
        'I moved to Vancouver',
        status: GaiaMemoryStatus.proposed,
      ).copyWith(replacesId: 'toronto'),
    ];
    await pump(tester);
    await tester.tap(find.text('Review'));
    await settle(tester);
    expect(inReview(find.text('In the inbox')), findsOneWidget);
    expect(inReview(find.text('Remember')), findsOneWidget);
    expect(inReview(find.text('Update')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

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

    // Leave unsorted drops the suggestion and files nothing; undo gives it
    // back.
    await key(tester, LogicalKeyboardKey.backspace);
    expect(stored('u0')!.topicIds, isEmpty);
    expect(controller.memorySorted.containsKey('u0'), isFalse);
    expect(inReview(find.text('Buy rice')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(controller.memorySorted['u0']?.topicIds, ['t1']);
    expect(inReview(find.text('Exam on Monday')), findsOneWidget);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  Finder askChat() => inReview(find.byType(GaiaChatBody));

  testWidgets('Ask Gaia (/) opens the memory\'s chat beside the card, the '
      'only chat built; another card hides it and coming back shows it; Esc '
      'in its composer closes it and gives the keys back; the chat that was '
      'open is back after', (tester) async {
    memories = [
      memory('p0', 'I prefer metric units', status: GaiaMemoryStatus.proposed),
      memory('p1', 'Fact 1', status: GaiaMemoryStatus.proposed),
    ];
    final controller = await pump(tester);
    final before = controller.currentChatId;
    await tester.tap(find.text('Review'));
    await settle(tester);

    await key(tester, LogicalKeyboardKey.slash);
    expect(controller.asking, 'p0');
    expect(askChat(), findsOneWidget);
    expect(find.byType(GaiaChatBody), findsOneWidget, reason: 'only one');
    expect(find.text('About: I prefer metric units'), findsOneWidget);
    // Beside the card in a wide window.
    expect(
      tester.getTopLeft(askChat()).dx,
      greaterThan(
        tester.getTopRight(inReview(find.text('I prefer metric units'))).dx,
      ),
    );
    // Typed into the composer, not the deck's keys.
    await tester.enterText(find.byType(EditableText).last, 'd');
    await settle(tester);
    expect(stored('p0')!.status, GaiaMemoryStatus.proposed);

    // Skip moves on: the chat goes, and comes back with its card.
    await tester.tap(inReview(find.text('Skip')));
    await settle(tester);
    expect(controller.asking, isNull);
    expect(askChat(), findsNothing);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(controller.asking, 'p0');
    expect(askChat(), findsOneWidget);

    Finder hint(String text) =>
        inReview(find.textContaining(text, findRichText: true));
    controller.focusComposer();
    await settle(tester);
    expect(hint('Esc back to the deck'), findsOneWidget);
    // Esc in the composer: the keys back to the deck, the chat still there.
    await key(tester, LogicalKeyboardKey.escape);
    expect(controller.asking, 'p0');
    expect(askChat(), findsOneWidget);
    expect(hint('/ back to the chat'), findsOneWidget);
    expect(hint('Esc close the chat'), findsOneWidget);
    // / goes back into it, and Esc out again.
    await key(tester, LogicalKeyboardKey.slash);
    // The composer takes the focus a frame later.
    await settle(tester);
    expect(hint('Esc back to the deck'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    expect(controller.asking, 'p0');
    // Esc on the deck closes the chat, and only that.
    await key(tester, LogicalKeyboardKey.escape);
    expect(controller.asking, isNull);
    expect(askChat(), findsNothing);
    expect(controller.currentChatId, before);
    expect(
      find.byType(GaiaMemoryReviewView),
      findsOneWidget,
      reason: 'the chat first, then the review',
    );
    // The keys are the deck's again, and the chat doesn't come back with
    // its card.
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(askChat(), findsNothing);

    await key(tester, LogicalKeyboardKey.slash);
    expect(askChat(), findsOneWidget);
    // Left with its chat open, the tab goes at once: fading out, its chat
    // column would show the chat it gave back.
    controller.showPanelTab(GaiaPanelTab.actions);
    await tester.pump();
    expect(find.byType(GaiaMemoryReviewView), findsNothing);
    controller.showPanelTab(GaiaPanelTab.memories);
    await settle(tester);
    await settle(tester);
    expect(askChat(), findsOneWidget);
    controller.closePanel();
    await settle(tester);
    expect(controller.asking, isNull);
    expect(controller.currentChatId, before);
    expect(find.byType(GaiaChatBody), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets("a narrow window puts the chat under the card; a list card's "
      'Ask Gaia opens that memory alone with its chat', (tester) async {
    memories = [memory('a1', 'I like tea')];
    final controller = await pump(tester);
    tester.view.physicalSize = const Size(800, 1000);
    await settle(tester);
    controller.startReview(GaiaMemoryReview.memory(controller, stored('a1')!));
    // The chat opens a frame after the review shows.
    await settle(tester);
    await settle(tester);
    expect(inReview(find.text('Reviewing this memory')), findsOneWidget);
    expect(controller.asking, 'a1');
    expect(
      tester.getTopLeft(askChat()).dy,
      greaterThan(tester.getBottomLeft(inReview(find.text('I like tea'))).dy),
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a rewrite Gaia offers in the chat, applied, changes the card '
      'above it', (tester) async {
    memories = [memory('a1', 'I really do like to drink tea a lot')];
    final controller = await pump(tester);
    controller.startReview(GaiaMemoryReview.memory(controller, stored('a1')!));
    await settle(tester);
    expect(controller.asking, 'a1');

    runner.turns.add([const ClaudeTextStart(), const ClaudeTextDelta('Sure')]);
    await tester.runAsync(() async {
      unawaited(controller.send('Rewrite this so it\'s more compact'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await settle(tester);
    expect(runner.sent.last.prompt, contains('Id: a1'));
    await tester.runAsync(
      () => runner.sent.last.tools!.call('memory_revise', {
        'id': 'a1',
        'text': 'I like tea',
      }),
    );
    await settle(tester);
    expect(find.text('Rewrite this memory?'), findsOneWidget);
    await tester.tap(find.text('Apply'));
    await settle(tester);
    await settle(tester);
    expect(stored('a1')!.text, 'I like tea');
    expect(inReview(find.text('I like tea')), findsWidgets);
    expect(find.text('Applied'), findsOneWidget);
    runner.finish(controller.currentChatId!);
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets("R applies Gaia's latest open change for the card in front, "
      'leaving the deck where it is; U puts the memory, its topics and the '
      'card back; with no open card R does nothing, and the hint offers R '
      'only when there is one (GAIA_SETTINGS_HLD.md §7.5)', (tester) async {
    memories = [
      memory('a1', 'I really do like to drink tea a lot', topicIds: ['t1']),
    ];
    final controller = await pump(tester);
    controller.startReview(GaiaMemoryReview.memory(controller, stored('a1')!));
    await settle(tester);
    expect(controller.asking, 'a1');
    Finder hint(String text) =>
        inReview(find.textContaining(text, findRichText: true));
    Future<void> toDeck() async {
      controller.review!.backToDeck();
      await settle(tester);
    }

    await toDeck();
    await key(tester, LogicalKeyboardKey.keyR);
    expect(sent('reviseMemory'), isEmpty, reason: 'no card to apply');
    expect(hint("R apply Gaia's change"), findsNothing);

    runner.turns.add([const ClaudeTextStart(), const ClaudeTextDelta('Sure')]);
    await tester.runAsync(() async {
      unawaited(controller.send('Shorter, and file it under Drinks'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await settle(tester);
    await tester.runAsync(
      () => runner.sent.last.tools!.call('memory_revise', {
        'id': 'a1',
        'text': 'I like tea',
        'addTopics': ['Drinks'],
        'removeTopics': ['School'],
      }),
    );
    await settle(tester);
    expect(find.text('Change this memory?'), findsOneWidget);
    await toDeck();
    expect(hint("R apply Gaia's change"), findsOneWidget);
    // Beside the chat, the hint wraps rather than shrinking out of reading.
    expect(
      tester.getRect(hint("R apply Gaia's change")).height,
      greaterThanOrEqualTo(10),
    );

    await key(tester, LogicalKeyboardKey.keyR);
    expect(stored('a1')!.text, 'I like tea');
    final drinks = topics.singleWhere((topic) => topic.name == 'Drinks');
    expect(stored('a1')!.topicIds, [drinks.id]);
    expect(controller.review!.index, 0, reason: 'the deck stays');
    expect(inReview(find.text('I like tea')), findsWidgets);
    expect(find.text('Applied'), findsOneWidget);
    expect(hint("R apply Gaia's change"), findsNothing);

    await key(tester, LogicalKeyboardKey.keyU);
    expect(stored('a1')!.text, 'I really do like to drink tea a lot');
    expect(stored('a1')!.topicIds, ['t1']);
    expect(topics.where((topic) => topic.name == 'Drinks'), isEmpty);
    expect(sent('reopenRevision'), hasLength(1));
    expect(find.text('Apply'), findsOneWidget, reason: 'the card open again');
    expect(hint("R apply Gaia's change"), findsOneWidget);
    runner.finish(controller.currentChatId!);
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets("a card's source line shows its chat read-only in the chat's "
      'place: no composer, its cards inert; another card hides it and coming '
      'back shows it; Ask Gaia and the source take turns; a second click or '
      'closing the panel gives the chat that was open back', (tester) async {
    chats = [
      GaiaChat(
        id: 'c1',
        title: 'Planning the study plan',
        createdAt: at,
        updatedAt: at,
        lastMessageAt: at,
        tier: GaiaTier.standard,
      ),
    ];
    GaiaMessage message(int seq, GaiaMessageRole role, List<GaiaPart> parts) =>
        GaiaMessage(
          id: 'm$seq',
          chatId: 'c1',
          seq: seq,
          role: role,
          parts: parts,
          status: GaiaMessageStatus.complete,
          createdAt: at,
          updatedAt: at,
        );
    messages = {
      'c1': [
        message(1, GaiaMessageRole.user, [
          const GaiaTextPart('Use kilometres from now on'),
        ]),
        message(2, GaiaMessageRole.assistant, [
          const GaiaTextPart('Noted.'),
          const GaiaMemoryPart(memoryId: 'p0', text: 'I prefer metric units'),
        ]),
        // Far more after it than the split shows.
        for (var seq = 3; seq < 40; seq++)
          message(
            seq,
            seq.isOdd ? GaiaMessageRole.user : GaiaMessageRole.assistant,
            [
              GaiaTextPart(
                [for (var i = 0; i < 6; i++) 'line $i of $seq'].join('\n\n'),
              ),
            ],
          ),
      ],
    };
    memories = [
      memory(
        'p0',
        'I prefer metric units',
        status: GaiaMemoryStatus.proposed,
        sourceChatId: 'c1',
      ),
      memory('p1', 'Fact 1', status: GaiaMemoryStatus.proposed),
    ];
    final controller = await pump(tester);
    final before = controller.currentChatId;
    await tester.tap(find.text('Review'));
    await settle(tester);

    final source = inReview(find.textContaining('Planning the study plan'));
    await tester.tap(source);
    await settle(tester);
    expect(controller.showingSource, 'c1');
    expect(controller.currentChatId, 'c1');
    // Scrolled up to the message with its memory card, not at the newest:
    // a jump, then a glide.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    final card = inReview(find.byType(GaiaMemoryCard));
    expect(card, findsOneWidget);
    expect(tester.getRect(card).top, greaterThanOrEqualTo(0));
    expect(tester.getRect(card).bottom, lessThanOrEqualTo(1400));
    expect(find.byType(GaiaChatBody), findsNothing, reason: 'no composer');
    // Hovering a message offers Copy, and nothing that acts on it.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(inReview(find.text('Noted.'))));
    await settle(tester);
    expect(find.byTooltip('Copy'), findsOneWidget);
    expect(find.byTooltip('Edit & resend'), findsNothing);
    expect(find.byTooltip('Fork from here'), findsNothing);
    await mouse.moveTo(Offset.zero);
    // Its memory card shows, but Remember on it does nothing.
    await tester.tap(
      find.descendant(of: card, matching: find.text('Remember')),
      warnIfMissed: false,
    );
    await settle(tester);
    expect(sent('decideMemory'), isEmpty);
    // The deck's keys still work: Skip moves on and hides it.
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(controller.showingSource, isNull);
    expect(controller.currentChatId, before);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(controller.showingSource, 'c1');

    // Ask Gaia takes its place, and the source line takes it back.
    await key(tester, LogicalKeyboardKey.slash);
    expect(controller.asking, 'p0');
    expect(controller.showingSource, isNull);
    expect(find.byType(GaiaChatBody), findsOneWidget);
    await tester.tap(source);
    await settle(tester);
    expect(controller.asking, isNull);
    expect(controller.showingSource, 'c1');
    // A second click hides it; the Ask Gaia chat asked for is back.
    await tester.tap(source);
    await settle(tester);
    expect(controller.showingSource, isNull);
    expect(controller.asking, 'p0');

    // Another tab hides it; back on Memories, it's shown again.
    await tester.tap(source);
    await settle(tester);
    controller.showPanelTab(GaiaPanelTab.actions);
    await settle(tester);
    expect(controller.showingSource, isNull);
    controller.showPanelTab(GaiaPanelTab.memories);
    await settle(tester);
    await settle(tester);
    expect(controller.showingSource, 'c1');
    controller.closePanel();
    await settle(tester);
    expect(controller.showingSource, isNull);
    expect(controller.currentChatId, before);
    expect(find.byType(GaiaChatBody), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('T adds a topic to an inbox card and a remembered one, and '
      'the card stays in front', (tester) async {
    memories = [
      memory('p0', 'Exam on Monday', status: GaiaMemoryStatus.proposed),
      memory('p1', 'Buy rice', status: GaiaMemoryStatus.proposed),
      memory('a0', 'Fact 0', topicIds: ['t1']),
      memory('a1', 'Fact 1', topicIds: ['t1']),
    ];
    final controller = await pump(tester);
    await tester.tap(find.text('Review'));
    await settle(tester);

    await key(tester, LogicalKeyboardKey.keyT);
    await tester.enterText(find.byType(EditableText).last, 'Exams');
    await tester.pump();
    await tester.tap(find.text('New topic: Exams'));
    await settle(tester);
    final exams = topics.singleWhere((topic) => topic.name == 'Exams');
    expect(stored('p0')!.topicIds, [exams.id]);
    expect(stored('p0')!.status, GaiaMemoryStatus.proposed);
    expect(inReview(find.text('Exam on Monday')), findsOneWidget);
    expect(controller.review!.index, 0, reason: 'T stays');

    controller.endReview();
    await settle(tester);
    await tester.tap(find.text('School').first);
    await settle(tester);
    await tester.tap(find.text('Review these (2)'));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.keyT);
    await tester.enterText(find.byType(EditableText).last, 'Maths');
    await tester.pump();
    await tester.tap(find.text('New topic: Maths'));
    await settle(tester);
    final maths = topics.singleWhere((topic) => topic.name == 'Maths');
    expect(stored('a0')!.topicIds, ['t1', maths.id]);
    expect(controller.review!.index, 0, reason: 'T stays');
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('with Vim, Esc in the topic picker goes to Normal; the next '
      'closes it with no topic added', (tester) async {
    memories = [
      memory('p0', 'Exam on Monday', status: GaiaMemoryStatus.proposed),
    ];
    final controller = await pump(tester);
    controller.textSettings.value = const GaiaTextSettings(vim: true);
    await settle(tester);
    await tester.tap(find.text('Review'));
    await settle(tester);

    await key(tester, LogicalKeyboardKey.keyT);
    expect(find.text('Add to topic'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.text('NORMAL'), findsOneWidget);
    expect(find.text('Add to topic'), findsOneWidget);

    await key(tester, LogicalKeyboardKey.escape);
    // The dialog's closing transition.
    await settle(tester);
    expect(find.text('Add to topic'), findsNothing);
    expect(stored('p0')!.topicIds, isEmpty);
    expect(controller.review, isNotNull, reason: 'the review stays open');
    // The review's keys are back: Enter remembers the card.
    await key(tester, LogicalKeyboardKey.enter);
    expect(stored('p0')!.status, GaiaMemoryStatus.active);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets("the sweep's cards (GAIA_MEMORY_TOPICS_HLD.md §27.4): Same "
      'thing merges its text as edited, These disagree keeps the one picked, '
      'Out of date is kept; Ctrl+Z puts each back', (tester) async {
    memories = [
      memory('a', 'I live in Toronto'),
      memory('b', 'Toronto is home', pinned: true),
      memory('v', 'I moved to Vancouver'),
      memory('e', 'My exam is next week'),
    ];
    suggestions = [
      sweepCard('s1', GaiaSuggestionKind.same, [
        'a',
        'b',
      ], text: 'I live in Toronto.'),
      sweepCard('s2', GaiaSuggestionKind.conflict, ['v', 'a'], why: 'Both.'),
      sweepCard('s3', GaiaSuggestionKind.expired, ['e']),
    ];
    await pump(tester);
    expect(find.text('3 suggestions'), findsOneWidget);
    await tester.tap(find.text('Review'));
    await settle(tester);
    expect(inReview(find.text('Same thing?')), findsOneWidget);
    expect(inReview(find.text('I live in Toronto.')), findsOneWidget);
    expect(inReview(find.text('Because.')), findsOneWidget);

    await key(tester, LogicalKeyboardKey.keyE);
    await tester.enterText(
      find.byType(EditableText).last,
      'I live in Toronto, Canada.',
    );
    await key(tester, LogicalKeyboardKey.enter);
    expect(sent('decideSuggestion'), isEmpty);
    expect(inReview(find.text('I live in Toronto, Canada.')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.enter);
    expect(sent('decideSuggestion').single, {
      'id': 's1',
      'accept': true,
      'text': 'I live in Toronto, Canada.',
    });
    expect(stored('a')!.text, 'I live in Toronto, Canada.');
    expect(stored('a')!.pinned, isTrue);
    expect(stored('b'), isNull);
    expect(inReview(find.text('These disagree')), findsOneWidget);
    // A why that ends in a full stop gets no second one.
    expect(inReview(find.text('Both.')), findsOneWidget);

    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(stored('a')!.text, 'I live in Toronto');
    expect(stored('b'), isNotNull);
    expect(suggestions.map((s) => s.id), contains('s1'));
    expect(inReview(find.text('Same thing?')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowRight);

    // 2 keeps the second: the first goes to the trash.
    await key(tester, LogicalKeyboardKey.digit2);
    expect(sent('decideSuggestion').last, {'id': 's2', 'keep': 'a'});
    expect(stored('v'), isNull);
    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(stored('v'), isNotNull);
    await key(tester, LogicalKeyboardKey.backspace);
    expect(sent('decideSuggestion').last, {'id': 's2'});

    expect(inReview(find.text('Out of date?')), findsOneWidget);
    expect(inReview(find.textContaining('saved')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.backspace);
    expect(sent('decideSuggestion').last, {'id': 's3'});
    expect(stored('e')!.status, GaiaMemoryStatus.active);
    expect(inReview(find.textContaining('kept both')), findsOneWidget);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets("the sweep's placements show as Sort these' own; Leave "
      'unsorted is remembered and undone; Sort these skips one left', (
    tester,
  ) async {
    memories = [memory('u0', 'Exam on Monday'), memory('u1', 'Buy rice')];
    suggestions = [
      sweepCard(
        'p0',
        GaiaSuggestionKind.place,
        ['u0'],
        placement: (topicIds: ['t1'], suggested: null, tags: const []),
      ),
    ];
    left = {'u1'};
    final runner = FakeUtilityRunner((_) => '[]');
    final controller = await pump(tester, utility: GaiaUtility(runner));
    expect(controller.memorySorted['u0']?.topicIds, ['t1']);
    await tester.runAsync(
      () => controller.sortMemories(controller.memoryList!.memories),
    );
    expect(runner.jobs, isEmpty, reason: 'u0 has one; u1 was left unsorted');

    await tester.tap(find.text('Unsorted'));
    await settle(tester);
    await tester.tap(find.text('Review these (2)'));
    await settle(tester);
    expect(inReview(find.text('File it in:')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.backspace);
    expect(sent('leaveUnsorted').single, {'memoryId': 'u0'});
    expect(controller.memorySorted.containsKey('u0'), isFalse);
    await key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(sent('undoLeaveUnsorted').single, {'memoryId': 'u0'});
    expect(controller.memorySorted['u0']?.topicIds, ['t1']);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Sweep now: one call a group, the topics with the first, what '
      "it finds kept, the Unsorted ones it doesn't name placed, and the "
      'sweep marked done; a failed call leaves it due', (tester) async {
    memories = [
      memory('a', 'I live in Toronto'),
      memory('b', 'Toronto is home'),
      memory('u', 'Buy rice'),
    ];
    GaiaSweepLine line(GaiaMemory m) =>
        (id: m.id, text: m.text, topics: const [], saved: at, pinned: false);
    sweepPlan = gaiaSweepPlanToJson((
      at: at,
      groups: [
        [line(memories[0]), line(memories[1])],
        [line(memories[2])],
      ],
      topics: [(id: 't1', path: 'School', count: 0, project: false)],
    ));
    var fail = false;
    var sweeps = 0;
    final runner = FakeUtilityRunner((job) {
      if (job.startsWith('File each fact')) {
        return '[{"n": 1, "topics": ["t1"]}]';
      }
      if (fail) return 'no';
      return sweeps++ == 0
          ? '[{"kind": "same", "n": [1, 2], "text": "I live in Toronto."}]'
          : '[]';
    });
    final controller = await pump(tester, utility: GaiaUtility(runner));
    final said = await tester.runAsync(
      () => controller.sweepMemories(force: true),
    );
    expect(sent('sweepPlan').single, {'force': true});
    expect(runner.usages, [
      'memory sweep',
      'memory sweep',
      'memory sweep sort',
    ]);
    expect(runner.inputs[0], contains('T1. School (0)'));
    expect(runner.inputs[1], isNot(contains('Topics:')));
    final found = (sent('sweepFound').single['suggestions']! as List).single;
    expect((found as Map)['memoryIds'], ['a', 'b']);
    expect(sent('sweepUnsorted').single['except'], ['a', 'b']);
    expect((sent('sweepPlaced').single['placements']! as Map).keys, ['u']);
    expect(sent('sweepDone'), hasLength(1));
    expect(said, startsWith('1 suggested and 1 placed, from 3 calls'));

    fail = true;
    await tester.runAsync(() => controller.sweepMemories(force: true));
    expect(sent('sweepDone'), hasLength(1));
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('U undoes the last decision, as Ctrl+Z does', (tester) async {
    memories = [
      memory('p0', 'Exam on Monday', status: GaiaMemoryStatus.proposed),
      memory('p1', 'Buy rice', status: GaiaMemoryStatus.proposed),
    ];
    final controller = await pump(tester);
    await tester.tap(find.text('Review'));
    await settle(tester);

    await key(tester, LogicalKeyboardKey.enter);
    expect(stored('p0')!.status, GaiaMemoryStatus.active);
    await key(tester, LogicalKeyboardKey.keyU);
    expect(stored('p0')!.status, GaiaMemoryStatus.proposed);
    expect(controller.review!.index, 0);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('with the Ask Gaia chat open, the deck decides with it in view, '
      'and /new leaves it be', (tester) async {
    memories = [
      memory('p0', 'I prefer metric units', status: GaiaMemoryStatus.proposed),
      memory('p1', 'Fact 1', status: GaiaMemoryStatus.proposed),
    ];
    final controller = await pump(tester);
    await tester.tap(find.text('Review'));
    await settle(tester);
    await key(tester, LogicalKeyboardKey.slash);
    final chatId = controller.currentChatId;

    await controller.send('/new');
    await settle(tester);
    expect(controller.asking, 'p0');
    expect(controller.currentChatId, chatId);
    expect(find.text('Not in an Ask Gaia chat'), findsOneWidget);

    await key(tester, LogicalKeyboardKey.escape);
    await key(tester, LogicalKeyboardKey.keyA);
    expect(stored('p0')!.status, GaiaMemoryStatus.active);
    // The next card, with no chat of its own.
    expect(controller.asking, isNull);
    expect(inReview(find.text('Fact 1')), findsOneWidget);
    // The controller's drafts timer.
    await tester.pump(const Duration(seconds: 5));
  });
}
