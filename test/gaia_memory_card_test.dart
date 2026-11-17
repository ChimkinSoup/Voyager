import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_activity_chip.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_debug_menu.dart';
import 'package:voyager/features/gaia/companion/gaia_memory_card.dart';

/// The memory card `memory_propose` puts in a reply (GAIA_HLD.md §11): kept
/// on the message, decided without holding up the turn.

const _tea = GaiaMemoryPart(memoryId: 'm1', text: 'Prefers tea', project: true);

void main() {
  test('a memory part survives the round trip, and an older build keeps it '
      'as an unknown part', () {
    final back = GaiaPart.fromJson(
      _tea.decided(GaiaCardState.accepted, text: 'Prefers green tea').toJson(),
    );
    expect(back, isA<GaiaMemoryPart>());
    back as GaiaMemoryPart;
    expect(back.memoryId, 'm1');
    expect(back.text, 'Prefers green tea');
    expect(back.project, isTrue);
    expect(back.state, GaiaCardState.accepted);
    // A state from a newer build reads as open.
    expect(
      (GaiaPart.fromJson({..._tea.toJson(), 'state': 'later'})
              as GaiaMemoryPart)
          .isOpen,
      isTrue,
    );
  });

  test("a streaming reply's parts keep the memory cards the user decided", () {
    const jazz = GaiaMemoryPart(memoryId: 'm2', text: 'Likes jazz');
    final shown = <GaiaPart>[
      const GaiaTextPart('Noted.'),
      _tea.decided(GaiaCardState.rejected),
      jazz,
    ];
    final kept = gaiaKeepMemoryDecisions([
      const GaiaTextPart('Noted. More'),
      _tea,
      jazz,
    ], shown);
    expect((kept[0] as GaiaTextPart).text, 'Noted. More');
    expect((kept[1] as GaiaMemoryPart).state, GaiaCardState.rejected);
    expect((kept[2] as GaiaMemoryPart).isOpen, isTrue);
  });

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  testWidgets('open, it follows an edit made in the inbox, unless typed in', (
    tester,
  ) async {
    Widget card(GaiaMemoryPart memory) => host(
      GaiaMemoryCard(
        key: const ValueKey('m1'),
        memory: memory,
        onRemember: (_) {},
      ),
    );
    String shown() =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;
    await tester.pumpWidget(card(_tea));
    await tester.pumpWidget(
      card(_tea.decided(GaiaCardState.open, text: 'Prefers oolong')),
    );
    expect(shown(), 'Prefers oolong');

    await tester.enterText(find.byType(TextField), 'Prefers black tea');
    await tester.pumpWidget(
      card(_tea.decided(GaiaCardState.open, text: 'Prefers sencha')),
    );
    expect(shown(), 'Prefers black tea', reason: "the user's edit stands");
  });

  testWidgets('open, it edits the text and remembers or dismisses it', (
    tester,
  ) async {
    final edits = <String>[];
    var remembered = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      host(
        GaiaMemoryCard(
          memory: _tea,
          onEdit: edits.add,
          onRemember: (_) => remembered++,
          onDismiss: () => dismissed++,
        ),
      ),
    );
    expect(find.text('Remember this for the project?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Prefers green tea');
    expect(edits.last, 'Prefers green tea');
    await tester.tap(find.text('Remember'));
    await tester.tap(find.text('Dismiss'));
    expect((remembered, dismissed), (1, 1));

    // No text, nothing to remember.
    await tester.enterText(find.byType(TextField), '  ');
    await tester.pump();
    final button = tester.widget<GaiaButton>(
      find.widgetWithText(GaiaButton, 'Remember'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('decided, or with nothing to answer it, it is a record', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        GaiaMemoryCard(
          memory: _tea.decided(
            GaiaCardState.accepted,
            text: 'Prefers green tea',
          ),
          onRemember: (_) {},
        ),
      ),
    );
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Prefers green tea'), findsOneWidget);
    expect(find.text('Remembered'), findsOneWidget);

    await tester.pumpWidget(host(const GaiaMemoryCard(memory: _tea)));
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Waiting in the memory inbox'), findsOneWidget);
  });

  testWidgets("the debug menu's preview decides here only, and offers it "
      'again', (tester) async {
    await tester.pumpWidget(host(const GaiaMemoryCardPreview()));
    await tester.enterText(find.byType(TextField), 'Prefers oolong');
    await tester.tap(find.text('Remember'));
    await tester.pump();
    expect(find.text('Prefers oolong'), findsOneWidget);
    expect(find.text('Remembered'), findsOneWidget);

    await tester.tap(find.text('Offer it again'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Prefers green tea with no sugar'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(find.text('Dismissed'), findsOneWidget);
  });

  testWidgets('its pin goes with Remember (GAIA_MEMORY_TOPICS_HLD.md §3.3)', (
    tester,
  ) async {
    final pins = <bool>[];
    await tester.pumpWidget(
      host(GaiaMemoryCard(memory: _tea, onRemember: pins.add)),
    );
    await tester.tap(find.text('Remember'));
    await tester.tap(find.byTooltip('Pin it to every chat'));
    await tester.pump();
    await tester.tap(find.text('Remember'));
    expect(pins, [false, true]);
  });

  testWidgets('open, it shows its topics and the new topic offered, to edit '
      'before Remember (GAIA_MEMORY_TOPICS_HLD.md §3.2)', (tester) async {
    var topics = <GaiaTopicLine>[(id: 'pets', path: 'Pets')];
    bool? newTopic;
    Widget card() => host(
      GaiaMemoryCard(
        memory: _tea,
        onRemember: (_) {},
        filing: (
          topics: topics,
          suggested: 'Vets under Pets',
          newTopic: newTopic,
        ),
        onTopics: (edited) => topics = edited,
        onNewTopic: (take) => newTopic = take,
        topicChoices: () async => const [
          (id: 'pets', path: 'Pets'),
          (id: 'lang', path: 'Languages'),
        ],
      ),
    );
    await tester.pumpWidget(card());
    expect(find.text('Pets'), findsOneWidget);
    expect(find.text('+ New topic: Vets under Pets'), findsOneWidget);

    await tester.tap(find.text('+ New topic: Vets under Pets'));
    expect(newTopic, isTrue);
    await tester.pumpWidget(card());
    expect(find.text('✓ New topic: Vets under Pets'), findsOneWidget);

    // Only the topics it isn't in are offered.
    // Pumped in steps: the editor's caret blinks for ever.
    Future<void> settleMenu() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.tap(find.text('+ Topic'));
    await settleMenu();
    expect(find.text('Pets'), findsOneWidget);
    await tester.tap(find.text('Languages'));
    await settleMenu();
    expect(topics.map((topic) => topic.id), ['pets', 'lang']);

    await tester.pumpWidget(card());
    await tester.tap(find.byIcon(Icons.close).first);
    expect(topics.map((topic) => topic.id), ['lang']);
    await tester.tap(find.byIcon(Icons.close).last);
    expect(newTopic, isFalse);
    await tester.pumpWidget(card());
    expect(find.textContaining('New topic'), findsNothing);

    // Decided, it's a record without them.
    await tester.pumpWidget(
      host(
        GaiaMemoryCard(
          memory: _tea.decided(GaiaCardState.accepted),
          filing: (topics: topics, suggested: null, newTopic: null),
        ),
      ),
    );
    expect(find.text('Languages'), findsNothing);
  });

  testWidgets('the recall chip counts what was given, opens to list each '
      'with its path, and a click opens it (GAIA_MEMORY_TOPICS_HLD.md §4.5)', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      host(
        GaiaRecallChip(
          part: const GaiaRecallPart([
            (id: 'a', text: 'Submit with marmoset', topic: 'CS246 › A1'),
            (id: 'b', text: 'Likes tea', topic: null),
          ]),
          onOpen: opened.add,
        ),
      ),
    );
    expect(find.text('Recalled 2 memories'), findsOneWidget);
    expect(find.text('Submit with marmoset'), findsNothing);
    await tester.tap(find.text('Recalled 2 memories'));
    await tester.pump();
    expect(find.text('CS246 › A1'), findsOneWidget);
    expect(find.text('Unsorted'), findsOneWidget);
    expect(find.textContaining('It may not have used them'), findsOneWidget);
    await tester.tap(find.text('Likes tea'));
    expect(opened, ['b']);

    await tester.pumpWidget(
      host(
        const GaiaRecallChip(
          part: GaiaRecallPart([(id: 'a', text: 'One', topic: null)]),
        ),
      ),
    );
    expect(find.text('Recalled 1 memory'), findsOneWidget);
  });
}
