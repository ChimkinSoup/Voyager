import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
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

  Finder caption(String name, String position) => find.byWidgetPredicate(
    (widget) =>
        widget is RichText &&
        widget.text.toPlainText().startsWith(name) &&
        widget.text.toPlainText().endsWith(position),
  );

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
    expect(caption('[image 2]', '2 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(caption('[image 3]', '3 of 3'), findsOneWidget);

    // Past the last image it stays put.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(caption('[image 3]', '3 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(caption('[image 1]', '1 of 3'), findsOneWidget);
  });

  testWidgets('Esc and a click beside the image close it', (tester) async {
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(caption('[image 2]', '2 of 3'), findsNothing);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // In the viewer, left of the square picture.
    await tester.tapAt(const Offset(100, 300));
    // A single click waits out the double click's window.
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(caption('[image 2]', '2 of 3'), findsNothing);
  });
}
