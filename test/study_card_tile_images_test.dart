// A deck tile is a thumbnail of a thumbnail, so it gets the compact image
// treatment STUDY_IMAGES.md specifies rather than the session's split layout:
// a face with words keeps showing its words and only reports that pictures are
// attached, while a face that is nothing but pictures shows the first one
// across the whole tile.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_card_tile.dart';

Uint8List _png(int seed) {
  final image = img.Image(width: 8, height: 8, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(seed * 30 % 255, 30, 60));
  return img.encodePng(image);
}

StudyCard _card({required String front, required String back}) {
  final now = DateTime.now().toUtc();
  return StudyCard(
    id: 'card-1',
    createdAt: now,
    updatedAt: now,
    deckId: 'deck-1',
    frontText: front,
    backText: back,
    dueAt: now,
  );
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late MediaFileStore fileStore;
  late MediaService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_tile_images');
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

  /// [WidgetTester.runAsync] because an ingest hands the decode to `compute`,
  /// and an isolate's answer never arrives inside a widget test's fake async
  /// zone.
  Future<List<MediaAsset>> ingest(WidgetTester tester, int count) async {
    final assets = <MediaAsset>[];
    await tester.runAsync(() async {
      for (var i = 0; i < count; i++) {
        assets.add(await service.ingestBytes(_png(i + 1)));
      }
    });
    return assets;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpTile(
    WidgetTester tester, {
    required StudyCard card,
    List<MediaAsset> frontImages = const [],
    List<MediaAsset> backImages = const [],
    bool showBack = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaServiceProvider.overrideWith((ref) => service),
          mediaFileStoreProvider.overrideWithValue(fileStore),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 180,
                height: 180,
                child: StudyCardTile(
                  card: card,
                  frontImages: frontImages,
                  backImages: backImages,
                  showBack: showBack,
                  onFlipped: (_) {},
                  multiSelectEnabled: false,
                  selected: false,
                  onToggleSelected: (_) {},
                  onLongPress: () {},
                  onEdit: () {},
                  onReverse: () {},
                  onResetProgress: () {},
                  onDelete: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('a card with no images shows neither picture nor badge', (
    tester,
  ) async {
    await pumpTile(
      tester,
      card: _card(front: 'Front', back: 'Back'),
    );

    expect(find.byType(MediaImage), findsNothing);
    expect(find.byIcon(PhosphorIconsRegular.image), findsNothing);
  });

  testWidgets('a face with text and images is marked, not illustrated', (
    tester,
  ) async {
    final images = await ingest(tester, 1);
    await pumpTile(
      tester,
      card: _card(front: 'What is this?', back: 'Back'),
      frontImages: images,
    );

    // Both faces are built for the flip, so the badge count is per face.
    expect(find.byIcon(PhosphorIconsRegular.image), findsOneWidget);
    expect(
      find.byType(MediaImage),
      findsNothing,
      reason: 'a full-width picture would swamp the text it previews',
    );
  });

  testWidgets('an image-only face fills the tile with the image', (
    tester,
  ) async {
    final images = await ingest(tester, 2);
    await pumpTile(
      tester,
      card: _card(front: '', back: 'Back'),
      frontImages: images,
    );

    // One image, not a carousel: a tile has no room to browse.
    expect(find.byType(MediaImage), findsOneWidget);
    expect(find.byIcon(PhosphorIconsRegular.image), findsNothing);
    expect(
      tester.widget<MediaImage>(find.byType(MediaImage)).asset.id,
      images.first.id,
    );
  });

  testWidgets('the badge follows the face that has the images', (tester) async {
    final images = await ingest(tester, 1);
    await pumpTile(
      tester,
      card: _card(front: 'Front', back: 'Back'),
      backImages: images,
      showBack: true,
    );

    expect(find.byIcon(PhosphorIconsRegular.image), findsOneWidget);
  });
}
