// Inspecting a card's image opens the viewer over the whole session — and
// until this guard existed, space still flipped the card behind it, and cram's
// arrows still graded it while the viewer was using those same arrows to turn
// its pages.
//
// The reason neither of the session's usual "am I the page on screen" tests
// caught it is what this file has to reproduce: the pages live inside a shell
// branch's own navigator, while the viewer is pushed on the root one. The
// branch route therefore stays current, and the viewer being non-opaque leaves
// its TickerMode on. Hence the nested [Navigator] in the harness — without it
// the viewer would cover the session's own route and the bug would not
// reproduce at all.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_lightbox.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/study/study_card_face.dart';
import 'package:voyager/features/study/study_keyboard_shortcuts.dart';

Uint8List _png() {
  final image = img.Image(width: 40, height: 30, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(200, 30, 60));
  return img.encodePng(image);
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late MediaFileStore fileStore;
  late MediaService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_lightbox_keys');
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

  /// Bounded pumps: a resolving image paints a progress indicator, which never
  /// settles.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('space does not flip the card behind the image viewer', (
    tester,
  ) async {
    late MediaAsset asset;
    await tester.runAsync(() async {
      asset = await service.ingestBytes(_png());
    });

    var flips = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaServiceProvider.overrideWith((ref) => service),
          mediaFileStoreProvider.overrideWithValue(fileStore),
        ],
        child: MaterialApp(
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => StudyKeyboardShortcuts(
                onSpace: () => flips++,
                showingBack: false,
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 300,
                      height: 400,
                      child: StudyCardFace(text: '', images: [asset]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);

    // The session is live: space flips.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(flips, 1);

    await tester.tap(find.byType(StudyCardImageCarousel));
    await settle(tester);
    expect(mediaLightboxIsOpen, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(flips, 1, reason: 'the viewer owns the keyboard while it is up');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(mediaLightboxIsOpen, isFalse);

    // …and hands it straight back.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(flips, 2);
  });
}
