// A lightbox page that joins a precache still in flight inherits that load's
// failure, even when the bytes have since arrived. The image reads them again
// once — and only once, so a file that cannot be decoded is not re-read on
// every frame.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

/// Hands out [answers] in turn, repeating the last.
class _ScriptedMediaService extends MediaService {
  _ScriptedMediaService(
    this.answers, {
    required super.repository,
    required super.fileStore,
  }) : super(
         readSettings: () async =>
             const AppSettings(mediaRemoteDownloadsEnabled: false),
       );

  final List<Uint8List?> answers;
  int reads = 0;

  @override
  Future<Uint8List?> bytesFor(MediaAsset asset) async =>
      answers[(reads++).clamp(0, answers.length - 1)];
}

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_error_reload');
    db = AppDatabase.inMemory();
    // Decodes are cached by hash across tests otherwise.
    PaintingBinding.instance.imageCache.clear();
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  final asset = MediaAsset(
    id: 'a1',
    createdAt: DateTime.utc(2026, 10, 1),
    updatedAt: DateTime.utc(2026, 10, 1),
    contentHash: 'h1',
    byteSize: 10,
    mimeType: 'image/png',
    width: 2,
    height: 2,
    uploadState: MediaUploadState.uploaded,
    downloadState: MediaDownloadState.present,
  );
  final garbage = Uint8List.fromList([1, 2, 3, 4]);
  final png = img.encodePng(img.Image(width: 2, height: 2));

  _ScriptedMediaService scripted(List<Uint8List?> answers) =>
      _ScriptedMediaService(
        answers,
        repository: DriftMediaRepository(db),
        fileStore: MediaFileStore(root: Directory('${tempDir.path}/media')),
      );

  Future<void> pump(WidgetTester tester, MediaService service) async {
    // Real time: decoding runs off the test's fake async zone.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mediaServiceProvider.overrideWith((ref) => service),
            databaseProvider.overrideWithValue(db),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: MediaImage(
                asset: asset,
                width: 100,
                height: 100,
                decodeFullResolution: true,
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
  }

  RawImage? painted(WidgetTester tester) {
    final found = find.byType(RawImage);
    return found.evaluate().isEmpty ? null : tester.widget<RawImage>(found);
  }

  testWidgets('a failed decode reads the bytes again and paints them', (
    tester,
  ) async {
    final service = scripted([garbage, png]);
    await pump(tester, service);
    expect(service.reads, 2);
    expect(painted(tester)?.image, isNotNull);
  });

  testWidgets('a file that never decodes is read again only once', (
    tester,
  ) async {
    final service = scripted([garbage]);
    await pump(tester, service);
    expect(service.reads, 2);
    expect(painted(tester)?.image, isNull);
  });
}
