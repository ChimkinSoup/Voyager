// v146: older builds marked an asset `localOnly` when an upload found no bytes
// on this device. Without bytes that now reads as "only on another device",
// which is never fetched (BUG-261), so the upgrade puts those rows back to
// `uploaded`, as a pulled asset is. A row holding the bytes keeps `localOnly`:
// it really was kept off the cloud.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/media_models.dart';

void main() {
  test(
    'a schema-145 asset left localOnly without bytes becomes fetchable',
    () async {
      final dir = Directory.systemTemp.createTempSync('voyager_local_only_mig');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/voyager.sqlite');

      final seed = AppDatabase(NativeDatabase(file));
      final seedRepository = DriftMediaRepository(seed);
      final now = DateTime.now().toUtc();
      MediaAsset asset(String id, MediaDownloadState download) => MediaAsset(
        id: id,
        contentHash: 'hash-$id',
        byteSize: 10,
        mimeType: 'image/png',
        width: 1,
        height: 1,
        uploadState: MediaUploadState.localOnly,
        downloadState: download,
        createdAt: now,
        updatedAt: now,
      );
      await seedRepository.upsertAsset(
        asset('elsewhere', MediaDownloadState.missing),
      );
      await seedRepository.upsertAsset(
        asset('held', MediaDownloadState.present),
      );
      await seed.customStatement('PRAGMA user_version = 145');
      await seed.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final repository = DriftMediaRepository(db);
      final elsewhere = (await repository.getAsset('elsewhere'))!;
      expect(elsewhere.uploadState, MediaUploadState.uploaded);
      expect(elsewhere.isOnlyElsewhere, isFalse);
      expect(
        (await repository.getAsset('held'))!.uploadState,
        MediaUploadState.localOnly,
      );
    },
  );
}
