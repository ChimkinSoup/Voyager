// A draft's image is attached to its chat by the asset it already has, not
// ingested again on send.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/gaia/host/gaia_media.dart';

import 'media_transfer_test.dart' show pngOf;

void main() {
  late Directory root;
  late AppDatabase db;
  late MediaService service;
  late GaiaMedia media;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('gaia_media_attach');
    db = AppDatabase.inMemory();
    service = MediaService(
      repository: DriftMediaRepository(db),
      fileStore: MediaFileStore(root: Directory('${root.path}/media')),
      readSettings: () async => const AppSettings(),
    );
    media = GaiaMedia(service);
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test('a stored draft image goes on the chat without its file read', () async {
    final draft = File('${root.path}/draft.png')
      ..writeAsBytesSync(pngOf(60, 40));
    final mediaId = await media.ingest(draft.path);

    final image = await media.attach(
      'chat-1',
      '${root.path}/gone.png',
      mediaId: mediaId,
    );

    expect(image.mediaId, mediaId);
    expect((image.width, image.height), (60, 40));
    expect(File(image.path).existsSync(), isTrue);
    final references = await service.referencesFor(
      FirestoreCollections.gaiaChats,
      'chat-1',
    );
    expect(references.map((r) => r.id), [image.referenceId]);
  });

  test('an uploaded asset on the retention clock is ingested again, so its '
      'upload is sent again (BUG-265)', () async {
    final draft = File('${root.path}/draft.png')
      ..writeAsBytesSync(pngOf(60, 40));
    final mediaId = await media.ingest(draft.path);
    // Uploaded, then left unreferenced: another device's purge may have
    // deleted the object.
    await service.repository.updateAssetTransferState(
      mediaId,
      uploadState: MediaUploadState.uploaded,
    );

    final image = await media.attach('chat-1', draft.path, mediaId: mediaId);

    expect(image.mediaId, mediaId);
    final asset = (await service.asset(mediaId))!;
    expect(asset.uploadState, isNot(MediaUploadState.uploaded));
  });

  test('an asset that is not here is ingested from the file', () async {
    final file = File('${root.path}/image.png')
      ..writeAsBytesSync(pngOf(30, 20));

    final image = await media.attach('chat-1', file.path, mediaId: 'missing');

    expect(image.mediaId, isNot('missing'));
    expect((image.width, image.height), (30, 20));
  });
}
