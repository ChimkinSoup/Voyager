// Grading a card is gated on its back being visible, and that gate used to
// open only when the flip animation *landed* — so a difficulty key pressed in
// the ~350ms after space was swallowed. The session now opens the gate the
// moment the card commits to its back face. The deck grid keeps the old
// timing on purpose: it feeds the reported face back in as the card's resting
// side, and an early report there would snap the tile and cut its flip short.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_flip_card.dart';
import 'package:voyager/features/study/study_keyboard_shortcuts.dart';
import 'package:voyager/features/study/study_session_page.dart';

const _deckId = 'session-deck';

List<StudyCard> _dueCards() {
  final now = DateTime.now().toUtc();
  return [
    StudyCard(
      id: 'card-0',
      createdAt: now,
      updatedAt: now,
      deckId: _deckId,
      frontText: 'Front 0',
      backText: 'Back 0',
      dueAt: now,
    ),
  ];
}

Future<void> _pumpSession(WidgetTester tester) async {
  final cards = _dueCards();
  final container = ProviderContainer(
    overrides: [studyAllCardsProvider.overrideWith((ref) async => cards)],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: StudySessionPage(cardIds: {for (final c in cards) c.id}),
      ),
    ),
  );
  await tester.pump();
  expect(find.text('Front 0'), findsOneWidget);
}

/// Whether the session is currently accepting grading keys.
bool _gradingArmed(WidgetTester tester) => tester
    .widget<StudyKeyboardShortcuts>(find.byType(StudyKeyboardShortcuts))
    .showingBack;

Finder _gradeButton(String label) =>
    find.byWidgetPredicate((w) => w is GlassButton && w.label == label);

/// Whether the on-screen grading buttons are tappable. The buttons stay
/// visually enabled and fade in, so the gate is the [IgnorePointer] wrapped
/// around them rather than a null `onPressed`.
bool _gradingButtonsEnabled(WidgetTester tester) => !tester
    .widget<IgnorePointer>(
      find
          .ancestor(of: _gradeButton('Fail'), matching: find.byType(IgnorePointer))
          .first,
    )
    .ignoring;

/// How far a grading button has faded from greyed-out to full strength.
double _labelAlpha(WidgetTester tester, String label) =>
    tester.widget<GlassButton>(_gradeButton(label)).textColor!.a;

Future<void> _pumpFlipCard(
  WidgetTester tester, {
  required ValueChanged<bool> onFlipChanged,
  required bool notifyFlipOnStart,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          height: 200,
          child: StudyFlipCard(
            notifyFlipOnStart: notifyFlipOnStart,
            onFlipChanged: onFlipChanged,
            front: const Text('Front'),
            back: const Text('Back'),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('a difficulty key lands while the card is still turning', (
    tester,
  ) async {
    await _pumpSession(tester);
    expect(_gradingArmed(tester), isFalse);
    expect(_gradingButtonsEnabled(tester), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    // A sliver of the 350ms flip — the card is mid-rotation, nowhere near
    // resting on its back.
    await tester.pump(const Duration(milliseconds: 40));

    expect(_gradingArmed(tester), isTrue);
    expect(_gradingButtonsEnabled(tester), isTrue);

    await tester.pumpAndSettle();
    expect(_gradingArmed(tester), isTrue);
  });

  testWidgets('flipping back closes the gate as the card starts returning', (
    tester,
  ) async {
    await _pumpSession(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(_gradingArmed(tester), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 40));

    expect(_gradingArmed(tester), isFalse);
  });

  testWidgets('the grading buttons are one uniform size', (tester) async {
    await _pumpSession(tester);

    final heights = [
      for (final label in ['Fail', 'Hard', 'Good', 'Easy'])
        tester.getSize(_gradeButton(label)).height,
    ];
    expect(heights, everyElement(56.0));

    // Equal widths too, so no label's box is sized by its own glyphs.
    final widths = [
      for (final label in ['Fail', 'Hard', 'Good', 'Easy'])
        tester.getSize(_gradeButton(label)).width,
    ];
    expect(widths.toSet(), hasLength(1));
  });

  testWidgets('the label fades in over the flip instead of snapping', (
    tester,
  ) async {
    await _pumpSession(tester);
    // Greyed out while the card rests on its front.
    expect(_labelAlpha(tester, 'Fail'), closeTo(0.4, 0.001));

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    // Pressable from the first frame of the flip, while still fully greyed.
    expect(_gradingButtonsEnabled(tester), isTrue);
    expect(_labelAlpha(tester, 'Fail'), closeTo(0.4, 0.001));

    await tester.pump(const Duration(milliseconds: 120));
    final midFlip = _labelAlpha(tester, 'Fail');
    expect(midFlip, greaterThan(0.4));
    expect(midFlip, lessThan(0.87));

    await tester.pumpAndSettle();
    expect(_labelAlpha(tester, 'Fail'), closeTo(0.87, 0.001));

    // All four fade together.
    for (final label in ['Hard', 'Good', 'Easy']) {
      expect(_labelAlpha(tester, label), closeTo(0.87, 0.001));
    }
  });

  testWidgets('the label fades back out when the card flips to its front', (
    tester,
  ) async {
    await _pumpSession(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(_labelAlpha(tester, 'Fail'), closeTo(0.87, 0.001));

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    // The gate shuts on the first frame of the return, but the buttons are
    // still lit — they follow the card down rather than snapping grey.
    expect(_gradingButtonsEnabled(tester), isFalse);
    expect(_labelAlpha(tester, 'Fail'), closeTo(0.87, 0.001));

    await tester.pump(const Duration(milliseconds: 120));
    final midFlip = _labelAlpha(tester, 'Fail');
    expect(midFlip, lessThan(0.87));
    expect(midFlip, greaterThan(0.4));

    await tester.pumpAndSettle();
    expect(_labelAlpha(tester, 'Fail'), closeTo(0.4, 0.001));

    // All four dim together.
    for (final label in ['Hard', 'Good', 'Easy']) {
      expect(_labelAlpha(tester, label), closeTo(0.4, 0.001));
    }
  });

  testWidgets('an early report is not repeated when the flip lands', (
    tester,
  ) async {
    final reports = <bool>[];
    await _pumpFlipCard(
      tester,
      onFlipChanged: reports.add,
      notifyFlipOnStart: true,
    );

    await tester.tap(find.byType(StudyFlipCard));
    await tester.pump();
    expect(reports, [true]);

    await tester.pumpAndSettle();
    expect(reports, [true]);
  });

  testWidgets('without the flag the face is reported only once it lands', (
    tester,
  ) async {
    final reports = <bool>[];
    await _pumpFlipCard(
      tester,
      onFlipChanged: reports.add,
      notifyFlipOnStart: false,
    );

    await tester.tap(find.byType(StudyFlipCard));
    await tester.pump(const Duration(milliseconds: 40));
    expect(reports, isEmpty);

    await tester.pumpAndSettle();
    expect(reports, [true]);
  });
}
