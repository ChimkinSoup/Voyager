import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_proposal_card.dart';

import 'narrow_window_harness.dart';

const _hint = 'Ctrl+Enter saves · or type what to change';

final _card = GaiaCardPart(
  id: 'p1',
  kind: GaiaCardKind.proposal,
  tool: 'propose_calendar_event',
  proposal: const GaiaProposal(
    entity: GaiaProposalEntity.event,
    choices: [(id: 'c1', name: 'Calendar')],
    fields: {
      'calendar': 'c1',
      'title': 'Call with the hotel',
      'allDay': false,
      'start': '2026-10-30T15:00',
      'end': '2026-10-30T16:30',
      'notes': '',
    },
  ),
);

/// The open card at [width], with Save all when [several] are open.
Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required bool several,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: VoyagerTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: GaiaProposalCard(
                card: _card,
                fields: _card.proposal!.fields,
                waiting: true,
                sendKey: 'Ctrl+Enter',
                onEdit: (_, _) {},
                onAccept: () {},
                onAcceptAll: several ? () {} : null,
                onReject: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    "the hint keeps to one line, beside the buttons or above them",
    (tester) async {
      await loadRealFonts(tester);
      await _pump(tester, width: 520, several: false);
      final oneLine = tester.getSize(find.text(_hint)).height;
      // The narrowest a card gets, in the smallest floater, to its cap.
      for (final width in [400.0, 520.0]) {
        for (final several in [false, true]) {
          await _pump(tester, width: width, several: several);
          final hint = tester.getRect(find.text(_hint));
          expect(hint.height, oneLine, reason: '$width, several: $several');
          // Above the buttons, when not beside them.
          final save = tester.getRect(find.text('Save'));
          expect(
            hint.bottom <= save.top || hint.right <= save.left,
            isTrue,
            reason: '$width, several: $several',
          );
        }
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('a reminder delete shows what goes, with Delete and Keep it', (
    tester,
  ) async {
    const before = {'text': 'Sidebar flickers on resize'};
    final card = GaiaCardPart(
      id: 'p2',
      kind: GaiaCardKind.proposal,
      tool: 'propose_reminder',
      proposal: const GaiaProposal(
        entity: GaiaProposalEntity.reminder,
        targetId: 'n1',
        baseVersion: 0,
        before: before,
        fields: before,
        delete: true,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.dark(),
        home: Scaffold(
          body: GaiaProposalCard(
            card: card,
            fields: before,
            waiting: true,
            sendKey: 'Ctrl+Enter',
            onEdit: (_, _) {},
            onAccept: () {},
            onReject: () {},
          ),
        ),
      ),
    );
    expect(find.text('Delete reminder "Sidebar flickers on resize"'), findsOne);
    final text = tester.widget<Text>(find.text('Sidebar flickers on resize'));
    expect(text.style?.decoration, TextDecoration.lineThrough);
    // Nothing to edit on a delete.
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Delete'), findsOne);
    expect(find.text('Keep it'), findsOne);
    // Only Delete is red: keeping it is the safe choice.
    GaiaButton button(String label) => tester.widget<GaiaButton>(
      find.ancestor(of: find.text(label), matching: find.byType(GaiaButton)),
    );
    final error = VoyagerTheme.dark().colorScheme.error;
    expect(button('Delete').color, error);
    expect(button('Keep it').color, isNot(error));
    expect(find.text('Ctrl+Enter deletes · or type what to change'), findsOne);
  });
}
