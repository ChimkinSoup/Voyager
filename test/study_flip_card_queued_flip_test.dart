import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/study/study_flip_card.dart';

Future<void> _pumpCard(WidgetTester tester, List<bool> reported) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 120,
            child: StudyFlipCard(
              onFlipChanged: reported.add,
              front: const Text('front'),
              back: const Text('back'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a tap during a flip is not swallowed', (tester) async {
    final reported = <bool>[];
    await _pumpCard(tester, reported);

    await tester.tap(find.byType(StudyFlipCard));
    await tester.pump();
    // Mid-flip: the card is still turning, so this tap has nowhere to go yet.
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byType(StudyFlipCard));

    await tester.pumpAndSettle();

    // Landed on the back, then turned itself back to the front.
    expect(reported, [true, false]);
    expect(find.text('front'), findsOneWidget);
  });

  testWidgets('two taps during one flip cancel each other', (tester) async {
    final reported = <bool>[];
    await _pumpCard(tester, reported);

    await tester.tap(find.byType(StudyFlipCard));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(StudyFlipCard));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(StudyFlipCard));

    await tester.pumpAndSettle();

    expect(reported, [true]);
    expect(find.text('back'), findsOneWidget);
  });
}
