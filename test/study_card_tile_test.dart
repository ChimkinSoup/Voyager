// A deck's card grid shows fronts, but its search matches fronts *and*
// backs — so a back-only hit would otherwise render as a tile with nothing in
// it resembling the query. These pin the two rules that fix that: the tile
// turns around to the side that actually matched, and the match is marked
// wherever it lands, including alongside LaTeX that can't be marked. They
// also pin the tile's own contract: tap flips (except in multi-select, where
// the tap belongs to the checkbox), and the review countdown rides the front
// face alone.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_card_tile.dart';
import 'package:voyager/features/study/study_flip_card.dart';

StudyCard _card({
  required String front,
  required String back,
  DateTime? dueAt,
  double interval = 0,
  int reviewCount = 0,
}) {
  final now = DateTime.now().toUtc();
  return StudyCard(
    id: 'card',
    createdAt: now,
    updatedAt: now,
    deckId: 'deck',
    frontText: front,
    backText: back,
    interval: interval,
    reviewCount: reviewCount,
    dueAt: dueAt ?? now,
  );
}

Future<void> _pumpTile(
  WidgetTester tester,
  StudyCard card, {
  List<String> keywords = const [],
  bool showBack = false,
  bool multiSelectEnabled = false,
  ValueChanged<bool>? onFlipped,
  ValueChanged<bool>? onToggleSelected,
  DateTime? now,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 180,
          height: 180,
          child: StudyCardTile(
            card: card,
            keywords: keywords,
            showBack: showBack,
            onFlipped: onFlipped ?? (_) {},
            multiSelectEnabled: multiSelectEnabled,
            selected: false,
            onToggleSelected: onToggleSelected ?? (_) {},
            onLongPress: () {},
            onEdit: () {},
            onReverse: () {},
            onResetProgress: () {},
            onDelete: () {},
            now: now,
          ),
        ),
      ),
    ),
  ),
);

/// Which face the tile was handed.
bool _showingBack(WidgetTester tester) =>
    tester.widget<StudyFlipCard>(find.byType(StudyFlipCard)).initiallyShowingBack;

/// Substrings drawn with the search emphasis anywhere in the tile.
List<String> _highlighted(WidgetTester tester) {
  final hits = <String>[];
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    text.textSpan?.visitChildren((child) {
      if (child is TextSpan &&
          child.text != null &&
          child.style?.fontWeight == FontWeight.w600) {
        hits.add(child.text!);
      }
      return true;
    });
  }
  return hits;
}

