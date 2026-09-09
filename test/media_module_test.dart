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
import 'package:voyager/domain/services/media_ingest.dart';

/// A solid-colour PNG of the given size, as encoded bytes.
Uint8List pngOf(int width, int height, {int r = 200, int g = 30, int b = 60}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return img.encodePng(image);
}

/// A PNG with a genuinely transparent pixel, to exercise the alpha branch.
Uint8List transparentPng(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(10, 20, 30, 255));
  image.setPixelRgba(0, 0, 0, 0, 0, 0);
  return img.encodePng(image);
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late DriftMediaRepository repository;
  late MediaFileStore fileStore;
  late MediaService service;
  late AppSettings settings;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_media_test');
    db = AppDatabase.inMemory();
    repository = DriftMediaRepository(db);
    fileStore = MediaFileStore(root: Directory('${tempDir.path}/media'));
    settings = const AppSettings();
    service = MediaService(
      repository: repository,
      fileStore: fileStore,
      readSettings: () async => settings,
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('ingest validation', () {
    test('sniffs the formats the pipeline accepts', () {
      expect(sniffImageFormat(pngOf(4, 4)), SniffedImageFormat.png);
      expect(
        sniffImageFormat(img.encodeJpg(img.Image(width: 4, height: 4))),
        SniffedImageFormat.jpeg,
      );
      expect(
        sniffImageFormat(Uint8List.fromList('GIF89a padding here'.codeUnits)),
        SniffedImageFormat.gif,
      );
    });

    test('refuses an input over 10 MB before decoding it', () {
      final huge = Uint8List(maxIngestInputBytes + 1);
      // PNG magic so the size check is provably what rejected it, not the
      // format sniff.
      huge.setRange(0, 4, [0x89, 0x50, 0x4E, 0x47]);
      expect(
        () => validateIngestInput(huge),
        throwsA(
          isA<MediaIngestException>().having(
            (e) => e.message,
            'message',
            contains('too large'),
          ),
        ),
      );
    });

    test('refuses a GIF by name', () {
      expect(
        () => validateIngestInput(
          Uint8List.fromList('GIF89a padding here'.codeUnits),
        ),
        throwsA(
          isA<MediaIngestException>().having(
            (e) => e.message,
            'message',
            contains('GIF'),
          ),
        ),
      );
    });

    test('refuses something that is not an image at all', () {
      expect(
        () => validateIngestInput(
          Uint8List.fromList('this is just prose, not a picture'.codeUnits),
        ),
        throwsA(isA<MediaIngestException>()),
      );
    });
  });

  group('ingest pipeline', () {
    test('downscales to the max edge and keeps the aspect ratio', () {
      final result = ingestImageIsolate(
        MediaIngestRequest.encoded(pngOf(4000, 2000)),
      );
      expect(result.width, maxIngestEdgePx);
      expect(result.height, maxIngestEdgePx ~/ 2);
    });

    test('leaves an image already under the cap at its own size', () {
      final result = ingestImageIsolate(
        MediaIngestRequest.encoded(pngOf(640, 480)),
      );
      expect(result.width, 640);
      expect(result.height, 480);
    });

    test('encodes an opaque image as JPEG', () {
      final result = ingestImageIsolate(
        MediaIngestRequest.encoded(pngOf(64, 64)),
      );
      expect(result.format, MediaImageFormat.jpeg);
    });

    test('keeps PNG when the image is actually transparent', () {
      final result = ingestImageIsolate(
        MediaIngestRequest.encoded(transparentPng(64, 64)),
      );
      expect(result.format, MediaImageFormat.png);
    });

    test('hashes the post-ingest bytes, so identical output dedupes', () {
      final a = ingestImageIsolate(MediaIngestRequest.encoded(pngOf(64, 64)));
      final b = ingestImageIsolate(MediaIngestRequest.encoded(pngOf(64, 64)));
      expect(a.contentHash, b.contentHash);

      final other = ingestImageIsolate(
        MediaIngestRequest.encoded(pngOf(64, 64, r: 10)),
      );
      expect(other.contentHash, isNot(a.contentHash));
    });
  });

  group('attach', () {
    test('writes a blob, an asset row and a reference', () async {
      final reference = await service.attachBytes(
        bytes: pngOf(120, 90),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );

      final asset = (await repository.getAsset(reference.mediaId))!;
      expect(asset.width, 120);
      expect(asset.height, 90);
      expect(asset.mimeType, 'image/jpeg');
      expect(asset.byteSize, greaterThan(0));
      expect(await fileStore.hasBytes(asset), isTrue);

      final owned = await service.referencesFor(
        FirestoreCollections.todoTasks,
        'task-1',
      );
      expect(owned.map((r) => r.id), [reference.id]);
    });

    test('a referenced asset is not on the retention clock', () async {
      final reference = await service.attachBytes(
        bytes: pngOf(32, 32),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      final asset = (await repository.getAsset(reference.mediaId))!;
      expect(asset.unreferencedAt, isNull);
      expect(asset.retentionClockStartedAt, isNull);
    });

    test('identical bytes dedupe onto one asset with two references', () async {
      final first = await service.attachBytes(
        bytes: pngOf(50, 50),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      final second = await service.attachBytes(
        bytes: pngOf(50, 50),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-2',
      );

      expect(second.mediaId, first.mediaId);
      expect(await repository.listAssets(), hasLength(1));
      expect(
        await repository.listReferencesForAsset(first.mediaId),
        hasLength(2),
      );
    });

    test('appends to the end of a gallery', () async {
      for (var i = 0; i < 3; i++) {
        await service.attachBytes(
          bytes: pngOf(20 + i, 20),
          collection: FirestoreCollections.todoTasks,
          documentId: 'task-1',
        );
      }
      final references = await service.referencesFor(
        FirestoreCollections.todoTasks,
        'task-1',
      );
      expect(references.map((r) => r.sortOrder), [0, 1, 2]);
    });

    test('uploads stay local forever when the setting is off', () async {
      settings = const AppSettings(mediaRemoteUploadsEnabled: false);
      final reference = await service.attachBytes(
        bytes: pngOf(24, 24),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      final asset = (await repository.getAsset(reference.mediaId))!;
      expect(asset.uploadState, MediaUploadState.localOnly);
    });

    test('queueLocalOnlyUploads re-queues them once uploads are on', () async {
      settings = const AppSettings(mediaRemoteUploadsEnabled: false);
      final reference = await service.attachBytes(
        bytes: pngOf(24, 24),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );

      settings = const AppSettings();
      expect(await service.queueLocalOnlyUploads(), 1);
      final asset = (await repository.getAsset(reference.mediaId))!;
      expect(asset.uploadState, MediaUploadState.pending);
    });
  });

  group('refcount', () {
    test('the clock starts only when the last reference goes', () async {
      final first = await service.attachBytes(
        bytes: pngOf(40, 40),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      final second = await service.addReference(
        mediaId: first.mediaId,
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-2',
      );

      await service.removeReference(first.id);
      expect(
        (await repository.getAsset(first.mediaId))!.unreferencedAt,
        isNull,
        reason: 'one reference is still live',
      );

      await service.removeReference(second.id);
      expect(
        (await repository.getAsset(first.mediaId))!.unreferencedAt,
        isNotNull,
      );
    });

    test('re-attaching the same bytes stops the clock again', () async {
      final reference = await service.attachBytes(
        bytes: pngOf(40, 40),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      await service.removeReference(reference.id);
      expect(
        (await repository.getAsset(reference.mediaId))!.unreferencedAt,
        isNotNull,
      );

      final again = await service.attachBytes(
        bytes: pngOf(40, 40),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      expect(again.mediaId, reference.mediaId);
      expect(
        (await repository.getAsset(reference.mediaId))!.unreferencedAt,
        isNull,
      );
    });

    test('deleting a parent detaches everything it owned', () async {
      await service.attachBytes(
        bytes: pngOf(41, 41),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      await service.attachBytes(
        bytes: pngOf(42, 42),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );

      await service.removeReferencesForOwner(
        FirestoreCollections.todoTasks,
        'task-1',
      );

      expect(
        await service.referencesFor(FirestoreCollections.todoTasks, 'task-1'),
        isEmpty,
      );
      for (final asset in await repository.listAssets()) {
        expect(asset.unreferencedAt, isNotNull);
      }
    });

    test('the detach reports the stamp its own restore matches on', () async {
      await service.attachBytes(
        bytes: pngOf(41, 41),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );

      final stamp = await service.removeReferencesForOwner(
        FirestoreCollections.todoTasks,
        'task-1',
      );
      expect(stamp, isNotNull);

      // The restore matches `deletedAt` exactly, and rows are stored to
      // microsecond precision. A caller that guesses the instant — passing the
      // parent's own `deletedAt`, which is a *different* `utcNow()` — matches
      // nothing and silently leaves every image detached. Hence the detach
      // reporting the instant it actually stamped rather than the caller
      // inferring it.
      await service.restoreReferencesForOwner(
        FirestoreCollections.todoTasks,
        'task-1',
        stamp!.subtract(const Duration(microseconds: 1)),
      );
      expect(
        await service.referencesFor(FirestoreCollections.todoTasks, 'task-1'),
        isEmpty,
        reason: 'a near-miss instant must not revive anything',
      );

      await service.restoreReferencesForOwner(
        FirestoreCollections.todoTasks,
        'task-1',
        stamp,
      );
      expect(
        await service.referencesFor(FirestoreCollections.todoTasks, 'task-1'),
        hasLength(1),
      );
    });

    test('a detach with nothing to detach reports no stamp', () async {
      expect(
        await service.removeReferencesForOwner(
          FirestoreCollections.todoTasks,
          'task-with-no-images',
        ),
        isNull,
      );
    });

    test('removing one image can be undone from its snapshot', () async {
      final reference = await service.attachBytes(
        bytes: pngOf(43, 43),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
        displayWidthPx: 240,
      );

      await service.removeReference(reference.id);
      expect(
        await service.referencesFor(FirestoreCollections.todoTasks, 'task-1'),
        isEmpty,
      );

      await service.restoreReference(reference);

      final live = await service.referencesFor(
        FirestoreCollections.todoTasks,
        'task-1',
      );
      expect(live, hasLength(1));
      expect(live.single.id, reference.id);
      // The placement comes back where it was, not just the row: sortOrder and
      // the display width are what decide where the image lands in the strip.
      expect(live.single.sortOrder, reference.sortOrder);
      expect(live.single.displayWidthPx, 240);
      expect(
        live.single.version,
        greaterThan((await repository.getReference(reference.id))!.version - 1),
        reason: 'the restore has to outrank the tombstone on the next sync',
      );
      // The asset is back on the clock rather than counting down to a purge.
      expect(
        (await repository.getAsset(reference.mediaId))!.unreferencedAt,
        isNull,
      );
    });

    test('replacing an image keeps the slot and swaps the refcounts', () async {
      final reference = await service.attachBytes(
        bytes: pngOf(60, 60),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
        displayWidthPx: 320,
      );
      final original = reference.mediaId;

      final replacement = await service.replaceReferenceImage(
        referenceId: reference.id,
        bytes: pngOf(60, 60, g: 200),
      );

      final updated = (await repository.getReference(reference.id))!;
      expect(updated.mediaId, replacement.id);
      expect(updated.sortOrder, reference.sortOrder);
      expect(updated.displayWidthPx, 320);
      expect((await repository.getAsset(original))!.unreferencedAt, isNotNull);
      expect(
        (await repository.getAsset(replacement.id))!.unreferencedAt,
        isNull,
      );
    });
  });

  group('purge', () {
    test('keeps everything inside the 30-day window', () async {
      final reference = await service.attachBytes(
        bytes: pngOf(70, 70),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      await service.removeReference(reference.id);

      await service.purgeExpired(DateTime.now().toUtc());

      final asset = await repository.getAsset(reference.mediaId);
      expect(asset, isNotNull);
      expect(await fileStore.hasBytes(asset!), isTrue);
    });

    test('deletes rows and blobs once the window has closed', () async {
      final reference = await service.attachBytes(
        bytes: pngOf(71, 71),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      final asset = (await repository.getAsset(reference.mediaId))!;
      await service.removeReference(reference.id);

      await service.purgeExpired(
        DateTime.now().toUtc().add(const Duration(days: 31)),
      );

      expect(await repository.getAsset(reference.mediaId), isNull);
      expect(await fileStore.hasBytes(asset), isFalse);
      expect(await repository.getReference(reference.id), isNull);
    });

    test('sweeps blobs no row claims any more', () async {
      final orphan = await fileStore.writeBytes(
        'deadbeef',
        MediaImageFormat.jpeg,
        pngOf(8, 8),
      );
      expect(await orphan.exists(), isTrue);

      await service.purgeExpired(DateTime.now().toUtc());

      expect(await orphan.exists(), isFalse);
    });
  });

  group('storage usage', () {
    test('counts live assets and the bytes on disk', () async {
      await service.attachBytes(
        bytes: pngOf(80, 80),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      await service.attachBytes(
        bytes: pngOf(80, 80, b: 200),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );

      final usage = await service.storageUsage();
      expect(usage.assetCount, 2);
      expect(usage.byteSize, greaterThan(0));
      expect(usage.pendingUploadCount, 2);
    });
  });

  group('deleteAssetEverywhere', () {
    test('detaches every reference and drops local bytes immediately', () async {
      final first = await service.attachBytes(
        bytes: pngOf(40, 40),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      await service.addReference(
        mediaId: first.mediaId,
        collection: FirestoreCollections.journalEntries,
        documentId: 'entry-1',
      );
      final asset = (await repository.getAsset(first.mediaId))!;
      expect(await fileStore.hasBytes(asset), isTrue);

      await service.deleteAssetEverywhere(first.mediaId);

      expect(
        await service.referencesFor(
          FirestoreCollections.todoTasks,
          'task-1',
        ),
        isEmpty,
      );
      expect(
        await service.referencesFor(
          FirestoreCollections.journalEntries,
          'entry-1',
        ),
        isEmpty,
      );
      final tombstone = await repository.getAsset(first.mediaId);
      expect(tombstone, isNotNull);
      expect(tombstone!.deletedAt, isNotNull);
      expect(await fileStore.hasBytes(asset), isFalse);
      expect(await repository.listAssets(), isEmpty);
    });

    test('reclaims disk space before the retention window closes', () async {
      final reference = await service.attachBytes(
        bytes: pngOf(72, 72),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      final asset = (await repository.getAsset(reference.mediaId))!;
      final before = await service.storageUsage();

      await service.deleteAssetEverywhere(reference.mediaId);

      final after = await service.storageUsage();
      expect(after.assetCount, before.assetCount - 1);
      expect(after.byteSize, lessThan(before.byteSize));
      expect(await fileStore.hasBytes(asset), isFalse);
    });
  });

  group('missing bytes', () {
    test('bytesFor returns null when downloads are disabled', () async {
      settings = const AppSettings(mediaRemoteDownloadsEnabled: false);
      final now = DateTime.now().toUtc();
      final asset = MediaAsset(
        id: 'remote-only',
        contentHash: 'nothing-on-this-device',
        byteSize: 100,
        mimeType: 'image/jpeg',
        width: 10,
        height: 10,
        downloadState: MediaDownloadState.missing,
        createdAt: now,
        updatedAt: now,
      );
      await repository.upsertAsset(asset);

      expect(await service.bytesFor(asset), isNull);
      expect(
        (await repository.getAsset('remote-only'))!.downloadState,
        MediaDownloadState.missing,
        reason: 'a disabled download must not leave the asset queued',
      );
    });
  });
}
