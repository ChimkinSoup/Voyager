import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_fan_stack.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

/// A distinct image per call, so each attach is a separate asset rather than
/// the same one deduplicated by content hash.
Uint8List pngOf(int seed) {
  final image = img.Image(width: 8, height: 8, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(seed * 20 % 255, 30, 60));
  return img.encodePng(image);
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late MediaFileStore fileStore;
  late MediaService service;

  const entryId = 'entry-1';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_fan');
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
  Future<List<MediaReference>> attach(WidgetTester tester, int count) async {
    final references = <MediaReference>[];
    await tester.runAsync(() async {
      for (var i = 0; i < count; i++) {
        references.add(
          await service.attachBytes(
            bytes: pngOf(i + 1),
            collection: FirestoreCollections.journalEntries,
            documentId: entryId,
          ),
        );
      }
    });
    return references;
  }

  /// Bounded pumps rather than `pumpAndSettle`: a [MediaImage] that is still
  /// resolving paints a progress indicator, which never settles.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpFan(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaServiceProvider.overrideWith((ref) => service),
          mediaFileStoreProvider.overrideWithValue(fileStore),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: MediaFanStack(
                collection: FirestoreCollections.journalEntries,
                documentId: entryId,
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('an entry with no images shows nothing at all', (tester) async {
    await pumpFan(tester);

    expect(find.byType(MediaImage), findsNothing);
    expect(
      tester.getSize(find.byType(MediaFanStack)),
      Size.zero,
      reason: 'an entry without images must not reserve corner space',
    );
  });

  testWidgets('every image is a card while under the cap', (tester) async {
    await attach(tester, 2);
    await pumpFan(tester);

    expect(find.byType(MediaImage), findsNWidgets(2));
    expect(find.textContaining('+'), findsNothing);
  });

  testWidgets('past the cap the fan draws three and counts the rest', (
    tester,
  ) async {
    await attach(tester, 5);
    await pumpFan(tester);

    expect(find.byType(MediaImage), findsNWidgets(3));
    expect(find.text('+2'), findsOneWidget);
  });

  testWidgets('the fan opens the lightbox on every image, not just the three', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await attach(tester, 5);
    await pumpFan(tester);

    await tester.tap(find.byType(MediaFanStack));
    await settle(tester);

    // More than one: the viewer builds the neighbouring page ahead of the
    // swipe so its image is ready before the slide starts.
    expect(find.byType(InteractiveViewer), findsWidgets);
    expect(
      find.text('1 / 5'),
      findsOneWidget,
      reason: 'the viewer swipes the whole set, however few cards are drawn',
    );
  });

  testWidgets('removing from the lightbox takes the image off the entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await attach(tester, 2);
    await pumpFan(tester);

    await tester.tap(find.byType(MediaFanStack));
    await settle(tester);
    await tester.tap(find.byTooltip('Remove image'));
    await settle(tester);
    await tester.tap(find.widgetWithText(GlassButton, 'Remove'));
    await settle(tester);

    // Still open, standing on the image that took the removed one's place.
    expect(find.byType(InteractiveViewer), findsWidgets);

    final remaining = await service.referencesFor(
      FirestoreCollections.journalEntries,
      entryId,
    );
    expect(remaining, hasLength(1));
  });
}
