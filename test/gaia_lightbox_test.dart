import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_lightbox.dart';

void main() {
  const images = [
    GaiaImagePart(mediaId: 'a', label: 1, width: 1, height: 1),
    GaiaImagePart(mediaId: 'b', label: 2, width: 1, height: 1),
    // The same picture again: one media id, its own page.
    GaiaImagePart(mediaId: 'a', label: 3, width: 1, height: 1),
  ];

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showGaiaLightbox(
              context,
              images: images,
              initial: 1,
              imageFile: (_) async => null,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the clicked image and steps through the chat', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.text('[image 2]'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.text('[image 3]'), findsOneWidget);

    // The last image only leans past the edge and comes back.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('Esc and a click beside the image close it', (tester) async {
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsNothing);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsNothing);
  });
}
