import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_card_view.dart';

/// A step list on screen (GAIA_HLD.md §15.6).
void main() {
  GaiaCardPart card({
    GaiaCardState state = GaiaCardState.open,
    bool resolved = true,
    Map<String, Object?>? answer,
  }) => GaiaCardPart(
    id: 'c',
    kind: GaiaCardKind.control,
    state: state,
    tool: 'os_steps',
    input: {
      'window': 'Notepad: "notes.txt"',
      'app': 'Notepad',
      'steps': [
        {'label': 'Click Button "File" [1,2 3x4]', 'resolved': true},
        {'label': 'Click "Save" (not on screen yet)', 'resolved': resolved},
      ],
    },
    answer: answer,
  );

  Future<void> pump(
    WidgetTester tester,
    GaiaCardPart part, {
    bool waiting = true,
    VoidCallback? onRunAll,
    VoidCallback? onRunNext,
    VoidCallback? onReject,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: GaiaCardView(
          card: part,
          waiting: waiting,
          sendKey: 'Ctrl+Enter',
          onRunAll: onRunAll,
          onRunNext: onRunNext,
          onReject: onReject,
        ),
      ),
    ),
  );

  testWidgets('shows the window and every step with its target', (
    tester,
  ) async {
    await pump(
      tester,
      card(),
      onRunAll: () {},
      onRunNext: () {},
      onReject: () {},
    );
    expect(find.textContaining('Notepad: "notes.txt"'), findsOneWidget);
    expect(find.text('Click Button "File" [1,2 3x4]'), findsOneWidget);
    expect(find.text('Run all'), findsOneWidget);
    expect(find.text('Next step'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
  });

  testWidgets('a step with no resolved target offers one at a time only', (
    tester,
  ) async {
    await pump(
      tester,
      card(resolved: false),
      onRunAll: () {},
      onRunNext: () {},
      onReject: () {},
    );
    expect(find.text('Run all'), findsNothing);
    expect(find.text('Next step'), findsOneWidget);
    expect(find.textContaining('runs the next step'), findsOneWidget);
    expect(gaiaControlCanRunAll(card(resolved: false)), isFalse);
    // What's already run doesn't count against it.
    expect(gaiaControlCanRunAll(card()), isTrue);
  });

  testWidgets('the phone can only deny', (tester) async {
    await pump(tester, card(), onReject: () {});
    expect(find.text('Run all'), findsNothing);
    expect(find.text('Next step'), findsNothing);
    expect(find.text('Deny'), findsOneWidget);
    expect(find.textContaining('at the desktop'), findsOneWidget);
  });

  testWidgets('a decided card is a record of how far it got', (tester) async {
    await pump(
      tester,
      card(
        state: GaiaCardState.accepted,
        answer: {
          'ran': 1,
          'stopped': 'The user pressed Esc.',
          'committed': {'steps': 1},
        },
      ),
      waiting: false,
    );
    expect(
      find.text('Stopped after 1 of 2: The user pressed Esc.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('Deny'), findsNothing);
  });
}
