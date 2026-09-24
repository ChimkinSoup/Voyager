import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_gallery_strip.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/settings_models.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late MediaFileStore fileStore;
  late MediaService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_strip');
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

  // The empty strip's hover highlight is the InkWell's box, so that box has
  // to reach the strip's border rather than sit inset inside its padding.
  testWidgets('empty strip ink fills the bordered box', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaServiceProvider.overrideWith((ref) => service),
          mediaFileStoreProvider.overrideWithValue(fileStore),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: MediaGalleryStrip(
                collection: FirestoreCollections.journalEntries,
                documentId: 'entry-1',
                emptyLabel: 'No images yet',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final strip = tester.getRect(
      find.descendant(
        of: find.byType(MediaGalleryStrip),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final ink = tester.getRect(
      find.descendant(
        of: find.byType(MediaGalleryStrip),
        matching: find.byType(InkWell),
      ),
    );

    // Inside the 1px border on every side, and no further.
    expect(ink, strip.deflate(1));
  });
}
