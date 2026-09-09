// Reversing a card swaps its two faces and duplicating one copies it, and
// with a gallery per face (STUDY_IMAGES.md) both operations have to carry the
// pictures with them — the two reference operations study asks the media
// module for.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

Uint8List _pngOf(int seed) {
  final image = img.Image(width: 8, height: 8, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(seed * 20 % 255, 30, 60));
  return img.encodePng(image);
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late DriftMediaRepository repository;
  late MediaService service;

  const cardId = 'card-1';
  const copyId = 'card-2';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_study_media');
    db = AppDatabase.inMemory();
    repository = DriftMediaRepository(db);
    service = MediaService(
      repository: repository,
      fileStore: MediaFileStore(root: Directory('${tempDir.path}/media')),
      readSettings: () async => const AppSettings(),
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> attach(MediaFacet facet, int seed) async {
    await service.attachBytes(
      bytes: _pngOf(seed),
      collection: FirestoreCollections.studyCards,
      documentId: cardId,
      facet: facet,
    );
  }

  Future<List<String>> mediaIds(String documentId, MediaFacet facet) async {
    final references = await service.referencesFor(
      FirestoreCollections.studyCards,
      documentId,
      facet: facet,
    );
    return [for (final r in references) r.mediaId];
  }

  group('swapFacets', () {
    test('reversing a card carries each face its own pictures', () async {
      await attach(MediaFacet.front, 1);
      await attach(MediaFacet.front, 2);
      await attach(MediaFacet.back, 3);
      final front = await mediaIds(cardId, MediaFacet.front);
      final back = await mediaIds(cardId, MediaFacet.back);

      await service.swapFacets(
        collection: FirestoreCollections.studyCards,
        documentId: cardId,
        a: MediaFacet.front,
        b: MediaFacet.back,
      );

      expect(await mediaIds(cardId, MediaFacet.back), front);
      expect(await mediaIds(cardId, MediaFacet.front), back);
    });

    test('a one-sided card ends up one-sided the other way round', () async {
      await attach(MediaFacet.front, 1);

      await service.swapFacets(
        collection: FirestoreCollections.studyCards,
        documentId: cardId,
        a: MediaFacet.front,
        b: MediaFacet.back,
      );

      expect(await mediaIds(cardId, MediaFacet.front), isEmpty);
      expect(await mediaIds(cardId, MediaFacet.back), hasLength(1));
    });

    test('carousel order survives the swap', () async {
      await attach(MediaFacet.front, 1);
      await attach(MediaFacet.front, 2);
      await attach(MediaFacet.front, 3);
      final ordered = await mediaIds(cardId, MediaFacet.front);

      await service.swapFacets(
        collection: FirestoreCollections.studyCards,
        documentId: cardId,
        a: MediaFacet.front,
        b: MediaFacet.back,
      );

      expect(await mediaIds(cardId, MediaFacet.back), ordered);
    });
  });

  group('duplicateReferencesForOwner', () {
    test('the copy gets both galleries, and the original keeps its own', () async {
      await attach(MediaFacet.front, 1);
      await attach(MediaFacet.back, 2);
      final front = await mediaIds(cardId, MediaFacet.front);
      final back = await mediaIds(cardId, MediaFacet.back);

      await service.duplicateReferencesForOwner(
        collection: FirestoreCollections.studyCards,
        fromDocumentId: cardId,
        toDocumentId: copyId,
      );

      expect(await mediaIds(copyId, MediaFacet.front), front);
      expect(await mediaIds(copyId, MediaFacet.back), back);
      expect(await mediaIds(cardId, MediaFacet.front), front);
      expect(await mediaIds(cardId, MediaFacet.back), back);
    });

    test('it copies placements, not blobs', () async {
      await attach(MediaFacet.front, 1);
      final assetsBefore = await repository.listAssets();

      await service.duplicateReferencesForOwner(
        collection: FirestoreCollections.studyCards,
        fromDocumentId: cardId,
        toDocumentId: copyId,
      );

      // One blob, two references — which is also what keeps the asset off the
      // retention clock when the original card is later deleted.
      expect(await repository.listAssets(), hasLength(assetsBefore.length));
      final mediaId = assetsBefore.single.id;
      expect(await repository.listReferencesForAsset(mediaId), hasLength(2));
    });

    test('deleting the original leaves the copy holding the blob', () async {
      await attach(MediaFacet.front, 1);
      await service.duplicateReferencesForOwner(
        collection: FirestoreCollections.studyCards,
        fromDocumentId: cardId,
        toDocumentId: copyId,
      );

      await service.removeReferencesForOwner(
        FirestoreCollections.studyCards,
        cardId,
      );

      expect(await mediaIds(copyId, MediaFacet.front), hasLength(1));
      final asset = (await repository.listAssets()).single;
      expect(
        asset.unreferencedAt,
        isNull,
        reason: 'the copy still points at it',
      );
    });
  });
}
