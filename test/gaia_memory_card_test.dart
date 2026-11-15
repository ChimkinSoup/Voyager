import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
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
        onRemember: () {},
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
          onRemember: () => remembered++,
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
          onRemember: () {},
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
}
