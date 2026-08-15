// Gesture mechanics for cram mode's swipe-to-decide card. The card is the
// app's only free-flying, momentum-carrying drag, so the three properties that
// make such a gesture feel physical are pinned here: a flick commits on where
// it is *heading* rather than where the finger stopped, a released card that
// falls short travels back to centre instead of teleporting, and reduced
// motion drops the full-width slide without dropping the decision.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_cram_page.dart';
import 'package:voyager/features/study/study_flip_card.dart';

const _deckId = 'cram-deck';

List<StudyCard> _cards(int count) {
  final now = DateTime.now().toUtc();
  return [
    for (var i = 0; i < count; i++)
      StudyCard(
        id: 'card-$i',
        createdAt: now,
        updatedAt: now,
        deckId: _deckId,
        frontText: 'Front $i',
        backText: 'Back $i',
        dueAt: now,
      ),
  ];
}

/// The live horizontal offset the card is painting at — the nearest [Transform]
/// above the flip card is the one the swipe spring drives.
double _cardOffset(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find
        .ancestor(
          of: find.byType(StudyFlipCard),
          matching: find.byType(Transform),
        )
        .first,
  );
  return transform.transform.getTranslation().x;
}

Future<void> _pumpCramPage(
  WidgetTester tester, {
  int cards = 3,
  bool reducedMotion = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      studyCardsProvider(_deckId).overrideWith((ref) async => _cards(cards)),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reducedMotion),
          child: const StudyCramPage(deckId: _deckId),
        ),
      ),
    ),
  );
  // Not pumpAndSettle: the card keeps a spring ticker alive, so settling can
  // outrun the timeout. A few frames is enough for the provider to resolve.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(find.text('Front 0'), findsOneWidget);
}

void main() {
  testWidgets('a short fast flick commits on its projected landing point', (
    tester,
  ) async {
    await _pumpCramPage(tester);

    // 60px of travel — half the commit threshold — but thrown hard enough that
    // it would coast well past it. Deciding on distance alone would ignore it.
    await tester.fling(
      find.byType(StudyFlipCard),
      const Offset(60, 0),
      3000,
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('Front 1'),
      findsOneWidget,
      reason: 'the flick should have passed card 0 and advanced to card 1',
    );
  });

  testWidgets('a card released short of the threshold springs back to centre', (
    tester,
  ) async {
    await _pumpCramPage(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(StudyFlipCard)),
    );
    // The first move is spent crossing the touch slop and is not reported as
    // a drag update, so tracking is measured across the move after it.
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 16));
    final afterSlop = _cardOffset(tester);

    await gesture.moveBy(const Offset(70, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      _cardOffset(tester) - afterSlop,
      closeTo(70, 0.5),
      reason: 'the card should track the pointer 1:1 while dragging',
    );

    // Come to rest before letting go, the way a finger that stops does, so the
    // release carries no momentum for the projection to amplify.
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(Offset.zero);
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pump();
    // The frame after release it is still out where it was let go, not snapped
    // home — the return is animated, and can therefore be grabbed again.
    expect(_cardOffset(tester), greaterThan(20));

    await tester.pump(const Duration(milliseconds: 800));
    expect(_cardOffset(tester), closeTo(0, 1));
    expect(
      find.text('Front 0'),
      findsOneWidget,
      reason: 'falling short is not a decision — the same card stays',
    );
  });

  testWidgets('reduced motion decides without flying the card off-screen', (
    tester,
  ) async {
    await _pumpCramPage(tester, reducedMotion: true);

    await tester.fling(
      find.byType(StudyFlipCard),
      const Offset(200, 0),
      3000,
    );
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      _cardOffset(tester),
      0,
      reason: 'reduced motion fades the card out in place, it does not slide',
    );

    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('Front 1'),
      findsOneWidget,
      reason: 'the decision still lands — only the travel is dropped',
    );
  });
}
