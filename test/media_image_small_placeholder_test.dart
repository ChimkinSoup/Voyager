// BUG-216: a 40 px thumbnail (the journal editor's image fan) whose bytes
// aren't here shows its placeholder's icon alone; the label didn't fit and
// overflowed. Larger tiles keep the label.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late MediaService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_placeholder');
    db = AppDatabase.inMemory();
    service = MediaService(
      repository: DriftMediaRepository(db),
      fileStore: MediaFileStore(root: Directory('${tempDir.path}/media')),
      readSettings: () async =>
          const AppSettings(mediaRemoteDownloadsEnabled: false),
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  MediaAsset asset(MediaDownloadState state) => MediaAsset(
    id: 'a1',
    createdAt: DateTime.utc(2026, 10, 1),
    updatedAt: DateTime.utc(2026, 10, 1),
    contentHash: 'absent',
    byteSize: 10,
    mimeType: 'image/png',
    width: 8,
    height: 8,
    downloadState: state,
  );

  Future<void> pump(
    WidgetTester tester,
    MediaAsset a,
    double size, {
    double textScale = 1,
  }) async {
    // Built in real time: the bytes lookup reads the disk, which never
    // completes inside the test's fake async zone.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [mediaServiceProvider.overrideWith((ref) => service)],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(
              body: Center(
                child: MediaImage(asset: a, width: size, height: size),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  for (final (state, label) in [
    (MediaDownloadState.missing, 'Download disabled'),
    (MediaDownloadState.failed, 'Retry'),
  ]) {
    testWidgets('BUG-216: a 40 px "$label" placeholder fits', (tester) async {
      await pump(tester, asset(state), 40);
      expect(tester.takeException(), isNull);
      expect(find.text(label), findsNothing);
      expect(find.byTooltip(label), findsOneWidget);
    });

    testWidgets('a "$label" placeholder fits with larger text too', (
      tester,
    ) async {
      await pump(tester, asset(state), 72, textScale: 1.3);
      expect(tester.takeException(), isNull);
      expect(find.byTooltip(label), findsOneWidget);
    });

    testWidgets('a large "$label" placeholder keeps its label', (tester) async {
      await pump(tester, asset(state), 120);
      expect(tester.takeException(), isNull);
      expect(find.text(label), findsOneWidget);
    });
  }
}
