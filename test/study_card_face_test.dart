// Study cards carry their images in a gallery per face rather than as tokens
// in the card's text (STUDY_IMAGES.md). These pin the layout that replaced the
// inline renderer: text alone gets the whole face, images alone get the whole
// face, and a face with both gives the text only the room it needs and the
// picture everything left over — down to an even split, past which the text
// scrolls instead of growing. Plus the carousel that browses a face with more
// than one picture, which must never be a swipe, because cram grades a card
// by swiping it.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/study/study_card_face.dart';
import 'package:voyager/features/study/study_rich_text.dart';

Uint8List _pngOf(int width, int height, {int r = 200}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(r, 30, 60));
  return img.encodePng(image);
}

const _faceSize = Size(300, 400);

void main() {
  group('legacy tokens', () {
    test('are stripped, along with the line break they were given', () {
      expect(
        stripStudyMediaTokens('above\n![[media:abc-1|480]]\nbelow'),
        'above\nbelow',
      );
      expect(stripStudyMediaTokens('![[media:abc]]'), '');
      // Not a token, so not touched.
      expect(stripStudyMediaTokens('![[note:abc]]'), '![[note:abc]]');
      expect(stripStudyMediaTokens('plain prose'), 'plain prose');
    });

    test('a face holding nothing but a token counts as image-only', () {
      expect(StudyCardFace.hasVisibleText('![[media:abc]]'), isFalse);
      expect(StudyCardFace.hasVisibleText('  '), isFalse);
      expect(StudyCardFace.hasVisibleText('![[media:abc]] caption'), isTrue);
    });
  });

  group('StudyCardFace layout', () {
    late Directory tempDir;
    late AppDatabase db;
    late MediaFileStore fileStore;
    late MediaService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('voyager_card_face');
      db = AppDatabase.inMemory();
      fileStore = MediaFileStore(root: Directory('${tempDir.path}/media'));
      service = MediaService(
        repository: DriftMediaRepository(db),
        fileStore: fileStore,
        readSettings: () async => const AppSettings(),
      );
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    /// [WidgetTester.runAsync] because an ingest hands the decode to
    /// `compute`, and an isolate's answer never arrives inside a widget test's
    /// fake async zone.
    Future<List<MediaAsset>> ingest(WidgetTester tester, int count) async {
      final assets = <MediaAsset>[];
      await tester.runAsync(() async {
        for (var i = 0; i < count; i++) {
          assets.add(await service.ingestBytes(_pngOf(40 + i, 30, r: 40 * (i + 1))));
        }
      });
      return assets;
    }

    /// Bounded pumps rather than `pumpAndSettle`: a [MediaImage] that is still
    /// resolving paints a progress indicator, which never settles.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> pumpFace(
      WidgetTester tester, {
      required String text,
      required List<MediaAsset> images,
    }) {
      return tester.pumpWidget(
        ProviderScope(
          overrides: [
            mediaServiceProvider.overrideWith((ref) => service),
            mediaFileStoreProvider.overrideWithValue(fileStore),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox.fromSize(
                  size: _faceSize,
                  child: StudyCardFace(text: text, images: images),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a text-only face is all text', (tester) async {
      await pumpFace(tester, text: 'What is a monad?', images: const []);
      await settle(tester);

      expect(find.byType(StudyRichText), findsOneWidget);
      expect(find.byType(StudyCardImageCarousel), findsNothing);
      expect(tester.getSize(find.byType(StudyRichText)).height, lessThan(400));
    });

    testWidgets('an image-only face is all image', (tester) async {
      final images = await ingest(tester, 1);
      await pumpFace(tester, text: '   ', images: images);
      await settle(tester);

      expect(find.byType(StudyCardImageCarousel), findsOneWidget);
      expect(find.byType(StudyRichText), findsNothing);
      expect(
        tester.getSize(find.byType(StudyCardImageCarousel)).height,
        _faceSize.height,
      );
    });

    testWidgets('short text leaves the rest of the face to the image', (
      tester,
    ) async {
      final images = await ingest(tester, 1);
      await pumpFace(tester, text: 'the answer', images: images);
      await settle(tester);

      final carousel = tester.getRect(find.byType(StudyCardImageCarousel));
      final richText = tester.getRect(find.byType(StudyRichText));
      // Images on top, text underneath — not the other way round.
      expect(carousel.bottom, lessThanOrEqualTo(richText.top));
      // One line of text keeps one line's worth of the face; the picture has
      // everything else, well past the even split it used to be pinned to.
      expect(richText.height, lessThan(_faceSize.height / 4));
      expect(carousel.height, greaterThan(_faceSize.height * 0.7));
      expect(carousel.height + richText.height, lessThan(_faceSize.height));
    });

    testWidgets('a wall of text stops at half, and scrolls from there', (
      tester,
    ) async {
      final images = await ingest(tester, 1);
      await pumpFace(
        tester,
        // Far more than half the face can hold at this width.
        text: List.filled(40, 'answer').join(' '),
        images: images,
      );
      await settle(tester);

      final carousel = tester.getRect(find.byType(StudyCardImageCarousel));
      final viewport = tester.getRect(
        find.ancestor(
          of: find.byType(StudyRichText),
          matching: find.byType(VoyagerScrollView),
        ),
      );
      // The image is held to half the face, give or take the region gap, and
      // the text region takes the other half rather than growing further.
      expect(carousel.height, closeTo(_faceSize.height / 2, 12));
      expect(viewport.height, closeTo(_faceSize.height / 2, 12));
      expect(
        viewport.bottom,
        closeTo(tester.getRect(find.byType(StudyCardFace)).bottom, 1),
      );

      // The text itself is taller than the region showing it, so it scrolls.
      final scrollable = find.descendant(
        of: find.byType(VoyagerScrollView),
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));

      await tester.drag(scrollable, const Offset(0, -60));
      await tester.pump();
      expect(position.pixels, greaterThan(0));
    });

    testWidgets('one image gets no carousel chrome', (tester) async {
      final images = await ingest(tester, 1);
      await pumpFace(tester, text: '', images: images);
      await settle(tester);

      expect(find.byTooltip('Next image'), findsNothing);
      expect(find.byTooltip('Previous image'), findsNothing);
    });

    testWidgets('arrows browse several images, and stop at the ends', (
      tester,
    ) async {
      final images = await ingest(tester, 3);
      await pumpFace(tester, text: '', images: images);
      await settle(tester);

      MediaAsset shown() => tester.widget<MediaImage>(
        find.descendant(
          of: find.byType(StudyCardImageCarousel),
          matching: find.byType(MediaImage),
        ),
      ).asset;

      expect(shown().id, images.first.id);

      await tester.tap(find.byTooltip('Next image'));
      await tester.pump();
      expect(shown().id, images[1].id);

      await tester.tap(find.byTooltip('Next image'));
      await tester.pump();
      expect(shown().id, images[2].id);

      // Already on the last one: the arrow is disabled rather than wrapping.
      await tester.tap(find.byTooltip('Next image'));
      await tester.pump();
      expect(shown().id, images[2].id);

      await tester.tap(find.byTooltip('Previous image'));
      await tester.pump();
      expect(shown().id, images[1].id);
    });

    testWidgets('an arrow at the end of the queue swallows its own tap', (
      tester,
    ) async {
      // The face sits inside a card that flips when tapped. A disabled arrow
      // used to register no recognizer at all, so a click on it fell through
      // and flipped the card — the one thing the user was plainly not aiming
      // at.
      final images = await ingest(tester, 2);
      var flips = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mediaServiceProvider.overrideWith((ref) => service),
            mediaFileStoreProvider.overrideWithValue(fileStore),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: GestureDetector(
                  onTap: () => flips++,
                  child: SizedBox.fromSize(
                    size: _faceSize,
                    child: StudyCardFace(text: '', images: images),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      // On the first image, so Previous is the dead one.
      await tester.tap(find.byTooltip('Previous image'));
      await tester.pump();
      expect(flips, 0);

      // And the live arrow still browses without flipping either.
      await tester.tap(find.byTooltip('Next image'));
      await tester.pump();
      expect(flips, 0);

      await tester.tap(find.byTooltip('Next image'));
      await tester.pump();
      expect(flips, 0);
    });

    testWidgets('a horizontal drag does not change the image', (tester) async {
      // Cram grades by swiping the whole card sideways. If the carousel took
      // that gesture too, every image on a cram card would be a coin toss.
      final images = await ingest(tester, 2);
      await pumpFace(tester, text: '', images: images);
      await tester.pump();

      await tester.drag(
        find.byType(StudyCardImageCarousel),
        const Offset(-200, 0),
      );
      await tester.pump();

      final shown = tester.widget<MediaImage>(
        find.descendant(
          of: find.byType(StudyCardImageCarousel),
          matching: find.byType(MediaImage),
        ),
      ).asset;
      expect(shown.id, images.first.id);
    });

    testWidgets('a legacy token renders as nothing on the face', (
      tester,
    ) async {
      await pumpFace(
        tester,
        text: 'before\n![[media:dead-id|300]]\nafter',
        images: const [],
      );
      await settle(tester);

      expect(find.text('before\nafter'), findsOneWidget);
      expect(find.textContaining('![[media:'), findsNothing);
    });
  });
}
