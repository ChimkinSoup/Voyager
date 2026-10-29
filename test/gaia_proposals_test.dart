import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_card_view.dart';
import 'package:voyager/features/gaia/tools/gaia_proposals.dart';

/// Proposals as both processes see them (GAIA_HLD.md §10): the card they
/// ride on, the helpers that read their fields, and the editor.
void main() {
  const todo = GaiaProposal(
    entity: GaiaProposalEntity.todo,
    targetId: 't1',
    baseVersion: 3,
    before: {
      'list': 'l1',
      'title': 'Buy milk',
      'notes': '',
      'due': null,
      'starred': false,
      'completed': false,
    },
    fields: {
      'list': 'l1',
      'title': 'Buy oat milk',
      'notes': '',
      'due': '2026-10-30',
      'starred': false,
      'completed': false,
    },
    choices: [(id: 'l1', name: 'Inbox')],
  );

  test('a proposal card survives the round trip through JSON', () {
    const card = GaiaCardPart(
      id: 'c1',
      kind: GaiaCardKind.proposal,
      tool: 'propose_todo',
      proposal: todo,
    );
    final back = GaiaCardPart.fromJson(card.toJson());
    expect(back.kind, GaiaCardKind.proposal);
    expect(back.tool, 'propose_todo');
    expect(back.proposal!.toJson(), todo.toJson());
    expect(back.proposal!.choices.single, (id: 'l1', name: 'Inbox'));
  });

  test('a when is a real day, or a real time on one', () {
    expect(gaiaParseWhen('2026-10-30'), (
      at: DateTime(2026, 10, 30),
      hasTime: false,
    ));
    expect(gaiaParseWhen('2026-10-30T14:05'), (
      at: DateTime(2026, 10, 30, 14, 5),
      hasTime: true,
    ));
    expect(gaiaParseWhen('2026-10-30 14:05')!.hasTime, isTrue);
    for (final bad in ['2026-02-30', '2026-10-30T25:00', 'tomorrow', 3]) {
      expect(gaiaParseWhen(bad), isNull, reason: '$bad');
    }
  });

  test('an edit lists what it changes, and one changing nothing is a '
      'problem', () {
    expect(gaiaProposalChanged(todo, todo.fields), ['title', 'due']);
    expect(gaiaProposalProblem(todo, todo.fields), isNull);
    expect(gaiaProposalProblem(todo, todo.before!), 'Nothing is changed.');
    expect(gaiaProposalTitle(todo, todo.fields), 'Change task "Buy oat milk"');
  });

  test('an event must end after it starts, in the form its all-day switch '
      'says', () {
    const event = GaiaProposal(
      entity: GaiaProposalEntity.event,
      fields: {},
      choices: [(id: 'c1', name: 'Personal')],
    );
    Map<String, Object?> fields(bool allDay, String start, String end) => {
      'calendar': 'c1',
      'title': 'Dentist',
      'allDay': allDay,
      'start': start,
      'end': end,
      'notes': '',
    };
    expect(
      gaiaProposalProblem(
        event,
        fields(false, '2026-10-30T14:00', '2026-10-30T15:00'),
      ),
      isNull,
    );
    expect(
      gaiaProposalProblem(
        event,
        fields(false, '2026-10-30T14:00', '2026-10-30T14:00'),
      ),
      'An event has to end after it starts.',
    );
    expect(
      gaiaProposalProblem(event, fields(true, '2026-10-30', '2026-10-30')),
      isNull,
    );
    expect(
      gaiaProposalProblem(
        event,
        fields(true, '2026-10-30T14:00', '2026-10-30'),
      ),
      contains('all-day'),
    );
  });

  test('approval tokens are 32 hex digits, and each is new', () {
    final a = gaiaApprovalToken();
    expect(isGaiaApprovalToken(a), isTrue);
    expect(a, isNot(gaiaApprovalToken()));
    expect(isGaiaApprovalToken('nope'), isFalse);
  });

  testWidgets('the editor shows what an edit changes, and edits go out '
      'through onEdit', (tester) async {
    final edits = <(String, Object?)>[];
    var accepted = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GaiaCardView(
              card: const GaiaCardPart(
                id: 'c1',
                kind: GaiaCardKind.proposal,
                tool: 'propose_todo',
                proposal: todo,
              ),
              waiting: true,
              onEdit: (key, value) => edits.add((key, value)),
              onAllow: () => accepted++,
              onReject: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('Change task "Buy oat milk"'), findsOneWidget);
    expect(find.text('Was: Buy milk'), findsOneWidget);
    expect(find.text('Was: none'), findsOneWidget, reason: 'the due date');
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Oat');
    expect(edits.last, ('title', 'Oat'));
    await tester.tap(find.text('Save'));
    expect(accepted, 1);
  });

  testWidgets('a new task is edited without a summary, and saved, it is '
      'summarised', (tester) async {
    const card = GaiaCardPart(
      id: 'c1',
      kind: GaiaCardKind.proposal,
      tool: 'propose_todo',
      proposal: GaiaProposal(
        entity: GaiaProposalEntity.todo,
        fields: {
          'list': 'l1',
          'title': 'Buy stamps',
          'notes': '',
          'due': null,
          'starred': false,
          'completed': false,
        },
        choices: [(id: 'l1', name: 'Inbox')],
      ),
    );
    Future<void> pump(GaiaCardPart card, {bool waiting = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: GaiaCardView(
                  card: card,
                  waiting: waiting,
                  onEdit: (_, _) {},
                  onAllow: () {},
                  onReject: () {},
                ),
              ),
            ),
          ),
        );
    final summary = find.textContaining('Title: Buy stamps', findRichText: true);

    await pump(card, waiting: true);
    expect(find.widgetWithText(TextField, 'Title'), findsOneWidget);
    expect(summary, findsNothing);

    await pump(
      card.decided(GaiaCardState.accepted, {'fields': card.proposal!.fields}),
    );
    expect(find.byType(TextField), findsNothing);
    expect(summary, findsOneWidget);
  });

  testWidgets('decided, it is a record of what came of it', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GaiaCardView(
            card: const GaiaCardPart(
              id: 'c1',
              kind: GaiaCardKind.proposal,
              tool: 'propose_todo',
              proposal: todo,
            ).decided(GaiaCardState.rejected, {'message': 'make it Friday'}),
          ),
        ),
      ),
    );
    expect(find.text('Turned down: "make it Friday"'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