void main() {
  group('search', () {
    test('a back-only match is the only case that turns a tile around', () {
      const keywords = ['derivative'];
      expect(
        studyCardMatchesBackOnly(
          _card(front: 'What is the slope?', back: 'The derivative'),
          keywords,
        ),
        isTrue,
      );
      expect(
        studyCardMatchesBackOnly(
          _card(front: 'Define derivative', back: 'A rate of change'),
          keywords,
        ),
        isFalse,
      );
      expect(
        studyCardMatchesBackOnly(
          _card(front: 'derivative of x', back: 'derivative is 1'),
          keywords,
        ),
        isFalse,
      );
      expect(
        studyCardMatchesBackOnly(
          _card(front: 'Front text', back: 'Back text'),
          const [],
        ),
        isFalse,
      );
    });

    testWidgets('the match is marked on whichever face is showing', (
      tester,
    ) async {
      await _pumpTile(
        tester,
        _card(front: 'What is the slope?', back: 'The derivative'),
        keywords: ['derivative'],
        showBack: true,
      );

      expect(_showingBack(tester), isTrue);
      expect(_highlighted(tester), contains('derivative'));
    });

    testWidgets('no query leaves the tile exactly as it was', (tester) async {
      await _pumpTile(tester, _card(front: 'Front text', back: 'Back text'));

      expect(_showingBack(tester), isFalse);
      expect(_highlighted(tester), isEmpty);
      expect(find.text('Front text'), findsOneWidget);
    });

    testWidgets('a card holding LaTeX is never windowed mid-delimiter', (
      tester,
    ) async {
      // Windowing this would risk cutting between the paired '$', which
      // renders the source verbatim instead of as math — so LaTeX cards show
      // in full.
      final long = 'padding ' * 60;
      await _pumpTile(
        tester,
        _card(front: 'Solve $long\$x^2\$ now', back: 'x = 0'),
        keywords: ['padding'],
      );

      expect(find.byType(StudyFlipCard), findsOneWidget);
      expect(_highlighted(tester), isNotEmpty);
    });

    testWidgets('an equation too wide for the tile shrinks instead of '
        'overflowing it', (tester) async {
      // Math doesn't line-break, so a wide equation lays out at its natural
      // width and used to stripe the tile with an overflow. It scales down to
      // the tile's width now — the pump itself fails if that regresses, since
      // the overflow throws.
      await _pumpTile(
        tester,
        _card(
          front:
              r'Evaluate $\int_{0}^{\infty} \frac{x^{3}}{e^{x}-1}\,dx = '
              r'\frac{\pi^{4}}{15} \quad \text{and} \quad '
              r'\sum_{n=1}^{\infty} \frac{1}{n^{2}} = \frac{\pi^{2}}{6}$',
          back: 'x = 0',
        ),
      );

      final fitted = tester.renderObject<RenderBox>(find.byType(FittedBox));
      final natural = (fitted as RenderProxyBox).child!.size;
      expect(natural.width, greaterThan(fitted.size.width));
      // 180 tile, less the face's 10pt padding on each side.
      expect(fitted.size.width, lessThanOrEqualTo(160.0));
    });

    testWidgets('a long plain-text card windows onto the match', (
      tester,
    ) async {
      await _pumpTile(
        tester,
        _card(front: '${'filler ' * 100}needle', back: 'back'),
        keywords: ['needle'],
      );

      expect(_showingBack(tester), isFalse);
      expect(_highlighted(tester), contains('needle'));
    });
  });

  group('flipping', () {
    testWidgets('a tap turns the tile over and reports the face it lands on', (
      tester,
    ) async {
      bool? reported;
      await _pumpTile(
        tester,
        _card(front: 'Front text', back: 'Back text'),
        onFlipped: (v) => reported = v,
      );

      await tester.tap(find.byType(StudyFlipCard));
      await tester.pumpAndSettle();

      expect(reported, isTrue);
      expect(find.text('Back text'), findsOneWidget);
    });

    testWidgets('in multi-select a tap selects instead of flipping', (
      tester,
    ) async {
      bool? flipped;
      bool? toggled;
      await _pumpTile(
        tester,
        _card(front: 'Front text', back: 'Back text'),
        multiSelectEnabled: true,
        onFlipped: (v) => flipped = v,
        onToggleSelected: (v) => toggled = v,
      );

      await tester.tap(find.byType(StudyFlipCard));
      await tester.pumpAndSettle();

      expect(flipped, isNull);
      expect(toggled, isTrue);
      expect(find.text('Front text'), findsOneWidget);
    });
  });

  group('review countdown', () {
    testWidgets('a scheduled card counts down in days, on the front only', (
      tester,
    ) async {
      // Both ends pinned to one clock: the countdown compares local calendar
      // days, so a duration measured from the real "now" reads a day higher
      // whenever the test happens to run late enough in the evening.
      final today = DateTime(2026, 8, 9, 9);
      final card = _card(
        front: 'Front text',
        back: 'Back text',
        dueAt: DateTime(2026, 8, 12, 11).toUtc(),
        interval: 3,
        reviewCount: 2,
      );

      await _pumpTile(tester, card, now: today);
      expect(find.text('3'), findsOneWidget);

      await _pumpTile(tester, card, showBack: true, now: today);
      expect(find.text('3'), findsNothing);
    });

    testWidgets('a card due now reads 0 in the error color', (tester) async {
      await _pumpTile(
        tester,
        _card(
          front: 'Front text',
          back: 'Back text',
          dueAt: DateTime.now().toUtc().subtract(const Duration(days: 9)),
          interval: 5,
          reviewCount: 4,
        ),
      );

      final label = tester.widget<Text>(find.text('0'));
      final scheme = Theme.of(
        tester.element(find.byType(StudyFlipCard)),
      ).colorScheme;
      expect(label.style?.color, scheme.error.withValues(alpha: 0.55));
    });
  });
}
