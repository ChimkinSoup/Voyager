import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_date_picker.dart';
import 'package:voyager/features/gaia/companion/gaia_proposal_card.dart';

import 'narrow_window_harness.dart';

/// An open card proposing [fields], its edits into [edits]. No
/// ProviderScope, as in the companion.
Future<void> _pump(
  WidgetTester tester,
  GaiaProposalEntity entity,
  Map<String, Object?> fields,
  Map<String, Object?> edits,
) async {
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final card = GaiaCardPart(
    id: 'p1',
    kind: GaiaCardKind.proposal,
    tool: 'propose',
    proposal: GaiaProposal(
      entity: entity,
      choices: const [(id: 'c1', name: 'Inbox')],
      fields: fields,
    ),
  );
  await tester.pumpWidget(
    // Stilled, so the rings' light settles.
    GaiaAmbient(
      running: false,
      child: MaterialApp(
        theme: VoyagerTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: GaiaProposalCard(
              card: card,
              fields: fields,
              waiting: true,
              onEdit: (key, value) => edits[key] = value,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets("a task's due date opens Voyager's picker in a glow ring", (
    tester,
  ) async {
    final edits = <String, Object?>{};
    await _pump(tester, GaiaProposalEntity.todo, {
      'title': 'Pack',
      'list': 'c1',
      'due': '2026-10-30',
      'starred': false,
    }, edits);
    await tester.tap(find.text('Fri 30 Oct 2026'));
    await tester.pumpAndSettle();
    expect(
      find.ancestor(
        of: find.byType(DateTimeSelectorPopover),
        matching: find.byType(GaiaGlowRing),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('12').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(DateTimeSelectorPopover), findsNothing);
    // The time was left off, as it was.
    expect(edits['due'], '2026-10-12');
  });

  testWidgets('Esc cancels: a task with no due date keeps none', (
    tester,
  ) async {
    final edits = <String, Object?>{};
    await _pump(tester, GaiaProposalEntity.todo, {
      'title': 'Pack',
      'list': 'c1',
      'due': null,
      'starred': false,
    }, edits);
    await tester.tap(find.text('none'));
    await tester.pumpAndSettle();
    expect(find.byType(DateTimeSelectorPopover), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(DateTimeSelectorPopover), findsNothing);
    expect(edits, isEmpty);
  });

  testWidgets("an attachment's remove button is still", (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.dark(),
        home: GaiaButton(icon: Icons.close, onPressed: () {}, still: true),
      ),
    );
    expect(find.byType(GaiaGlowRing), findsNothing);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets("an all-day event's start is a day alone", (tester) async {
    final edits = <String, Object?>{};
    await _pump(tester, GaiaProposalEntity.event, {
      'calendar': 'c1',
      'title': 'Trip',
      'allDay': true,
      'start': '2026-10-30',
      'end': '2026-10-31',
      'notes': '',
    }, edits);
    await tester.tap(find.text('Fri 30 Oct 2026'));
    await tester.pumpAndSettle();
    expect(find.byType(DateSelectorPopover), findsOneWidget);
    expect(find.byType(DateTimeSelectorPopover), findsNothing);
    await tester.tap(find.text('12').first);
    await tester.pumpAndSettle();
    expect(find.byType(DateSelectorPopover), findsNothing);
    expect(edits['start'], '2026-10-12');
  });

  testWidgets("a timed event's start keeps its time", (tester) async {
    final edits = <String, Object?>{};
    await _pump(tester, GaiaProposalEntity.event, {
      'calendar': 'c1',
      'title': 'Call',
      'allDay': false,
      'start': '2026-10-30T15:00',
      'end': '2026-10-30T16:00',
      'notes': '',
    }, edits);
    await tester.tap(find.text('Fri 30 Oct 2026 15:00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('12').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(edits['start'], '2026-10-12T15:00');
  });

  for (final timed in [true, false]) {
    for (final width in [400.0, 800.0]) {
      testWidgets('the quick picks keep to one line: timed $timed, $width', (
        tester,
      ) async {
        await loadRealFonts(tester);
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          GaiaAmbient(
            running: false,
            child: MaterialApp(
              theme: VoyagerTheme.dark(),
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showGaiaDatePicker(
                    context,
                    initial: DateTime(2026, 10, 30, 15),
                    timed: timed,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final calendar = tester.getRect(find.byType(DateSelectorPopover));
        final picks = [
          for (final label in ['Today', 'Tomorrow', 'Next Week'])
            tester.getRect(
              find.ancestor(
                of: find.text(label),
                matching: find.byType(GaiaButton),
              ),
            ),
        ];
        for (final pick in picks) {
          expect(pick.top, picks.first.top);
          expect(pick.right, lessThanOrEqualTo(calendar.right));
        }
        // Full size where the window's wide enough.
        if (width == 800) expect(picks.first.height, 28);
        expect(
          find.widgetWithText(GaiaButton, 'Done'),
          findsNWidgets(timed ? 1 : 0),
        );
      });
    }
  }
}
